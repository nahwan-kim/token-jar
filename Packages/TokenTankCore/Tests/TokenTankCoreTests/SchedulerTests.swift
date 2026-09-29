import Foundation
import Testing
@testable import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Result-based refresh scheduling", .serialized)
struct SchedulerTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("failure retries after 60 seconds and success waits five minutes")
    func failureRetriesSoonSuccessWaitsInterval() async {
        let clock = ManualClock(now: Self.start)
        let network = QueueNetworkClient(results: [])
        let adapter = RequestCountingAdapter(id: .codex, outcomes: [
            .failure(CollectionError(kind: .transientNetwork, diagnosticCode: "test.transient")),
            .success(()),
            .success(()),
        ])
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(network: network, clock: clock)
        )

        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 1)
        #expect(await coordinator.nextDue(for: .codex) == Self.start.addingTimeInterval(60))

        await clock.advance(by: .seconds(59))
        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 1)

        await clock.advance(by: .seconds(1))
        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 2)
        guard case .fresh = await coordinator.state(for: .codex) else {
            Issue.record("Expected the retry to succeed")
            return
        }

        await clock.advance(by: .seconds(299))
        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 2)

        await clock.advance(by: .seconds(1))
        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 3)
    }

    @Test("429 waits for the larger of Retry-After and 60 seconds")
    func rateLimitHonorsRetryAfter() async {
        let clock = ManualClock(now: Self.start)
        let longWait = RequestCountingAdapter(id: .codex, outcomes: [
            .failure(CollectionError(
                kind: .rateLimited,
                diagnosticCode: "test.429.long",
                retryAfter: Self.start.addingTimeInterval(120)
            )),
            .success(()),
        ])
        let shortWait = RequestCountingAdapter(id: .claude, outcomes: [
            .failure(CollectionError(
                kind: .rateLimited,
                diagnosticCode: "test.429.short",
                retryAfter: Self.start.addingTimeInterval(10)
            )),
            .success(()),
        ])
        let coordinator = RefreshCoordinator(
            adapters: [longWait, shortWait],
            context: TestContextFactory.make(clock: clock)
        )

        await coordinator.refreshDue()
        #expect(await coordinator.nextDue(for: .codex) == Self.start.addingTimeInterval(120))
        #expect(await coordinator.nextDue(for: .claude) == Self.start.addingTimeInterval(60))

        await clock.advance(by: .seconds(59))
        await coordinator.refreshDue()
        #expect(await shortWait.requestCount == 1)

        await clock.advance(by: .seconds(1))
        await coordinator.refreshDue()
        #expect(await shortWait.requestCount == 2)
        #expect(await longWait.requestCount == 1)

        await clock.advance(by: .seconds(59))
        await coordinator.refreshDue()
        #expect(await longWait.requestCount == 1)

        await clock.advance(by: .seconds(1))
        await coordinator.refreshDue()
        #expect(await longWait.requestCount == 2)
    }

    @Test("consecutive transient failures back off to five minutes; authentication rereads every minute")
    func backoffAndAuthenticationCadence() async {
        let clock = ManualClock(now: Self.start)
        let transient = CollectionError(kind: .sourceUnavailable, diagnosticCode: "test.unavailable")
        let authentication = CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "test.auth",
            recoveryAction: .signInSourceApp
        )
        let failing = RequestCountingAdapter(id: .codex, outcomes: Array(repeating: .failure(transient), count: 5))
        let signedOut = RequestCountingAdapter(id: .grok, outcomes: Array(repeating: .failure(authentication), count: 3))
        let coordinator = RefreshCoordinator(
            adapters: [failing, signedOut],
            context: TestContextFactory.make(clock: clock)
        )

        var transientDelays: [TimeInterval] = []
        var authenticationDelays: [TimeInterval] = []
        for _ in 0..<5 {
            await coordinator.refreshDue()
            let now = await clock.now()
            if let due = await coordinator.nextDue(for: .codex) {
                transientDelays.append(due.timeIntervalSince(now))
            }
            if authenticationDelays.count < 3, let due = await coordinator.nextDue(for: .grok) {
                authenticationDelays.append(due.timeIntervalSince(now))
            }
            let wait = max(
                (await coordinator.nextDue(for: .codex))?.timeIntervalSince(now) ?? 0,
                0
            )
            await clock.advance(by: .seconds(Int64(wait)))
        }
        #expect(transientDelays == [60, 120, 240, 300, 300])
        #expect(await failing.requestCount == 5)
        #expect(authenticationDelays == [60, 60, 60])
    }

    @Test("nothing is collected while asleep; after wake, collection waits for the network path")
    func sleepAndWakeWaitForNetwork() async {
        let clock = ManualClock(now: Self.start)
        let adapter = RequestCountingAdapter(id: .codex, outcomes: [.success(()), .success(())])
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(clock: clock)
        )

        await coordinator.handle(.willSleep)
        await coordinator.refreshDue()
        await clock.advance(by: .seconds(3_600))
        await coordinator.refreshDue()
        await coordinator.refreshStaleProviders()
        #expect(await adapter.requestCount == 0)

        await coordinator.handle(.didWake)
        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 0)

        await coordinator.handle(.networkPathChanged(isSatisfied: false))
        await coordinator.waitForScheduledRuns()
        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 0)

        await coordinator.handle(.networkPathChanged(isSatisfied: true))
        await coordinator.waitForScheduledRuns()
        #expect(await adapter.requestCount == 1)

        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 1)
    }

    @Test("wake without a path update collects once the grace period ends")
    func wakeGraceExpires() async {
        let clock = ManualClock(now: Self.start)
        let adapter = RequestCountingAdapter(id: .codex, outcomes: [.success(())])
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(clock: clock)
        )

        await coordinator.handle(.didWake)
        await clock.advance(by: .seconds(29))
        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 0)

        await clock.advance(by: .seconds(1))
        await coordinator.refreshDue()
        #expect(await adapter.requestCount == 1)
    }

    @Test("a network path that returns makes transiently stale providers due at once")
    func networkRestoreMakesTransientFailuresDue() async {
        let clock = ManualClock(now: Self.start)
        let offline = RequestCountingAdapter(id: .codex, outcomes: [
            .failure(CollectionError(kind: .offline, diagnosticCode: "test.offline")),
            .success(()),
        ])
        let signedOut = RequestCountingAdapter(id: .grok, outcomes: [
            .failure(CollectionError(kind: .externalSessionMissing, diagnosticCode: "test.missing")),
        ])
        let coordinator = RefreshCoordinator(
            adapters: [offline, signedOut],
            context: TestContextFactory.make(clock: clock)
        )

        await coordinator.handle(.networkPathChanged(isSatisfied: false))
        await coordinator.waitForScheduledRuns()
        await coordinator.refreshDue()
        #expect(await offline.requestCount == 1)
        #expect(await signedOut.requestCount == 1)

        await clock.advance(by: .seconds(5))
        await coordinator.handle(.networkPathChanged(isSatisfied: true))
        await coordinator.waitForScheduledRuns()
        #expect(await offline.requestCount == 2)
        #expect(await signedOut.requestCount == 1)
    }

    @Test("a collection whose path dropped and returned while running is due immediately")
    func pathFlapDuringCollection() async {
        let clock = ManualClock(now: Self.start)
        let adapter = GateAdapter(id: .codex, probe: ConcurrencyProbe())
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(clock: clock)
        )

        let running = Task { await coordinator.refresh(.codex) }
        await adapter.waitForFetches(1)
        await coordinator.handle(.networkPathChanged(isSatisfied: false))
        await coordinator.handle(.networkPathChanged(isSatisfied: true))
        await coordinator.waitForScheduledRuns()
        await adapter.complete(.failure(CollectionError(kind: .transientNetwork, diagnosticCode: "test.lost")))
        await running.value

        #expect(await coordinator.nextDue(for: .codex) == Self.start)
    }

    @Test("manual refreshes within 30 seconds reuse the current state")
    func manualRefreshFloor() async {
        let clock = ManualClock(now: Self.start)
        let network = QueueNetworkClient(results: Array(
            repeating: .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            count: 3
        ))
        let adapter = NetworkRequestAdapter()
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(network: network, clock: clock)
        )

        await coordinator.refresh(.claude, userInitiated: true)
        await clock.advance(by: .seconds(10))
        await coordinator.refresh(.claude, userInitiated: true)
        await coordinator.refreshAll(userInitiated: true)
        await clock.advance(by: .seconds(19))
        await coordinator.refresh(.claude, userInitiated: true)
        #expect(await network.requests.count == 1)
        guard case .fresh = await coordinator.state(for: .claude) else {
            Issue.record("A skipped manual refresh keeps the current state")
            return
        }

        await clock.advance(by: .seconds(1))
        await coordinator.refresh(.claude, userInitiated: true)
        #expect(await network.requests.count == 2)

        await coordinator.repairClaudeConnection()
        #expect(await network.requests.count == 3)
    }

    @Test("opening a usage surface collects only providers older than 60 seconds")
    func surfaceOpenRefreshesOnlyStaleProviders() async {
        let clock = ManualClock(now: Self.start)
        let codex = RequestCountingAdapter(id: .codex, outcomes: Array(repeating: .success(()), count: 3))
        let claude = RequestCountingAdapter(id: .claude, outcomes: Array(repeating: .success(()), count: 3))
        let grok = RequestCountingAdapter(id: .grok, outcomes: [
            .success(()),
            .failure(CollectionError(
                kind: .rateLimited,
                diagnosticCode: "test.429",
                retryAfter: Self.start.addingTimeInterval(600)
            )),
            .success(()),
        ])
        let coordinator = RefreshCoordinator(
            adapters: [codex, claude, grok],
            context: TestContextFactory.make(clock: clock)
        )

        await coordinator.refreshDue()
        await clock.advance(by: .seconds(40))
        await coordinator.refresh(.claude)
        await coordinator.refresh(.grok)
        await clock.advance(by: .seconds(25))

        await coordinator.refreshStaleProviders()
        #expect(await codex.requestCount == 2)
        #expect(await claude.requestCount == 2)
        #expect(await grok.requestCount == 2)

        await coordinator.refreshStaleProviders()
        await clock.advance(by: .seconds(20))
        await coordinator.refreshStaleProviders()
        #expect(await codex.requestCount == 2)
        #expect(await claude.requestCount == 2)
        #expect(await grok.requestCount == 2)
    }

    @Test("a slow provider does not block the start of others")
    func poolStartsNextProviderWhenOneFinishes() async {
        let probe = ConcurrencyProbe()
        let codex = GateAdapter(id: .codex, probe: probe)
        let claude = GateAdapter(id: .claude, probe: probe)
        let grok = GateAdapter(id: .grok, probe: probe)
        let coordinator = RefreshCoordinator(
            adapters: [codex, claude, grok],
            context: TestContextFactory.make(),
            concurrencyLimit: 2
        )

        let run = Task { await coordinator.refreshAll() }
        await codex.waitForFetches(1)
        await claude.waitForFetches(1)
        #expect(await grok.fetchCount == 0)

        await claude.complete(.success(TestContextFactory.snapshot(providerID: .claude)))
        await grok.waitForFetches(1)
        #expect(await codex.completedCount == 0)

        await grok.complete(.success(TestContextFactory.snapshot(providerID: .grok)))
        await codex.complete(.success(TestContextFactory.snapshot(providerID: .codex)))
        await run.value
        #expect(await probe.maximum == 2)
    }

    @Test("the scheduler loop consumes injected sleep, wake, and path events")
    func activityEventsDriveTheLoop() async {
        let clock = ManualClock(now: Self.start)
        let diagnostics = SignalingDiagnostics()
        let activity = ScriptedActivity()
        let adapter = RequestCountingAdapter(id: .codex, outcomes: [.success(()), .success(())])
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(clock: clock, diagnostics: diagnostics),
            activity: activity
        )

        await coordinator.start()
        await diagnostics.wait(for: "collection.succeeded", count: 1)
        await activity.send(.willSleep)
        await diagnostics.wait(for: "activity.will-sleep", count: 1)
        await activity.send(.didWake)
        await diagnostics.wait(for: "activity.did-wake", count: 1)
        await clock.advance(by: .seconds(600))
        await activity.send(.networkPathChanged(isSatisfied: true))
        await diagnostics.wait(for: "collection.succeeded", count: 2)
        await coordinator.stop()
        #expect(await adapter.requestCount == 2)
    }
}

private actor RequestCountingAdapter: ProviderAdapter {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let defaultAbbreviation: String
    nonisolated let sourceDescriptor: ProviderSourceDescriptor
    private var outcomes: [Result<Void, CollectionError>]
    private(set) var requestCount = 0

    init(id: ProviderID, outcomes: [Result<Void, CollectionError>]) {
        self.id = id
        self.displayName = id.displayName
        self.defaultAbbreviation = id.defaultAbbreviation
        self.sourceDescriptor = TestContextFactory.snapshot(providerID: id).source
        self.outcomes = outcomes
    }

    func probeAvailability(context: CollectionContext) -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        requestCount += 1
        guard !outcomes.isEmpty else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "test.outcomes.empty")
        }
        try outcomes.removeFirst().get()
        return TestContextFactory.snapshot(providerID: id, refreshedAt: await context.clock.now())
    }
}

private struct NetworkRequestAdapter: ProviderAdapter {
    let id: ProviderID = .claude
    let displayName = "Claude"
    let defaultAbbreviation = "CLD"
    var sourceDescriptor: ProviderSourceDescriptor { TestContextFactory.snapshot(providerID: .claude).source }

    func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        _ = try await context.network.send(NetworkRequest(
            providerID: .claude,
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!
        ))
        return TestContextFactory.snapshot(providerID: .claude)
    }
}

private actor ConcurrencyProbe {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }
}

private actor GateAdapter: ProviderAdapter {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let defaultAbbreviation: String
    nonisolated let sourceDescriptor: ProviderSourceDescriptor
    private let probe: ConcurrencyProbe
    private var pending: [CheckedContinuation<ProviderSnapshot, Error>] = []
    private var fetchWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var fetchCount = 0
    private(set) var completedCount = 0

    init(id: ProviderID, probe: ConcurrencyProbe) {
        self.id = id
        self.displayName = id.displayName
        self.defaultAbbreviation = id.defaultAbbreviation
        self.sourceDescriptor = TestContextFactory.snapshot(providerID: id).source
        self.probe = probe
    }

    func probeAvailability(context: CollectionContext) -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        await probe.enter()
        fetchCount += 1
        let ready = fetchWaiters.filter { $0.count <= fetchCount }
        fetchWaiters.removeAll { $0.count <= fetchCount }
        for waiter in ready { waiter.continuation.resume() }
        let result: Result<ProviderSnapshot, Error>
        do {
            result = .success(try await withCheckedThrowingContinuation { pending.append($0) })
        } catch {
            result = .failure(error)
        }
        await probe.leave()
        completedCount += 1
        return try result.get()
    }

    func waitForFetches(_ count: Int) async {
        guard fetchCount < count else { return }
        await withCheckedContinuation { fetchWaiters.append((count, $0)) }
    }

    func complete(_ result: Result<ProviderSnapshot, CollectionError>) {
        guard !pending.isEmpty else { return }
        let continuation = pending.removeFirst()
        switch result {
        case let .success(snapshot): continuation.resume(returning: snapshot)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}

private actor SignalingDiagnostics: DiagnosticsSink {
    private var counts: [String: Int] = [:]
    private var waiters: [(code: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ event: DiagnosticEvent) {
        counts[event.code, default: 0] += 1
        let reached = waiters.filter { counts[$0.code, default: 0] >= $0.count }
        waiters.removeAll { counts[$0.code, default: 0] >= $0.count }
        for waiter in reached { waiter.continuation.resume() }
    }

    func wait(for code: String, count: Int) async {
        guard counts[code, default: 0] < count else { return }
        await withCheckedContinuation { waiters.append((code, count, $0)) }
    }
}

private actor ScriptedActivity: SystemActivityMonitoring {
    private var continuation: AsyncStream<SystemActivityEvent>.Continuation?
    private var buffered: [SystemActivityEvent] = []

    nonisolated func events() -> AsyncStream<SystemActivityEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SystemActivityEvent.self)
        Task { await self.attach(continuation) }
        return stream
    }

    private func attach(_ continuation: AsyncStream<SystemActivityEvent>.Continuation) {
        self.continuation = continuation
        for event in buffered { continuation.yield(event) }
        buffered.removeAll()
    }

    func send(_ event: SystemActivityEvent) {
        if let continuation {
            continuation.yield(event)
        } else {
            buffered.append(event)
        }
    }
}
