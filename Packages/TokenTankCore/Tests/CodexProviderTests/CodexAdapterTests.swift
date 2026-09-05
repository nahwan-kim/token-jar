import Foundation
import Testing
@testable import CodexProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Codex official app-server adapter")
struct CodexAdapterTests {
    @Test("maps every keyed rate-limit window and reset credit without fallback merging")
    func keyedRateLimits() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "legacy",
                "primary": {"usedPercent": 99, "windowDurationMins": 15, "resetsAt": 1800000000}
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "limitName": "Codex",
                  "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1800000100},
                  "secondary": {"usedPercent": "42.5", "windowDurationMins": 10080, "resetsAt": 1800000200}
                },
                "codex_other": {
                  "limitId": "codex_other",
                  "limitName": "codex_other",
                  "primary": {"usedPercent": 5, "windowDurationMins": 60, "resetsAt": 1800000300}
                }
              },
              "rateLimitResetCredits": {
                "availableCount": 2,
                "credits": [
                  {"id": "credit-1", "title": "Rate-limit reset", "status": "available", "expiresAt": 1800000400}
                ]
              }
            }
            """.utf8
        )

        let snapshot = try CodexAdapter.decodeSnapshot(
            from: data,
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(snapshot.providerID == .codex)
        #expect(snapshot.quotas.map(\.id.rawValue) == [
            "codex.primary",
            "codex.secondary",
            "codex_other.primary",
            "rateLimitResetCredits",
            "rateLimitResetCredit.credit-1",
        ])
        #expect(!snapshot.quotas.contains(where: { $0.id.rawValue.hasPrefix("legacy") }))
        #expect(snapshot.quotas[0].percentage.value == 25)
        #expect(snapshot.quotas[0].remaining?.rawText == "75")
        #expect(snapshot.quotas[1].percentage.rawText == "42.5")
        #expect(snapshot.quotas[1].sourceFields["windowDurationMins"] == "10080")
        #expect(snapshot.quotas[3].remaining?.rawText == "2")
    }

    @Test("falls back to the single official bucket only when keyed map is absent")
    func legacySingleBucket() throws {
        let data = Data(
            """
            {"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1800000100}}}
            """.utf8
        )
        let snapshot = try CodexAdapter.decodeSnapshot(from: data)
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].percentage.value == 0)
    }

    @Test("empty keyed map fails closed instead of silently changing source shape")
    func emptyKeyedMap() {
        #expect(throws: CollectionError.self) {
            try CodexAdapter.decodeSnapshot(
                from: Data("{\"rateLimitsByLimitId\":{}}".utf8)
            )
        }
    }

    @Test("decodes a documented ChatGPT account email alongside rate limits")
    func accountEmail() throws {
        let data = Data(
            """
            {
              "account": {
                "type": "chatgpt",
                "email": "  owner@example.com  "
              },
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 12}
              }
            }
            """.utf8
        )

        let snapshot = try CodexAdapter.decodeSnapshot(from: data)

        #expect(snapshot.accountEmail == "owner@example.com")
        #expect(snapshot.quotas.count == 1)
    }

    @Test("omits account email when account metadata is missing or has the wrong shape")
    func malformedAccountMetadata() throws {
        let payloads = [
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 12}
              }
            }
            """,
            """
            {
              "account": "owner@example.com",
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 12}
              }
            }
            """,
            """
            {
              "account": {"email": 42},
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 12}
              }
            }
            """,
        ]

        for payload in payloads {
            let snapshot = try CodexAdapter.decodeSnapshot(from: Data(payload.utf8))
            #expect(snapshot.accountEmail == nil)
            #expect(snapshot.quotas.count == 1)
        }
    }
    @Test("fetch reads only the injected app-server capability")
    func injectedReader() async throws {
        let payload = Data(
            """
            {
              "account": {
                "type": "chatgpt",
                "email": "codex@example.com"
              },
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1800000100}
              }
            }
            """.utf8
        )
        let reader = MemoryCodexAccountUsageReader(results: [.success(payload)])
        let context = TestContextFactory.make(codexAccount: reader)

        let snapshot = try await CodexAdapter().fetchSnapshot(context: context)
        #expect(snapshot.quotas.first?.percentage.value == 12)
        #expect(snapshot.accountEmail == "codex@example.com")
    }
}
