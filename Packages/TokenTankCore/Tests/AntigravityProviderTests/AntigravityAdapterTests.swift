import Foundation
import Testing
@testable import AntigravityProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Antigravity CLI usage adapter")
struct AntigravityAdapterTests {
    /// Shape of a live `agy -p /usage --output-format json` `command.data` (values synthetic).
    private let usage = Data(
        """
        {
          "groups": [
            {
              "name": "Gemini Models",
              "description": "Models within this group: Gemini 4 Neon, Gemini 4 Hydrogen",
              "buckets": [
                {"id": "gemini-weekly", "name": "Weekly Limit Remaining", "window": "weekly", "reset_time": "2026-10-31T03:08:24Z", "remaining_fraction": 0.99022806},
                {"id": "gemini-5h", "name": "Five Hour Limit Remaining", "window": "5h", "reset_time": "2026-10-30T06:16:15Z", "remaining_fraction": 0.25}
              ]
            },
            {
              "name": "Claude and GPT models",
              "buckets": [
                {"id": "3p-weekly", "window": "weekly", "reset_time": "2026-11-06T01:30:02Z", "remaining_fraction": 1},
                {"id": "3p-5h", "window": "5h", "reset_time": "2026-10-30T06:30:02Z", "remaining_fraction": 0}
              ]
            },
            {
              "name": "Gemini 4 Argon",
              "buckets": [
                {"id": "gemini-argon-wtu-weekly", "window": "weekly", "reset_time": "2026-11-07T03:08:13Z", "remaining_fraction": 0.0021298667}
              ]
            }
          ]
        }
        """.utf8
    )

    @Test("buckets become remaining percentages per group, 5-hour before weekly")
    func decodeUsage() throws {
        let snapshot = try AntigravityAdapter.decodeSnapshot(from: usage)
        #expect(snapshot.quotas.map(\.originalName) == ["gemini.5h", "gemini.weekly", "3p.5h", "3p.weekly", "gemini-argon-wtu.weekly"])
        #expect(snapshot.quotas.map(\.id.rawValue) == ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly", "gemini-argon-wtu-weekly"])
        let gemini = snapshot.quotas[0]
        #expect(gemini.percentage.meaning == .remaining)
        #expect(gemini.percentage.value == 25)
        #expect(gemini.used?.value == 75)
        #expect(gemini.resetsAt == ISO8601DateFormatter().date(from: "2026-10-30T06:16:15Z"))
        #expect(gemini.sourceFields["antigravityGroup"] == "Gemini")
        #expect(snapshot.quotas[1].percentage.value == Decimal(string: "99.022806"))
        #expect(snapshot.quotas[2].percentage.value == 0)
        #expect(snapshot.quotas[3].percentage.value == 100)
        #expect(snapshot.quotas[3].sourceFields["antigravityGroup"] == "Claude/GPT")
        #expect(snapshot.quotas[4].sourceFields["antigravityGroup"] == "Gemini 4 Argon")
        #expect(snapshot.quotas[4].percentage.value == Decimal(string: "0.21298667"))
    }

    @Test("a fraction outside 0...1, an unreadable reset time, a bucket without a window, or a missing group list fails closed")
    func schemaDrift() {
        let outOfRange = Data(#"{"groups":[{"buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":1.5}]}]}"#.utf8)
        let badReset = Data(#"{"groups":[{"buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.5,"reset_time":"tomorrow"}]}]}"#.utf8)
        #expect(throws: CollectionError(kind: .schemaChanged, diagnosticCode: "antigravity.usage.fraction-invalid")) {
            try AntigravityAdapter.decodeSnapshot(from: outOfRange)
        }
        #expect(throws: CollectionError(kind: .schemaChanged, diagnosticCode: "antigravity.usage.reset-invalid")) {
            try AntigravityAdapter.decodeSnapshot(from: badReset)
        }
        let noWindow = Data(#"{"groups":[{"buckets":[{"id":"gemini-5h","remaining_fraction":0.5}]}]}"#.utf8)
        #expect(throws: CollectionError(kind: .schemaChanged, diagnosticCode: "antigravity.usage.window-invalid")) {
            try AntigravityAdapter.decodeSnapshot(from: noWindow)
        }
        #expect(throws: CollectionError(kind: .schemaChanged, diagnosticCode: "antigravity.usage.groups-missing")) {
            try AntigravityAdapter.decodeSnapshot(from: Data("{}".utf8))
        }
    }

    @Test("fetch uses only the CLI reader and passes its sign-in failure through")
    func fetchUsesTheReader() async throws {
        let signIn = CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "antigravity.agy.sign-in-required",
            recoveryAction: .signInSourceApp
        )
        let network = QueueNetworkClient(results: [])
        let context = TestContextFactory.make(
            network: network,
            antigravityUsage: MemoryAntigravityUsageReader(results: [.success(usage), .failure(signIn)])
        )

        let snapshot = try await AntigravityAdapter().fetchSnapshot(context: context)
        #expect(snapshot.quotas.count == 5)
        #expect(snapshot.accountEmail == nil)
        await #expect(throws: signIn) { try await AntigravityAdapter().fetchSnapshot(context: context) }
        #expect(await network.requests.isEmpty)
    }
}
