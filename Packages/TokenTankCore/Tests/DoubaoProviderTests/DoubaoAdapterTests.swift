import Foundation
import Testing
@testable import DoubaoProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Volcano plan usage adapter")
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

    @Test("maps every raw plan period and derives only exact same-row arithmetic")
    func decodePeriods() throws {
        let snapshot = try DoubaoAdapter.decodeSnapshot(from: fixture, mode: .codingPlan)

        #expect(snapshot.providerID == .doubao)
        #expect(snapshot.source.id == "volcano-openapi.coding-plan.usage")
        #expect(snapshot.quotas.map(\.originalName) == ["5h", "weekly"])
        #expect(snapshot.quotas[0].used?.value == 250)
        #expect(snapshot.quotas[0].remaining?.value == 750)
        #expect(snapshot.quotas[0].percentage.value == 25)
        #expect(snapshot.quotas[0].sourceFields["total"] == "1000")
        #expect(snapshot.quotas[1].resetsAt == Date(timeIntervalSince1970: 1_800_000_200))
    }

    @Test("source modes remain independent")
    func modesDoNotMerge() throws {
        let coding = try DoubaoAdapter.decodeSnapshot(from: fixture, mode: .codingPlan)
        let agent = try DoubaoAdapter.decodeSnapshot(from: fixture, mode: .agentPlan)

        #expect(coding.source.id != agent.source.id)
        #expect(coding.quotas.allSatisfy { $0.id.rawValue.hasPrefix("coding-plan.") })
        #expect(agent.quotas.allSatisfy { $0.id.rawValue.hasPrefix("agent-plan.") })
    }

    @Test("V4 request is deterministic and signs only the selected action")
    func signingContract() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let coding = try DoubaoAdapter.signedRequest(
            mode: .codingPlan,
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "dummy",
            date: date
        )
        let codingAgain = try DoubaoAdapter.signedRequest(
            mode: .codingPlan,
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "dummy",
            date: date
        )
        let agent = try DoubaoAdapter.signedRequest(
            mode: .agentPlan,
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "dummy",
            date: date
        )

        #expect(coding.url.host == "open.volcengineapi.com")
        #expect(coding.url.query?.contains("Action=GetCodingPlanUsage") == true)
        #expect(agent.url.host == "ark.cn-beijing.volces.com")
        #expect(agent.url.query?.contains("Action=GetAFPUsage") == true)
        #expect(coding.headers["X-Content-Sha256"] == "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
        #expect(coding.headers["Authorization"] == codingAgain.headers["Authorization"])
        #expect(coding.headers["Authorization"] != agent.headers["Authorization"])
        #expect(coding.headers["Authorization"]?.contains("dummy") == false)
        #expect(coding.body == Data("{}".utf8))
    }

    @Test("fetch reads the configured AK/SK from the app credential capability")
    func fetchContract() async throws {
        let credentials = InMemoryCredentialStore(
            values: [
                CredentialID(providerID: .doubao, name: "access-key-id"): "access",
                CredentialID(providerID: .doubao, name: "secret-access-key"): "secret",
            ]
        )
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let context = TestContextFactory.make(network: network, credentials: credentials)

        let snapshot = try await DoubaoAdapter(mode: .agentPlan).fetchSnapshot(context: context)
        let request = try #require(await network.requests.first)
        #expect(snapshot.source.id.contains("agent-plan"))
        #expect(request.providerID == .doubao)
        #expect(request.url.query?.contains("Action=GetAFPUsage") == true)
    }
}
