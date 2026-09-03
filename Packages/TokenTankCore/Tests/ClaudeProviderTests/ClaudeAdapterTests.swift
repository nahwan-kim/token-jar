import Foundation
import Testing
@testable import ClaudeProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Claude organization Admin API adapter")
struct ClaudeAdapterTests {
    private let fixture = Data(
        """
        {
          "data": [
            {
              "starting_at": "2026-08-01T00:00:00Z",
              "ending_at": "2026-08-02T00:00:00Z",
              "results": [
                {
                  "model": "claude-sonnet",
                  "context_window": 200000,
                  "uncached_input_tokens": 10,
                  "output_tokens": "4",
                  "cache_creation": {"ephemeral_5m_input_tokens": 3},
                  "server_tool_use": {"web_search_requests": 99}
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """.utf8
    )

    @Test("preserves organization token categories without inventing subscription quota")
    func decodeUsage() throws {
        let snapshot = try ClaudeAdapter.decodeSnapshot(from: fixture)

        #expect(snapshot.providerID == .claude)
        #expect(snapshot.source.detail.contains("never presented as Claude Pro/Max consumer subscription quota"))
        #expect(Set(snapshot.quotas.map(\.originalName)) == [
            "uncached_input_tokens",
            "output_tokens",
            "ephemeral_5m_input_tokens",
            "web_search_requests",
        ])
        #expect(snapshot.quotas.allSatisfy { $0.remaining == nil })
        #expect(snapshot.quotas.allSatisfy { $0.percentage.value == nil })
        #expect(snapshot.quotas.allSatisfy { $0.resetsAt == nil })
        #expect(snapshot.quotas.first(where: { $0.originalName == "web_search_requests" })?.used?.unit == "requests")
        #expect(snapshot.quotas.allSatisfy { $0.sourceFields["context_window"] == "200000" })
    }

    @Test("fetch uses current-month UTC bounds and an app-owned Admin key")
    func requestContract() async throws {
        let now = Date(timeIntervalSince1970: 1_789_430_400) // 2026-09-15T00:00:00Z
        let clock = ManualClock(now: now)
        let credentials = InMemoryCredentialStore(
            values: [CredentialID(providerID: .claude, name: "admin-api-key"): "admin-secret"]
        )
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let context = TestContextFactory.make(network: network, credentials: credentials, clock: clock)

        _ = try await ClaudeAdapter().fetchSnapshot(context: context)
        let request = try #require(await network.requests.first)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.method == .get)
        #expect(request.providerID == .claude)
        #expect(request.headers["x-api-key"] == "admin-secret")
        #expect(request.headers["anthropic-version"] == "2023-06-01")
        #expect(query["starting_at"] == "2026-09-01T00:00:00Z")
        #expect(query["ending_at"] == "2026-09-15T00:00:00Z")
        #expect(query["bucket_width"] == "1d")
    }

    @Test("fetch follows the official page token without dropping buckets")
    func pagination() async throws {
        let firstPage = Data(
            """
            {
              "data": [
                {
                  "starting_at": "2026-09-01T00:00:00Z",
                  "ending_at": "2026-09-02T00:00:00Z",
                  "results": [{"uncached_input_tokens": 10}]
                }
              ],
              "has_more": true,
              "next_page": "page-2"
            }
            """.utf8
        )
        let secondPage = Data(
            """
            {
              "data": [
                {
                  "starting_at": "2026-09-02T00:00:00Z",
                  "ending_at": "2026-09-03T00:00:00Z",
                  "results": [{"output_tokens": 4}]
                }
              ],
              "has_more": false,
              "next_page": null
            }
            """.utf8
        )
        let credentials = InMemoryCredentialStore(
            values: [CredentialID(providerID: .claude, name: "admin-api-key"): "admin-secret"]
        )
        let network = QueueNetworkClient(
            results: [
                .success(NetworkResponse(statusCode: 200, headers: [:], body: firstPage)),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: secondPage)),
            ]
        )
        let context = TestContextFactory.make(network: network, credentials: credentials)

        let snapshot = try await ClaudeAdapter().fetchSnapshot(context: context)
        #expect(snapshot.quotas.map(\.originalName) == ["uncached_input_tokens", "output_tokens"])
        let requests = await network.requests
        #expect(requests.count == 2)
        let secondQuery = URLComponents(
            url: requests[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(secondQuery?.first(where: { $0.name == "page" })?.value == "page-2")
    }

    @Test("pagination metadata fails closed when a next-page token is absent")
    func invalidPagination() async throws {
        var root = try #require(
            JSONSerialization.jsonObject(with: fixture) as? [String: Any]
        )
        root["has_more"] = true
        root.removeValue(forKey: "next_page")
        let body = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let credentials = InMemoryCredentialStore(
            values: [CredentialID(providerID: .claude, name: "admin-api-key"): "admin-secret"]
        )
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: body))]
        )
        let context = TestContextFactory.make(network: network, credentials: credentials)

        do {
            _ = try await ClaudeAdapter().fetchSnapshot(context: context)
            Issue.record("Expected invalid pagination metadata")
        } catch let error as CollectionError {
            #expect(error.kind == .schemaChanged)
            #expect(error.diagnosticCode == "claude.usage.pagination-invalid")
        }
    }

    @Test("missing credential is configuration-required, not a transient login guess")
    func missingCredential() async {
        let context = TestContextFactory.make(credentials: InMemoryCredentialStore())
        let availability = await ClaudeAdapter().probeAvailability(context: context)
        guard case let .needsConfiguration(code) = availability else {
            Issue.record("Expected needsConfiguration")
            return
        }
        #expect(code == "claude.credentials.missing")
    }

    @Test("Retry-After survives HTTP error classification")
    func retryAfter() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credentials = InMemoryCredentialStore(
            values: [CredentialID(providerID: .claude, name: "admin-api-key"): "admin-secret"]
        )
        let network = QueueNetworkClient(
            results: [
                .success(NetworkResponse(statusCode: 429, headers: ["Retry-After": "120"], body: Data())),
            ]
        )
        let context = TestContextFactory.make(network: network, credentials: credentials, clock: ManualClock(now: now))

        do {
            _ = try await ClaudeAdapter().fetchSnapshot(context: context)
            Issue.record("Expected rate limit")
        } catch let error as CollectionError {
            #expect(error.kind == .rateLimited)
            #expect(error.retryAfter == now.addingTimeInterval(120))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
