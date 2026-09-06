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
    @Test("only the failing Codex account retains its last successful data as stale")
    func codexAccountStalenessIsIsolated() async {
        let initialDate = Date(timeIntervalSince1970: 1_800_000_000)
        let latestDate = initialDate.addingTimeInterval(300)
        let initial = Self.codexSnapshot(
            refreshedAt: initialDate,
            accounts: [
                Self.codexAccount(
                    sourceID: .primary,
                    email: "primary-old@example.com",
                    percentage: 10,
                    refreshedAt: initialDate
                ),
                Self.codexAccount(
                    sourceID: .secondary,
                    email: "secondary-old@example.com",
                    percentage: 20,
                    refreshedAt: initialDate
                ),
            ]
        )
        let secondaryFailure = CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "test.codex.secondary-auth"
        )
        let latest = Self.codexSnapshot(
            refreshedAt: latestDate,
            accounts: [
                Self.codexAccount(
                    sourceID: .primary,
                    email: "primary-new@example.com",
                    percentage: 30,
                    refreshedAt: latestDate
                ),
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.secondary.id,
                    quotas: [],
                    failure: secondaryFailure,
                    failedAt: latestDate
                ),
            ]
        )
        let adapter = QueueProviderAdapter(
            id: .codex,
            results: [.success(initial), .success(latest)]
        )
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make()
        )

        await coordinator.refresh(.codex)
        await coordinator.refresh(.codex)

        guard case let .fresh(snapshot) = await coordinator.state(for: .codex) else {
            Issue.record("Expected a fresh provider state with one stale account")
            return
        }
        let primary = snapshot.account(for: CodexAccountSource.primary.id)
        let secondary = snapshot.account(for: CodexAccountSource.secondary.id)
        #expect(primary?.accountEmail == "primary-new@example.com")
        #expect(primary?.quotas.first?.percentage.value == 30)
        #expect(primary?.failure == nil)
        #expect(secondary?.accountEmail == "secondary-old@example.com")
        #expect(secondary?.quotas.first?.percentage.value == 20)
        #expect(secondary?.failure?.kind == secondaryFailure.kind)
        #expect(secondary?.failure?.diagnosticCode == secondaryFailure.diagnosticCode)
        #expect(secondary?.refreshedAt == initialDate)
        #expect(snapshot.hasStaleAccounts)
    }

    @Test("cancelled refresh cannot publish a late successful snapshot")
    func cancelledRefreshDoesNotPublishLateSuccess() async {
        let previous = TestContextFactory.snapshot(providerID: .codex)
        let adapter = SuspendedProviderAdapter(id: .codex)
        let coordinator = RefreshCoordinator(
            adapters: [adapter],
            context: TestContextFactory.make()
        )

        let firstTask = Task { await coordinator.refresh(.codex) }
        #expect(await eventually { await adapter.fetchCount == 1 })
        await adapter.complete(with: .success(previous))
        await firstTask.value
        guard case .fresh = await coordinator.state(for: .codex) else {
            Issue.record("Expected a baseline successful snapshot")
            return
        }

        let lateSnapshot = TestContextFactory.snapshot(providerID: .codex, percentage: 99)
        let refreshTask = Task { await coordinator.refresh(.codex) }
        #expect(await eventually { await adapter.fetchCount == 2 })
        let stopTask = Task { await coordinator.stop() }
        #expect(await eventually { await adapter.cancellationCount == 1 })
        await adapter.complete(with: .success(lateSnapshot))
        await stopTask.value
        await refreshTask.value

        guard case let .refreshing(retained) = await coordinator.state(for: .codex) else {
            Issue.record("Expected cancellation to leave the last state unpublished")
            return
        }
        #expect(retained == previous)
        #expect(retained != lateSnapshot)
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

    @Test("a suspended adapter does not lose completion delivered before fetch")
    func suspendedAdapterEarlyCompletion() async throws {
        let snapshot = TestContextFactory.snapshot(providerID: .claude)
        let adapter = SuspendedProviderAdapter(id: .claude)
        await adapter.complete(with: .success(snapshot))
        let result = try await adapter.fetchSnapshot(context: TestContextFactory.make())
        #expect(result == snapshot)
        #expect(await adapter.fetchCount == 1)
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

        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: Data()))]
        )
        let claudeRequest = ExternalFileRequest(
            providerID: .claude,
            relativePath: ".claude.json",
            maximumBytes: 32 * 1024 * 1024
        )
        let grokRequest = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let deniedRequest = ExternalFileRequest(providerID: .claude, relativePath: ".claude/session")
        let external = MemoryExternalSessionReader(
            files: [
                claudeRequest: Data("{\"cachedUsageUtilization\":{}}".utf8),
                grokRequest: Data("{\"https://auth.x.ai::fixture\":{\"key\":\"token\"}}".utf8),
                deniedRequest: Data("external".utf8),
            ]
        )
        let credentials = InMemoryCredentialStore()
        let codex = MemoryCodexAccountUsageReader(
            results: [
                .success([
                    CodexAccountRead.success(sourceID: .primary, data: Data("codex".utf8)),
                ]),
            ]
        )
        let doubao = MemoryDoubaoPlanUsageReader(results: [.success(Data("doubao".utf8))])
        let context = TestContextFactory.make(
            network: network,
            credentials: credentials,
            externalSessions: external,
            sqlite: MemorySQLiteReader(values: [
                "cursorAuth/accessToken": "value",
                "cursorAuth/cachedEmail": "owner@example.com",
            ]),
            codexAccount: codex,
            doubaoPlan: doubao
        )
        let scoped = context.scoped(to: .claude)

        #expect(await collectionError {
            _ = try await scoped.credentials.read(CredentialID(providerID: .claude, name: "admin-api-key"))
        }?.diagnosticCode == "capability.credentials.read-denied")
        #expect(await collectionError {
            try await scoped.credentials.write("replacement", for: CredentialID(providerID: .claude, name: "admin-api-key"))
        }?.diagnosticCode == "capability.credentials.write-denied")
        #expect(await collectionError {
            _ = try await scoped.network.send(
                NetworkRequest(
                    providerID: .grok,
                    url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
                )
            )
        }?.diagnosticCode == "capability.network.provider-mismatch")
        #expect(await network.requests.isEmpty)
        #expect(await scoped.externalSessions.exists(claudeRequest) == true)
        #expect(try await scoped.externalSessions.read(claudeRequest) == Data("{\"cachedUsageUtilization\":{}}".utf8))
        #expect(await scoped.externalSessions.exists(deniedRequest) == false)
        #expect(await scoped.externalSessions.exists(grokRequest) == false)
        #expect(await collectionError {
            _ = try await scoped.externalSessions.read(deniedRequest)
        }?.diagnosticCode == "capability.external-session.denied")
        #expect(await collectionError {
            _ = try await scoped.sqlite.values(
                in: deniedRequest,
                table: "store",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["key"]
            )
        }?.diagnosticCode == "capability.sqlite.request-denied")
        #expect(await collectionError {
            _ = try await scoped.codexAccount.readAccounts()
        }?.diagnosticCode == "capability.codex-account.denied")
        let grokScoped = context.scoped(to: .grok)
        #expect(await grokScoped.externalSessions.exists(grokRequest) == true)
        #expect(try await grokScoped.externalSessions.read(grokRequest) == Data("{\"https://auth.x.ai::fixture\":{\"key\":\"token\"}}".utf8))
        let codexScoped = context.scoped(to: .codex)
        #expect(try await codexScoped.codexAccount.readAccounts().count == 1)
        let doubaoScoped = context.scoped(to: .doubao)
        #expect(try await doubaoScoped.doubaoPlan.readPlanUsage() == Data("doubao".utf8))
        #expect(await collectionError {
            _ = try await scoped.doubaoPlan.readPlanUsage()
        }?.diagnosticCode == "capability.doubao-plan.denied")

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
            keys: ["cursorAuth/accessToken", "cursorAuth/cachedEmail"]
        ) == ["cursorAuth/accessToken": "value", "cursorAuth/cachedEmail": "owner@example.com"])
        #expect(await collectionError {
            _ = try await cursorScoped.sqlite.values(
                in: cursorRequest,
                table: "ItemTable",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["cursorAuth/accessToken", "cursorAuth/cachedEmail", "cursorAuth/refreshToken"]
            )
        }?.diagnosticCode == "capability.sqlite.request-denied")
        #expect(await collectionError {
            _ = try await cursorScoped.sqlite.values(
                in: ExternalFileRequest(providerID: .cursor, relativePath: "other.vscdb"),
                table: "ItemTable",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["cursorAuth/accessToken", "cursorAuth/cachedEmail"]
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
        preferences.providers[1].isVisible = false

        for value in [false, true] {
            preferences.showsMenuBarPercentSign = value
            try await store.save(preferences)
            let loaded = await store.load()

            #expect(loaded.showsMenuBarPercentSign == value)
            #expect(loaded.providers[1].isVisible == false)
        }
        #expect(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []) == ["user-preferences-v1"])
        let persisted = try #require(defaults.data(forKey: "user-preferences-v1"))
        let text = String(decoding: persisted, as: UTF8.self)
        #expect(!text.contains("quotas"))
        #expect(!text.contains("snapshot"))
        #expect(!text.contains("token"))
        #expect(!text.contains("abbreviation"))
    }

    private static func codexSnapshot(
        refreshedAt: Date,
        accounts: [ProviderAccountSnapshot]
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: .codex,
            source: TestContextFactory.snapshot(providerID: .codex, refreshedAt: refreshedAt).source,
            accounts: accounts,
            refreshedAt: refreshedAt
        )
    }

    private static func codexAccount(
        sourceID: CodexAccountSource,
        email: String,
        percentage: Decimal,
        refreshedAt: Date
    ) -> ProviderAccountSnapshot {
        let rawPercentage = NSDecimalNumber(decimal: percentage).stringValue
        return ProviderAccountSnapshot(
            sourceID: sourceID.id,
            quotas: [
                RawQuotaItem(
                    id: "codex.primary",
                    originalName: "Primary",
                    used: SourceValue(value: percentage, rawText: rawPercentage, unit: "%"),
                    remaining: nil,
                    percentage: SourcePercentage(
                        value: percentage,
                        rawText: rawPercentage,
                        meaning: .used
                    ),
                    resetsAt: nil
                ),
            ],
            refreshedAt: refreshedAt,
            accountEmail: email
        )
    }
    private func eventually(
        condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
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
    private var pendingResult: Result<ProviderSnapshot, CollectionError>?
    private(set) var fetchCount = 0
    private(set) var cancellationCount = 0

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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation = $0
                if let result = pendingResult {
                    pendingResult = nil
                    complete(with: result)
                }
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }
    private func recordCancellation() {
        cancellationCount += 1
    }

    func complete(with result: Result<ProviderSnapshot, CollectionError>) {
        guard let continuation else {
            pendingResult = result
            return
        }
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
