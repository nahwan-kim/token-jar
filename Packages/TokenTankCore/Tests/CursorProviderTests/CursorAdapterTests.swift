import Foundation
import Testing
@testable import CursorProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Cursor.app owner-session usage-summary adapter")
struct CursorAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var token: String {
        // exp is intentionally more than 60 seconds after the test clock.
        try! makeJWT(subject: "auth0|cursor-user-123", exp: 1_900_000_000)
    }

    private let fixture = Data(
        """
        {
          "billingCycleStart": "2026-08-01T00:00:00Z",
          "billingCycleEnd": "2026-09-01T00:00:00Z",
          "membershipType": "pro",
          "limitType": "monthly",
          "isUnlimited": false,
          "individualUsage": {
            "plan": {
              "enabled": true,
              "used": "100",
              "limit": "100",
              "remaining": "0",
              "breakdown": {"included": "80", "bonus": 0, "total": "80"},
              "autoPercentUsed": "20.5",
              "apiPercentUsed": 0,
              "totalPercentUsed": "50.0"
            },
            "onDemand": {"enabled": true, "used": "25", "limit": "100"},
            "overall": {"used": 0, "limit": 0, "remaining": 0}
          },
          "teamUsage": {
            "onDemand": {"used": "3", "limit": "10", "remaining": "7"},
            "pooled": {"enabled": false, "used": "0"}
          }
        }
        """.utf8
    )

    @Test("missing local token reports source configuration")
    func availabilityMissingToken() async {
        let availability = await CursorAdapter().probeAvailability(
            context: TestContextFactory.make(clock: ManualClock(now: now))
        )
        #expect(availability == .needsConfiguration(code: "cursor.app-session.missing"))
    }

    @Test("descriptor identifies the external Cursor.app local session")
    func descriptor() {
        let descriptor = CursorAdapter().sourceDescriptor
        #expect(descriptor.id == "cursor.app-session.usage-summary")
        #expect(descriptor.kind == .localSession)
        #expect(descriptor.credentialOwnership == .externalProvider)
        #expect(descriptor.documentationURL?.absoluteString == "https://prod.cursor.com/help/models-and-usage/usage-limits")
        #expect(descriptor.detail.localizedCaseInsensitiveContains("read-only"))
        #expect(descriptor.detail.localizedCaseInsensitiveContains("undocumented"))
        #expect(descriptor.detail.localizedCaseInsensitiveContains("fail closed"))
    }

    @Test("reads only the allowlisted SQLite key and sends an ephemeral owner cookie")
    func requestContract() async throws {
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let sqlite = RecordingSQLiteReader(token: token)
        let context = TestContextFactory.make(
            network: network,
            sqlite: sqlite,
            clock: ManualClock(now: now)
        )

        _ = try await CursorAdapter().fetchSnapshot(context: context)
        let request = try #require(await network.requests.first)
        #expect(request.providerID == .cursor)
        #expect(request.url.absoluteString == "https://cursor.com/api/usage-summary")
        #expect(request.method == .get)
        #expect(request.body == nil)
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Cookie"] == "WorkosCursorSessionToken=cursor-user-123%3A%3A\(token)")
        #expect(request.headers["Authorization"] == nil)
        let sqliteRequests = await sqlite.requests
        #expect(sqliteRequests.count == 1)
        let sqliteRequest = try #require(sqliteRequests.first)
        #expect(sqliteRequest.providerID == .cursor)
        #expect(sqliteRequest.root == .home)
        #expect(sqliteRequest.relativePath == "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        #expect(sqliteRequest.maximumBytes == 64 * 1024 * 1024)
        #expect(await sqlite.tables == ["ItemTable"])
        #expect(await sqlite.keyColumns == ["key"])
        #expect(await sqlite.valueColumns == ["value"])
        #expect(await sqlite.keys == [["cursorAuth/accessToken"]])
    }

    @Test("rejects expired, malformed, and oversized session tokens before network access")
    func jwtValidation() async throws {
        let network = QueueNetworkClient(results: [])
        let expired = try makeJWT(subject: "cursor-user-123", exp: 1_800_000_060)
        let malformed = "not-a-jwt"
        let oversized = String(repeating: "a", count: 32 * 1024 + 1)
        let oversizedSubject = try makeJWT(
            subject: String(repeating: "a", count: 257),
            exp: 1_900_000_000
        )

        for candidate in [expired, malformed, oversized, oversizedSubject] {
            let sqlite = MemorySQLiteReader(values: ["cursorAuth/accessToken": candidate])
            let context = TestContextFactory.make(
                network: network,
                sqlite: sqlite,
                clock: ManualClock(now: now)
            )
            do {
                _ = try await CursorAdapter().fetchSnapshot(context: context)
                Issue.record("Expected JWT validation failure")
            } catch let error as CollectionError {
                #expect(error.kind == (candidate == expired ? .authenticationRevoked : .schemaChanged))
                #expect(error.diagnosticCode == (candidate == expired ? "cursor.app-session.expired" : "cursor.app-session.jwt-invalid"))
            }
        }
        #expect(await network.requests.isEmpty)
    }

    @Test("preserves every usage block, percentage, breakdown, reset, and raw field")
    func fullResponseFidelity() throws {
        let snapshot = try CursorAdapter.decodeSnapshot(
            from: fixture,
            subject: "cursor-user-123",
            refreshedAt: now
        )

        #expect(snapshot.providerID == .cursor)
        #expect(snapshot.quotas.count == 11)
        #expect(snapshot.quotas.first?.originalName == "individualUsage.plan")
        #expect(snapshot.quotas.dropFirst().first?.originalName == "individualUsage.plan.breakdown.included")
        let plan = try #require(snapshot.quotas.first { $0.originalName == "individualUsage.plan" })
        #expect(plan.used?.rawText == "100")
        #expect(plan.remaining?.rawText == "0")
        #expect(plan.percentage.rawText == "50.0")
        #expect(plan.sourceFields["membershipType"] == "pro")
        #expect(plan.sourceFields["limitType"] == "monthly")
        #expect(plan.sourceFields["isUnlimited"] == "false")
        #expect(plan.sourceFields["billingCycleEnd"] == "2026-09-01T00:00:00Z")
        #expect(plan.sourceFields["resetSource"] == "2026-09-01T00:00:00Z")
        #expect(plan.resetsAt == ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))

        let breakdown = try #require(
            snapshot.quotas.first { $0.originalName == "individualUsage.plan.breakdown.included" }
        )
        #expect(breakdown.used?.rawText == "80")
        #expect(breakdown.sourceFields["breakdownField"] == "included")
        let auto = try #require(
            snapshot.quotas.first { $0.originalName == "individualUsage.plan.autoPercentUsed" }
        )
        #expect(auto.percentage.rawText == "20.5")
        #expect(auto.percentage.meaning == .used)
        #expect(snapshot.quotas.allSatisfy { !$0.id.rawValue.contains("cursor-user-123") })
        #expect(snapshot.quotas.allSatisfy { !$0.sourceFields.values.contains("cursor-user-123") })
        #expect(snapshot.quotas.allSatisfy { !$0.sourceFields.values.contains(token) })
    }

    @Test("derives only exact same-block remaining and percentage, preserving missing versus zero")
    func exactLocalArithmetic() throws {
        let response = Data(
            """
            {
              "billingCycleEnd": "2026-09-01T00:00:00Z",
              "individualUsage": {
                "onDemand": {"used": "25", "limit": "100"},
                "overall": {"used": "0", "limit": "0"}
              },
              "teamUsage": {"pooled": {"used": "0"}}
            }
            """.utf8
        )
        let snapshot = try CursorAdapter.decodeSnapshot(
            from: response,
            subject: "cursor-user-123",
            refreshedAt: now
        )
        let onDemand = try #require(snapshot.quotas.first { $0.originalName == "individualUsage.onDemand" })
        #expect(onDemand.used?.rawText == "25")
        #expect(onDemand.remaining?.rawText == "75")
        #expect(onDemand.percentage.rawText == "25")
        #expect(onDemand.sourceFields["derivedRemaining"] == "75")
        #expect(onDemand.sourceFields["derivedPercentage"] == "25")

        let overall = try #require(snapshot.quotas.first { $0.originalName == "individualUsage.overall" })
        #expect(overall.used?.rawText == "0")
        #expect(overall.remaining?.rawText == "0")
        #expect(overall.percentage.value == nil)
        let pooled = try #require(snapshot.quotas.first { $0.originalName == "teamUsage.pooled" })
        #expect(pooled.used?.rawText == "0")
        #expect(pooled.remaining == nil)
        #expect(pooled.percentage.value == nil)
    }

    @Test("rejects wrong containers, booleans as numbers, and negatives")
    func schemaErrors() {
        let fixtures = [
            Data("{\"individualUsage\": []}".utf8),
            Data("{\"individualUsage\": {\"plan\": {\"used\": true}}}".utf8),
            Data("{\"individualUsage\": {\"plan\": {\"used\": -1}}}".utf8),
            Data("{\"teamUsage\": {\"pooled\": []}}".utf8),
            Data("{\"individualUsage\": {\"plan\": {\"used\": 1, \"futureQuota\": 2}}}".utf8),
            Data("{\"individualUsage\": {\"plan\": {\"breakdown\": {\"included\": 1, \"future\": 2}}}}".utf8),
            Data("{\"individualUsage\": {\"plan\": {\"used\": 1}}, \"futureUsage\": {}}".utf8),
            Data("{\"billingCycleStart\":\"2026-09-01T00:00:00Z\",\"billingCycleEnd\":\"2026-08-01T00:00:00Z\",\"individualUsage\":{\"plan\":{\"used\":1}}}".utf8),
        ]
        for fixture in fixtures {
            do {
                _ = try CursorAdapter.decodeSnapshot(from: fixture, subject: "cursor-user-123", refreshedAt: now)
                Issue.record("Expected schema failure")
            } catch let error as CollectionError {
                #expect(error.kind == .schemaChanged)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("preserves transport user ID casing while hashing normalized identity")
    func transportIdentity() async throws {
        let mixedCaseToken = try makeJWT(subject: "auth0|User-ID", exp: 1_900_000_000)
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let snapshot = try await CursorAdapter().fetchSnapshot(
            context: TestContextFactory.make(
                network: network,
                sqlite: MemorySQLiteReader(values: ["cursorAuth/accessToken": mixedCaseToken]),
                clock: ManualClock(now: now)
            )
        )
        let request = try #require(await network.requests.first)
        #expect(request.headers["Cookie"] == "WorkosCursorSessionToken=User-ID%3A%3A\(mixedCaseToken)")
        #expect(snapshot.quotas.allSatisfy { !$0.id.rawValue.localizedCaseInsensitiveContains("user-id") })
    }

    @Test("disabled empty optional blocks do not erase valid quotas")
    func disabledOptionalBlock() throws {
        let response = Data(
            "{\"individualUsage\":{\"plan\":{\"used\":1},\"onDemand\":{\"enabled\":false}},\"teamUsage\":{}}".utf8
        )
        let snapshot = try CursorAdapter.decodeSnapshot(
            from: response,
            subject: "cursor-user-123",
            refreshedAt: now
        )
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas.first?.originalName == "individualUsage.plan")
    }

    @Test("empty successful responses fail closed")
    func emptyResponse() {
        do {
            _ = try CursorAdapter.decodeSnapshot(
                from: Data("{\"membershipType\":\"pro\",\"individualUsage\":{}}".utf8),
                subject: "cursor-user-123",
                refreshedAt: now
            )
            Issue.record("Expected empty response failure")
        } catch let error as CollectionError {
            #expect(error.kind == .malformedResponse)
            #expect(error.diagnosticCode == "cursor.usage-summary.empty-success")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private actor RecordingSQLiteReader: ReadOnlySQLiteReader {
        let token: String
        private(set) var requests: [ExternalFileRequest] = []
        private(set) var tables: [String] = []
        private(set) var keyColumns: [String] = []
        private(set) var valueColumns: [String] = []
        private(set) var keys: [[String]] = []

        init(token: String) {
            self.token = token
        }

        func values(
            in request: ExternalFileRequest,
            table: String,
            keyColumn: String,
            valueColumn: String,
            keys: [String]
        ) -> [String: String] {
            requests.append(request)
            tables.append(table)
            keyColumns.append(keyColumn)
            valueColumns.append(valueColumn)
            self.keys.append(keys)
            return ["cursorAuth/accessToken": token]
        }
    }
    private func makeJWT(subject: String, exp: Int) throws -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(Data("{\"alg\":\"none\"}".utf8))
        let payload = try JSONSerialization.data(
            withJSONObject: ["exp": exp, "sub": subject],
            options: [.sortedKeys]
        )
        return "\(header).\(base64URL(payload)).\(base64URL(Data("signature".utf8)))"
    }
}
