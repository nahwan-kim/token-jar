import Foundation
import Testing
@testable import DoubaoProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Volcano arkcli plan usage adapter")
struct DoubaoAdapterTests {
    private let fixture = Data(
        """
        {
          "Result": {
            "QuotaUsage": [
              {"Level":"5h","Used":250,"Quota":1000,"Percent":25,"ResetTimestamp":1800000100},
              {"Level":"weekly","Used":"12500","Quota":"50000","Percent":"25","ResetTimestamp":"1800000200000"}
            ]
          }
        }
        """.utf8
    )

    @Test("descriptor identifies arkcli plan usage, not OpenAPI AK/SK")
    func descriptor() {
        let descriptor = DoubaoAdapter().sourceDescriptor
        #expect(descriptor.id == "volcano.arkcli.usage-plan")
        #expect(descriptor.kind == .officialCLI)
        #expect(descriptor.credentialOwnership == .externalProvider)
        #expect(descriptor.detail.contains("arkcli usage plan --format json"))
        #expect(descriptor.detail.contains("never signs OpenAPI requests"))
    }

    @Test("maps every raw plan period and derives only exact same-row arithmetic")
    func decodePeriods() throws {
        let snapshot = try DoubaoAdapter.decodeSnapshot(from: fixture)
        #expect(snapshot.providerID == .doubao)
        #expect(snapshot.source.id == "volcano.arkcli.usage-plan")
        #expect(snapshot.quotas.map(\.originalName) == ["5h", "weekly"])
        #expect(snapshot.quotas[0].used?.value == 250)
        #expect(snapshot.quotas[0].remaining?.value == 750)
        #expect(snapshot.quotas[0].percentage.value == 25)
        #expect(snapshot.quotas[0].sourceFields["total"] == "1000")
        #expect(snapshot.quotas[1].resetsAt == Date(timeIntervalSince1970: 1_800_000_200))
    }

    @Test("fetch reads arkcli output and never uses app-owned credentials or network")
    func fetchContract() async throws {
        let credentials = InMemoryCredentialStore(
            values: [CredentialID(providerID: .doubao, name: "access-key-id"): "must-not-be-read"]
        )
        let network = QueueNetworkClient(results: [])
        let context = TestContextFactory.make(
            network: network,
            credentials: credentials,
            doubaoPlan: MemoryDoubaoPlanUsageReader(results: [.success(fixture)])
        )

        let snapshot = try await DoubaoAdapter().fetchSnapshot(context: context)
        #expect(snapshot.quotas.map(\.originalName) == ["5h", "weekly"])
        #expect(await network.requests.isEmpty)
    }

    @Test("expired arkcli SSO is source-owner setup, not a Token Tank credential")
    func missingSession() throws {
        let body = Data(
            """
            {
              "ok": false,
              "error": {
                "type": "error",
                "message": "please run arkcli auth login volc-sso: refresh_token is invalid"
              }
            }
            """.utf8
        )
        do {
            _ = try DoubaoAdapter.decodeSnapshot(from: body)
            Issue.record("Expected missing session")
        } catch let error as CollectionError {
            #expect(error.kind == .externalSessionMissing)
            #expect(error.diagnosticCode == "doubao.arkcli.session-missing")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
