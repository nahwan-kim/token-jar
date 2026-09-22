import Foundation
import Testing
@testable import ClaudeProvider
@testable import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Claude OAuth usage adapter")
struct ClaudeAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = ClaudeSession(
        accessToken: "synthetic-claude-token",
        expiresAt: Date(timeIntervalSince1970: 4_070_908_800),
        subscriptionType: "Max 5x",
        rateLimitTier: "fallback-tier"
    )

    private let fixture = Data(
        """
        {
          "five_hour": {"utilization": 24, "resets_at": "2030-09-03T09:50:00.505688Z"},
          "seven_day": {"utilization": "22", "resets_at": "2030-09-08T13:00:00Z"},
          "seven_day_opus": null,
          "seven_day_oauth_apps": {"utilization": 12},
          "seven_day_routines": {"utilization": 9},
          "seven_day_cowork": {"utilization": 7}
        }
        """.utf8
    )

    @Test("decodes named windows with stable raw values")
    func decodeNamedWindows() throws {
        let snapshot = try ClaudeAdapter.decodeSnapshot(from: fixture, refreshedAt: now)
        #expect(snapshot.source.id == "claude.oauth.usage")
        #expect(snapshot.source.kind == .localSession)
        #expect(snapshot.source.credentialOwnership == .externalProvider)
        #expect(snapshot.refreshedAt == now)
        #expect(snapshot.quotas.map(\.originalName) == [
            "five_hour", "seven_day", "seven_day_oauth_apps", "seven_day_routines", "seven_day_cowork",
        ])
        #expect(snapshot.quotas[0].percentage.rawText == "24")
        #expect(snapshot.quotas[1].percentage.rawText == "22")
        #expect(snapshot.quotas[0].remaining?.rawText == "76")
    }

    @Test("limits preserve session, weekly, and model scoped rows")
    func decodeLimits() throws {
        let body = Data(
            """
            {"limits":[
              {"kind":"session","group":"session","percent":24,"resets_at":"2030-09-03T09:50:00Z","scope":null},
              {"kind":"weekly_all","group":"weekly","percent":22,"scope":null},
              {"kind":"weekly_scoped","group":"weekly","percent":44,"scope":{"model":{"display_name":"Fable"}}}
            ],"five_hour":{"utilization":99},"seven_day_sonnet":{"utilization":31}}
            """.utf8
        )
        let snapshot = try ClaudeAdapter.decodeSnapshot(from: body, refreshedAt: now)
        #expect(snapshot.quotas.map(\.originalName) == [
            "session", "weekly_all", "weekly_scoped.Fable", "seven_day_sonnet",
        ])
        #expect(snapshot.quotas.first { $0.originalName == "weekly_scoped.Fable" }?.sourceFields["scope"] == "Fable")
        #expect(!snapshot.quotas.contains { $0.originalName == "five_hour" })
    }
    @Test("null and empty limits fall back to named windows")
    func optionalLimitsFallback() throws {
        for limits in ["null", "[]"] {
            let body = Data(
                "{\"limits\":\(limits),\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":\"18\"}}".utf8
            )
            let snapshot = try ClaudeAdapter.decodeSnapshot(from: body, refreshedAt: now)
            #expect(snapshot.quotas.map(\.originalName) == ["seven_day"])
            #expect(snapshot.quotas[0].percentage.rawText == "18")
        }
    }

    @Test("percentages over one hundred preserve the source and omit remaining")
    func overOneHundredPercent() throws {
        let snapshot = try ClaudeAdapter.decodeSnapshot(
            from: Data("{\"five_hour\":{\"utilization\":\"125.5\"}}".utf8),
            refreshedAt: now
        )
        #expect(snapshot.quotas[0].percentage.rawText == "125.5")
        #expect(snapshot.quotas[0].used?.rawText == "125.5")
        #expect(snapshot.quotas[0].remaining == nil)
    }

    @Test("request uses the exact OAuth contract and user interaction policy")
    func requestContract() async throws {
        let sessions = MemoryClaudeSessionProvider(results: [.success(session)])
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(
                statusCode: 200,
                headers: [:],
                body: Data("{\"account\":{\"email\":\"owner@example.com\"}}".utf8)
            )),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let clock = ManualClock(now: now)
        let snapshot = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
            network: network,
            claudeSession: sessions,
            clock: clock,
            isUserInitiated: true
        ))
        let requests = await network.requests
        #expect(requests.count == 3)
        let usage = requests[0]
        #expect(usage.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(usage.method == .get)
        #expect(usage.timeout == 30)
        #expect(usage.headers == [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": "Bearer synthetic-claude-token",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.280",
        ])
        #expect(requests[1].url.absoluteString == "https://api.anthropic.com/api/oauth/profile")
        #expect(requests[1].headers == usage.headers)
        #expect(requests[1].timeout == 15)
        #expect(requests[2].url.absoluteString == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        #expect(requests[2].headers == usage.headers)
        #expect(requests[2].timeout == 15)
        #expect(await sessions.allowInteractionRequests == [false])
        #expect(snapshot.refreshedAt == now)
        #expect(snapshot.accountEmail == "owner@example.com")
        #expect(snapshot.accounts.first?.sourceID == "claude.oauth")
        #expect(snapshot.accounts.first?.plan == "Max 5x")
    }

    @Test("availability is descriptive and performs no session, network, or file operation")
    func availabilityDoesNotFetch() async {
        let sessions = MemoryClaudeSessionProvider(results: [])
        let network = QueueNetworkClient(results: [])
        let external = RecordingExternalSessionReader()
        let availability = await ClaudeAdapter().probeAvailability(context: TestContextFactory.make(
            network: network,
            claudeSession: sessions,
            externalSessions: external
        ))
        guard case let .available(descriptor) = availability else {
            Issue.record("Expected available descriptor")
            return
        }
        #expect(descriptor.id == "claude.oauth.usage")
        #expect(await sessions.allowInteractionRequests.isEmpty)
        #expect(await network.requests.isEmpty)
        #expect(await external.operationCount == 0)
    }

    @Test("live percentages change between polls and frozen legacy cache is never read")
    func livePolling() async throws {
        let first = Data("{\"five_hour\":{\"utilization\":12}}".utf8)
        let second = Data("{\"five_hour\":{\"utilization\":47}}".utf8)
        let sessions = MemoryClaudeSessionProvider(results: [.success(session), .success(session)])
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 200, headers: [:], body: first)),
            .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: second)),
            .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let external = RecordingExternalSessionReader()
        let context = TestContextFactory.make(network: network, claudeSession: sessions, externalSessions: external)
        let adapter = ClaudeAdapter()
        let old = try await adapter.fetchSnapshot(context: context)
        let new = try await adapter.fetchSnapshot(context: context)
        #expect(old.quotas[0].percentage.value == 12)
        #expect(new.quotas[0].percentage.value == 47)
        #expect(await network.requests.filter { $0.url.path == "/api/oauth/usage" && $0.url.query == nil }.count == 2)
        #expect(await external.operationCount == 0)
    }

    @Test("profile failures never suppress quota or borrow identity")
    func optionalProfileFailure() async throws {
        let sessions = MemoryClaudeSessionProvider(results: [.success(session), .success(session)])
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(
                statusCode: 200,
                headers: [:],
                body: Data("{\"account\":{\"email\":\"first@example.com\"}}".utf8)
            )),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(
                statusCode: 403,
                headers: [:],
                body: Data("{\"account\":{\"email\":\"stale@example.com\"}}".utf8)
            )),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let context = TestContextFactory.make(network: network, claudeSession: sessions)
        let first = try await ClaudeAdapter().fetchSnapshot(context: context)
        let second = try await ClaudeAdapter().fetchSnapshot(context: context)
        #expect(first.accountEmail == "first@example.com")
        #expect(!second.quotas.isEmpty)
        #expect(second.accountEmail == nil)
        #expect(second.accounts.first?.accountEmail == nil)
        #expect(second.accounts.first?.plan == "Max 5x")
    }

    @Test("unchanged authentication and scope rejection are sanitized without a network retry")
    func authenticationFailures() async {
        for status in [401, 403] {
            let sessions = MemoryClaudeSessionProvider(results: [.success(session), .success(session)])
            let network = QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: status, headers: [:], body: Data("secret".utf8))),
            ])
            do {
                _ = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                    network: network,
                    claudeSession: sessions
                ))
                Issue.record("Expected auth failure")
            } catch let error as CollectionError {
                #expect(error.kind == .authenticationRejected)
                #expect(error.diagnosticCode == (status == 401
                    ? "claude.oauth.authentication-rejected"
                    : "claude.oauth.scope-rejected"))
                #expect(error.recoveryAction == .signInSourceApp)
                #expect(!error.diagnosticCode.contains("secret"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(await network.requests.count == 1)
            #expect(await sessions.allowInteractionRequests == (status == 401 ? [false, false] : [false]))
            #expect(await sessions.rejectedAccessTokens == (status == 401 ? [nil, session.accessToken] : [nil]))
        }
    }

    @Test("401 adopts externally rotated credentials without authorizing repair, including manual refresh")
    func externalAuthenticationRecovery() async throws {
        for userInitiated in [false, true] {
            let renewed = ClaudeSession(accessToken: "renewed-token", expiresAt: now.addingTimeInterval(3600))
            let sessions = MemoryClaudeSessionProvider(results: [.success(session), .success(renewed)])
            let network = QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: 401, headers: [:], body: Data("secret".utf8))),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{\"account\":{\"email\":\"renewed@example.com\"}}".utf8))),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            ])
            let snapshot = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                network: network, claudeSession: sessions, isUserInitiated: userInitiated
            ))
            #expect(snapshot.quotas.first?.percentage.value == 24)
            #expect(snapshot.accountEmail == "renewed@example.com")
            #expect(await sessions.allowInteractionRequests == [false, false])
            #expect(await sessions.rejectedAccessTokens == [nil, session.accessToken])
            #expect(await network.requests.map { $0.headers["Authorization"] } == [
                "Bearer synthetic-claude-token", "Bearer renewed-token", "Bearer renewed-token", "Bearer renewed-token",
            ])
        }
    }

    @Test("a second 401 terminates recovery and retains the previous successful snapshot")
    func repeatedAuthenticationRejection() async {
        let renewed = ClaudeSession(accessToken: "renewed-token", expiresAt: now.addingTimeInterval(3600))
        let sessions = MemoryClaudeSessionProvider(results: [.success(session), .success(session), .success(renewed)])
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .success(NetworkResponse(statusCode: 401, headers: [:], body: Data())),
            .success(NetworkResponse(statusCode: 401, headers: [:], body: Data("secret".utf8))),
        ])
        let coordinator = RefreshCoordinator(
            adapters: [ClaudeAdapter()],
            context: TestContextFactory.make(network: network, claudeSession: sessions)
        )
        await coordinator.refresh(.claude)
        await coordinator.refresh(.claude)
        guard case let .authenticationActionRequired(previous, failure) = await coordinator.state(for: .claude) else {
            Issue.record("Expected authentication failure retaining previous snapshot")
            return
        }
        #expect(previous?.quotas.first?.percentage.value == 24)
        #expect(failure.diagnosticCode == "claude.oauth.authentication-rejected")
        #expect(await sessions.rejectedAccessTokens == [nil, nil, session.accessToken])
        #expect(await network.requests.count == 5)
    }

    @Test("renewal failure and cancellation propagate without another usage request")
    func failedAuthenticationRecovery() async {
        for kind in [CollectionErrorKind.transientNetwork, .cancelled, .externalSessionMissing] {
            let sessions = MemoryClaudeSessionProvider(results: [
                .success(session),
                .failure(CollectionError(kind: kind, diagnosticCode: "claude.session.recovery-failed")),
            ])
            let network = QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: 401, headers: [:], body: Data())),
            ])
            do {
                _ = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                    network: network, claudeSession: sessions
                ))
                Issue.record("Expected renewal failure")
            } catch let error as CollectionError {
                #expect(error.kind == kind)
                #expect(error.diagnosticCode == "claude.session.recovery-failed")
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(await network.requests.count == 1)
            #expect(await sessions.allowInteractionRequests == [false, false])
        }
    }

    @Test("a context without recovery capability cannot initiate repair")
    func missingRecoveryCapabilityCannotRepair() async {
        for userInitiated in [false, true] {
            for kind in [CollectionErrorKind.authenticationRejected, .keychainUnavailable] {
                let failure = CollectionError(kind: kind, diagnosticCode: "test.repair-required",
                                              recoveryAction: .repairClaudeConnection)
                let sessions = MemoryClaudeSessionProvider(results: [.failure(failure)])
                let network = QueueNetworkClient(results: [])
                do {
                    _ = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                        network: network, claudeSession: sessions, isUserInitiated: userInitiated
                    ))
                    Issue.record("Expected recovery capability requirement")
                } catch let error as CollectionError {
                    #expect(error == failure)
                } catch {
                    Issue.record("Unexpected error: \(error)")
                }
                #expect(await sessions.allowInteractionRequests == [false])
                #expect(await network.requests.isEmpty)
            }
        }
    }

    @Test("explicit repair grants one attempt only when a read-only lookup needs it")
    func explicitRepairAfterReadOnlyFailure() async throws {
        for rejectedByUsage in [false, true] {
            let failure = CollectionError(kind: .authenticationRejected, diagnosticCode: "test.repair-required",
                                          recoveryAction: .repairClaudeConnection)
            let renewed = ClaudeSession(accessToken: "repaired-token", expiresAt: now.addingTimeInterval(3600))
            var sessionResults: [Result<ClaudeSession, CollectionError>] = [.failure(failure), .success(renewed)]
            var responses: [Result<NetworkResponse, CollectionError>] = [
                .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            ]
            if rejectedByUsage {
                sessionResults.insert(.success(session), at: 0)
                responses.insert(.success(NetworkResponse(statusCode: 401, headers: [:], body: Data())), at: 0)
            }
            let sessions = MemoryClaudeSessionProvider(results: sessionResults)
            let network = QueueNetworkClient(results: responses)
            let snapshot = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                network: network, claudeSession: sessions, isUserInitiated: true, allowsClaudeRecovery: true
            ))
            #expect(snapshot.quotas.first?.percentage.value == 24)
            #expect(await sessions.allowInteractionRequests == (rejectedByUsage ? [false, false, true] : [false, true]))
            #expect(await sessions.rejectedAccessTokens == (rejectedByUsage
                ? [nil, session.accessToken, session.accessToken] : [nil, nil]))
        }
    }

    @Test("one collection cannot authorize another repair after the renewed token receives 401")
    func repairBudgetSurvivesHTTPRetry() async {
        let failure = CollectionError(kind: .authenticationRejected, diagnosticCode: "test.repair-required",
                                      recoveryAction: .repairClaudeConnection)
        let sessions = MemoryClaudeSessionProvider(results: [.failure(failure), .success(session), .failure(failure)])
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 401, headers: [:], body: Data())),
        ])
        do {
            _ = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                network: network, claudeSession: sessions, isUserInitiated: true, allowsClaudeRecovery: true
            ))
            Issue.record("Expected exhausted repair budget")
        } catch let error as CollectionError {
            #expect(error == failure)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await sessions.allowInteractionRequests == [false, true, false])
        #expect(await network.requests.count == 1)
    }

    @Test("explicit repair does not turn missing credentials or transport errors into prompts")
    func repairRequiresTypedRecoveryAction() async {
        for kind in [CollectionErrorKind.externalSessionMissing, .offline, .cancelled] {
            let failure = CollectionError(kind: kind, diagnosticCode: "test.not-repairable")
            let sessions = MemoryClaudeSessionProvider(results: [.failure(failure)])
            let network = QueueNetworkClient(results: [])
            do {
                _ = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                    network: network, claudeSession: sessions, isUserInitiated: true, allowsClaudeRecovery: true
                ))
                Issue.record("Expected original failure")
            } catch let error as CollectionError {
                #expect(error == failure)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(await sessions.allowInteractionRequests == [false])
            #expect(await network.requests.isEmpty)
        }
    }

    @Test("denied repair retains usage and the next background collection retries recovery")
    func deniedRepairRetainsLastGoodUsage() async {
        let failure = CollectionError(kind: .keychainUnavailable, diagnosticCode: "test.keychain.denied",
                                      recoveryAction: .repairClaudeConnection)
        let sessions = MemoryClaudeSessionProvider(results: [
            .success(session), .failure(failure), .failure(failure), .failure(failure), .success(session),
        ])
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let coordinator = RefreshCoordinator(
            adapters: [ClaudeAdapter()],
            context: TestContextFactory.make(network: network, claudeSession: sessions, clock: ManualClock(now: now))
        )
        await coordinator.refresh(.claude)
        let captured = await coordinator.state(for: .claude).snapshot
        await coordinator.repairClaudeConnection()
        guard case let .stale(previous, error, _) = await coordinator.state(for: .claude) else {
            Issue.record("Expected retained stale snapshot after denied repair")
            return
        }
        #expect(previous == captured)
        #expect(error == failure)
        await coordinator.refresh(.claude)
        #expect(await sessions.allowInteractionRequests == [false, false, true, false, true])
        #expect(await network.requests.count == 6)
        guard case let .fresh(recovered) = await coordinator.state(for: .claude) else {
            Issue.record("Expected next background collection to recover without a repair click")
            return
        }
        #expect(recovered.quotas == captured?.quotas)
        #expect(recovered.refreshedAt == now)
    }

    @Test("background collection repairs an inaccessible native Keychain session before fetching usage")
    func backgroundCollectionAuthorizesNativeKeychain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": session.accessToken,
                "expiresAt": session.expiresAt.timeIntervalSince1970 * 1_000,
                "scopes": ["user:profile"],
            ]
        ])
        let reader = NativeClaudeCredentialReader(homeDirectory: root, keychainLookup: { allowed in
            guard allowed else {
                throw CollectionError(kind: .keychainUnavailable,
                                      diagnosticCode: "claude.session.keychain.unavailable")
            }
            return data
        })
        let refresher = CountingAuthRefresher()
        let clock = ManualClock(now: now)
        let sessions = ClaudeCodeSessionProvider(clock: clock, credentials: reader, refresher: refresher)
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let coordinator = RefreshCoordinator(adapters: [ClaudeAdapter()], context: TestContextFactory.make(
            network: network, claudeSession: sessions, clock: clock
        ))

        await coordinator.refresh(.claude)

        guard case let .fresh(snapshot) = await coordinator.state(for: .claude) else {
            Issue.record("Expected automatic Keychain authorization instead of a stuck repair-required state")
            return
        }
        #expect(snapshot.quotas.first?.percentage.value == 24)
        #expect(await network.requests.count == 3)
        #expect(await refresher.count == 0)
    }

    private actor CountingAuthRefresher: ClaudeAuthRefreshing {
        private(set) var count = 0
        func refresh() { count += 1 }
    }

    @Test("background collection renews expired or HTTP-rejected credentials once through their owner")
    func backgroundCollectionRenewsOwnerSession() async throws {
        for rejectedByHTTP in [false, true] {
            func credentials(_ token: String, expiresAt: Date) throws -> Data {
                try JSONSerialization.data(withJSONObject: [
                    "claudeAiOauth": [
                        "accessToken": token,
                        "expiresAt": expiresAt.timeIntervalSince1970 * 1_000,
                        "scopes": ["user:profile"],
                    ]
                ])
            }
            let owner = RotatingCredentialOwner(
                initial: try credentials("old-token", expiresAt: rejectedByHTTP ? now.addingTimeInterval(300) : now),
                renewed: try credentials("new-token", expiresAt: now.addingTimeInterval(3600))
            )
            let clock = ManualClock(now: now)
            let sessions = ClaudeCodeSessionProvider(clock: clock, credentials: owner, refresher: owner)
            var responses: [Result<NetworkResponse, CollectionError>] = [
                .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            ]
            if rejectedByHTTP {
                responses.insert(.success(NetworkResponse(statusCode: 401, headers: [:], body: Data())), at: 0)
            }
            let network = QueueNetworkClient(results: responses)
            let coordinator = RefreshCoordinator(adapters: [ClaudeAdapter()], context: TestContextFactory.make(
                network: network, claudeSession: sessions, clock: clock
            ))

            await coordinator.refresh(.claude)

            guard case let .fresh(snapshot) = await coordinator.state(for: .claude) else {
                Issue.record("Expected automatic owner renewal without a repair click")
                continue
            }
            #expect(snapshot.quotas.first?.percentage.value == 24)
            #expect(await owner.refreshCount == 1)
            #expect(await owner.interactionFlags == [false, true, false])
            #expect(await network.requests.map { $0.headers["Authorization"] } == (
                rejectedByHTTP
                    ? ["Bearer old-token", "Bearer new-token", "Bearer new-token", "Bearer new-token"]
                    : ["Bearer new-token", "Bearer new-token", "Bearer new-token"]
            ))
        }
    }

    private actor RotatingCredentialOwner: ClaudeCredentialReading, ClaudeAuthRefreshing {
        private var file: Data
        private let renewed: Data
        private(set) var refreshCount = 0
        private(set) var interactionFlags: [Bool] = []

        init(initial: Data, renewed: Data) {
            self.file = initial
            self.renewed = renewed
        }

        func readFile() -> Data? { file }
        func readKeychain(allowInteraction: Bool) -> Data? {
            interactionFlags.append(allowInteraction)
            return nil
        }
        func refresh() {
            refreshCount += 1
            file = renewed
        }
    }

    @Test("the single retry preserves scope, rate-limit, network, and malformed-response failures")
    func retriedFailureClassification() async {
        let cases: [(Int, Data, CollectionErrorKind)] = [
            (403, Data(), .authenticationRejected),
            (429, Data(), .rateLimited),
            (503, Data(), .transientNetwork),
            (200, Data("{}".utf8), .malformedResponse),
        ]
        for (status, body, expectedKind) in cases {
            let renewed = ClaudeSession(accessToken: "renewed-token", expiresAt: now.addingTimeInterval(3600))
            let sessions = MemoryClaudeSessionProvider(results: [.success(session), .success(renewed)])
            let network = QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: 401, headers: [:], body: Data())),
                .success(NetworkResponse(statusCode: status, headers: ["Retry-After": "120"], body: body)),
            ])
            do {
                _ = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                    network: network, claudeSession: sessions, clock: ManualClock(now: now)
                ))
                Issue.record("Expected retry failure")
            } catch let error as CollectionError {
                #expect(error.kind == expectedKind)
                if status == 429 {
                    #expect(error.retryAfter == now.addingTimeInterval(120))
                }
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(await network.requests.count == 2)
            #expect(await sessions.rejectedAccessTokens == [nil, session.accessToken])
        }
    }

    @Test("session failures remain sanitized and send no request")
    func sessionFailure() async {
        let sessions = MemoryClaudeSessionProvider(results: [
            .failure(CollectionError(
                kind: .externalSessionMissing,
                diagnosticCode: "claude.session.missing",
                recoveryAction: .signInSourceApp
            )),
        ])
        let network = QueueNetworkClient(results: [])
        do {
            _ = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                network: network,
                claudeSession: sessions
            ))
            Issue.record("Expected session failure")
        } catch let error as CollectionError {
            #expect(error.kind == .externalSessionMissing)
            #expect(error.diagnosticCode == "claude.session.missing")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await network.requests.isEmpty)
    }

    @Test("HTTP failures keep a previous coordinator snapshot and cold failures invent none")
    func coordinatorStaleBehavior() async {
        let sessions = MemoryClaudeSessionProvider(results: [.success(session), .success(session)])
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .success(NetworkResponse(statusCode: 503, headers: [:], body: Data())),
        ])
        let context = TestContextFactory.make(network: network, claudeSession: sessions, clock: ManualClock(now: now))
        let coordinator = RefreshCoordinator(adapters: [ClaudeAdapter()], context: context)
        await coordinator.refresh(.claude)
        await coordinator.refresh(.claude)
        guard case let .stale(previous, failure, _) = await coordinator.state(for: .claude) else {
            Issue.record("Expected stale previous snapshot")
            return
        }
        #expect(previous?.quotas.first?.percentage.value == 24)
        #expect(failure.kind == .transientNetwork)

        let cold = RefreshCoordinator(
            adapters: [ClaudeAdapter()],
            context: TestContextFactory.make(
                network: QueueNetworkClient(results: [
                    .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
                ]),
                claudeSession: MemoryClaudeSessionProvider(results: [.success(session)])
            )
        )
        await cold.refresh(.claude)
        guard case let .stale(snapshot, _, _) = await cold.state(for: .claude) else {
            Issue.record("Expected cold stale state")
            return
        }
        #expect(snapshot == nil)
    }

    @Test("Retry-After numeric, HTTP date, and invalid values bound coordinator refresh")
    func retryAfterCooldown() async {
        let retryDate = now.addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        let tooDistant = formatter.string(from: now.addingTimeInterval(172_800))
        let cases = [
            ("120", 120.0),
            (formatter.string(from: retryDate), 120.0),
            ("unsafe", 300.0),
            ("1e300", 300.0),
            (tooDistant, 300.0),
        ]
        for (header, seconds) in cases {
            let clock = ManualClock(now: now)
            let sessions = MemoryClaudeSessionProvider(results: [.success(session), .success(session)])
            let network = QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: 429, headers: ["Retry-After": header], body: Data())),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
                .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
            ])
            let coordinator = RefreshCoordinator(
                adapters: [ClaudeAdapter()],
                context: TestContextFactory.make(network: network, claudeSession: sessions, clock: clock)
            )
            await coordinator.refresh(.claude)
            await clock.advance(by: .seconds(seconds - 0.001))
            await coordinator.refresh(.claude)
            #expect(await network.requests.count == 1)
            await clock.advance(by: .seconds(0.001))
            await coordinator.refresh(.claude)
            #expect(await network.requests.filter { $0.url.path == "/api/oauth/usage" && $0.url.query == nil }.count == 2)
        }
    }

    @Test("malformed windows, limits, percentages, and reset timestamps fail closed")
    func malformedSuccess() {
        let bodies = [
            "{}",
            "[]",
            "{\"five_hour\":[]}",
            "{\"five_hour\":{}}",
            "{\"five_hour\":{\"utilization\":null}}",
            "{\"five_hour\":{\"utilization\":-1}}",
            "{\"five_hour\":{\"utilization\":true}}",
            "{\"five_hour\":{\"utilization\":\"not-a-number\"}}",
            "{\"five_hour\":{\"utilization\":20,\"resets_at\":\"bad\"}}",
            "{\"limits\":{}}",
            "{\"limits\":[{\"kind\":\"session\"}]}",
            "{\"limits\":[{\"kind\":\"weekly_scoped\",\"percent\":20,\"scope\":null}]}",
            "{\"limits\":[{\"kind\":\"unknown\",\"percent\":20}]}",
        ]
        for body in bodies {
            do {
                _ = try ClaudeAdapter.decodeSnapshot(from: Data(body.utf8), refreshedAt: now)
                Issue.record("Expected malformed response for \(body)")
            } catch let error as CollectionError {
                #expect(error.kind == .schemaChanged || error.kind == .malformedResponse)
                #expect(!error.kind.requiresAuthenticationAction)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("null optional windows do not create fake zero quotas")
    func nullWindows() throws {
        let body = Data("{\"five_hour\":null,\"seven_day\":{\"utilization\":0}}".utf8)
        let snapshot = try ClaudeAdapter.decodeSnapshot(from: body, refreshedAt: now)
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].originalName == "seven_day")
        #expect(snapshot.quotas[0].percentage.rawText == "0")
    }

    @Test("extra usage preserves rounded published percentage, missing percentage, and over-cap amounts")
    func extraUsage() throws {
        let rounded = Data(
            """
            {"extra_usage":{"is_enabled":true,"used_credits":"1","monthly_limit":"3","utilization":"33.3","currency":"USD"}}
            """.utf8
        )
        let roundedSnapshot = try ClaudeAdapter.decodeSnapshot(from: rounded, refreshedAt: now)
        #expect(roundedSnapshot.quotas[0].originalName == "extra_usage")
        #expect(roundedSnapshot.quotas[0].used?.rawText == "1")
        #expect(roundedSnapshot.quotas[0].remaining?.rawText.hasPrefix("2") == true)
        #expect(roundedSnapshot.quotas[0].percentage.rawText == "33.3")

        let missingPercent = try ClaudeAdapter.decodeSnapshot(
            from: Data(
                "{\"extra_usage\":{\"is_enabled\":true,\"used_credits\":25,\"monthly_limit\":100,\"utilization\":null}}".utf8
            ),
            refreshedAt: now
        )
        #expect(missingPercent.quotas[0].percentage.value == nil)
        #expect(missingPercent.quotas[0].used?.rawText == "25")

        let overCap = try ClaudeAdapter.decodeSnapshot(
            from: Data(
                "{\"extra_usage\":{\"is_enabled\":true,\"used_credits\":125,\"monthly_limit\":100,\"utilization\":125}}".utf8
            ),
            refreshedAt: now
        )
        #expect(overCap.quotas[0].used?.rawText == "125")
        #expect(overCap.quotas[0].percentage.rawText == "125")
        #expect(overCap.quotas[0].remaining == nil)
    }

    @Test("reset credits preserve exact counts, dates, and safe source fields")
    func resetCreditsDecode() throws {
        let body = Data(
            """
            {"cedar_ember":{"eligible":false,"grants":[
              {"id":"first_grant","label":"First","resets_left":2,"starts_at":"2030-09-01T00:00:00Z","ends_at":"2030-09-02T00:00:00Z","paused":true,"usable_now":false,"secret":"ignored"},
              {"id":"second-2","label":"","resets_left":3,"starts_at":null,"ends_at":null,"paused":false,"usable_now":true}
            ]}}
            """.utf8
        )
        let rows = try ClaudeAdapter.decodeResetCredits(from: body)
        #expect(rows.map(\.id.rawValue) == [
            "rateLimitResetCredits", "rateLimitResetCredit.first_grant", "rateLimitResetCredit.second-2",
        ])
        #expect(rows[0].remaining?.rawText == "5")
        #expect(rows[0].remaining?.unit == "credits")
        #expect(rows[0].percentage.value == nil)
        #expect(rows[1].remaining?.rawText == "2")
        #expect(rows[2].remaining?.rawText == "3")
        #expect(rows[2].used == nil)
        #expect(rows[2].originalName == "second-2")
        #expect(rows[1].resetsAt == ISO8601DateFormatter().date(from: "2030-09-02T00:00:00Z"))
        #expect(rows[1].sourceFields == [
            "item": "cedar_ember.grant", "resets_left": "2",
            "starts_at": "2030-09-01T00:00:00Z", "ends_at": "2030-09-02T00:00:00Z",
            "paused": "true", "usable_now": "false",
        ])
        #expect(rows[2].sourceFields["starts_at"] == nil)
        #expect(rows[1].sourceFields["secret"] == nil)
    }

    @Test("empty grants are explicit zero while absent or null optional data stays unknown")
    func resetCreditsEmptyAndUnknown() throws {
        for body in ["{}", "{\"cedar_ember\":null}", "{\"cedar_ember\":{}}", "{\"cedar_ember\":{\"grants\":null}}"] {
            #expect(try ClaudeAdapter.decodeResetCredits(from: Data(body.utf8)).isEmpty)
        }
        let rows = try ClaudeAdapter.decodeResetCredits(
            from: Data("{\"cedar_ember\":{\"eligible\":true,\"grants\":[]}}".utf8)
        )
        #expect(rows.count == 1)
        #expect(rows[0].remaining?.rawText == "0")
        let spent = try ClaudeAdapter.decodeResetCredits(
            from: Data("{\"cedar_ember\":{\"grants\":[{\"id\":\"spent\",\"resets_left\":0}]}}".utf8)
        )
        #expect(spent.count == 2)
        #expect(spent[0].remaining?.value == 0)
        #expect(spent[1].remaining?.value == 0)
    }

    @Test("malformed reset grants reject the entire optional response")
    func malformedResetCredits() {
        let bodies = [
            "{\"cedar_ember\":{\"eligible\":1,\"grants\":[]}}",
            "{\"cedar_ember\":{\"eligible\":\"true\",\"grants\":[]}}",
            "{\"cedar_ember\":{\"eligible\":null,\"grants\":[]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"A\",\"resets_left\":1}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":\"1\"}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":true}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":1.5}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":-1}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":1e128}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\"}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":1,\"ends_at\":\"bad\"}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":1,\"starts_at\":\"bad\"}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":1,\"usable_now\":\"true\"}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":1,\"paused\":0}]}}",
            "{\"cedar_ember\":{\"grants\":[{\"id\":\"ok\",\"resets_left\":1},{\"id\":\"ok\",\"resets_left\":2}]}}",
        ]
        for body in bodies {
            #expect(throws: CollectionError.self) {
                try ClaudeAdapter.decodeResetCredits(from: Data(body.utf8))
            }
        }
    }

    @Test("supplemental failures and malformed or non-success bodies cannot drop primary usage")
    func optionalResetCreditsFailure() async throws {
        let responses: [Result<NetworkResponse, CollectionError>] = [
            .failure(CollectionError(kind: .transientNetwork, diagnosticCode: "test.optional.failed")),
            .success(NetworkResponse(statusCode: 401, headers: [:], body: Data("secret".utf8))),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("{\"cedar_ember\":{\"grants\":[{}]}}".utf8))),
        ]
        for optionalResponse in responses {
            let sessions = MemoryClaudeSessionProvider(results: [.success(session)])
            let network = QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
                .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
                optionalResponse,
            ])
            let snapshot = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                network: network, claudeSession: sessions
            ))
            #expect(snapshot.quotas.first?.originalName == "five_hour")
            #expect(!snapshot.quotas.contains { $0.id.rawValue == "rateLimitResetCredits" })
            #expect(await sessions.allowInteractionRequests == [false])
            #expect(await network.requests.count == 3)
        }
    }

    @Test("supplemental cancellation propagates without credential mutation or retry")
    func optionalResetCreditsCancellation() async {
        let sessions = MemoryClaudeSessionProvider(results: [.success(session)])
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
            .failure(CollectionError(kind: .cancelled, diagnosticCode: "test.optional.cancelled")),
        ])
        do {
            _ = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                network: network, claudeSession: sessions
            ))
            Issue.record("Expected supplemental cancellation")
        } catch let error as CollectionError {
            #expect(error.kind == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await sessions.allowInteractionRequests == [false])
        #expect(await sessions.rejectedAccessTokens == [nil])
        #expect(await network.requests.count == 3)
    }

    @Test("valid supplemental rows are shared by provider and account snapshots")
    func supplementalRowsShared() async throws {
        let sessions = MemoryClaudeSessionProvider(results: [.success(session)])
        let resetBody = Data("{\"cedar_ember\":{\"grants\":[{\"id\":\"ticket\",\"resets_left\":3}]}}".utf8)
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: resetBody)),
        ])
        let snapshot = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
            network: network, claudeSession: sessions
        ))
        #expect(snapshot.quotas == snapshot.accounts.first?.quotas)
        #expect(snapshot.quotas.first { $0.id.rawValue == "rateLimitResetCredits" }?.remaining?.rawText == "3")
    }

    @Test("transport cancellation propagates without a fallback snapshot")
    func cancellation() async {
        let sessions = MemoryClaudeSessionProvider(results: [.success(session)])
        do {
            _ = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
                network: CancellingNetworkClient(),
                claudeSession: sessions
            ))
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await sessions.allowInteractionRequests == [false])
    }
}

private actor RecordingExternalSessionReader: ExternalSessionReader {
    private(set) var operationCount = 0

    func exists(_ request: ExternalFileRequest) -> Bool {
        operationCount += 1
        return false
    }

    func read(_ request: ExternalFileRequest) throws -> Data {
        operationCount += 1
        throw CollectionError(kind: .externalSessionMissing, diagnosticCode: "test.external.missing")
    }
}

private struct CancellingNetworkClient: NetworkClient {
    func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        throw CancellationError()
    }
}
