import Darwin
import Foundation
import Testing
@testable import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Grok CLI session (read-only, CLI-owned renewal)", .serialized)
struct GrokSessionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let officialScope = "https://auth.x.ai::client-id"

    @Test("a fresh session is returned without running the Grok CLI")
    func freshSessionNeedsNoCLI() async throws {
        let store = MemoryGrokAuthStore([officialScope: entry(token: "access-fresh", expiresAt: now.addingTimeInterval(3_600))])
        let refresher = RecordingGrokRefresher()
        let provider = GrokOAuthSessionProvider(clock: ManualClock(now: now), store: store, refresher: refresher)

        #expect(try await provider.session(rejectedAccessToken: nil).accessToken == "access-fresh")
        #expect(await refresher.runs == 0)
    }

    @Test("ISO-8601, epoch, and epoch-millisecond expiries are understood")
    func expiryFormats() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Each entry is built inside its iteration: Swift 6.0 rejects sending a `[String: Any]`
        // whose values still belong to a non-Sendable array the loop reads again.
        for format in 0..<3 {
            var value = entry(token: "access-fresh", expiresAt: nil)
            switch format {
            case 0: value["expires_at"] = formatter.string(from: now.addingTimeInterval(3_600))
            case 1: value["expires_at"] = String(Int(now.addingTimeInterval(3_600).timeIntervalSince1970))
            default: value["expires_at"] = now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000
            }
            let refresher = RecordingGrokRefresher()
            let provider = GrokOAuthSessionProvider(
                clock: ManualClock(now: now),
                store: MemoryGrokAuthStore([officialScope: value]),
                refresher: refresher
            )
            #expect(try await provider.session(rejectedAccessToken: nil).accessToken == "access-fresh")
            #expect(await refresher.runs == 0)
        }
    }

    @Test("an expired session runs the Grok CLI once and adopts the token it wrote")
    func expiredSessionLetsCLIRenew() async throws {
        let store = MemoryGrokAuthStore([officialScope: entry(token: "access-old", expiresAt: now.addingTimeInterval(30))])
        let refresher = RecordingGrokRefresher {
            await store.replace([self.officialScope: self.entry(token: "access-new", expiresAt: self.now.addingTimeInterval(3_600))])
        }
        let provider = GrokOAuthSessionProvider(clock: ManualClock(now: now), store: store, refresher: refresher)

        let read = try await provider.accounts(rejectedAccessTokens: [], allowsCLIRefresh: true)
        #expect(read.ranCLIRefresh)
        #expect(read.accounts.map(\.session?.accessToken) == ["access-new"])
        #expect(await refresher.runs == 1)
        #expect(await store.loads == 2)
    }

    @Test("a session the CLI did not renew reports that running the Grok CLI renews it")
    func unrenewedSessionAsksToRunCLI() async throws {
        let store = MemoryGrokAuthStore([officialScope: entry(token: "access-old", expiresAt: now.addingTimeInterval(-10))])
        let refresher = RecordingGrokRefresher()
        let provider = GrokOAuthSessionProvider(clock: ManualClock(now: now), store: store, refresher: refresher)

        let read = try await provider.accounts(rejectedAccessTokens: [], allowsCLIRefresh: true)
        let failure = try #require(read.accounts.first?.failure)
        #expect(failure.kind == .sourceUnavailable)
        #expect(failure.recoveryAction == .runSourceCLI)
        #expect(failure.diagnosticCode == "grok.session.expired")

        let missingCLI = GrokOAuthSessionProvider(
            clock: ManualClock(now: now),
            store: store,
            refresher: RecordingGrokRefresher(failure: CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "grok.cli-refresh.executable-missing",
                recoveryAction: .runSourceCLI
            ))
        )
        let missing = try await missingCLI.accounts(rejectedAccessTokens: [], allowsCLIRefresh: true)
        #expect(missing.accounts.first?.failure?.diagnosticCode == "grok.cli-refresh.executable-missing")
    }

    @Test("without refresh permission an expired session is only reread")
    func refreshNotAllowedOnlyRereads() async throws {
        let store = MemoryGrokAuthStore([officialScope: entry(token: "access-old", expiresAt: now.addingTimeInterval(-10))])
        let refresher = RecordingGrokRefresher()
        let provider = GrokOAuthSessionProvider(clock: ManualClock(now: now), store: store, refresher: refresher)

        let read = try await provider.accounts(rejectedAccessTokens: [], allowsCLIRefresh: false)
        #expect(read.ranCLIRefresh == false)
        #expect(read.accounts.first?.failure?.recoveryAction == .runSourceCLI)
        #expect(await refresher.runs == 0)
    }

    @Test("a rejected token is renewed by the CLI, but a newer file token is used as is")
    func rejectedTokenComparison() async throws {
        let store = MemoryGrokAuthStore([officialScope: entry(token: "access-newer", expiresAt: now.addingTimeInterval(3_600))])
        let refresher = RecordingGrokRefresher()
        let provider = GrokOAuthSessionProvider(clock: ManualClock(now: now), store: store, refresher: refresher)
        #expect(try await provider.session(rejectedAccessToken: "access-old").accessToken == "access-newer")
        #expect(await refresher.runs == 0)

        let rejected = try await provider.accounts(rejectedAccessTokens: ["access-newer"], allowsCLIRefresh: true)
        #expect(await refresher.runs == 1)
        #expect(rejected.accounts.first?.failure?.diagnosticCode == "grok.session.rejected")
    }

    @Test("every signed-in scope is an account, deduplicated by user_id")
    func multipleAccounts() async throws {
        var legacy = entry(token: "access-legacy", expiresAt: now.addingTimeInterval(3_600), userID: "user-a")
        legacy.removeValue(forKey: "auth_mode")
        let store = MemoryGrokAuthStore([
            officialScope: entry(token: "access-a", expiresAt: now.addingTimeInterval(3_600), userID: "user-a"),
            "https://auth.x.ai::other-client": entry(
                token: "access-b",
                expiresAt: now.addingTimeInterval(3_600),
                userID: "user-b",
                clientID: "other-client",
                email: "b@example.com"
            ),
            "https://accounts.x.ai/sign-in": legacy,
            "xai::api_key": ["key": "xai-not-a-session"],
        ])
        let provider = GrokOAuthSessionProvider(clock: ManualClock(now: now), store: store, refresher: RecordingGrokRefresher())

        let read = try await provider.accounts(rejectedAccessTokens: [], allowsCLIRefresh: true)
        #expect(read.accounts.map(\.sourceID) == ["grok.oidc.client-id", "grok.oidc.other-client"])
        #expect(read.accounts.map(\.accountEmail) == ["owner@example.com", "b@example.com"])
    }

    @Test("the scoped capability runs the Grok CLI at most once per collection")
    func cliRefreshOncePerCollection() async throws {
        let store = MemoryGrokAuthStore([officialScope: entry(token: "access-old", expiresAt: now.addingTimeInterval(-10))])
        let refresher = RecordingGrokRefresher()
        let provider = GrokOAuthSessionProvider(clock: ManualClock(now: now), store: store, refresher: refresher)
        let context = TestContextFactory.make(grokSession: provider)

        let collection = context.scoped(to: .grok)
        _ = try await collection.grokSession.accounts(rejectedAccessTokens: [], allowsCLIRefresh: true)
        _ = try await collection.grokSession.accounts(rejectedAccessTokens: ["access-old"], allowsCLIRefresh: true)
        #expect(await refresher.runs == 1)

        let nextCollection = context.scoped(to: .grok)
        _ = try await nextCollection.grokSession.accounts(rejectedAccessTokens: [], allowsCLIRefresh: true)
        #expect(await refresher.runs == 2)
    }

    @Test("unofficial issuer metadata is rejected before any use")
    func unofficialIssuerRejected() async throws {
        var value = entry(token: "access-fresh", expiresAt: now.addingTimeInterval(3_600))
        value["oidc_issuer"] = "https://attacker.example"
        let provider = GrokOAuthSessionProvider(
            clock: ManualClock(now: now),
            store: MemoryGrokAuthStore([officialScope: value]),
            refresher: RecordingGrokRefresher()
        )
        await expectError(.authenticationRejected) {
            _ = try await provider.session(rejectedAccessToken: nil)
        }
    }

    @Test("the file store only reads: permissions and links are enforced and nothing is written")
    func filesystemStoreIsReadOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let grok = directory.appendingPathComponent(".grok")
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: grok.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = grok.appendingPathComponent("auth.json")
        let original = try JSONSerialization.data(withJSONObject: [
            officialScope: entry(token: "access-old", expiresAt: now.addingTimeInterval(-10)),
        ])
        try original.write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)

        let provider = GrokOAuthSessionProvider(
            clock: ManualClock(now: now),
            store: GrokAuthFileStore(homeDirectory: directory),
            refresher: RecordingGrokRefresher()
        )
        _ = try await provider.accounts(rejectedAccessTokens: [], allowsCLIRefresh: true)
        #expect(try Data(contentsOf: auth) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: grok.path) == ["auth.json"])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: auth.path)
        await expectError(.unsafePath) { _ = try await GrokAuthFileStore(homeDirectory: directory).load() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)

        let link = grok.appendingPathComponent("linked.json")
        try FileManager.default.moveItem(at: auth, to: link)
        try FileManager.default.createSymbolicLink(at: auth, withDestinationURL: link)
        await expectError(.unsafePath) { _ = try await GrokAuthFileStore(homeDirectory: directory).load() }
    }

    @Test("the Grok CLI refresher runs `grok models` from an empty directory with a clean environment")
    func cliRefresherInvocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let observed = directory.appendingPathComponent("observed")
        let executable = directory.appendingPathComponent("grok")
        let script = """
        #!/bin/sh
        {
          printf 'args=%s\\n' "$*"
          printf 'entries=%s\\n' "$(ls -A | wc -l | tr -d ' ')"
          printf 'grok_home=%s\\n' "${GROK_HOME-unset}"
          printf 'home=%s\\n' "$HOME"
        } > "\(observed.path)"
        echo "model-a"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(setenv("GROK_HOME", "/tmp/elsewhere", 1) == 0)
        defer { unsetenv("GROK_HOME") }

        let refresher = GrokCLIAuthRefresher(
            executableCandidates: [directory.appendingPathComponent("missing"), executable],
            homeDirectory: directory,
            timeout: .seconds(5)
        )
        try await refresher.refresh()
        let text = try String(contentsOf: observed, encoding: .utf8)
        #expect(text.contains("args=models\n"))
        #expect(text.contains("entries=0\n"))
        #expect(text.contains("grok_home=unset\n"))
        #expect(text.contains("home=\(directory.path)\n"))

        let missing = GrokCLIAuthRefresher(
            executableCandidates: [directory.appendingPathComponent("missing")],
            homeDirectory: directory,
            timeout: .seconds(5)
        )
        await expectError(.sourceUnavailable) { try await missing.refresh() }
    }

    @Test("the Grok CLI refresher enforces its output limit")
    func cliRefresherOutputLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("grok")
        try Data("#!/bin/sh\nhead -c 400000 /dev/zero\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let refresher = GrokCLIAuthRefresher(executableCandidates: [executable], homeDirectory: directory, timeout: .seconds(5))
        do {
            try await refresher.refresh()
            Issue.record("Expected the output limit to stop the CLI")
        } catch let error as CollectionError {
            #expect(error.diagnosticCode == "grok.cli-refresh.output-size-limit")
        }
    }

    private func entry(
        token: String,
        expiresAt: Date?,
        userID: String = "user-owner",
        clientID: String = "client-id",
        email: String = "owner@example.com"
    ) -> [String: Any] {
        var value: [String: Any] = [
            "key": token,
            "auth_mode": "oidc",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": clientID,
            "refresh_token": "refresh-owned-by-cli",
            "user_id": userID,
            "email": email,
        ]
        if let expiresAt {
            let formatter = ISO8601DateFormatter()
            value["expires_at"] = formatter.string(from: expiresAt)
        }
        return value
    }

    private func expectError(
        _ kind: CollectionErrorKind,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(kind)")
        } catch let error as CollectionError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor MemoryGrokAuthStore: GrokAuthFileStoring {
    private var root: [String: Any]
    private(set) var loads = 0

    init(_ root: [String: Any]) {
        self.root = root
    }

    func replace(_ root: [String: Any]) {
        self.root = root
    }

    func load() throws -> GrokAuthFileDocument {
        loads += 1
        var entries: [(key: String, value: [String: Any])] = []
        for key in root.keys.sorted() where key.hasPrefix("https://auth.x.ai::") {
            if let value = root[key] as? [String: Any], let token = value["key"] as? String, grokAccessTokenIsSafe(token) {
                entries.append((key, value))
            }
        }
        if let value = root["https://accounts.x.ai/sign-in"] as? [String: Any],
           let token = value["key"] as? String, grokAccessTokenIsSafe(token) {
            entries.append(("https://accounts.x.ai/sign-in", value))
        }
        return GrokAuthFileDocument(
            data: (try? JSONSerialization.data(withJSONObject: root)) ?? Data(),
            root: root,
            entries: entries
        )
    }
}

private actor RecordingGrokRefresher: GrokAuthRefreshing {
    private let failure: CollectionError?
    private let effect: (@Sendable () async -> Void)?
    private(set) var runs = 0

    init(failure: CollectionError? = nil, effect: (@Sendable () async -> Void)? = nil) {
        self.failure = failure
        self.effect = effect
    }

    func refresh() async throws {
        runs += 1
        await effect?()
        if let failure { throw failure }
    }
}
