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

    private let session = GrokSession(
        accessToken: "synthetic-grok-session-token",
        accountEmail: "fixture@example.com",
        expiresAt: Date(timeIntervalSince1970: 4_070_908_800)
    )

    @Test("descriptor identifies the Grok OAuth refresh and credits services")
    func descriptor() {
        let descriptor = GrokAdapter().sourceDescriptor
        #expect(descriptor.id == "grok.cli-proxy.credits")
        #expect(descriptor.name == "Grok CLI SuperGrok credits")
        #expect(descriptor.kind == .localSession)
        #expect(descriptor.credentialOwnership == .externalProvider)
        #expect(descriptor.detail.contains("auth.x.ai"))
        #expect(descriptor.detail.contains("cli-chat-proxy.grok.com"))
        #expect(descriptor.detail.contains("never imports browser cookies"))
        #expect(descriptor.detail.contains("never launches a CLI subprocess"))
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

    @Test("fetch uses the shared Grok session and exact proxy request")
    func requestContract() async throws {
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let sessions = MemoryGrokSessionProvider(results: [.success(session)])
        let context = TestContextFactory.make(
            network: network,
            grokSession: sessions,
            credentials: InMemoryCredentialStore(
                values: [CredentialID(providerID: .grok, name: "management-api-key"): "must-not-be-read"]
            )
        )

        let snapshot = try await GrokAdapter().fetchSnapshot(context: context)
        #expect(snapshot.accountEmail == "fixture@example.com")
        #expect(await sessions.rejectedAccessTokens == [nil])
        let sent = try #require(await network.requests.first)
        #expect(sent.method == .get)
        #expect(sent.providerID == .grok)
        #expect(sent.url.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(sent.headers["Authorization"] == "Bearer synthetic-grok-session-token")
        #expect(sent.headers["x-xai-token-auth"] == "xai-grok-cli")
        #expect(sent.body == nil)
    }

    @Test("availability probe performs no session or network I/O")
    func availabilityProbeIsPure() async {
        let sessions = MemoryGrokSessionProvider(results: [])
        let network = QueueNetworkClient(results: [])
        let availability = await GrokAdapter().probeAvailability(
            context: TestContextFactory.make(network: network, grokSession: sessions)
        )

        guard case .available = availability else {
            Issue.record("Expected available descriptor")
            return
        }
        #expect(await sessions.rejectedAccessTokens.isEmpty)
        #expect(await network.requests.isEmpty)
    }

    @Test("session failure occurs before billing and requests source-app sign-in")
    func sessionFailureBeforeBilling() async {
        let network = QueueNetworkClient(results: [])
        let sessions = MemoryGrokSessionProvider(results: [
            .failure(CollectionError(
                kind: .authenticationRejected,
                diagnosticCode: "grok.oauth.refresh-rejected"
            )),
        ])

        do {
            _ = try await GrokAdapter().fetchSnapshot(
                context: TestContextFactory.make(network: network, grokSession: sessions)
            )
            Issue.record("Expected session failure")
        } catch let error as CollectionError {
            #expect(error.kind == .authenticationRejected)
            #expect(error.diagnosticCode == "grok.oauth.refresh-rejected")
            #expect(error.recoveryAction == .signInSourceApp)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await sessions.rejectedAccessTokens == [nil])
        #expect(await network.requests.isEmpty)
    }

    @Test("one proxy authentication rejection renews once with the rejected token")
    func authenticationRejectionRenewsOnce() async throws {
        for statusCode in [401, 403] {
            let oldSession = GrokSession(accessToken: "old-token", accountEmail: "old@example.com")
            let newSession = GrokSession(accessToken: "new-token", accountEmail: "new@example.com")
            let sessions = MemoryGrokSessionProvider(results: [
                .success(oldSession),
                .success(newSession),
            ])
            let network = QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: statusCode, headers: [:], body: Data())),
                .success(NetworkResponse(statusCode: 200, headers: [:], body: fixture)),
            ])

            let snapshot = try await GrokAdapter().fetchSnapshot(
                context: TestContextFactory.make(network: network, grokSession: sessions)
            )

            #expect(snapshot.accountEmail == "new@example.com")
            #expect(await sessions.rejectedAccessTokens == [nil, "old-token"])
            let requests = await network.requests
            #expect(requests.count == 2)
            #expect(requests[0].headers["Authorization"] == "Bearer old-token")
            #expect(requests[1].headers["Authorization"] == "Bearer new-token")
        }
    }

    @Test("a second proxy authentication rejection surfaces without another renewal")
    func secondAuthenticationRejectionStops() async {
        for statusCode in [401, 403] {
            let sessions = MemoryGrokSessionProvider(results: [
                .success(GrokSession(accessToken: "old-token")),
                .success(GrokSession(accessToken: "new-token")),
            ])
            let network = QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: statusCode, headers: [:], body: Data())),
                .success(NetworkResponse(statusCode: statusCode, headers: [:], body: Data())),
            ])

            do {
                _ = try await GrokAdapter().fetchSnapshot(
                    context: TestContextFactory.make(network: network, grokSession: sessions)
                )
                Issue.record("Expected repeated authentication rejection")
            } catch let error as CollectionError {
                #expect(error.kind == (statusCode == 401 ? .authenticationRejected : .authenticationRevoked))
                #expect(error.recoveryAction == .signInSourceApp)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(await sessions.rejectedAccessTokens == [nil, "old-token"])
            #expect(await network.requests.count == 2)
        }
    }

    @Test("non-authentication proxy errors do not request renewal")
    func nonAuthenticationErrorDoesNotRenew() async {
        let sessions = MemoryGrokSessionProvider(results: [.success(session)])
        let network = QueueNetworkClient(results: [
            .success(NetworkResponse(statusCode: 500, headers: [:], body: Data())),
        ])

        do {
            _ = try await GrokAdapter().fetchSnapshot(
                context: TestContextFactory.make(network: network, grokSession: sessions)
            )
            Issue.record("Expected proxy failure")
        } catch let error as CollectionError {
            #expect(error.kind == .transientNetwork)
            #expect(error.diagnosticCode == "grok.credits.http-500")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await sessions.rejectedAccessTokens == [nil])
        #expect(await network.requests.count == 1)
    }

    @Test("billing cancellation is propagated without renewal")
    func billingCancellationDoesNotRenew() async {
        let sessions = MemoryGrokSessionProvider(results: [.success(session)])
        let network = QueueNetworkClient(results: [
            .failure(CollectionError(kind: .cancelled, diagnosticCode: "network.cancelled")),
        ])

        do {
            _ = try await GrokAdapter().fetchSnapshot(
                context: TestContextFactory.make(network: network, grokSession: sessions)
            )
            Issue.record("Expected cancellation")
        } catch let error as CollectionError {
            #expect(error.kind == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await sessions.rejectedAccessTokens == [nil])
        #expect(await network.requests.count == 1)
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
            grokSession: MemoryGrokSessionProvider(results: [.success(session)]),
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
                grokSession: MemoryGrokSessionProvider(results: [.success(session)]),
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
        let network = QueueNetworkClient(
            results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: fixture))]
        )
        let context = TestContextFactory.make(
            network: network,
            grokSession: MemoryGrokSessionProvider(results: [.success(session)])
        )

        let snapshot = try await GrokAdapter().fetchSnapshot(context: context)
        #expect(snapshot.quotas.first?.percentage.rawText == "37.5")
        let requests = await network.requests
        #expect(requests.count == 1)
    }

    @Test("failed web fallback preserves unknown proxy usage and reset")
    func failedWebFallbackPreservesProxy() async throws {
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
            grokSession: MemoryGrokSessionProvider(results: [.success(session)])
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
        let network = CancellationNetworkClient(
            proxyBody: Self.unknownProxyFixture
        )
        let context = TestContextFactory.make(
            network: network,
            grokSession: MemoryGrokSessionProvider(results: [.success(session)])
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
