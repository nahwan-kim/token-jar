import Foundation
import Testing
@testable import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Refresh and persistence behavior", .serialized)
struct RuntimeTests {
    @Test("transient failure retains the process-lifetime last success as stale")
    func staleRetainsLastSuccess() async {
        let snapshot = TestContextFactory.snapshot(providerID: .codex)
        let diagnostics = RecordingDiagnostics()
        let adapter = QueueProviderAdapter(
            id: .codex,
            results: [
                .success(snapshot),
                .failure(CollectionError(kind: .offline, diagnosticCode: "test.offline")),
            ]
        )
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(diagnostics: diagnostics)
        )

        await coordinator.refresh(.codex)
        await coordinator.refresh(.codex)

        guard case let .stale(retained, failure, _) = await coordinator.state(for: .codex) else {
            Issue.record("Expected stale state")
            return
        }
        #expect(retained == snapshot)
        #expect(failure.kind == .offline)
        #expect(failure.recoveryAction == .waitForNextRefresh)
        let events = await diagnostics.events.filter { $0.category == "collection" }
        #expect(events.map(\.code) == [
            "collection.started",
            "collection.succeeded",
            "collection.started",
            "test.offline",
        ])
        #expect(events[1].duration != nil)
        #expect(events[3].duration != nil)
        #expect(events[0].correlationID == events[1].correlationID)
        #expect(events[2].correlationID == events[3].correlationID)
        #expect(events[0].correlationID != events[2].correlationID)
    }

    @Test("temporary Keychain failure never becomes a login prompt")
    func keychainFailureIsStale() async {
        let adapter = QueueProviderAdapter(
            id: .grok,
            results: [
                .failure(CollectionError(kind: .keychainUnavailable, diagnosticCode: "test.keychain.locked")),
            ]
        )
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make()
        )

        await coordinator.refresh(.grok)

        guard case let .stale(_, failure, _) = await coordinator.state(for: .grok) else {
            Issue.record("Expected stale state rather than authenticationActionRequired")
            return
        }
        #expect(failure.kind == .keychainUnavailable)
        #expect(failure.recoveryAction == .waitForNextRefresh)
    }

    @Test("missing original external session requests source-owner login")
    func missingExternalSessionRequestsOwnerLogin() async {
        let adapter = QueueProviderAdapter(
            id: .cursor,
            results: [
                .failure(CollectionError(kind: .externalSessionMissing, diagnosticCode: "test.cursor.missing")),
            ]
        )
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make()
        )

        await coordinator.refresh(.cursor)

        guard case let .authenticationActionRequired(_, failure) = await coordinator.state(for: .cursor) else {
            Issue.record("Expected authenticationActionRequired")
            return
        }
        #expect(failure.recoveryAction == .signInSourceApp)
    }

    @Test("manual refreshes coalesce onto one in-flight request")
    func manualRefreshCoalesces() async throws {
        let snapshot = TestContextFactory.snapshot(providerID: .claude)
        let adapter = SuspendedProviderAdapter(id: .claude)
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make()
        )

        async let first: Void = coordinator.refresh(.claude)
        async let second: Void = coordinator.refresh(.claude)
        #expect(await eventually { await adapter.fetchCount == 1 })
        await adapter.complete(with: .success(snapshot))
        _ = await (first, second)

        #expect(await adapter.fetchCount == 1)
        guard case let .fresh(actual) = await coordinator.state(for: .claude) else {
            Issue.record("Expected fresh state")
            return
        }
        #expect(actual == snapshot)
    }

    @Test("Retry-After is a lower bound for later refresh attempts")
    func retryAfterLowerBound() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualClock(now: now)
        let snapshot = TestContextFactory.snapshot(providerID: .doubao, refreshedAt: now.addingTimeInterval(600))
        let adapter = QueueProviderAdapter(
            id: .doubao,
            results: [
                .failure(
                    CollectionError(
                        kind: .rateLimited,
                        diagnosticCode: "test.rate-limited",
                        retryAfter: now.addingTimeInterval(600)
                    )
                ),
                .success(snapshot),
            ]
        )
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(clock: clock)
        )

        await coordinator.refresh(.doubao)
        await coordinator.refresh(.doubao)
        #expect(await adapter.fetchCount == 1)

        await clock.advance(by: .seconds(599))
        await coordinator.refresh(.doubao)
        #expect(await adapter.fetchCount == 1)

        await clock.advance(by: .seconds(1))
        await coordinator.refresh(.doubao)
        #expect(await adapter.fetchCount == 2)
        guard case .fresh = await coordinator.state(for: .doubao) else {
            Issue.record("Expected refresh at Retry-After boundary")
            return
        }
    }

    @Test("automatic refresh waits five minutes and does not busy-poll")
    func automaticCadence() async {
        let clock = ManualClock()
        let diagnostics = RecordingDiagnostics()
        let adapter = QueueProviderAdapter(
            id: .codex,
            results: [
                .success(TestContextFactory.snapshot(providerID: .codex)),
                .success(TestContextFactory.snapshot(providerID: .codex, percentage: 30)),
            ]
        )
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(clock: clock, diagnostics: diagnostics)
        )

        await coordinator.start()
        #expect(await eventually { await adapter.fetchCount == 1 })
        #expect(await eventually { await clock.waitingCount == 1 })
        #expect(await adapter.fetchCount == 1)

        await clock.advance(by: .seconds(299))
        await Task.yield()
        #expect(await adapter.fetchCount == 1)

        await clock.advance(by: .seconds(1))
        #expect(await eventually { await adapter.fetchCount == 2 })
        await coordinator.stop()
        #expect(await diagnostics.events.filter { $0.category == "schedule" }.map(\.code) == [
            "schedule.started",
            "schedule.cycle",
            "schedule.cycle",
            "schedule.stopped",
        ])
    }

    @Test("a slow collection skips missed intervals instead of catch-up bursting")
    func slowCollectionSkipsMissedIntervals() async {
        let clock = ManualClock()
        let adapter = AdvancingProviderAdapter(
            clock: clock,
            snapshot: TestContextFactory.snapshot(providerID: .codex)
        )
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make(clock: clock)
        )

        await coordinator.start()
        #expect(await eventually { await adapter.fetchCount == 1 })
        #expect(await eventually { await clock.waitingCount == 1 })

        await clock.advance(by: .seconds(299))
        await Task.yield()
        #expect(await adapter.fetchCount == 1)

        await clock.advance(by: .seconds(1))
        #expect(await eventually { await adapter.fetchCount == 2 })
        await coordinator.stop()
    }

    @Test("provider and source identities cannot cross coordinator boundaries")
    func providerIdentityBinding() async {
        let mismatchedSnapshot = TestContextFactory.snapshot(providerID: .claude)
        let snapshotAdapter = QueueProviderAdapter(
            id: .codex,
            results: [.success(mismatchedSnapshot)]
        )
        let snapshotCoordinator = RefreshCoordinator(
            adapters: [snapshotAdapter],
            context: TestContextFactory.make()
        )

        await snapshotCoordinator.refresh(.codex)

        guard case let .stale(snapshot, snapshotFailure, _) =
            await snapshotCoordinator.state(for: .codex) else {
            Issue.record("Expected mismatched snapshot rejection")
            return
        }
        #expect(snapshot == nil)
        #expect(snapshotFailure.diagnosticCode == "collection.snapshot-identity-mismatch")

        let mismatchedSource = ProviderSourceDescriptor(
            id: "test.wrong-source",
            name: "Wrong source",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: nil,
            detail: "Wrong source"
        )
        let sourceAdapter = QueueProviderAdapter(
            id: .codex,
            availability: .available(mismatchedSource),
            results: []
        )
        let sourceCoordinator = RefreshCoordinator(
            adapters: [sourceAdapter],
            context: TestContextFactory.make()
        )

        await sourceCoordinator.refresh(.codex)

        guard case let .stale(_, sourceFailure, _) =
            await sourceCoordinator.state(for: .codex) else {
            Issue.record("Expected mismatched source rejection")
            return
        }
        #expect(sourceFailure.diagnosticCode == "collection.source-identity-mismatch")
        #expect(await sourceAdapter.fetchCount == 0)
    }

    @Test("stopped coordinators reject later manual refreshes")
    func stoppedCoordinatorRejectsRefresh() async {
        let adapter = QueueProviderAdapter(
            id: .codex,
            results: [.success(TestContextFactory.snapshot(providerID: .codex))]
        )
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make()
        )

        await coordinator.stop()
        await coordinator.refresh(.codex)
        await coordinator.refreshAll()

        #expect(await adapter.fetchCount == 0)
        #expect(await coordinator.state(for: .codex) == .neverLoaded)
    }
    @Test("provider execution receives a least-privilege capability scope")
    func providerCapabilityScope() async throws {
        let credentials = InMemoryCredentialStore()
        let claudeID = CredentialID(providerID: .claude, name: "admin-api-key")
        let grokID = CredentialID(providerID: .grok, name: "management-api-key")
        await credentials.write("claude-key", for: claudeID)
        await credentials.write("grok-key", for: grokID)

        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: Data()))]
        )
        let externalRequest = ExternalFileRequest(providerID: .claude, relativePath: ".claude/session")
        let external = MemoryExternalSessionReader(files: [externalRequest: Data("external".utf8)])
        let codex = MemoryCodexAccountUsageReader(results: [.success(Data("codex".utf8))])
        let context = TestContextFactory.make(
            network: network,
            credentials: credentials,
            externalSessions: external,
            sqlite: MemorySQLiteReader(values: ["cursorAuth/accessToken": "value"]),
            codexAccount: codex
        )
        let scoped = context.scoped(to: .claude)

        #expect(try await scoped.credentials.read(claudeID) == "claude-key")
        #expect(await collectionError {
            _ = try await scoped.credentials.read(grokID)
        }?.diagnosticCode == "capability.credentials.read-denied")
        #expect(await collectionError {
            try await scoped.credentials.write("replacement", for: claudeID)
        }?.diagnosticCode == "capability.credentials.write-denied")
        #expect(await collectionError {
            _ = try await scoped.network.send(
                NetworkRequest(
                    providerID: .grok,
                    url: URL(string: "https://management-api.x.ai/v1/billing/teams/team/prepaid/balance")!
                )
            )
        }?.diagnosticCode == "capability.network.provider-mismatch")
        #expect(await network.requests.isEmpty)
        #expect(await scoped.externalSessions.exists(externalRequest) == false)
        #expect(await collectionError {
            _ = try await scoped.externalSessions.read(externalRequest)
        }?.diagnosticCode == "capability.external-session.denied")
        #expect(await collectionError {
            _ = try await scoped.sqlite.values(
                in: externalRequest,
                table: "store",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["key"]
            )
        }?.diagnosticCode == "capability.sqlite.request-denied")
        #expect(await collectionError {
            _ = try await scoped.codexAccount.readRateLimits()
        }?.diagnosticCode == "capability.codex-account.denied")

        let codexScoped = context.scoped(to: .codex)
        #expect(try await codexScoped.codexAccount.readRateLimits() == Data("codex".utf8))

        let cursorScoped = context.scoped(to: .cursor)
        let cursorRequest = ExternalFileRequest(
            providerID: .cursor,
            relativePath: "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            maximumBytes: 64 * 1024 * 1024
        )
        #expect(try await cursorScoped.sqlite.values(
            in: cursorRequest,
            table: "ItemTable",
            keyColumn: "key",
            valueColumn: "value",
            keys: ["cursorAuth/accessToken"]
        ) == ["cursorAuth/accessToken": "value"])
        #expect(await collectionError {
            _ = try await cursorScoped.sqlite.values(
                in: ExternalFileRequest(providerID: .cursor, relativePath: "other.vscdb"),
                table: "ItemTable",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["cursorAuth/accessToken"]
            )
        }?.diagnosticCode == "capability.sqlite.request-denied")
}

    private func collectionError(
        _ operation: () async throws -> Void
    ) async -> CollectionError? {
        do {
            try await operation()
            return nil
        } catch let error as CollectionError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }

    @Test("only non-secret display preferences persist")
    func preferencesOnly() async throws {
        let suite = "com.tokentank.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPreferencesStore(suiteName: suite)
        var preferences = UserPreferences()
        preferences.providers[0].abbreviation = "  LONG-ABBREVIATION  "
        preferences.providers[1].isVisible = false

        try await store.save(preferences)
        let loaded = await store.load()

        #expect(loaded.providers[0].abbreviation == "LONG-ABB")
        #expect(loaded.providers[1].isVisible == false)
        #expect(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []) == ["user-preferences-v1"])
        let persisted = try #require(defaults.data(forKey: "user-preferences-v1"))
        let text = String(decoding: persisted, as: UTF8.self)
        #expect(!text.contains("quotas"))
        #expect(!text.contains("snapshot"))
        #expect(!text.contains("token"))
    }

    private func eventually(
        attempts: Int = 200,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }
}

private actor SuspendedProviderAdapter: ProviderAdapter {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let defaultAbbreviation: String
    nonisolated let sourceDescriptor: ProviderSourceDescriptor

    private var continuation: CheckedContinuation<ProviderSnapshot, Error>?
    private(set) var fetchCount = 0

    init(id: ProviderID) {
        self.id = id
        self.displayName = id.displayName
        self.defaultAbbreviation = id.defaultAbbreviation
        self.sourceDescriptor = ProviderSourceDescriptor(
            id: "test.\(id.rawValue)",
            name: "Test \(id.displayName)",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: nil,
            detail: "Test source"
        )
    }

    func probeAvailability(context: CollectionContext) -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        fetchCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(with result: Result<ProviderSnapshot, CollectionError>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case let .success(snapshot): continuation.resume(returning: snapshot)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}

private actor AdvancingProviderAdapter: ProviderAdapter {
    nonisolated var id: ProviderID { .codex }
    nonisolated var displayName: String { ProviderID.codex.displayName }
    nonisolated var defaultAbbreviation: String { ProviderID.codex.defaultAbbreviation }
    nonisolated var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "test.codex",
            name: "Test Codex",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: nil,
            detail: "Test source"
        )
    }

    private let clock: ManualClock
    private let snapshot: ProviderSnapshot
    private(set) var fetchCount = 0

    init(clock: ManualClock, snapshot: ProviderSnapshot) {
        self.clock = clock
        self.snapshot = snapshot
    }

    func probeAvailability(context: CollectionContext) -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    func fetchSnapshot(context: CollectionContext) async -> ProviderSnapshot {
        fetchCount += 1
        if fetchCount == 1 {
            await clock.advance(by: .seconds(301))
        }
        return snapshot
    }
}
