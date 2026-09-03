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

    private let adapters: [ProviderID: any ProviderAdapter]
    private let context: CollectionContext
    private let snapshotStore: InMemorySnapshotStore
    private let interval: Duration
    private let concurrencyLimit: Int

    private var states: [ProviderID: CollectionState]
    private var nextAllowedRefresh: [ProviderID: Date] = [:]
    private var inFlight: [ProviderID: Task<ProviderSnapshot, Error>] = [:]
    private var refreshReservations = Set<ProviderID>()
    private var generation: UInt = 0
    private var acceptingRefreshes = true
    private var scheduleTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<[ProviderID: CollectionState]>.Continuation] = [:]

    public init(
        adapters: [any ProviderAdapter],
        context: CollectionContext,
        snapshotStore: InMemorySnapshotStore = InMemorySnapshotStore(),
        interval: Duration = RefreshCoordinator.defaultInterval,
        concurrencyLimit: Int = 2
    ) {
        precondition(concurrencyLimit > 0)
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        self.context = context
        self.snapshotStore = snapshotStore
        self.interval = interval
        self.concurrencyLimit = concurrencyLimit
        self.states = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, .neverLoaded) })
    }

    deinit {
        scheduleTask?.cancel()
        for task in inFlight.values { task.cancel() }
        for continuation in continuations.values { continuation.finish() }
    }

    public func start() {
        guard scheduleTask == nil else { return }
        acceptingRefreshes = true
        scheduleTask = Task { [weak self, interval] in
            guard let self else { return }
            await self.context.diagnostics.record(
                DiagnosticEvent(level: .info, category: "schedule", code: "schedule.started")
            )
            var nextDeadline = await self.context.clock.monotonicNow()
            while !Task.isCancelled {
                await self.context.diagnostics.record(
                    DiagnosticEvent(level: .debug, category: "schedule", code: "schedule.cycle")
                )
                await self.refreshAll()
                nextDeadline += interval
                let current = await self.context.clock.monotonicNow()
                if nextDeadline <= current {
                    nextDeadline = current + interval
                }
                do {
                    try await self.context.clock.sleep(for: nextDeadline - current)
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
        for task in inFlight.values { task.cancel() }
        for task in inFlight.values { _ = try? await task.value }
        inFlight.removeAll()
        await schedule?.value
    }

    public func currentStates() -> [ProviderID: CollectionState] {
        states
    }

    public func state(for providerID: ProviderID) -> CollectionState {
        states[providerID] ?? .neverLoaded
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

    public func refreshAll() async {
        guard acceptingRefreshes else { return }
        let providerIDs = ProviderID.allCases.filter { adapters[$0] != nil }
        var start = 0
        while start < providerIDs.count {
            let end = min(start + concurrencyLimit, providerIDs.count)
            let batch = Array(providerIDs[start..<end])
            await withTaskGroup(of: Void.self) { group in
                for providerID in batch {
                    group.addTask { [weak self] in
                        await self?.refresh(providerID)
                    }
                }
            }
            start = end
        }
    }

    public func refresh(_ providerID: ProviderID) async {
        guard acceptingRefreshes else { return }
        guard let adapter = adapters[providerID] else { return }

        if refreshReservations.contains(providerID) {
            if let existing = inFlight[providerID] {
                _ = try? await existing.value
            }
            return
        }
        refreshReservations.insert(providerID)
        defer { refreshReservations.remove(providerID) }
        let operationGeneration = generation

        let now = await context.clock.now()
        if let allowedAt = nextAllowedRefresh[providerID], now < allowedAt {
            return
        }
        let startedAt = await context.clock.monotonicNow()
        let correlationID = UUID()

        let previous: ProviderSnapshot?
        if let current = states[providerID]?.snapshot {
            previous = current
        } else {
            previous = await snapshotStore.snapshot(for: providerID)
        }
        states[providerID] = .refreshing(previous: previous)
        emitStates()

        let providerContext = self.context.scoped(to: providerID, correlationID: correlationID)
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
        await context.diagnostics.record(
            DiagnosticEvent(
                level: .info,
                category: "collection",
                code: "collection.started",
                providerID: providerID,
                correlationID: correlationID
            )
        )

        do {
            let snapshot = try await task.value
            guard
                snapshot.providerID == providerID,
                snapshot.source == adapter.sourceDescriptor
            else {
                throw CollectionError(
                    kind: .malformedResponse,
                    diagnosticCode: "collection.snapshot-identity-mismatch"
                )
            }
            guard operationGeneration == generation else { return }
            await snapshotStore.store(snapshot)
            guard operationGeneration == generation else { return }
            states[providerID] = .fresh(snapshot)
            nextAllowedRefresh.removeValue(forKey: providerID)
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
                failure: CollectionError(kind: .cancelled, diagnosticCode: "collection.cancelled"),
                duration: await elapsed(since: startedAt),
                correlationID: correlationID
            )
        } catch let failure as CollectionError {
            guard operationGeneration == generation else { return }
            await transitionToFailure(
                providerID: providerID,
                previous: previous,
                failure: failure,
                duration: await elapsed(since: startedAt),
                correlationID: correlationID
            )
        } catch {
            guard operationGeneration == generation else { return }
            await transitionToFailure(
                providerID: providerID,
                previous: previous,
                failure: CollectionError(kind: .sourceUnavailable, diagnosticCode: "collection.untyped-error"),
                duration: await elapsed(since: startedAt),
                correlationID: correlationID
            )
        }

        guard operationGeneration == generation else { return }
        inFlight.removeValue(forKey: providerID)
        emitStates()
    }

    private func transitionToFailure(
        providerID: ProviderID,
        previous: ProviderSnapshot?,
        failure: CollectionError,
        duration: Duration,
        correlationID: UUID
    ) async {
        if let retryAfter = failure.retryAfter {
            nextAllowedRefresh[providerID] = retryAfter
        }
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

extension CollectionContext {
    func scoped(to providerID: ProviderID, correlationID: UUID = UUID()) -> CollectionContext {
        CollectionContext(
            network: ProviderScopedNetworkClient(providerID: providerID, base: network),
            credentials: ProviderScopedCredentialStore(providerID: providerID, base: credentials),
            externalSessions: ProviderScopedExternalSessionReader(providerID: providerID, base: externalSessions),
            sqlite: ProviderScopedSQLiteReader(providerID: providerID, base: sqlite),
            codexAccount: ProviderScopedCodexAccountReader(providerID: providerID, base: codexAccount),
            doubaoPlan: ProviderScopedDoubaoPlanReader(providerID: providerID, base: doubaoPlan),
            clock: clock,
            diagnostics: NoDiagnostics(),
            correlationID: correlationID
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

private struct ProviderScopedExternalSessionReader: ExternalSessionReader {
    let providerID: ProviderID
    let base: any ExternalSessionReader

    func exists(_ request: ExternalFileRequest) async -> Bool {
        guard isAllowed(request) else { return false }
        return await base.exists(request)
    }

    func read(_ request: ExternalFileRequest) async throws -> Data {
        guard isAllowed(request) else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "capability.external-session.denied"
            )
        }
        return try await base.read(request)
    }

    private func isAllowed(_ request: ExternalFileRequest) -> Bool {
        guard request.providerID == providerID, request.root == .home else { return false }
        switch providerID {
        case .claude:
            return request.relativePath == ".claude.json"
                && request.maximumBytes == 32 * 1024 * 1024
        case .grok:
            return request.relativePath == ".grok/auth.json"
                && request.maximumBytes == 64 * 1024
        default:
            return false
        }
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
            keys == ["cursorAuth/accessToken"]
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

    func readRateLimits() async throws -> Data {
        guard providerID == .codex else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "capability.codex-account.denied"
            )
        }
        return try await base.readRateLimits()
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

