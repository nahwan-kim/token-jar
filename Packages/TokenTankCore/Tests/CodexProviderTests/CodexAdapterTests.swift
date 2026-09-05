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
        let reader = MemoryCodexAccountUsageReader(
            results: [
                .success([
                    CodexAccountRead.success(sourceID: .primary, data: payload),
                ]),
            ]
        )
        let context = TestContextFactory.make(codexAccount: reader)

        let snapshot = try await CodexAdapter().fetchSnapshot(context: context)
        #expect(snapshot.quotas.first?.percentage.value == 12)
        #expect(snapshot.accountEmail == "codex@example.com")
    }
    @Test("keeps identical raw quota IDs separate by account source")
    func identicalQuotaIDsStaySeparate() async throws {
        let reader = MemoryCodexAccountUsageReader(
            results: [
                .success([
                    CodexAccountRead.success(
                        sourceID: .primary,
                        data: Self.payload(email: "primary@example.com", usedPercent: 11)
                    ),
                    CodexAccountRead.success(
                        sourceID: .secondary,
                        data: Self.payload(email: "secondary@example.com", usedPercent: 77)
                    ),
                ]),
            ]
        )

        let snapshot = try await CodexAdapter().fetchSnapshot(
            context: TestContextFactory.make(codexAccount: reader)
        )
        let primary = try #require(snapshot.account(for: CodexAccountSource.primary.id))
        let secondary = try #require(snapshot.account(for: CodexAccountSource.secondary.id))

        #expect(primary.quotas.map(\.id.rawValue) == ["codex.primary"])
        #expect(secondary.quotas.map(\.id.rawValue) == ["codex.primary"])
        #expect(primary.quotas.first?.percentage.value == 11)
        #expect(secondary.quotas.first?.percentage.value == 77)
    }

    @Test("default and secondary account failures remain independent")
    func accountFailuresRemainIndependent() async throws {
        let primaryFailure = CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "test.codex.primary-unavailable"
        )
        let secondaryFailure = CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "test.codex.secondary-auth"
        )
        let reader = MemoryCodexAccountUsageReader(
            results: [
                .success([
                    CodexAccountRead.failed(sourceID: .primary, failure: primaryFailure),
                    CodexAccountRead.success(
                        sourceID: .secondary,
                        data: Self.payload(email: "secondary@example.com", usedPercent: 31)
                    ),
                ]),
                .success([
                    CodexAccountRead.success(
                        sourceID: .primary,
                        data: Self.payload(email: "primary@example.com", usedPercent: 19)
                    ),
                    CodexAccountRead.failed(sourceID: .secondary, failure: secondaryFailure),
                ]),
            ]
        )
        let adapter = CodexAdapter()
        let context = TestContextFactory.make(codexAccount: reader)

        let primaryFailureSnapshot = try await adapter.fetchSnapshot(context: context)
        let primaryFailed = try #require(
            primaryFailureSnapshot.account(for: CodexAccountSource.primary.id)
        )
        let secondarySucceeded = try #require(
            primaryFailureSnapshot.account(for: CodexAccountSource.secondary.id)
        )
        #expect(primaryFailed.failure == primaryFailure)
        #expect(secondarySucceeded.failure == nil)
        #expect(secondarySucceeded.quotas.first?.percentage.value == 31)

        let secondaryFailureSnapshot = try await adapter.fetchSnapshot(context: context)
        let primarySucceeded = try #require(
            secondaryFailureSnapshot.account(for: CodexAccountSource.primary.id)
        )
        let secondaryFailed = try #require(
            secondaryFailureSnapshot.account(for: CodexAccountSource.secondary.id)
        )
        #expect(primarySucceeded.failure == nil)
        #expect(primarySucceeded.quotas.first?.percentage.value == 19)
        #expect(secondaryFailed.failure == secondaryFailure)
        #expect(secondaryFailureSnapshot.quotas.isEmpty)
    }

    @Test("duplicate account source identity fails closed")
    func duplicateAccountSourceIdentity() async throws {
        let reader = MemoryCodexAccountUsageReader(
            results: [
                .success([
                    CodexAccountRead.success(
                        sourceID: .primary,
                        data: Self.payload(email: "first@example.com", usedPercent: 10)
                    ),
                    CodexAccountRead.success(
                        sourceID: .primary,
                        data: Self.payload(email: "second@example.com", usedPercent: 20)
                    ),
                ]),
            ]
        )

        do {
            _ = try await CodexAdapter().fetchSnapshot(
                context: TestContextFactory.make(codexAccount: reader)
            )
            Issue.record("Expected duplicate account source identity to fail")
        } catch let error as CollectionError {
            #expect(error.diagnosticCode == "codex.accounts.duplicate-identity")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("changed account emails remain attached to their stable source IDs")
    func changedEmailDoesNotCrossAccounts() async throws {
        let reader = MemoryCodexAccountUsageReader(
            results: [
                .success([
                    CodexAccountRead.success(
                        sourceID: .primary,
                        data: Self.payload(email: "old-primary@example.com", usedPercent: 10)
                    ),
                    CodexAccountRead.success(
                        sourceID: .secondary,
                        data: Self.payload(email: "old-secondary@example.com", usedPercent: 20)
                    ),
                ]),
                .success([
                    CodexAccountRead.success(
                        sourceID: .secondary,
                        data: Self.payload(email: "new-secondary@example.com", usedPercent: 40)
                    ),
                    CodexAccountRead.success(
                        sourceID: .primary,
                        data: Self.payload(email: "new-primary@example.com", usedPercent: 30)
                    ),
                ]),
            ]
        )
        let adapter = CodexAdapter()
        let context = TestContextFactory.make(codexAccount: reader)

        let first = try await adapter.fetchSnapshot(context: context)
        let second = try await adapter.fetchSnapshot(context: context)
        #expect(first.account(for: CodexAccountSource.primary.id)?.accountEmail == "old-primary@example.com")
        #expect(first.account(for: CodexAccountSource.secondary.id)?.accountEmail == "old-secondary@example.com")
        #expect(second.account(for: CodexAccountSource.primary.id)?.accountEmail == "new-primary@example.com")
        #expect(second.account(for: CodexAccountSource.secondary.id)?.accountEmail == "new-secondary@example.com")
        #expect(second.account(for: CodexAccountSource.primary.id)?.quotas.first?.percentage.value == 30)
        #expect(second.account(for: CodexAccountSource.secondary.id)?.quotas.first?.percentage.value == 40)
    }

    private static func payload(email: String, usedPercent: Int) -> Data {
        Data(
            """
            {
              "account": {"type": "chatgpt", "email": "\(email)"},
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": \(usedPercent)}
              }
            }
            """.utf8
        )
    }
}
