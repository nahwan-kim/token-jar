import Darwin
import Foundation
import Testing
@testable import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Antigravity CLIProxyAPI sessions")
struct AntigravitySessionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cli-proxy-api/auths"),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: home.appendingPathComponent(".cli-proxy-api").path
        )
        return home
    }

    private func writeAuth(
        _ name: String,
        in home: URL,
        directory: String = ".cli-proxy-api/auths",
        fields: [String: Any],
        permissions: Int = 0o600
    ) throws {
        let url = home.appendingPathComponent(directory).appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: fields).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func auth(_ email: String, expired: Date, disabled: Bool = false) -> [String: Any] {
        [
            "type": "antigravity",
            "access_token": "ya29.token-\(email)",
            "refresh_token": "refresh-\(email)",
            "email": email,
            "project_id": "aicode-consumers",
            "expired": ISO8601DateFormatter().string(from: expired),
            "disabled": disabled,
        ]
    }

    @Test("reads every enabled antigravity file in both auth directories; expired files ask for CLIProxyAPI")
    func readsFiles() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAuth("antigravity-a@example.com.json", in: home, fields: auth("a@example.com", expired: now.addingTimeInterval(1_800)))
        try writeAuth("antigravity-b@example.com.json", in: home, fields: auth("b@example.com", expired: now.addingTimeInterval(-10)))
        try writeAuth("antigravity-c@example.com.json", in: home, fields: auth("c@example.com", expired: now.addingTimeInterval(1_800), disabled: true))
        try writeAuth("codex-x.json", in: home, fields: ["type": "codex", "access_token": "x"])
        try writeAuth(
            "antigravity-d@example.com.json",
            in: home,
            directory: ".cli-proxy-api",
            fields: auth("d@example.com", expired: now.addingTimeInterval(1_800))
        )

        let provider = CLIProxyAntigravitySessionProvider(clock: ManualClock(now: now), homeDirectory: home)
        let reads = try await provider.accounts()

        #expect(reads.map(\.accountEmail) == ["a@example.com", "b@example.com", "d@example.com"])
        #expect(reads[0].session?.accessToken == "ya29.token-a@example.com")
        #expect(reads[0].session?.projectID == "aicode-consumers")
        #expect(reads[1].session == nil)
        #expect(reads[1].failure?.diagnosticCode == "antigravity.session.expired")
        #expect(reads[1].failure?.recoveryAction == .runSourceCLI)
        #expect(Set(reads.map(\.sourceID)).count == 3)
    }

    @Test("a group- or world-readable auth file is refused")
    func refusesReadableFile() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAuth(
            "antigravity-a@example.com.json",
            in: home,
            fields: auth("a@example.com", expired: now.addingTimeInterval(1_800)),
            permissions: 0o644
        )
        let provider = CLIProxyAntigravitySessionProvider(clock: ManualClock(now: now), homeDirectory: home)
        await #expect(throws: CollectionError(kind: .unsafePath, diagnosticCode: "antigravity.session.auth-file.unsafe")) {
            try await provider.accounts()
        }
    }

    @Test("no auth file means sign in through CLIProxyAPI")
    func missing() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = CLIProxyAntigravitySessionProvider(clock: ManualClock(now: now), homeDirectory: home)
        await #expect(throws: CollectionError(
            kind: .externalSessionMissing,
            diagnosticCode: "antigravity.session.auth-file.missing",
            recoveryAction: .signInSourceApp
        )) {
            try await provider.accounts()
        }
    }

    @Test("timestamp plus expires_in is the expiry when expired is absent")
    func timestampExpiry() throws {
        let read = try #require(try CLIProxyAntigravitySessionProvider.read([
            "type": "antigravity",
            "access_token": "ya29.token",
            "timestamp": (now.timeIntervalSince1970 - 3_590) * 1_000,
            "expires_in": 3_599,
        ], now: now))
        #expect(read.session == nil)
        #expect(read.failure?.diagnosticCode == "antigravity.session.expired")
    }

    @Test("a present but unreadable expiry fails closed instead of passing for no expiry")
    func malformedExpiry() {
        for fields: [String: Any] in [
            ["expired": "soon"],
            ["expired": 1_800_000_000],
            ["expires_in": "3599", "timestamp": now.timeIntervalSince1970 * 1_000],
            ["expires_in": 3_599],
            ["expires_in": -1, "timestamp": now.timeIntervalSince1970 * 1_000],
        ] {
            let root = fields.merging(["type": "antigravity", "access_token": "ya29.token"]) { current, _ in current }
            #expect(throws: CollectionError(kind: .malformedResponse, diagnosticCode: "antigravity.session.expiry-invalid")) {
                _ = try CLIProxyAntigravitySessionProvider.read(root, now: now)
            }
        }
    }

    @Test("the same sign-in in both directories keeps the usable copy")
    func duplicatePrefersUsableSession() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAuth("antigravity-a.json", in: home, fields: auth("a@example.com", expired: now.addingTimeInterval(-10)))
        try writeAuth(
            "antigravity-a.json",
            in: home,
            directory: ".cli-proxy-api",
            fields: auth("a@example.com", expired: now.addingTimeInterval(1_800))
        )
        let reads = try await CLIProxyAntigravitySessionProvider(clock: ManualClock(now: now), homeDirectory: home).accounts()
        #expect(reads.count == 1)
        #expect(reads[0].session?.accessToken == "ya29.token-a@example.com")
    }

    @Test("a symlinked CLIProxyAPI directory is never followed")
    func symlinkedDirectoryIsRefused() async throws {
        let home = try makeHome()
        let elsewhere = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try writeAuth("antigravity-a.json", in: elsewhere, fields: auth("a@example.com", expired: now.addingTimeInterval(1_800)))
        try FileManager.default.removeItem(at: home.appendingPathComponent(".cli-proxy-api"))
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".cli-proxy-api"),
            withDestinationURL: elsewhere.appendingPathComponent(".cli-proxy-api")
        )
        let provider = CLIProxyAntigravitySessionProvider(clock: ManualClock(now: now), homeDirectory: home)
        await #expect(throws: CollectionError.self) { try await provider.accounts() }
    }

    @Test("both directories share one file budget")
    func fileBudgetIsShared() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for index in 0..<20 {
            let email = "a\(index)@example.com"
            try writeAuth("antigravity-\(index).json", in: home, fields: auth(email, expired: now.addingTimeInterval(1_800)))
            try writeAuth(
                "antigravity-\(index).json",
                in: home,
                directory: ".cli-proxy-api",
                fields: auth("b\(index)@example.com", expired: now.addingTimeInterval(1_800))
            )
        }
        let reads = try await CLIProxyAntigravitySessionProvider(clock: ManualClock(now: now), homeDirectory: home).accounts()
        #expect(reads.count == 32)
    }

    @Test("only the two Code Assist POSTs are allowlisted")
    func allowlist() {
        func request(_ url: URL, body: Data?, method: HTTPMethod = .post, provider: ProviderID = .antigravity) -> NetworkRequest {
            NetworkRequest(providerID: provider, url: url, method: method, body: body, timeout: 15)
        }
        let summary = AntigravityRequestPolicy.quotaSummaryURL
        let load = AntigravityRequestPolicy.loadCodeAssistURL
        let summaryBody = AntigravityRequestPolicy.quotaSummaryBody(projectID: "aicode-consumers")
        #expect(URLSessionNetworkClient.isAllowed(request(summary, body: summaryBody)))
        #expect(URLSessionNetworkClient.isAllowed(request(load, body: AntigravityRequestPolicy.loadCodeAssistBody)))
        for denied in [
            request(summary, body: nil),
            request(summary, body: summaryBody, method: .get),
            request(summary, body: summaryBody, provider: .claude),
            request(summary, body: Data(#"{"project":"aicode-consumers","extra":1}"#.utf8)),
            request(summary, body: Data(#"{"project":"../x"}"#.utf8)),
            request(summary, body: Data("not json".utf8)),
            request(load, body: summaryBody),
            request(URL(string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!, body: summaryBody),
            request(URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary?x=1")!, body: summaryBody),
            request(URL(string: "https://oauth2.googleapis.com/token")!, body: Data()),
        ] {
            #expect(!URLSessionNetworkClient.isAllowed(denied))
        }
        #expect(URLSessionNetworkClient.isAllowed(request(summary, body: Data("{}".utf8))))
    }
}
