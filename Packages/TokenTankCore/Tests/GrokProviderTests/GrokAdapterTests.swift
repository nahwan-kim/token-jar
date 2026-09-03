import Foundation
import Testing
@testable import GrokProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Grok CLI SuperGrok credits adapter")
struct GrokAdapterTests {
    private let fixture = Data(
        """
        {
          "config": {
            "creditUsagePercent": 37.5,
            "currentPeriod": {"end": "2026-09-10T00:00:00Z"},
            "billingPeriodEnd": "2026-09-10T00:00:00Z"
          }
        }
        """.utf8
    )

    private let authFile = Data(
        """
        {
          "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": {
            "key": "synthetic-grok-session-token",
            "refresh_token": "synthetic-refresh",
            "expires_at": "2099-01-01T00:00:00Z",
            "auth_mode": "oidc",
            "email": "fixture@example.com",
            "team_id": "team-fixture",
            "user_id": "user-fixture",
            "first_name": "Fixture",
            "last_name": "User"
          }
        }
        """.utf8
    )

    @Test("descriptor identifies CodexBar SuperGrok credits, not Management prepaid balance")
    func descriptor() {
        let descriptor = GrokAdapter().sourceDescriptor
        #expect(descriptor.id == "grok.cli-proxy.credits")
        #expect(descriptor.name == "Grok CLI SuperGrok credits")
        #expect(descriptor.kind == .localSession)
        #expect(descriptor.credentialOwnership == .externalProvider)
        #expect(descriptor.detail.contains("cli-chat-proxy.grok.com"))
        #expect(descriptor.detail.contains("never imports browser cookies"))
        #expect(descriptor.detail.contains("never uses grok agent stdio"))
        #expect(descriptor.detail.contains("never calls the xAI Management prepaid-balance API"))
    }

    @Test("preserves published credit percent and reset without inventing quota")
    func decodeCredits() throws {
        let snapshot = try GrokAdapter.decodeSnapshot(from: fixture)
        let quota = try #require(snapshot.quotas.first)

        #expect(snapshot.providerID == .grok)
        #expect(snapshot.quotas.count == 1)
        #expect(quota.id.rawValue == "credits")
        #expect(quota.originalName == "credits")
        #expect(quota.percentage.rawText == "37.5")
        #expect(quota.percentage.meaning == .used)
        #expect(quota.remaining?.rawText == "62.5")
        #expect(quota.resetsAt != nil)
        #expect(quota.sourceFields["percentField"] == "creditUsagePercent")
    }

    @Test("on-demand ratio is used only when creditUsagePercent is absent")
    func derivedOnDemandPercent() throws {
        let body = Data(
            """
            {
              "config": {
                "onDemandUsed": {"val": 25},
                "onDemandCap": {"val": 100},
                "billingPeriodEnd": "2026-09-10T00:00:00Z"
              }
            }
            """.utf8
        )
        let snapshot = try GrokAdapter.decodeSnapshot(from: body)
        let quota = try #require(snapshot.quotas.first)
        #expect(quota.percentage.rawText == "25")
        #expect(quota.sourceFields["percentField"] == "onDemandUsed/onDemandCap")
    }

    @Test("fetch reads the Grok CLI auth file and never uses app-owned Management keys")
    func requestContract() async throws {
        let request = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let context = TestContextFactory.make(
            network: network,
            credentials: InMemoryCredentialStore(
                values: [CredentialID(providerID: .grok, name: "management-api-key"): "must-not-be-read"]
            ),
            externalSessions: MemoryExternalSessionReader(files: [request: authFile])
        )

        _ = try await GrokAdapter().fetchSnapshot(context: context)
        let sent = try #require(await network.requests.first)
        #expect(sent.method == .get)
        #expect(sent.providerID == .grok)
        #expect(sent.url.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(sent.headers["Authorization"] == "Bearer synthetic-grok-session-token")
        #expect(sent.headers["x-xai-token-auth"] == "xai-grok-cli")
        #expect(sent.body == nil)
    }

    @Test("missing auth file is source-owner setup, not a Token Tank credential")
    func missingSession() async {
        let availability = await GrokAdapter().probeAvailability(context: TestContextFactory.make())
        guard case let .needsConfiguration(code) = availability else {
            Issue.record("Expected needsConfiguration")
            return
        }
        #expect(code == "grok.cli-session.missing")
    }

    @Test("expired CLI token fails closed before network access")
    func expiredSession() async {
        let expired = Data(
            """
            {
              "https://auth.x.ai::fixture": {
                "key": "expired-token",
                "expires_at": "2020-01-01T00:00:00Z"
              }
            }
            """.utf8
        )
        let request = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let network = QueueNetworkClient(results: [])
        do {
            _ = try await GrokAdapter().fetchSnapshot(
                context: TestContextFactory.make(
                    network: network,
                    externalSessions: MemoryExternalSessionReader(files: [request: expired]),
                    clock: ManualClock(now: Date(timeIntervalSince1970: 1_800_000_000))
                )
            )
            Issue.record("Expected expired session")
        } catch let error as CollectionError {
            #expect(error.kind == .authenticationRevoked)
            #expect(error.diagnosticCode == "grok.cli-session.expired")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await network.requests.isEmpty)
    }

    @Test("management keys and cookie-shaped tokens are rejected")
    func rejectedTokenShapes() async {
        let bodies = [
            Data("{\"https://auth.x.ai::fixture\":{\"key\":\"xai-management\"}}".utf8),
            Data("{\"https://auth.x.ai::fixture\":{\"key\":\"Cookie: session=abc\"}}".utf8),
        ]
        for body in bodies {
            let request = ExternalFileRequest(
                providerID: .grok,
                relativePath: ".grok/auth.json",
                maximumBytes: 64 * 1024
            )
            let network = QueueNetworkClient(results: [])
            do {
                _ = try await GrokAdapter().fetchSnapshot(
                    context: TestContextFactory.make(
                        network: network,
                        externalSessions: MemoryExternalSessionReader(files: [request: body])
                    )
                )
                Issue.record("Expected token rejection")
            } catch let error as CollectionError {
                #expect(error.kind == .authenticationRejected)
                #expect(error.diagnosticCode == "grok.cli-session.token-missing")
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(await network.requests.isEmpty)
        }
    }

    @Test("period-only payload keeps credits without inventing a percent")
    func unknownUsage() throws {
        let body = Data(
            """
            {
              "config": {
                "currentPeriod": {"end": "2026-09-10T00:00:00Z"}
              }
            }
            """.utf8
        )
        let snapshot = try GrokAdapter.decodeSnapshot(from: body)
        let quota = try #require(snapshot.quotas.first)
        #expect(quota.percentage.value == nil)
        #expect(quota.used == nil)
        #expect(quota.resetsAt != nil)
    }
}
