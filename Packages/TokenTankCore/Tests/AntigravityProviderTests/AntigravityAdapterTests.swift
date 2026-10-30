import Foundation
import Testing
@testable import AntigravityProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

private actor MemoryAntigravitySessionProvider: AntigravitySessionProviding {
    let reads: [AntigravityAccountRead]

    init(reads: [AntigravityAccountRead]) {
        self.reads = reads
    }

    func accounts() -> [AntigravityAccountRead] { reads }
}

@Suite("Antigravity quota summary adapter")
struct AntigravityAdapterTests {
    /// Shape of a live retrieveUserQuotaSummary response (values synthetic).
    private let summary = Data(
        """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {"bucketId": "gemini-weekly", "window": "weekly", "resetTime": "2026-10-31T03:08:24Z", "remainingFraction": 0.99022806},
                {"bucketId": "gemini-5h", "window": "5h", "resetTime": "2026-10-30T06:16:15Z", "remainingFraction": 0.25}
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {"bucketId": "3p-weekly", "window": "weekly", "resetTime": "2026-11-06T01:30:02Z", "remainingFraction": 1},
                {"bucketId": "3p-5h", "window": "5h", "resetTime": "2026-10-30T06:30:02Z", "remainingFraction": 0},
                {"bucketId": "3p-daily", "window": "daily", "disabled": true, "remainingFraction": 0.5}
              ]
            }
          ]
        }
        """.utf8
    )

    private let loadCodeAssist = Data(
        #"{"currentTier":{"id":"free-tier","name":"Antigravity"},"paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}"#.utf8
    )

    private func read(_ email: String, token: String, project: String? = "aicode-consumers") -> AntigravityAccountRead {
        AntigravityAccountRead(
            sourceID: "antigravity.\(email)",
            accountEmail: email,
            session: AntigravitySession(accessToken: token, accountEmail: email, projectID: project)
        )
    }

    private func ok(_ body: Data) -> Result<NetworkResponse, CollectionError> {
        .success(NetworkResponse(statusCode: 200, headers: [:], body: body))
    }

    @Test("buckets become remaining percentages per group, 5-hour before weekly, disabled skipped")
    func decodeSummary() throws {
        let snapshot = try AntigravityAdapter.decodeSnapshot(from: summary)
        #expect(snapshot.quotas.map(\.originalName) == ["gemini.5h", "gemini.weekly", "3p.5h", "3p.weekly"])
        #expect(snapshot.quotas.map(\.id.rawValue) == ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
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
    }

    @Test("a fraction outside 0...1, an unreadable reset time, or a missing group list fails closed")
    func schemaDrift() {
        let outOfRange = Data(#"{"groups":[{"buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":1.5}]}]}"#.utf8)
        let badReset = Data(#"{"groups":[{"buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,"resetTime":"tomorrow"}]}]}"#.utf8)
        #expect(throws: CollectionError.self) { try AntigravityAdapter.decodeSnapshot(from: outOfRange) }
        #expect(throws: CollectionError(kind: .schemaChanged, diagnosticCode: "antigravity.summary.reset-invalid")) {
            try AntigravityAdapter.decodeSnapshot(from: badReset)
        }
        #expect(throws: CollectionError.self) { try AntigravityAdapter.decodeSnapshot(from: Data("{}".utf8)) }
    }

    @Test("plan prefers the paid tier name, else maps the current tier")
    func plan() {
        #expect(AntigravityAdapter.decodePlan(from: loadCodeAssist) == "Google AI Pro")
        #expect(AntigravityAdapter.decodePlan(from: Data(#"{"currentTier":{"id":"standard-tier"}}"#.utf8)) == "Paid")
        #expect(AntigravityAdapter.decodePlan(from: Data("not json".utf8)) == nil)
    }

    @Test("fetch sends the summary for the stored project, then loadCodeAssist for the plan")
    func requestContract() async throws {
        let network = QueueNetworkClient(results: [ok(summary), ok(loadCodeAssist)])
        let context = TestContextFactory.make(
            network: network,
            antigravitySession: MemoryAntigravitySessionProvider(reads: [read("a@example.com", token: "token-a")])
        )

        let snapshot = try await AntigravityAdapter().fetchSnapshot(context: context)
        let requests = await network.requests
        #expect(requests.map(\.url) == [AntigravityRequestPolicy.quotaSummaryURL, AntigravityRequestPolicy.loadCodeAssistURL])
        #expect(requests.allSatisfy { $0.method == .post && $0.headers["Authorization"] == "Bearer token-a" })
        #expect(requests[0].body == Data(#"{"project":"aicode-consumers"}"#.utf8))
        #expect(requests[1].body == AntigravityRequestPolicy.loadCodeAssistBody)
        #expect(snapshot.accountEmail == "a@example.com")
        #expect(snapshot.quotas.count == 4)
        #expect(snapshot.quotas.allSatisfy { $0.sourceFields["plan"] == "Google AI Pro" })
    }

    @Test("a failed plan lookup keeps the usage")
    func planFailureIsNotFatal() async throws {
        let network = QueueNetworkClient(results: [
            ok(summary),
            .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
        ])
        let context = TestContextFactory.make(
            network: network,
            antigravitySession: MemoryAntigravitySessionProvider(reads: [read("a@example.com", token: "token-a", project: nil)])
        )
        let snapshot = try await AntigravityAdapter().fetchSnapshot(context: context)
        #expect(await network.requests.first?.body == Data("{}".utf8))
        #expect(snapshot.quotas.count == 4)
        #expect(snapshot.quotas.allSatisfy { $0.sourceFields["plan"] == nil })
    }

    @Test("a rejected token asks for a new sign-in")
    func rejected() async {
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 401, headers: [:], body: Data())),
        ])
        let context = TestContextFactory.make(
            network: network,
            antigravitySession: MemoryAntigravitySessionProvider(reads: [read("a@example.com", token: "token-a")])
        )
        await #expect(throws: CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "antigravity.summary.authentication.rejected",
            recoveryAction: .signInSourceApp
        )) {
            try await AntigravityAdapter().fetchSnapshot(context: context)
        }
        #expect(await network.requests.count == 1)
    }

    @Test("several sign-ins become account cards; one failing account keeps the other")
    func multipleAccounts() async throws {
        let expired = AntigravityAccountRead(
            sourceID: "antigravity.b",
            accountEmail: "b@example.com",
            session: nil,
            failure: CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.session.expired", recoveryAction: .runSourceCLI)
        )
        let network = QueueNetworkClient(results: [ok(summary), ok(loadCodeAssist)])
        let context = TestContextFactory.make(
            network: network,
            antigravitySession: MemoryAntigravitySessionProvider(reads: [read("a@example.com", token: "token-a"), expired])
        )
        let snapshot = try await AntigravityAdapter().fetchSnapshot(context: context)
        #expect(snapshot.accounts.count == 2)
        #expect(snapshot.account(for: "antigravity.a@example.com")?.plan == "Google AI Pro")
        #expect(snapshot.account(for: "antigravity.a@example.com")?.quotas.count == 4)
        #expect(snapshot.account(for: "antigravity.b")?.failure?.diagnosticCode == "antigravity.session.expired")
    }
}
