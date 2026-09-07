import Foundation
import Testing
@testable import GrokProvider
import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Grok CLI SuperGrok credits adapter")
struct GrokAdapterTests {
    private let fixture = Data(
        """
        {
          "config": {
            "creditUsagePercent": 37.5,
            "currentPeriod": {"end": "2026-09-10T00:00:00Z"},
            "billingPeriodEnd": "2026-09-10T00:00:00Z"
          }
        }
        """.utf8
    )

    private let authFile = Data(
        """
        {
          "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": {
            "key": "synthetic-grok-session-token",
            "refresh_token": "synthetic-refresh",
            "expires_at": "2099-01-01T00:00:00Z",
            "auth_mode": "oidc",
            "email": "fixture@example.com",
            "team_id": "team-fixture",
            "user_id": "user-fixture",
            "first_name": "Fixture",
            "last_name": "User"
          }
        }
        """.utf8
    )

    @Test("descriptor identifies CodexBar SuperGrok credits, not Management prepaid balance")
    func descriptor() {
        let descriptor = GrokAdapter().sourceDescriptor
        #expect(descriptor.id == "grok.cli-proxy.credits")
        #expect(descriptor.name == "Grok CLI SuperGrok credits")
        #expect(descriptor.kind == .localSession)
        #expect(descriptor.credentialOwnership == .externalProvider)
        #expect(descriptor.detail.contains("cli-chat-proxy.grok.com"))
        #expect(descriptor.detail.contains("never imports browser cookies"))
        #expect(descriptor.detail.contains("never uses grok agent stdio"))
        #expect(descriptor.detail.contains("never calls the xAI Management prepaid-balance API"))
    }

    @Test("preserves published credit percent and reset without inventing quota")
    func decodeCredits() throws {
        let snapshot = try GrokAdapter.decodeSnapshot(from: fixture)
        let quota = try #require(snapshot.quotas.first)

        #expect(snapshot.providerID == .grok)
        #expect(snapshot.accountEmail == nil)
        #expect(snapshot.quotas.count == 1)
        #expect(quota.id.rawValue == "credits")
        #expect(quota.originalName == "credits")
        #expect(quota.percentage.rawText == "37.5")
        #expect(quota.percentage.meaning == .used)
        #expect(quota.remaining?.rawText == "62.5")
        #expect(quota.resetsAt != nil)
        #expect(quota.sourceFields["percentField"] == "creditUsagePercent")
    }

    @Test("on-demand ratio is used only when creditUsagePercent is absent")
    func derivedOnDemandPercent() throws {
        let body = Data(
            """
            {
              "config": {
                "onDemandUsed": {"val": 25},
                "onDemandCap": {"val": 100},
                "billingPeriodEnd": "2026-09-10T00:00:00Z"
              }
            }
            """.utf8
        )
        let snapshot = try GrokAdapter.decodeSnapshot(from: body)
        let quota = try #require(snapshot.quotas.first)
        #expect(quota.percentage.rawText == "25")
        #expect(quota.sourceFields["percentField"] == "onDemandUsed/onDemandCap")
    }

    @Test("fetch reads the Grok CLI auth file and never uses app-owned Management keys")
    func requestContract() async throws {
        let request = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let context = TestContextFactory.make(
            network: network,
            credentials: InMemoryCredentialStore(
                values: [CredentialID(providerID: .grok, name: "management-api-key"): "must-not-be-read"]
            ),
            externalSessions: MemoryExternalSessionReader(files: [request: authFile])
        )

        let snapshot = try await GrokAdapter().fetchSnapshot(context: context)
        #expect(snapshot.accountEmail == "fixture@example.com")
        let sent = try #require(await network.requests.first)
        #expect(sent.method == .get)
        #expect(sent.providerID == .grok)
        #expect(sent.url.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(sent.headers["Authorization"] == "Bearer synthetic-grok-session-token")
        #expect(sent.headers["x-xai-token-auth"] == "xai-grok-cli")
        #expect(sent.body == nil)
    }

    @Test("missing or malformed auth email keeps Grok quotas available")
    func optionalAccountEmail() async throws {
        let bodies = [
            Data(
                """
                {
                  "https://auth.x.ai::fixture": {
                    "key": "synthetic-grok-session-token",
                    "expires_at": "2099-01-01T00:00:00Z"
                  }
                }
                """.utf8
            ),
            Data(
                """
                {
                  "https://auth.x.ai::fixture": {
                    "key": "synthetic-grok-session-token",
                    "expires_at": "2099-01-01T00:00:00Z",
                    "email": "not-an-email"
                  }
                }
                """.utf8
            ),
        ]

        for body in bodies {
            let request = ExternalFileRequest(
                providerID: .grok,
                relativePath: ".grok/auth.json",
                maximumBytes: 64 * 1024
            )
            let network = QueueNetworkClient(
                results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
            )
            let context = TestContextFactory.make(
                network: network,
                externalSessions: MemoryExternalSessionReader(files: [request: body])
            )

            let snapshot = try await GrokAdapter().fetchSnapshot(context: context)
            #expect(snapshot.accountEmail == nil)
            #expect(snapshot.quotas.count == 1)
        }
    }

    @Test("missing auth file is source-owner setup, not a Token Jar credential")
    func missingSession() async {
        let availability = await GrokAdapter().probeAvailability(context: TestContextFactory.make())
        guard case let .needsConfiguration(code) = availability else {
            Issue.record("Expected needsConfiguration")
            return
        }
        #expect(code == "grok.cli-session.missing")
    }

    @Test("expired CLI token fails closed before network access")
    func expiredSession() async {
        let expired = Data(
            """
            {
              "https://auth.x.ai::fixture": {
                "key": "expired-token",
                "expires_at": "2020-01-01T00:00:00Z"
              }
            }
            """.utf8
        )
        let request = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let network = QueueNetworkClient(results: [])
        do {
            _ = try await GrokAdapter().fetchSnapshot(
                context: TestContextFactory.make(
                    network: network,
                    externalSessions: MemoryExternalSessionReader(files: [request: expired]),
                    clock: ManualClock(now: Date(timeIntervalSince1970: 1_800_000_000))
                )
            )
            Issue.record("Expected expired session")
        } catch let error as CollectionError {
            #expect(error.kind == .authenticationRevoked)
            #expect(error.diagnosticCode == "grok.cli-session.expired")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await network.requests.isEmpty)
    }

    @Test("management keys and cookie-shaped tokens are rejected")
    func rejectedTokenShapes() async {
        let bodies = [
            Data("{\"https://auth.x.ai::fixture\":{\"key\":\"xai-management\"}}".utf8),
            Data("{\"https://auth.x.ai::fixture\":{\"key\":\"Cookie: session=abc\"}}".utf8),
        ]
        for body in bodies {
            let request = ExternalFileRequest(
                providerID: .grok,
                relativePath: ".grok/auth.json",
                maximumBytes: 64 * 1024
            )
            let network = QueueNetworkClient(results: [])
            do {
                _ = try await GrokAdapter().fetchSnapshot(
                    context: TestContextFactory.make(
                        network: network,
                        externalSessions: MemoryExternalSessionReader(files: [request: body])
                    )
                )
                Issue.record("Expected token rejection")
            } catch let error as CollectionError {
                #expect(error.kind == .authenticationRejected)
                #expect(error.diagnosticCode == "grok.cli-session.token-missing")
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(await network.requests.isEmpty)
        }
    }

    @Test("period-only payload keeps credits without inventing a percent")
    func unknownUsage() throws {
        let body = Data(
            """
            {
              "config": {
                "currentPeriod": {"end": "2026-09-10T00:00:00Z"}
              }
            }
            """.utf8
        )
        let snapshot = try GrokAdapter.decodeSnapshot(from: body)
        let quota = try #require(snapshot.quotas.first)
        #expect(quota.percentage.value == nil)
        #expect(quota.used == nil)
        #expect(quota.resetsAt != nil)
    }
    @Test("successful proxy fallback adopts published web usage and preserves proxy authority")
    func webBillingFallback() async throws {
        let request = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let now = Date(timeIntervalSince1970: 1_850_000_000)
        let proxyBody = Self.unknownProxyFixture
        let proxySnapshot = try GrokAdapter.decodeSnapshot(from: proxyBody)
        let proxyReset = proxySnapshot.quotas.first?.resetsAt
        let webBody = Self.grpcResponse(Self.publishedPercentPayload(37.5))
        let network = QueueNetworkClient(
            results: [
                .success(NetworkResponse(statusCode: 200, headers: [:], body: proxyBody)),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: webBody)),
            ]
        )
        let context = TestContextFactory.make(
            network: network,
            externalSessions: MemoryExternalSessionReader(files: [request: authFile]),
            clock: ManualClock(now: now)
        )

        let snapshot = try await GrokAdapter().fetchSnapshot(context: context)
        let quota = try #require(snapshot.quotas.first)
        #expect(quota.percentage.rawText == "37.5")
        #expect(quota.sourceFields["webPercentSource"] == "grok.com.grpc-web.published")
        #expect(quota.remaining?.rawText == "62.5")
        #expect(quota.resetsAt == proxyReset)
        #expect(snapshot.accountEmail == "fixture@example.com")
        #expect(snapshot.source == GrokAdapter().sourceDescriptor)
        #expect(quota.sourceFields["resetSource"] == "2026-09-10T00:00:00Z")

        let requests = await network.requests
        #expect(requests.count == 2)
        let webRequest = try #require(requests.last)
        #expect(webRequest.method == .post)
        #expect(webRequest.url == GrokWebBilling.endpoint)
        #expect(webRequest.headers == [
            "Authorization": "Bearer synthetic-grok-session-token",
            "Origin": "https://grok.com",
            "Referer": "https://grok.com/?_s=usage",
            "Accept": "*/*",
            "Content-Type": "application/grpc-web+proto",
            "x-grpc-web": "1",
            "x-user-agent": "connect-es/2.1.1",
            "User-Agent": "TokenJar",
        ])
        #expect(webRequest.body == Data([0, 0, 0, 0, 0]))
        #expect(webRequest.timeout == 6)
    }

    @Test("active weekly or monthly period with omitted usage adopts zero")
    func webBillingImplicitZero() async throws {
        let request = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let now = Date(timeIntervalSince1970: 1_850_000_000)
        let proxyReset = try GrokAdapter.decodeSnapshot(from: Self.unknownProxyFixture)
            .quotas.first?.resetsAt
        for periodType in [UInt8(1), UInt8(2)] {
            let network = QueueNetworkClient(
                results: [
                    .success(NetworkResponse(statusCode: 200, headers: [:], body: Self.unknownProxyFixture)),
                    .success(NetworkResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Self.grpcResponse(
                            Self.activePeriodPayload(
                                periodType: periodType,
                                start: 1_840_000_000,
                                end: 1_900_000_000
                            )
                        )
                    )),
                ]
            )
            let context = TestContextFactory.make(
                network: network,
                externalSessions: MemoryExternalSessionReader(files: [request: authFile]),
                clock: ManualClock(now: now)
            )

            let snapshot = try await GrokAdapter().fetchSnapshot(context: context)
            let quota = try #require(snapshot.quotas.first)
            #expect(quota.percentage.value == 0)
            #expect(quota.sourceFields["webPercentSource"] == "grok.com.grpc-web.implicit-zero")
            #expect(quota.resetsAt == proxyReset)
        }
    }

    @Test("proxy usage takes precedence and avoids the web retry")
    func proxyUsagePrecedence() async throws {
        let request = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let context = TestContextFactory.make(
            network: network,
            externalSessions: MemoryExternalSessionReader(files: [request: authFile])
        )

        let snapshot = try await GrokAdapter().fetchSnapshot(context: context)
        #expect(snapshot.quotas.first?.percentage.rawText == "37.5")
        let requests = await network.requests
        #expect(requests.count == 1)
    }

    @Test("failed web fallback preserves unknown proxy usage and reset")
    func failedWebFallbackPreservesProxy() async throws {
        let request = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let proxyReset = try GrokAdapter.decodeSnapshot(from: Self.unknownProxyFixture)
            .quotas.first?.resetsAt
        let network = QueueNetworkClient(
            results: [
                .success(NetworkResponse(statusCode: 200, headers: [:], body: Self.unknownProxyFixture)),
                .success(NetworkResponse(statusCode: 503, headers: [:], body: Data("unavailable".utf8))),
            ]
        )
        let context = TestContextFactory.make(
            network: network,
            externalSessions: MemoryExternalSessionReader(files: [request: authFile])
        )

        let snapshot = try await GrokAdapter().fetchSnapshot(context: context)
        let quota = try #require(snapshot.quotas.first)
        #expect(quota.percentage.value == nil)
        #expect(quota.used == nil)
        #expect(quota.resetsAt == proxyReset)
        #expect(snapshot.accountEmail == "fixture@example.com")
        let requests = await network.requests
        #expect(requests.count == 2)
    }

    @Test("cancellation from web fallback is propagated")
    func webBillingCancellation() async throws {
        let request = ExternalFileRequest(
            providerID: .grok,
            relativePath: ".grok/auth.json",
            maximumBytes: 64 * 1024
        )
        let network = CancellationNetworkClient(
            proxyBody: Self.unknownProxyFixture
        )
        let context = TestContextFactory.make(
            network: network,
            externalSessions: MemoryExternalSessionReader(files: [request: authFile])
        )

        do {
            _ = try await GrokAdapter().fetchSnapshot(context: context)
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("web parser accepts only valid active periods for implicit zero")
    func webBillingPeriodValidation() throws {
        let now = Date(timeIntervalSince1970: 1_850_000_000)
        let invalidPayloads = [
            Self.activePeriodPayload(periodType: 0, start: 1_840_000_000, end: 1_900_000_000),
            Self.activePeriodPayload(periodType: 3, start: 1_840_000_000, end: 1_900_000_000),
            Self.activePeriodPayload(periodType: 2, start: 1_860_000_000, end: 1_900_000_000),
            Self.activePeriodPayload(periodType: 2, start: 1_840_000_000, end: 1_850_000_000),
            Self.activePeriodPayload(periodType: 2, start: 1_840_000_000, end: nil),
        ]
        for payload in invalidPayloads {
            #expect(throws: GrokWebBillingError.self) {
                try GrokWebBilling.parseGRPCWebResponse(Self.grpcResponse(payload), now: now)
            }
        }
    }

    @Test("web parser rejects malformed protobuf, frame, and grpc status")
    func webBillingMalformedResponses() throws {
        let malformedPayloads = [
            Self.grpcFrame(Data([0x00])),
            Self.grpcFrame(Self.fixed64Field(tag: [0x89, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02])),
            Self.grpcFrame(Self.publishedPercentPayload(20) + Data([0x0D, 0x00])),
            Self.grpcFrame(Self.duplicatePublishedPercentPayload),
            Self.grpcFrame(Data([0x0A, 0x02, 0x08, 0x01])),
            Data([0, 0, 0]),
        ]
        for data in malformedPayloads {
            #expect(throws: GrokWebBillingError.self) {
                try GrokWebBilling.parseGRPCWebResponse(data)
            }
        }

        let grpcFailure = Self.grpcFrame(Data("grpc-status: 16\r\ngrpc-message: token%20expired\r\n".utf8), flags: 0x80)
        #expect(throws: GrokWebBillingError.self) {
            try GrokWebBilling.parseGRPCWebResponse(grpcFailure)
        }
    }

    @Test("unknown length-delimited fields stay opaque")
    func webBillingUnknownFields() throws {
        let payload = Self.activePeriodPayload(
            periodType: 2,
            start: 1_840_000_000,
            end: 1_900_000_000
        ) + Self.lengthDelimited(path: [14], contents: Self.publishedPercentPayload(99))
        let parsed = try GrokWebBilling.parseGRPCWebResponse(
            Self.grpcResponse(payload),
            now: Date(timeIntervalSince1970: 1_850_000_000)
        )
        #expect(parsed.usedPercent == 0)
        #expect(parsed.usedPercentIsImplicitZero)
        #expect(!parsed.usedPercentIsWirePublished)
    }

    @Test("known malformed nested messages prevent implicit zero")
    func webBillingKnownMalformedNested() {
        let payload = Self.activePeriodPayload(
            periodType: 2,
            start: 1_840_000_000,
            end: 1_900_000_000
        ) + Self.lengthDelimited(path: [1, 8], contents: Data([0x0D]))
        #expect(throws: GrokWebBillingError.self) {
            try GrokWebBilling.parseGRPCWebResponse(Self.grpcResponse(payload))
        }
    }

    private struct CancellationNetworkClient: NetworkClient {
        let proxyBody: Data

        func send(_ request: NetworkRequest) async throws -> NetworkResponse {
            if request.method == .get {
                return NetworkResponse(statusCode: 200, headers: [:], body: proxyBody)
            }
            throw CancellationError()
        }
    }

    private static let unknownProxyFixture = Data(
        """
        {
          "config": {
            "currentPeriod": {
              "end": "2026-09-10T00:00:00Z"
            }
          }
        }
        """.utf8
    )

    private static func publishedPercentPayload(_ percent: Float) -> Data {
        var config = Data([0x0D])
        var bits = percent.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { config.append(contentsOf: $0) }
        return Data([0x0A, UInt8(config.count)]) + config
    }

    private static var duplicatePublishedPercentPayload: Data {
        var config = Data()
        for percent in [Float(20), Float(30)] {
            config.append(0x0D)
            var bits = percent.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { config.append(contentsOf: $0) }
        }
        return Data([0x0A, UInt8(config.count)]) + config
    }

    private static func activePeriodPayload(
        periodType: UInt8,
        start: UInt64,
        end: UInt64?
    ) -> Data {
        var period = Data([0x08, periodType])
        let startMessage = Data([0x08]) + Self.varint(start)
        period.append(contentsOf: [0x12, UInt8(startMessage.count)])
        period.append(contentsOf: startMessage)
        if let end {
            let endMessage = Data([0x08]) + Self.varint(end)
            period.append(contentsOf: [0x1A, UInt8(endMessage.count)])
            period.append(contentsOf: endMessage)
        }
        var config = Data([0x42, UInt8(period.count)])
        config.append(contentsOf: period)
        return Data([0x0A, UInt8(config.count)]) + config
    }

    private static func grpcResponse(_ payload: Data) -> Data {
        grpcFrame(payload) + grpcFrame(Data("grpc-status: 0\r\n".utf8), flags: 0x80)
    }

    private static func grpcFrame(_ payload: Data, flags: UInt8 = 0) -> Data {
        var data = Data([flags])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(contentsOf: payload)
        return data
    }

    private static func lengthDelimited(path: [UInt64], contents: Data) -> Data {
        var payload = contents
        for field in path.reversed() {
            payload = Self.varint((field << 3) | 2) + Self.varint(UInt64(payload.count)) + payload
        }
        return payload
    }

    private static func fixed64Field(tag: [UInt8]) -> Data {
        Data(tag + [UInt8](repeating: 0, count: 8))
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        return data
    }
}
