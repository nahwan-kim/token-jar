import Foundation
import Testing
@testable import GrokProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("xAI developer prepaid-balance adapter")
struct GrokAdapterTests {
    private let fixture = Data(
        """
        {
          "total": {"val": "-1000"},
          "changes": [
            {
              "changeOrigin": "PURCHASE",
              "amount": {"val": "-1000"},
              "createTime": "2026-08-20T10:00:00Z",
              "topupStatus": "SUCCEEDED",
              "paymentProcessor": {"kind": "STRIPE"}
            }
          ]
        }
        """.utf8
    )

    @Test("descriptor identifies official xAI developer billing, not consumer quota")
    func descriptor() {
        let descriptor = GrokAdapter().sourceDescriptor
        #expect(descriptor.id == "xai.management-api.prepaid-balance")
        #expect(descriptor.name == "xAI Management API prepaid balance")
        #expect(descriptor.kind == .officialAPI)
        #expect(descriptor.credentialOwnership == .tokenTank)
        #expect(descriptor.documentationURL?.absoluteString == "https://docs.x.ai/developers/management-api-guide")
        #expect(descriptor.detail.localizedCaseInsensitiveContains("official xAI developer prepaid balance"))
        #expect(descriptor.detail.localizedCaseInsensitiveContains("never presented as consumer SuperGrok"))
    }

    @Test("preserves the authoritative ledger direction without synthesizing quota")
    func decodeBalance() throws {
        let snapshot = try GrokAdapter.decodeSnapshot(from: fixture)

        #expect(snapshot.providerID == .grok)
        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.quotas[0].originalName == "total.val")
        #expect(snapshot.quotas[0].remaining?.value == -1000)
        #expect(snapshot.quotas[0].remaining?.rawText == "-1000")
        #expect(snapshot.quotas[0].remaining?.unit == "USD cents")
        #expect(snapshot.quotas[0].percentage.value == nil)
        #expect(snapshot.quotas[1].originalName == "PURCHASE")
        #expect(snapshot.quotas[1].used?.rawText == "-1000")
        #expect(snapshot.quotas[1].id.rawValue.hasPrefix("grok-change."))
        #expect(!snapshot.quotas[1].id.rawValue.contains("PURCHASE"))
        #expect(snapshot.quotas[1].sourceFields["paymentProcessor.kind"] == "STRIPE")
    }

    @Test("request uses a bounded unreserved team ID and only app-owned Keychain fields")
    func requestContract() async throws {
        let credentials = InMemoryCredentialStore(
            values: [
                CredentialID(providerID: .grok, name: "management-api-key"): "management-secret",
                CredentialID(providerID: .grok, name: "team-id"): "team_alpha-123",
            ]
        )
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let context = TestContextFactory.make(network: network, credentials: credentials)

        _ = try await GrokAdapter().fetchSnapshot(context: context)
        let request = try #require(await network.requests.first)

        #expect(request.method == .get)
        #expect(request.providerID == .grok)
        #expect(request.url.absoluteString.contains("/teams/team_alpha-123/prepaid/balance"))
        #expect(request.headers["Authorization"] == "Bearer management-secret")
        #expect(request.body == nil)
    }

    @Test("team ID path-control characters fail before network access")
    func invalidTeamID() async {
        let credentials = InMemoryCredentialStore(
            values: [
                CredentialID(providerID: .grok, name: "management-api-key"): "management-secret",
                CredentialID(providerID: .grok, name: "team-id"): "team/../alpha",
            ]
        )
        let network = QueueNetworkClient(results: [])
        do {
            _ = try await GrokAdapter().fetchSnapshot(
                context: TestContextFactory.make(network: network, credentials: credentials)
            )
            Issue.record("Expected team ID rejection")
        } catch let error as CollectionError {
            #expect(error.kind == .malformedResponse)
            #expect(error.diagnosticCode == "grok.team-id.invalid")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await network.requests.isEmpty)
    }

    @Test("missing team or key reports configuration")
    func missingConfiguration() async {
        let credentials = InMemoryCredentialStore(
            values: [CredentialID(providerID: .grok, name: "management-api-key"): "key-only"]
        )
        let availability = await GrokAdapter().probeAvailability(
            context: TestContextFactory.make(credentials: credentials)
        )
        guard case .needsConfiguration = availability else {
            Issue.record("Expected needsConfiguration")
            return
        }
    }

    @Test("empty successful object fails closed")
    func emptyObject() {
        #expect(throws: CollectionError.self) {
            try GrokAdapter.decodeSnapshot(from: Data("{}".utf8))
        }
    }

    @Test("missing balance-change inventory fails closed")
    func missingChanges() {
        do {
            _ = try GrokAdapter.decodeSnapshot(
                from: Data("{\"total\":{\"val\":\"100\"}}".utf8)
            )
            Issue.record("Expected missing changes failure")
        } catch let error as CollectionError {
            #expect(error.kind == .schemaChanged)
            #expect(error.diagnosticCode == "grok.balance-changes.missing-or-invalid")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
