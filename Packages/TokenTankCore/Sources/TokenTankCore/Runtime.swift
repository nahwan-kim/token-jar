import Foundation
import TokenTankDomain

public actor InMemorySnapshotStore {
    private var snapshots: [ProviderID: ProviderSnapshot] = [:]

    public init() {}

    public func snapshot(for providerID: ProviderID) -> ProviderSnapshot? {
        snapshots[providerID]
    }

    public func store(_ snapshot: ProviderSnapshot) {
        snapshots[snapshot.providerID] = snapshot
    }

    public func removeAll() {
        snapshots.removeAll(keepingCapacity: false)
    }
}

public protocol PreferencesStore: Sendable {
    func load() async -> UserPreferences
    func save(_ preferences: UserPreferences) async throws
}

public actor UserDefaultsPreferencesStore: PreferencesStore {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(suiteName: String = "com.tokentank.preferences", key: String = "user-preferences-v1") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = key
    }

    public func load() -> UserPreferences {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? decoder.decode(UserPreferences.self, from: data)
        else { return UserPreferences() }
        return decoded.normalized()
    }

    public func save(_ preferences: UserPreferences) throws {
        let normalized = preferences.normalized()
        defaults.set(try encoder.encode(normalized), forKey: key)
    }
}

public actor RefreshCoordinator {
    public static let defaultInterval: Duration = .seconds(300)
    /// First retry after a failure; consecutive failures double it up to the success interval.
    public static let retryInterval: Duration = .seconds(60)
    /// A manual refresh within this window of the provider's last collection start reuses the
    /// current state instead of starting another collection.
    public static let manualRefreshFloor: Duration = .seconds(30)
    /// How often the scheduler re-evaluates due providers. Wall-clock based, so a sleep that
    /// outlasts a due time is noticed on the first tick after wake.
    public static let tickInterval: Duration = .seconds(15)
    /// After wake, collection waits for a satisfied network path for at most this long.
    public static let wakeNetworkGrace: Duration = .seconds(30)
    /// Opening a usage surface refreshes providers whose last success is older than this.
    public static let surfaceStaleAge: Duration = .seconds(60)

    private let adapters: [ProviderID: any ProviderAdapter]
    private let providerOrder: [ProviderID]
    private let context: CollectionContext
    private let snapshotStore: InMemorySnapshotStore
    private let interval: Duration
    private let retryBase: Duration
    private let tick: Duration
    private let concurrencyLimit: Int
    private let activity: (any SystemActivityMonitoring)?

    private var states: [ProviderID: CollectionState]
    private var nextAllowedRefresh: [ProviderID: Date] = [:]
    private var nextDueAt: [ProviderID: Date] = [:]
    private var consecutiveFailures: [ProviderID: Int] = [:]
    private var lastStartedAt: [ProviderID: Date] = [:]
    private var lastSucceededAt: [ProviderID: Date] = [:]
    private var queued: Set<ProviderID> = []
    private var runningPoolCollections = 0
    private var slotWaiters: [CheckedContinuation<Bool, Never>] = []
    private var isAsleep = false
    private var networkSatisfied = true
    private var wakeGateDeadline: Date?
    private var networkRestoredAt: Date?
    private var inFlight: [ProviderID: Task<ProviderSnapshot, Error>] = [:]
    private var activeOperations: [ProviderID: CollectionOperation] = [:]
    private var operationWaiters: [ProviderID: [CheckedContinuation<Void, Never>]] = [:]
    private var generation: UInt = 0
    private var acceptingRefreshes = true
    private var scheduleTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var triggeredRuns: [UUID: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncStream<[ProviderID: CollectionState]>.Continuation] = [:]

    private enum CollectionOperation: Equatable {
        case ordinary
        case claudeRepair
    }

    public init(
        adapters: [any ProviderAdapter],
        context: CollectionContext,
        snapshotStore: InMemorySnapshotStore = InMemorySnapshotStore(),
        interval: Duration = RefreshCoordinator.defaultInterval,
        retryInterval: Duration = RefreshCoordinator.retryInterval,
        tickInterval: Duration = RefreshCoordinator.tickInterval,
        concurrencyLimit: Int = 2,
        activity: (any SystemActivityMonitoring)? = nil
    ) {
        precondition(concurrencyLimit > 0)
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        self.providerOrder = ProviderID.allCases.filter { id in adapters.contains { $0.id == id } }
        self.context = context
        self.snapshotStore = snapshotStore
        self.interval = interval
        self.retryBase = retryInterval
        self.tick = tickInterval
        self.concurrencyLimit = concurrencyLimit
        self.activity = activity
        self.states = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, .neverLoaded) })
    }

    deinit {
        scheduleTask?.cancel()
        activityTask?.cancel()
        for task in triggeredRuns.values { task.cancel() }
        for task in inFlight.values { task.cancel() }
        for waiter in slotWaiters { waiter.resume(returning: false) }
        for continuation in continuations.values { continuation.finish() }
    }

    public func start() {
        guard scheduleTask == nil else { return }
        acceptingRefreshes = true
        if let activity, activityTask == nil {
            activityTask = Task { [weak self] in
                for await event in activity.events() {
                    guard let self, !Task.isCancelled else { break }
                    await self.handle(event)
                }
            }
        }
        scheduleTask = Task { [weak self] in
            guard let self else { return }
            await self.context.diagnostics.record(
                DiagnosticEvent(level: .info, category: "schedule", code: "schedule.started")
            )
            while !Task.isCancelled {
                await self.triggerDueRun()
                let delay = await self.nextTickDelay()
                do {
                    try await self.context.clock.sleep(for: delay)
                } catch {
                    break
                }
            }
            await self.context.diagnostics.record(
                DiagnosticEvent(level: .info, category: "schedule", code: "schedule.stopped")
            )
        }
    }

    public func stop() async {
        acceptingRefreshes = false
        generation &+= 1
        let schedule = scheduleTask
        schedule?.cancel()
        scheduleTask = nil
        let activityObserver = activityTask
        activityObserver?.cancel()
        activityTask = nil
        let waiters = slotWaiters
        slotWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: false) }
        let runs = Array(triggeredRuns.values)
        triggeredRuns.removeAll()
        for run in runs { run.cancel() }
        for task in inFlight.values { task.cancel() }
        for task in inFlight.values { _ = try? await task.value }
        inFlight.removeAll()
        for run in runs { await run.value }
        await schedule?.value
    }

    public func currentStates() -> [ProviderID: CollectionState] {
        states
    }

    public func state(for providerID: ProviderID) -> CollectionState {
        states[providerID] ?? .neverLoaded
    }

    /// When the provider is next collected by the scheduler; `nil` means immediately.
    public func nextDue(for providerID: ProviderID) -> Date? {
        nextDueAt[providerID]
    }

    public func stateStream() -> AsyncStream<[ProviderID: CollectionState]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [ProviderID: CollectionState].self)
        continuations[id] = continuation
        continuation.yield(states)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    /// Collects every provider whose next check is due, at most `concurrencyLimit` at a time.
    /// Returns when the collections it started have finished. Nothing runs while the system is
    /// asleep, or right after wake until the network path is satisfied or the grace expires.
    public func refreshDue() async {
        guard acceptingRefreshes, !isAsleep else { return }
        let now = await context.clock.now()
        guard acceptingRefreshes, !isAsleep else { return }
        if let deadline = wakeGateDeadline {
            guard now >= deadline else { return }
            wakeGateDeadline = nil
        }
        let due = providerOrder.filter { providerID in
            activeOperations[providerID] == nil
                && !queued.contains(providerID)
                && (nextDueAt[providerID] ?? .distantPast) <= now
        }
        guard !due.isEmpty else { return }
        await context.diagnostics.record(
            DiagnosticEvent(level: .debug, category: "schedule", code: "schedule.cycle")
        )
        await runPool(due, userInitiated: false)
    }

    /// A usage window or menu opened: providers whose last success is older than
    /// `surfaceStaleAge` become due now, still subject to the manual floor and Retry-After.
    public func refreshStaleProviders(olderThan age: Duration = RefreshCoordinator.surfaceStaleAge) async {
        guard acceptingRefreshes else { return }
        let now = await context.clock.now()
        guard acceptingRefreshes else { return }
        for providerID in providerOrder where activeOperations[providerID] == nil && !queued.contains(providerID) {
            if let succeeded = lastSucceededAt[providerID], now.timeIntervalSince(succeeded) <= age.seconds {
                continue
            }
            if isWithinManualFloor(providerID, now: now) { continue }
            if let allowedAt = nextAllowedRefresh[providerID], now < allowedAt { continue }
            if (nextDueAt[providerID] ?? .distantPast) > now {
                nextDueAt[providerID] = now
            }
        }
        await refreshDue()
    }

    public func handle(_ event: SystemActivityEvent) async {
        let now = await context.clock.now()
        switch event {
        case .willSleep:
            isAsleep = true
            await record("activity.will-sleep")
        case .didWake:
            isAsleep = false
            wakeGateDeadline = now.addingTimeInterval(Self.wakeNetworkGrace.seconds)
            await record("activity.did-wake")
        case let .networkPathChanged(isSatisfied):
            let restored = isSatisfied && !networkSatisfied
            networkSatisfied = isSatisfied
            await record(isSatisfied ? "activity.network-satisfied" : "activity.network-unsatisfied")
            guard isSatisfied else { return }
            let openedWakeGate = wakeGateDeadline != nil
            wakeGateDeadline = nil
            if restored {
                networkRestoredAt = now
                for providerID in providerOrder where stateFailedTransiently(providerID) {
                    nextDueAt[providerID] = now
                }
            }
            if restored || openedWakeGate {
                triggerDueRun()
            }
        }
    }

    public func refreshAll(userInitiated: Bool = false) async {
        guard acceptingRefreshes else { return }
        let now = await context.clock.now()
        guard acceptingRefreshes else { return }
        let providerIDs = providerOrder.filter { providerID in
            guard !queued.contains(providerID) else { return false }
            guard userInitiated, activeOperations[providerID] == nil else { return true }
            return !isWithinManualFloor(providerID, now: now)
        }
        await runPool(providerIDs, userInitiated: userInitiated)
    }

    public func repairClaudeConnection() async {
        guard acceptingRefreshes, adapters[.claude] != nil else { return }
        let requestGeneration = generation
        var waitedForOrdinaryCollection = false

        while let activeOperation = activeOperations[.claude] {
            await waitForOperation(.claude)
            guard
                !Task.isCancelled,
                acceptingRefreshes,
                requestGeneration == generation
            else { return }
            if activeOperation == .claudeRepair { return }
            waitedForOrdinaryCollection = true
        }

        guard
            !Task.isCancelled,
            acceptingRefreshes,
            requestGeneration == generation,
            !waitedForOrdinaryCollection || stateRequiresClaudeRepair
        else { return }

        activeOperations[.claude] = .claudeRepair
        await collectReserved(.claude, operation: .claudeRepair, isUserInitiated: true)
    }

    public func refresh(_ providerID: ProviderID, userInitiated: Bool = false) async {
        await refresh(providerID, userInitiated: userInitiated, enforcesManualFloor: userInitiated)
    }

    private func refresh(_ providerID: ProviderID, userInitiated: Bool, enforcesManualFloor: Bool) async {
        guard acceptingRefreshes, adapters[providerID] != nil else { return }
        if activeOperations[providerID] != nil {
            await waitForOperation(providerID)
            return
        }
        if enforcesManualFloor {
            let now = await context.clock.now()
            guard acceptingRefreshes else { return }
            if activeOperations[providerID] != nil {
                await waitForOperation(providerID)
                return
            }
            if isWithinManualFloor(providerID, now: now) {
                await context.diagnostics.record(
                    DiagnosticEvent(
                        level: .debug,
                        category: "collection",
                        code: "collection.manual-floor",
                        providerID: providerID
                    )
                )
                return
            }
        }
        activeOperations[providerID] = .ordinary
        await collectReserved(providerID, operation: .ordinary, isUserInitiated: userInitiated)
    }

    private func isWithinManualFloor(_ providerID: ProviderID, now: Date) -> Bool {
        guard let started = lastStartedAt[providerID] else { return false }
        return now.timeIntervalSince(started) < Self.manualRefreshFloor.seconds
    }

    /// Starts providers in order as pool slots free up: one slow provider holds one slot and
    /// never delays the start of providers behind it beyond the concurrency limit.
    private func runPool(_ providerIDs: [ProviderID], userInitiated: Bool) async {
        guard !providerIDs.isEmpty else { return }
        for providerID in providerIDs { queued.insert(providerID) }
        await withTaskGroup(of: Void.self) { group in
            for (index, providerID) in providerIDs.enumerated() {
                guard await acquirePoolSlot() else {
                    for remaining in providerIDs[index...] { queued.remove(remaining) }
                    break
                }
                queued.remove(providerID)
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.refresh(providerID, userInitiated: userInitiated, enforcesManualFloor: false)
                    await self.releasePoolSlot()
                }
            }
        }
    }

    private func acquirePoolSlot() async -> Bool {
        guard acceptingRefreshes else { return false }
        if runningPoolCollections < concurrencyLimit {
            runningPoolCollections += 1
            return true
        }
        return await withCheckedContinuation { slotWaiters.append($0) }
    }

    private func releasePoolSlot() {
        if !slotWaiters.isEmpty, acceptingRefreshes {
            // Hand the slot directly to the next waiting provider.
            slotWaiters.removeFirst().resume(returning: true)
        } else {
            runningPoolCollections = max(0, runningPoolCollections - 1)
        }
    }

    private func triggerDueRun() {
        guard acceptingRefreshes, !isAsleep else { return }
        let id = UUID()
        triggeredRuns[id] = Task { [weak self] in
            await self?.refreshDue()
            await self?.finishTriggeredRun(id)
        }
    }

    /// Awaits collections started by system events or the scheduler loop.
    public func waitForScheduledRuns() async {
        while let run = triggeredRuns.values.first {
            await run.value
        }
    }

    private func finishTriggeredRun(_ id: UUID) {
        triggeredRuns.removeValue(forKey: id)
    }

    private func nextTickDelay() async -> Duration {
        let now = await context.clock.now()
        let earliest = providerOrder
            .filter { activeOperations[$0] == nil && !queued.contains($0) }
            .map { nextDueAt[$0] ?? .distantPast }
            .min()
        guard let earliest, earliest > now else { return tick }
        let untilDue = Duration.milliseconds(Int64((earliest.timeIntervalSince(now) * 1_000).rounded(.up)))
        return min(tick, untilDue)
    }

    private func record(_ code: String) async {
        await context.diagnostics.record(DiagnosticEvent(level: .info, category: "activity", code: code))
    }

    private func stateFailedTransiently(_ providerID: ProviderID) -> Bool {
        switch states[providerID] {
        case let .stale(_, failure, _):
            return Self.isNetworkTransient(failure.kind)
        case let .fresh(snapshot):
            return snapshot.accounts.contains { $0.failure.map { Self.isNetworkTransient($0.kind) } ?? false }
        default:
            return false
        }
    }

    private static func isNetworkTransient(_ kind: CollectionErrorKind) -> Bool {
        kind == .transientNetwork || kind == .offline || kind == .sourceUnavailable
    }

    /// Delay before the next scheduled check after a collection outcome.
    /// Success waits the full interval. Rate limiting honors the larger of Retry-After and the
    /// retry interval. An authentication action is re-read quietly every retry interval. Other
    /// failures back off exponentially from the retry interval up to the success interval.
    static func retryDelay(
        after failure: CollectionError,
        consecutiveFailures: Int,
        now: Date,
        retryInterval: Duration,
        maximum: Duration
    ) -> TimeInterval {
        let base = retryInterval.seconds
        let backoff = min(maximum.seconds, base * pow(2, Double(max(0, consecutiveFailures - 1))))
        switch failure.kind {
        case .rateLimited:
            let requested = failure.retryAfter.map { $0.timeIntervalSince(now) } ?? backoff
            return max(base, requested)
        case let kind where kind.requiresAuthenticationAction:
            return base
        default:
            return max(base, backoff)
        }
    }

    private func scheduleAfterCollection(
        _ providerID: ProviderID,
        startedAt: Date,
        failure: CollectionError?,
        accountFailures: [CollectionError]
    ) async {
        let now = await context.clock.now()
        let retryable = failure.map { [$0] } ?? accountFailures.filter { !$0.kind.requiresAuthenticationAction }
        guard !retryable.isEmpty else {
            consecutiveFailures[providerID] = 0
            nextDueAt[providerID] = now.addingTimeInterval(interval.seconds)
            return
        }
        let count = (consecutiveFailures[providerID] ?? 0) + 1
        consecutiveFailures[providerID] = count
        let delays = retryable.map {
            Self.retryDelay(
                after: $0,
                consecutiveFailures: count,
                now: now,
                retryInterval: retryBase,
                maximum: interval
            )
        }
        // A rate-limited account must not be asked again before it said to.
        let delay = retryable.contains { $0.kind == .rateLimited } ? delays.max()! : delays.min()!
        var due = now.addingTimeInterval(delay)
        if let restoredAt = networkRestoredAt, restoredAt >= startedAt,
           retryable.contains(where: { Self.isNetworkTransient($0.kind) }),
           !retryable.contains(where: { $0.kind == .rateLimited }) {
            // The path dropped and came back while this collection was running.
            due = now
        }
        nextDueAt[providerID] = due
    }

    private func collectReserved(
        _ providerID: ProviderID,
        operation: CollectionOperation,
        isUserInitiated: Bool
    ) async {
        defer { finishOperation(providerID) }
        guard !Task.isCancelled, acceptingRefreshes, let adapter = adapters[providerID] else { return }
        let operationGeneration = generation

        let now = await context.clock.now()
        guard !Task.isCancelled, acceptingRefreshes, operationGeneration == generation else { return }
        if let allowedAt = nextAllowedRefresh[providerID], now < allowedAt {
            if (nextDueAt[providerID] ?? .distantPast) < allowedAt {
                nextDueAt[providerID] = allowedAt
            }
            return
        }
        lastStartedAt[providerID] = now
        let startedAt = await context.clock.monotonicNow()
        let correlationID = UUID()

        let previous: ProviderSnapshot?
        if let current = states[providerID]?.snapshot {
            previous = current
        } else {
            previous = await snapshotStore.snapshot(for: providerID)
        }
        guard !Task.isCancelled, acceptingRefreshes, operationGeneration == generation else { return }
        states[providerID] = .refreshing(previous: previous)
        emitStates()

        let allowsClaudeRecovery = providerID == .claude
        let providerContext = self.context.scoped(
            to: providerID,
            correlationID: correlationID,
            isUserInitiated: isUserInitiated,
            allowsClaudeRecovery: allowsClaudeRecovery
        )
        let task = Task<ProviderSnapshot, Error> {
            switch await adapter.probeAvailability(context: providerContext) {
            case let .available(source):
                guard source == adapter.sourceDescriptor else {
                    throw CollectionError(
                        kind: .malformedResponse,
                        diagnosticCode: "collection.source-identity-mismatch"
                    )
                }
                return try await adapter.fetchSnapshot(context: providerContext)
            case let .needsConfiguration(code):
                throw CollectionError(kind: .appCredentialMissing, diagnosticCode: code)
            case let .unavailable(failure):
                throw failure
            }
        }
        inFlight[providerID] = task
        do {
            let snapshot = try await withTaskCancellationHandler {
                await context.diagnostics.record(
                    DiagnosticEvent(
                        level: .info,
                        category: "collection",
                        code: "collection.started",
                        providerID: providerID,
                        correlationID: correlationID
                    )
                )
                let result = try await task.value
                if operation == .claudeRepair { try Task.checkCancellation() }
                return result
            } onCancel: {
                // Explicit repair owns its operation, so cancelling it cancels the collection.
                // Ordinary callers retain shared-operation cancellation behavior.
                if operation == .claudeRepair { task.cancel() }
            }
            guard
                snapshot.providerID == providerID,
                snapshot.source == adapter.sourceDescriptor
            else {
                throw CollectionError(
                    kind: .malformedResponse,
                    diagnosticCode: "collection.snapshot-identity-mismatch"
                )
            }
            let mergedSnapshot = snapshot.retainingAccountData(from: previous)
            guard operationGeneration == generation else { return }
            await snapshotStore.store(mergedSnapshot)
            guard operationGeneration == generation else { return }
            states[providerID] = .fresh(mergedSnapshot)
            nextAllowedRefresh.removeValue(forKey: providerID)
            lastSucceededAt[providerID] = await context.clock.now()
            await scheduleAfterCollection(
                providerID,
                startedAt: now,
                failure: nil,
                accountFailures: mergedSnapshot.accounts.compactMap(\.failure)
            )
            await context.diagnostics.record(
                DiagnosticEvent(
                    level: .info,
                    category: "collection",
                    code: "collection.succeeded",
                    providerID: providerID,
                    duration: await elapsed(since: startedAt),
                    correlationID: correlationID
                )
            )
        } catch is CancellationError {
            guard operationGeneration == generation else { return }
            await transitionToFailure(
                providerID: providerID,
                previous: previous,
                startedAt: now,
                failure: CollectionError(kind: .cancelled, diagnosticCode: "collection.cancelled"),
                duration: await elapsed(since: startedAt),
                correlationID: correlationID
            )
        } catch let failure as CollectionError {
            guard operationGeneration == generation else { return }
            await transitionToFailure(
                providerID: providerID,
                previous: previous,
                startedAt: now,
                failure: failure,
                duration: await elapsed(since: startedAt),
                correlationID: correlationID
            )
        } catch {
            guard operationGeneration == generation else { return }
            await transitionToFailure(
                providerID: providerID,
                previous: previous,
                startedAt: now,
                failure: CollectionError(kind: .sourceUnavailable, diagnosticCode: "collection.untyped-error"),
                duration: await elapsed(since: startedAt),
                correlationID: correlationID
            )
        }

        guard operationGeneration == generation else { return }
        inFlight.removeValue(forKey: providerID)
        emitStates()
    }

    private var stateRequiresClaudeRepair: Bool {
        let failure: CollectionError?
        switch states[.claude] {
        case let .stale(_, currentFailure, _), let .authenticationActionRequired(_, currentFailure):
            failure = currentFailure
        case let .fresh(snapshot):
            // A multi-account snapshot can succeed while one account still needs repair.
            return snapshot.accounts.contains { $0.failure?.recoveryAction == .repairClaudeConnection }
        default:
            failure = nil
        }
        return failure?.recoveryAction == .repairClaudeConnection
    }

    private func waitForOperation(_ providerID: ProviderID) async {
        guard activeOperations[providerID] != nil else { return }
        await withCheckedContinuation { continuation in
            operationWaiters[providerID, default: []].append(continuation)
        }
    }

    private func finishOperation(_ providerID: ProviderID) {
        activeOperations.removeValue(forKey: providerID)
        let waiters = operationWaiters.removeValue(forKey: providerID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func transitionToFailure(
        providerID: ProviderID,
        previous: ProviderSnapshot?,
        startedAt: Date,
        failure: CollectionError,
        duration: Duration,
        correlationID: UUID
    ) async {
        if let retryAfter = failure.retryAfter {
            nextAllowedRefresh[providerID] = retryAfter
        }
        await scheduleAfterCollection(providerID, startedAt: startedAt, failure: failure, accountFailures: [])
        if failure.kind.requiresAuthenticationAction {
            states[providerID] = .authenticationActionRequired(snapshot: previous, failure: failure)
        } else {
            states[providerID] = .stale(
                snapshot: previous,
                failure: failure,
                failedAt: await context.clock.now()
            )
        }
        await context.diagnostics.record(
            DiagnosticEvent(
                level: failure.kind == .cancelled ? .debug : .error,
                category: "collection",
                code: failure.diagnosticCode,
                providerID: providerID,
                duration: duration,
                correlationID: correlationID
            )
        )
    }

    private func elapsed(since startedAt: Duration) async -> Duration {
        await context.clock.monotonicNow() - startedAt
    }

    public func clearProcessLifetimeSnapshots() async {
        await stop()
        await snapshotStore.removeAll()
        nextAllowedRefresh.removeAll()
        nextDueAt.removeAll()
        consecutiveFailures.removeAll()
        lastStartedAt.removeAll()
        lastSucceededAt.removeAll()
        queued.removeAll()
        runningPoolCollections = 0
        isAsleep = false
        wakeGateDeadline = nil
        networkRestoredAt = nil
        states = Dictionary(uniqueKeysWithValues: adapters.keys.map { ($0, .neverLoaded) })
        emitStates()
    }

    private func emitStates() {
        for continuation in continuations.values {
            continuation.yield(states)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

extension Duration {
    /// Whole and fractional seconds as a `TimeInterval`.
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

extension CollectionContext {
    func scoped(
        to providerID: ProviderID,
        correlationID: UUID = UUID(),
        isUserInitiated: Bool = false,
        allowsClaudeRecovery: Bool = false
    ) -> CollectionContext {
        CollectionContext(
            network: ProviderScopedNetworkClient(providerID: providerID, base: network),
            credentials: ProviderScopedCredentialStore(providerID: providerID, base: credentials),
            externalSessions: ProviderDeniedExternalSessionReader(),
            sqlite: ProviderScopedSQLiteReader(providerID: providerID, base: sqlite),
            codexAccount: ProviderScopedCodexAccountReader(providerID: providerID, base: codexAccount),
            doubaoPlan: ProviderScopedDoubaoPlanReader(providerID: providerID, base: doubaoPlan),
            grokSession: ProviderScopedGrokSessionProvider(providerID: providerID, base: grokSession),
            claudeSession: ProviderScopedClaudeSessionProvider(
                providerID: providerID,
                base: claudeSession,
                allowsClaudeRecovery: allowsClaudeRecovery
            ),
            clock: clock,
            diagnostics: NoDiagnostics(),
            correlationID: correlationID,
            isUserInitiated: isUserInitiated,
            allowsClaudeRecovery: allowsClaudeRecovery
        )
    }
}

private struct ProviderScopedNetworkClient: NetworkClient {
    let providerID: ProviderID
    let base: any NetworkClient

    func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        guard request.providerID == providerID else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "capability.network.provider-mismatch"
            )
        }
        return try await base.send(request)
    }
}

private actor ProviderScopedGrokSessionProvider: GrokSessionProviding {
    let providerID: ProviderID
    let base: any GrokSessionProviding
    /// The Grok CLI runs at most once per collection.
    private var cliRefreshSpent = false

    init(providerID: ProviderID, base: any GrokSessionProviding) {
        self.providerID = providerID
        self.base = base
    }

    func session(rejectedAccessToken: String?) async throws -> GrokSession {
        guard providerID == .grok else { throw deniedError }
        return try await base.session(rejectedAccessToken: rejectedAccessToken)
    }

    func accounts(rejectedAccessTokens: Set<String>, allowsCLIRefresh: Bool) async throws -> GrokAccountsRead {
        guard providerID == .grok else { throw deniedError }
        let read = try await base.accounts(
            rejectedAccessTokens: rejectedAccessTokens,
            allowsCLIRefresh: allowsCLIRefresh && !cliRefreshSpent
        )
        if read.ranCLIRefresh { cliRefreshSpent = true }
        return read
    }

    private var deniedError: CollectionError {
        CollectionError(kind: .sourceUnavailable, diagnosticCode: "capability.grok-session.denied")
    }
}

private actor ProviderScopedClaudeSessionProvider: ClaudeSessionProviding {
    let providerID: ProviderID
    let base: any ClaudeSessionProviding
    let allowsClaudeRecovery: Bool
    /// One interactive recovery (Keychain approval or Claude Code repair) per account per collection.
    private var spentInteractionAccounts: Set<String> = []

    init(
        providerID: ProviderID,
        base: any ClaudeSessionProviding,
        allowsClaudeRecovery: Bool
    ) {
        self.providerID = providerID
        self.base = base
        self.allowsClaudeRecovery = allowsClaudeRecovery
    }

    func session(allowInteraction: Bool, rejectedAccessToken: String?) async throws -> ClaudeSession {
        try await session(
            account: ClaudeAccount.defaultSourceID,
            allowInteraction: allowInteraction,
            rejectedAccessToken: rejectedAccessToken
        )
    }

    func accounts() async throws -> [ClaudeAccount] {
        guard providerID == .claude else { throw deniedError }
        return try await base.accounts()
    }

    func session(
        account sourceID: String,
        allowInteraction: Bool,
        rejectedAccessToken: String?
    ) async throws -> ClaudeSession {
        guard providerID == .claude else { throw deniedError }
        if allowInteraction {
            guard allowsClaudeRecovery, spentInteractionAccounts.insert(sourceID).inserted else {
                throw deniedError
            }
        }
        return try await base.session(
            account: sourceID,
            allowInteraction: allowInteraction,
            rejectedAccessToken: rejectedAccessToken
        )
    }

    private var deniedError: CollectionError {
        CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "capability.claude-session.denied"
        )
    }
}

private struct ProviderScopedCredentialStore: AppCredentialStore {
    let providerID: ProviderID
    let base: any AppCredentialStore

    func read(_ id: CredentialID) async throws -> String? {
        guard id.providerID == providerID, Self.allowedNames(for: providerID).contains(id.name) else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "capability.credentials.read-denied"
            )
        }
        return try await base.read(id)
}

    func write(_ value: String, for id: CredentialID) async throws {
        throw CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "capability.credentials.write-denied"
        )
    }

    func delete(_ id: CredentialID) async throws {
        throw CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "capability.credentials.delete-denied"
        )
    }

    private static func allowedNames(for providerID: ProviderID) -> Set<String> {
        switch providerID {
        case .codex, .claude, .grok, .cursor, .doubao: []
        }
    }
}

private struct ProviderDeniedExternalSessionReader: ExternalSessionReader {
    func exists(_ request: ExternalFileRequest) async -> Bool { false }

    func read(_ request: ExternalFileRequest) async throws -> Data {
        throw CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "capability.external-session.denied"
        )
    }
}

private struct ProviderScopedSQLiteReader: ReadOnlySQLiteReader {
    let providerID: ProviderID
    let base: any ReadOnlySQLiteReader

    func values(
        in request: ExternalFileRequest,
        table: String,
        keyColumn: String,
        valueColumn: String,
        keys: [String]
    ) async throws -> [String: String] {
        guard
            providerID == .cursor,
            request.providerID == providerID,
            request.root == .home,
            request.relativePath == "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            request.maximumBytes == 64 * 1024 * 1024,
            table == "ItemTable",
            keyColumn == "key",
            valueColumn == "value",
            keys == ["cursorAuth/accessToken", "cursorAuth/cachedEmail"]
        else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "capability.sqlite.request-denied"
            )
        }
        return try await base.values(
            in: request,
            table: table,
            keyColumn: keyColumn,
            valueColumn: valueColumn,
            keys: keys
        )
    }
}

private struct ProviderScopedCodexAccountReader: CodexAccountUsageReader {
    let providerID: ProviderID
    let base: any CodexAccountUsageReader

    func readAccounts() async throws -> [CodexAccountRead] {
        guard providerID == .codex else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "capability.codex-account.denied"
            )
        }
        return try await base.readAccounts()
    }
}
private struct ProviderScopedDoubaoPlanReader: DoubaoPlanUsageReader {
    let providerID: ProviderID
    let base: any DoubaoPlanUsageReader

    func readPlanUsage() async throws -> Data {
        guard providerID == .doubao else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "capability.doubao-plan.denied"
            )
        }
        return try await base.readPlanUsage()
    }
}

