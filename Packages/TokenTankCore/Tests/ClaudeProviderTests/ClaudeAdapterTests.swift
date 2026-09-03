import Foundation
import Testing
@testable import ClaudeProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Claude Code local usage cache adapter")
struct ClaudeAdapterTests {
    private let fixture = Data(
        """
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": 1788415439629,
            "accountUuid": "synthetic-account",
            "utilization": {
              "five_hour": {
                "utilization": 24,
                "resets_at": "2026-09-03T09:50:00.505688+00:00"
              },
              "seven_day": {
                "utilization": 22,
                "resets_at": "2026-09-08T13:00:00.505716+00:00"
              },
              "seven_day_opus": null,
              "extra_usage": {"is_enabled": false, "utilization": null},
              "limits": [
                {
                  "kind": "session",
                  "group": "session",
                  "percent": 24,
                  "resets_at": "2026-09-03T09:50:00.505688+00:00",
                  "scope": null
                },
                {
                  "kind": "weekly_all",
                  "group": "weekly",
                  "percent": 22,
                  "resets_at": "2026-09-08T13:00:00.505716+00:00",
                  "scope": null
                },
                {
                  "kind": "weekly_scoped",
                  "group": "weekly",
                  "percent": 44,
                  "resets_at": "2026-09-08T13:00:00.505935+00:00",
                  "scope": {"model": {"display_name": "Fable"}}
                }
              ]
            }
          }
        }
        """.utf8
    )

    @Test("preserves session, weekly, and scoped utilization without Admin API credentials")
    func decodeUsage() throws {
        let snapshot = try ClaudeAdapter.decodeSnapshot(from: fixture)
        let session = try #require(snapshot.quotas.first { $0.originalName == "session" })
        let weekly = try #require(snapshot.quotas.first { $0.originalName == "weekly_all" })
        let fable = try #require(snapshot.quotas.first { $0.originalName == "weekly_scoped.Fable" })

        #expect(snapshot.providerID == .claude)
        #expect(snapshot.source.id == "claude.code.local-usage-cache")
        #expect(snapshot.source.kind == .localSession)
        #expect(snapshot.source.credentialOwnership == .externalProvider)
        #expect(snapshot.source.detail.contains("Orca"))
        #expect(session.percentage.rawText == "24")
        #expect(session.percentage.meaning == .used)
        #expect(session.remaining?.rawText == "76")
        #expect(weekly.percentage.rawText == "22")
        #expect(fable.percentage.rawText == "44")
        #expect(fable.sourceFields["scope"] == "Fable")
        #expect(session.resetsAt != nil)
    }

    @Test("fetch reads only the Claude Code usage cache and sends no network")
    func requestContract() async throws {
        let request = ExternalFileRequest(
            providerID: .claude,
            relativePath: ".claude.json",
            maximumBytes: 32 * 1024 * 1024
        )
        let network = QueueNetworkClient(results: [])
        let context = TestContextFactory.make(
            network: network,
            externalSessions: MemoryExternalSessionReader(files: [request: fixture])
        )

        let snapshot = try await ClaudeAdapter().fetchSnapshot(context: context)
        #expect(snapshot.quotas.map(\.originalName) == ["session", "weekly_all", "weekly_scoped.Fable"])
        #expect(await network.requests.isEmpty)
    }

    @Test("missing local cache is source-owner setup, not a Token Tank credential")
    func missingCache() async {
        let availability = await ClaudeAdapter().probeAvailability(context: TestContextFactory.make())
        guard case let .unavailable(error) = availability else {
            Issue.record("Expected unavailable")
            return
        }
        #expect(error.kind == .externalSessionMissing)
        #expect(error.diagnosticCode == "claude.usage-cache.missing")
    }

    @Test("windows remain when the source omits the limits array")
    func windowFallback() throws {
        let body = Data(
            """
            {
              "cachedUsageUtilization": {
                "utilization": {
                  "five_hour": {"utilization": "11", "resets_at": "2026-09-03T09:50:00Z"},
                  "seven_day": {"utilization": 0}
                }
              }
            }
            """.utf8
        )
        let snapshot = try ClaudeAdapter.decodeSnapshot(from: body)
        #expect(snapshot.quotas.map(\.originalName) == ["five_hour", "seven_day"])
        #expect(snapshot.quotas[0].percentage.rawText == "11")
        #expect(snapshot.quotas[1].percentage.rawText == "0")
    }

    @Test("schema drift fails closed")
    func schemaDrift() {
        let bodies = [
            Data("{}".utf8),
            Data("{\"cachedUsageUtilization\":[]}".utf8),
            Data("{\"cachedUsageUtilization\":{\"utilization\":{\"limits\":[{\"kind\":\"session\"}]}}}".utf8),
        ]
        for body in bodies {
            do {
                _ = try ClaudeAdapter.decodeSnapshot(from: body)
                Issue.record("Expected schema failure")
            } catch let error as CollectionError {
                #expect(error.kind == .schemaChanged || error.kind == .malformedResponse)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}
