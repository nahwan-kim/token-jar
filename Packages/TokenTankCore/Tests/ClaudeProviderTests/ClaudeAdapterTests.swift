import Foundation
import Testing
@testable import ClaudeProvider
import TokenTankCore
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
        ])
        let clock = ManualClock(now: now)
        let snapshot = try await ClaudeAdapter().fetchSnapshot(context: TestContextFactory.make(
            network: network,
            claudeSession: sessions,
            clock: clock,
            isUserInitiated: true
        ))
        let requests = await network.requests
        #expect(requests.count == 2)
        let usage = requests[0]
        #expect(usage.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(usage.method == .get)
        #expect(usage.timeout == 30)
        #expect(usage.headers == [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": "Bearer synthetic-claude-token",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
        ])
        #expect(requests[1].url.absoluteString == "https://api.anthropic.com/api/oauth/profile")
        #expect(requests[1].headers == usage.headers)
        #expect(requests[1].timeout == 15)
        #expect(await sessions.allowInteractionRequests == [true])
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
            .success(NetworkResponse(statusCode: 200, headers: [:], body: second)),
            .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
        ])
        let external = RecordingExternalSessionReader()
        let context = TestContextFactory.make(network: network, claudeSession: sessions, externalSessions: external)
        let adapter = ClaudeAdapter()
        let old = try await adapter.fetchSnapshot(context: context)
        let new = try await adapter.fetchSnapshot(context: context)
        #expect(old.quotas[0].percentage.value == 12)
        #expect(new.quotas[0].percentage.value == 47)
        #expect(await network.requests.filter { $0.url.path == "/api/oauth/usage" }.count == 2)
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
            .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            .success(NetworkResponse(
                statusCode: 403,
                headers: [:],
                body: Data("{\"account\":{\"email\":\"stale@example.com\"}}".utf8)
            )),
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

    @Test("authentication and scope rejection are sanitized and never retried")
    func authenticationFailures() async {
        for status in [401, 403] {
            let sessions = MemoryClaudeSessionProvider(results: [.success(session)])
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
            #expect(await sessions.allowInteractionRequests == [false])
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
            #expect(await network.requests.filter { $0.url.path == "/api/oauth/usage" }.count == 2)
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
