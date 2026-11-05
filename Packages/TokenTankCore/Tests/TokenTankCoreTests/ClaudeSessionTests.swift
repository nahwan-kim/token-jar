import Darwin
import Foundation
import Testing
@testable import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Claude Code native session", .serialized)
struct ClaudeSessionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("security tool read passes the item selectors and returns the value without its newline")
    func securityToolReadsValue() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"{"claudeAiOauth":{"accessToken":"tool-token"}}"#
        let executable = try script(in: root, body: """
        [ "$#" = 6 ] && [ "$1" = find-generic-password ] && [ "$2" = -s ] && [ "$3" = "Claude Code-credentials-1a2b3c4d" ] \\
            && [ "$4" = -a ] && [ "$5" = some-user ] && [ "$6" = -w ] || exit 9
        printf '%s\\n' '\(json)'
        """)

        let data = try await NativeClaudeCredentialReader.readWithSecurityTool(
            service: "Claude Code-credentials-1a2b3c4d", account: "some-user", executable: executable, timeout: 5
        )

        #expect(data == Data(json.utf8))
    }

    @Test("security tool hex output for non-printable values is decoded")
    func securityToolDecodesHex() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"{"claudeAiOauth":{"accessToken":"héx"}}"#
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        let executable = try script(in: root, body: "echo \(hex)")

        let data = try await NativeClaudeCredentialReader.readWithSecurityTool(
            service: "svc", account: "acct", executable: executable, timeout: 5
        )

        #expect(data == Data(json.utf8))
    }

    @Test("security tool exit 44 means the item does not exist")
    func securityToolItemNotFound() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script(in: root, body: "exit 44")

        let data = try await NativeClaudeCredentialReader.readWithSecurityTool(
            service: "svc", account: "acct", executable: executable, timeout: 5
        )

        #expect(data == nil)
    }

    @Test("any other security tool exit status is a retryable keychainUnavailable carrying the status")
    func securityToolOtherStatus() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script(in: root, body: "echo ignored; exit 36")

        await expectError(.keychainUnavailable, code: "claude.session.keychain.status-36", recoveryAction: .retry) {
            try await NativeClaudeCredentialReader.readWithSecurityTool(
                service: "svc", account: "acct", executable: executable, timeout: 5
            )
        }
    }

    @Test("a security tool that outlives the timeout is terminated and reported promptly")
    func securityToolTimeout() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script(in: root, body: "exec sleep 30")

        let started = ContinuousClock.now
        await expectError(.keychainUnavailable, code: "claude.session.keychain.timeout", recoveryAction: .retry) {
            try await NativeClaudeCredentialReader.readWithSecurityTool(
                service: "svc", account: "acct", executable: executable, timeout: 0.2
            )
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("a security tool that cannot be launched is reported as launch failure")
    func securityToolLaunchFailure() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing-security")
        await expectError(.keychainUnavailable, code: "claude.session.keychain.launch-failed", recoveryAction: .retry) {
            try await NativeClaudeCredentialReader.readWithSecurityTool(
                service: "svc", account: "acct", executable: missing, timeout: 5
            )
        }
    }

    @Test("cancelling a read terminates the security tool and throws cancellation")
    func securityToolCancellation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("started")
        let executable = try script(in: root, body: "touch '\(marker.path)'; exec sleep 30")

        let task = Task {
            try await NativeClaudeCredentialReader.readWithSecurityTool(
                service: "svc", account: "acct", executable: executable, timeout: 30
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = ContinuousClock.now
        task.cancel()
        await expectCancellation { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("MCP-only file permits the separate native Claude AI Keychain session")
    func mcpOnlyFileUsesKeychain() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(Data(#"{"mcpOAuth":{"server":{"accessToken":"never-use"}}}"#.utf8)),
            keychain: .success(credentials(token: "native-ai", expiry: now.addingTimeInterval(120)))
        )
        let refresher = RecordingClaudeRefresher()
        #expect(try await provider(reader: reader, refresher: refresher)
            .session(allowsRefresh: false, rejectedAccessToken: nil).accessToken == "native-ai")
        #expect(await refresher.count == 0)
        #expect(await reader.keychainReads == 1)
    }

    @Test("credentials expiring while Keychain responds are not treated as fresh")
    func expiryDuringNativeRead() async {
        let clock = ManualClock(now: now)
        let reader = AdvancingClaudeCredentialReader(
            clock: clock, data: credentials(token: "expired-during-read", expiry: now.addingTimeInterval(1))
        )
        let provider = ClaudeCodeSessionProvider(
            clock: clock, credentials: reader, refresher: RecordingClaudeRefresher()
        )
        await expectError(.authenticationRejected, code: ClaudeSession.refreshRequiredDiagnosticCode) {
            try await provider.session(allowsRefresh: false, rejectedAccessToken: nil)
        }
    }

    @Test("locked console skips native Keychain lookup and falls back to a fresh file")
    func lockedConsoleNeverStartsKeychainLookup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = NativeClaudeCredentialReader(
            homeDirectory: root, screenIsUnlocked: { false },
            keychainLookup: {
                Issue.record("Locked-screen lookup must not reach Security")
                return nil
            }
        )
        await expectError(
            .keychainUnavailable,
            code: "claude.session.keychain.screen-locked",
            recoveryAction: .retry
        ) {
            try await provider(reader: reader).session(allowsRefresh: false, rejectedAccessToken: nil)
        }

        let directory = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try credentials(token: "fresh-file", expiry: now.addingTimeInterval(120))
            .write(to: directory.appendingPathComponent(".credentials.json"))
        #expect(try await provider(reader: reader).session(allowsRefresh: false, rejectedAccessToken: nil).accessToken == "fresh-file")
    }

    @Test("native reader returns the injected Keychain value and starts no lookup when pre-cancelled")
    func nativeReaderLookup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = LockedCounter()
        let reader = NativeClaudeCredentialReader(
            homeDirectory: root,
            screenIsUnlocked: { true },
            keychainLookup: {
                calls.increment()
                return Data("value".utf8)
            }
        )
        #expect(try await reader.readKeychain() == Data("value".utf8))
        #expect(calls.value == 1)

        let cancelled = Task {
            await Task.yield()
            return try await reader.readKeychain()
        }
        cancelled.cancel()
        await expectCancellation { try await cancelled.value }
        #expect(calls.value == 1)
    }

    @Test("fresh credential file is authoritative over Keychain")
    func freshFilePrecedence() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "file-token", expiry: now.addingTimeInterval(120))),
            keychain: .success(credentials(token: "keychain-token", expiry: now.addingTimeInterval(120)))
        )
        let provider = provider(reader: reader)

        let session = try await provider.session(allowsRefresh: false, rejectedAccessToken: nil)

        #expect(session.accessToken == "file-token")
        #expect(session.subscriptionType == "max")
        #expect(session.rateLimitTier == "default_claude_max_20x")
        #expect(await reader.keychainReads == 0)
    }

    @Test("expiresAt is interpreted exclusively as epoch milliseconds")
    func expiryUsesMilliseconds() async {
        let secondsValue = Int64(now.addingTimeInterval(120).timeIntervalSince1970)
        let reader = ClaudeTestCredentialReader(
            file: .success(rawCredentials(
                token: "token",
                expiry: secondsValue,
                scopes: ["user:profile"]
            )),
            keychain: .success(nil)
        )

        await expectError(
            .authenticationRejected,
            code: ClaudeSession.refreshRequiredDiagnosticCode,
            recoveryAction: .runSourceCLI
        ) {
            try await provider(reader: reader).session(allowsRefresh: false, rejectedAccessToken: nil)
        }
    }

    @Test("fresh Keychain replaces an expired file without owner refresh")
    func expiredFileFreshKeychain() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "file-old", expiry: now.addingTimeInterval(-1))),
            keychain: .success(credentials(token: "keychain-new", expiry: now.addingTimeInterval(120)))
        )
        let refresher = RecordingClaudeRefresher()
        let provider = provider(reader: reader, refresher: refresher)

        #expect(try await provider.session(allowsRefresh: false, rejectedAccessToken: nil).accessToken == "keychain-new")
        #expect(await refresher.count == 0)
    }

    @Test("lookup of expired credentials without refresh reports refresh required")
    func expiredWithoutRefreshRequiresRefresh() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now)),
            keychain: .success(nil)
        )
        let refresher = RecordingClaudeRefresher()

        await expectError(
            .authenticationRejected,
            code: ClaudeSession.refreshRequiredDiagnosticCode,
            recoveryAction: .runSourceCLI
        ) {
            try await provider(reader: reader, refresher: refresher)
                .session(allowsRefresh: false, rejectedAccessToken: nil)
        }
        #expect(await refresher.count == 0)
        #expect(await reader.keychainReads == 1)
    }

    @Test("lookup of near-expiry credentials without refresh reports refresh required")
    func nearExpiryWithoutRefreshRequiresRefresh() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "near", expiry: now.addingTimeInterval(60))),
            keychain: .success(nil)
        )
        let refresher = RecordingClaudeRefresher()

        await expectError(.authenticationRejected, code: ClaudeSession.refreshRequiredDiagnosticCode) {
            try await provider(reader: reader, refresher: refresher)
                .session(allowsRefresh: false, rejectedAccessToken: nil)
        }
        #expect(await refresher.count == 0)
        #expect(await reader.keychainReads == 1)
    }

    @Test("lookup of a rejected token without refresh reports refresh required")
    func rejectedTokenWithoutRefreshRequiresRefresh() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "rejected", expiry: now.addingTimeInterval(300))),
            keychain: .success(nil)
        )
        let refresher = RecordingClaudeRefresher()

        await expectError(.authenticationRejected, code: ClaudeSession.refreshRequiredDiagnosticCode) {
            try await provider(reader: reader, refresher: refresher)
                .session(allowsRefresh: false, rejectedAccessToken: "rejected")
        }
        #expect(await refresher.count == 0)
        #expect(await reader.keychainReads == 1)
    }

    @Test("refresh rotates through the owner and rereads the Keychain once")
    func explicitRefreshSuccess() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(nil),
            keychain: .success(credentials(token: "old", expiry: now))
        )
        let replacement = credentials(token: "new", expiry: now.addingTimeInterval(300))
        let refresher = RecordingClaudeRefresher {
            await reader.setKeychain(replacement)
        }

        let session = try await provider(reader: reader, refresher: refresher)
            .session(allowsRefresh: true, rejectedAccessToken: nil)

        #expect(session.accessToken == "new")
        #expect(await refresher.count == 1)
        #expect(await reader.keychainReads == 2)
    }

    @Test("a failed owner refresh adopts an external rotation")
    func ownerRotationDuringFailedRefresh() async throws {
        let old = credentials(token: "old", expiry: now)
        let reader = SequencedClaudeCredentialReader(files: [
            old,
            credentials(token: "rotated", expiry: now.addingTimeInterval(300)),
        ])
        let refresher = RecordingClaudeRefresher {
            throw CollectionError(kind: .transientNetwork, diagnosticCode: "test.refresh-failed")
        }

        let session = try await provider(reader: reader, refresher: refresher)
            .session(allowsRefresh: true, rejectedAccessToken: nil)

        #expect(session.accessToken == "rotated")
        #expect(await refresher.count == 1)
        #expect(await reader.keychainReads == 1)
    }

    @Test("a rejected file token permits a fresh different Keychain token")
    func rejectedFileFreshKeychain() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "rejected", expiry: now.addingTimeInterval(300))),
            keychain: .success(credentials(token: "keychain", expiry: now.addingTimeInterval(300)))
        )
        let refresher = RecordingClaudeRefresher()

        let session = try await provider(reader: reader, refresher: refresher)
            .session(allowsRefresh: false, rejectedAccessToken: "rejected")

        #expect(session.accessToken == "keychain")
        #expect(await refresher.count == 0)
        #expect(await reader.keychainReads == 1)
    }

    @Test("rejections remain source-scoped until both stores rotate through owner renewal")
    func sourceScopedRejectionsDriveRenewal() async throws {
        let fileA = credentials(token: "file-a", expiry: now.addingTimeInterval(300))
        let keychainB = credentials(token: "keychain-b", expiry: now.addingTimeInterval(300))
        let fileC = credentials(token: "file-c", expiry: now.addingTimeInterval(300))
        let reader = ClaudeTestCredentialReader(
            file: .success(fileA),
            keychain: .success(keychainB)
        )
        let refresher = RecordingClaudeRefresher {
            await reader.setFile(fileC)
        }
        let provider = provider(reader: reader, refresher: refresher)

        #expect(try await provider.session(
            allowsRefresh: false,
            rejectedAccessToken: "file-a"
        ).accessToken == "keychain-b")
        #expect(try await provider.session(
            allowsRefresh: false,
            rejectedAccessToken: nil
        ).accessToken == "keychain-b")
        #expect(await refresher.count == 0)

        #expect(try await provider.session(
            allowsRefresh: true,
            rejectedAccessToken: "keychain-b"
        ).accessToken == "file-c")
        #expect(await refresher.count == 1)
        #expect(try await provider.session(
            allowsRefresh: false,
            rejectedAccessToken: nil
        ).accessToken == "file-c")
    }

    @Test("multiple Keychain rotations never resurrect an unchanged rejected file token")
    func keychainRotationsPreserveRejectedFile() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "file-a", expiry: now.addingTimeInterval(300))),
            keychain: .success(credentials(token: "keychain-b", expiry: now.addingTimeInterval(300)))
        )
        let refresher = RecordingClaudeRefresher()
        let provider = provider(reader: reader, refresher: refresher)

        #expect(try await provider.session(
            allowsRefresh: false,
            rejectedAccessToken: "file-a"
        ).accessToken == "keychain-b")

        for (rejected, replacement) in [
            ("keychain-b", "keychain-c"),
            ("keychain-c", "keychain-d"),
            ("keychain-d", "keychain-e"),
        ] {
            await reader.setKeychain(credentials(
                token: replacement,
                expiry: now.addingTimeInterval(300)
            ))
            #expect(try await provider.session(
                allowsRefresh: false,
                rejectedAccessToken: rejected
            ).accessToken == replacement)
        }

        #expect(try await provider.session(
            allowsRefresh: false,
            rejectedAccessToken: nil
        ).accessToken == "keychain-e")
        #expect(await refresher.count == 0)
    }

    @Test("refresh rejects an unchanged token after one owner refresh")
    func refreshUnchangedFailsClosed() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(nil),
            keychain: .success(credentials(token: "same", expiry: now))
        )
        let replacement = credentials(token: "same", expiry: now.addingTimeInterval(300))
        let refresher = RecordingClaudeRefresher {
            await reader.setKeychain(replacement)
        }

        await expectError(
            .authenticationRejected,
            code: ClaudeSession.refreshRequiredDiagnosticCode,
            recoveryAction: .runSourceCLI
        ) {
            try await provider(reader: reader, refresher: refresher)
                .session(allowsRefresh: true, rejectedAccessToken: nil)
        }
        #expect(await refresher.count == 1)
        #expect(await reader.keychainReads == 2)
    }

    @Test("malformed replacement credentials remain fail-closed")
    func refreshMalformed() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now)),
            keychain: .success(nil)
        )
        let refresher = RecordingClaudeRefresher {
            await reader.setFile(Data("{bad".utf8))
        }

        await expectError(.malformedResponse, code: "claude.session.credentials.invalid-json") {
            try await provider(reader: reader, refresher: refresher)
                .session(allowsRefresh: true, rejectedAccessToken: nil)
        }
        #expect(await refresher.count == 1)
        #expect(await reader.keychainReads == 1)
    }

    @Test("a Keychain read failure never launches the owner refresher")
    func keychainFailureDoesNotRefresh() async {
        let denial = CollectionError(kind: .keychainUnavailable, diagnosticCode: "test.denied", recoveryAction: .retry)
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now)),
            keychain: .failure(denial)
        )
        let refresher = RecordingClaudeRefresher()

        await expectError(
            .keychainUnavailable,
            code: "test.denied",
            recoveryAction: .retry
        ) {
            try await provider(reader: reader, refresher: refresher)
                .session(allowsRefresh: true, rejectedAccessToken: nil)
        }
        #expect(await refresher.count == 0)
        #expect(await reader.keychainReads == 1)
    }

    @Test("a lookup without refresh does not repeat a failed owner refresh")
    func lookupWithoutRefreshDoesNotRepeatFailedRefresh() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now.addingTimeInterval(300))),
            keychain: .success(nil)
        )
        let refresher = RecordingClaudeRefresher {
            throw CollectionError(kind: .authenticationRejected, diagnosticCode: "test.refresh-failed")
        }
        let provider = provider(reader: reader, refresher: refresher)

        await expectError(.authenticationRejected, code: "test.refresh-failed") {
            try await provider.session(allowsRefresh: true, rejectedAccessToken: "old")
        }
        await expectError(
            .authenticationRejected,
            code: ClaudeSession.refreshRequiredDiagnosticCode,
            recoveryAction: .runSourceCLI
        ) {
            try await provider.session(allowsRefresh: false, rejectedAccessToken: nil)
        }

        #expect(await refresher.count == 1)
        #expect(await reader.keychainReads == 3)
    }

    @Test("missing credentials never launches the owner refresher")
    func missingDoesNotRefresh() async {
        let reader = ClaudeTestCredentialReader(file: .success(nil), keychain: .success(nil))
        let refresher = RecordingClaudeRefresher()

        await expectError(.externalSessionMissing, recoveryAction: .signInSourceApp) {
            try await provider(reader: reader, refresher: refresher).session(allowsRefresh: true, rejectedAccessToken: nil)
        }
        #expect(await refresher.count == 0)
    }

    @Test("missing user profile scope is rejected without fallback or refresh")
    func missingProfileScope() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "token", expiry: now.addingTimeInterval(120), scopes: ["org:create_api_key"])),
            keychain: .success(credentials(token: "hidden", expiry: now.addingTimeInterval(120)))
        )
        let refresher = RecordingClaudeRefresher()

        await expectError(
            .authenticationRejected,
            code: "claude.session.profile-scope-missing",
            recoveryAction: .signInSourceApp
        ) {
            try await provider(reader: reader, refresher: refresher).session(allowsRefresh: true, rejectedAccessToken: nil)
        }
        #expect(await reader.keychainReads == 0)
        #expect(await refresher.count == 0)
    }

    @Test("MCP-only stores never supply Claude credentials or trigger owner renewal")
    func mcpOnlyRejected() async {
        let data = try! JSONSerialization.data(withJSONObject: [
            "mcpOAuth": ["server": ["accessToken": "not-a-claude-token"]],
        ])
        let reader = ClaudeTestCredentialReader(file: .success(data), keychain: .success(data))
        let refresher = RecordingClaudeRefresher()

        await expectError(
            .externalSessionMissing,
            code: "claude.session.credentials-missing",
            recoveryAction: .signInSourceApp
        ) {
            try await provider(reader: reader, refresher: refresher).session(allowsRefresh: true, rejectedAccessToken: nil)
        }
        #expect(await reader.keychainReads == 1)
        #expect(await refresher.count == 0)
    }

    @Test("file permission and schema errors are not hidden by Keychain")
    func errorsNotHidden() async {
        for failure in [
            CollectionError(kind: .permissionDenied, diagnosticCode: "test.permission"),
            CollectionError(kind: .unsafePath, diagnosticCode: "test.unsafe"),
            CollectionError(kind: .malformedResponse, diagnosticCode: "test.schema"),
        ] {
            let reader = ClaudeTestCredentialReader(
                file: .failure(failure),
                keychain: .success(credentials(token: "hidden", expiry: now.addingTimeInterval(120)))
            )
            await expectError(failure.kind, code: failure.diagnosticCode) {
                try await provider(reader: reader).session(allowsRefresh: true, rejectedAccessToken: nil)
            }
            #expect(await reader.keychainReads == 0)
        }
    }

    @Test("Keychain read failures keep their own recovery action")
    func keychainUnavailableMapping() async {
        let failure = CollectionError(kind: .keychainUnavailable, diagnosticCode: "test.locked", recoveryAction: .retry)
        let reader = ClaudeTestCredentialReader(file: .success(nil), keychain: .failure(failure))
        await expectError(.keychainUnavailable, code: "test.locked", recoveryAction: .retry) {
            try await provider(reader: reader).session(allowsRefresh: false, rejectedAccessToken: nil)
        }
    }

    @Test("invalid expiry representations and unsafe tokens are rejected")
    func strictFields() async {
        let invalidValues: [Any] = [true, false, 0, -1, "1800000000000"]
        for expiry in invalidValues {
            let data = rawCredentials(token: "token", expiry: expiry, scopes: ["user:profile"])
            let reader = ClaudeTestCredentialReader(file: .success(data), keychain: .success(nil))
            await expectError(.malformedResponse, code: "claude.session.expiry-invalid") {
                try await provider(reader: reader).session(allowsRefresh: false, rejectedAccessToken: nil)
            }
        }

        for token in [
            "",
            " leading",
            "line\nbreak",
            "tökén",
            String(repeating: "a", count: 16 * 1024 + 1),
        ] {
            let reader = ClaudeTestCredentialReader(
                file: .success(credentials(token: token, expiry: now.addingTimeInterval(120))),
                keychain: .success(nil)
            )
            await expectError(.authenticationRejected, code: "claude.session.access-token-invalid") {
                try await provider(reader: reader).session(allowsRefresh: false, rejectedAccessToken: nil)
            }
        }
    }

    @Test("cancellation before lookup has no read or refresh side effects")
    func cancellationBeforeOperation() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now)),
            keychain: .success(nil)
        )
        let refresher = RecordingClaudeRefresher()
        let provider = provider(reader: reader, refresher: refresher)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.session(allowsRefresh: true, rejectedAccessToken: nil)
        }

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await reader.fileReads == 0)
        #expect(await refresher.count == 0)
    }

    @Test("started refresh settles after cancellation and all concurrent waiters deduplicate")
    func cancellationAndConcurrentDeduplication() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now)),
            keychain: .success(nil)
        )
        let replacement = credentials(token: "new", expiry: now.addingTimeInterval(120))
        let refresher = GatedClaudeRefresher {
            await reader.setFile(replacement)
        }
        let provider = provider(reader: reader, refresher: refresher)
        let owner = Task { try await provider.session(allowsRefresh: true, rejectedAccessToken: nil) }
        await refresher.waitUntilStarted()
        let observers = (0..<8).map { _ in
            Task { try await provider.session(allowsRefresh: true, rejectedAccessToken: nil) }
        }
        await Task.yield()
        owner.cancel()
        observers[0].cancel()
        await refresher.release()

        await expectCancellation { try await owner.value }
        for (index, observer) in observers.enumerated() {
            do {
                let session = try await observer.value
                if index == 0 {
                    Issue.record("Expected cancelled observer")
                } else {
                    #expect(session.accessToken == "new")
                }
            } catch is CancellationError {
                #expect(index == 0)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(await refresher.count == 1)
        #expect(await reader.keychainReads == 1)
        #expect(try await provider.session(allowsRefresh: false, rejectedAccessToken: nil).accessToken == "new")
    }

    @Test("concurrent refreshes coalesce while the initial Keychain read is in flight")
    func concurrentRefreshesCoalesceInitialRead() async throws {
        let old = credentials(token: "old", expiry: now)
        let replacement = credentials(token: "new", expiry: now.addingTimeInterval(120))
        let reader = FirstKeychainReadGatedReader(file: old)
        let refresher = RecordingClaudeRefresher {
            await reader.setFile(replacement)
        }
        let provider = provider(reader: reader, refresher: refresher)

        let callers = (0..<8).map { _ in
            Task { try await provider.session(allowsRefresh: true, rejectedAccessToken: nil) }
        }
        await reader.waitUntilReadStarted()
        await Task.yield()
        #expect(await reader.keychainReads == 1)
        await reader.releaseRead()

        for caller in callers {
            #expect(try await caller.value.accessToken == "new")
        }
        #expect(await refresher.count == 1)
        #expect(await reader.keychainReads == 1)
    }

    @Test("cancelling the last refresh waiter during the initial Keychain read prevents owner launch")
    func cancellationBeforeOwnerLaunch() async {
        let reader = FirstKeychainReadGatedReader(file: credentials(token: "old", expiry: now))
        let refresher = RecordingClaudeRefresher()
        let provider = provider(reader: reader, refresher: refresher)
        let callers = (0..<4).map { _ in
            Task { try await provider.session(allowsRefresh: true, rejectedAccessToken: nil) }
        }

        await reader.waitUntilReadStarted()
        for caller in callers { caller.cancel() }
        await reader.releaseRead()
        for caller in callers {
            await expectCancellation { try await caller.value }
        }

        #expect(await refresher.count == 0)
        #expect(await reader.keychainReads == 1)
    }

    @Test("a coalesced refresh result is still checked against each caller's rejected token")
    func concurrentRefreshPreservesCallerRejection() async throws {
        let old = credentials(token: "old", expiry: now)
        let replacement = credentials(token: "new", expiry: now.addingTimeInterval(120))
        let reader = FirstKeychainReadGatedReader(file: old)
        let refresher = RecordingClaudeRefresher {
            await reader.setFile(replacement)
        }
        let provider = provider(reader: reader, refresher: refresher)
        let owner = Task {
            try await provider.session(allowsRefresh: true, rejectedAccessToken: nil)
        }

        await reader.waitUntilReadStarted()
        let rejectingObserver = Task {
            try await provider.session(allowsRefresh: true, rejectedAccessToken: "new")
        }
        await Task.yield()
        await reader.releaseRead()

        #expect(try await owner.value.accessToken == "new")
        await expectError(
            .authenticationRejected,
            code: ClaudeSession.refreshRequiredDiagnosticCode,
            recoveryAction: .runSourceCLI
        ) {
            try await rejectingObserver.value
        }
        #expect(await refresher.count == 1)
    }

    @Test("credential file rejects symlinks, non-regular files, and oversized data")
    func secureCredentialFileReads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let file = claude.appendingPathComponent(".credentials.json")
        let outside = root.appendingPathComponent("outside.json")
        try credentials(token: "token", expiry: now.addingTimeInterval(120)).write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        await expectNativeFileError(root: root, kind: .unsafePath)

        try FileManager.default.removeItem(at: file)
        #expect(Darwin.mkfifo(file.path, S_IRUSR | S_IWUSR) == 0)
        await expectNativeFileError(root: root, kind: .unsafePath, code: "filesystem.not-regular")

        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0x61, count: 64 * 1024 + 1).write(to: file)
        await expectNativeFileError(root: root, kind: .unsafePath, code: "filesystem.size-limit")
    }

    private func expectNativeFileError(
        root: URL,
        kind: CollectionErrorKind,
        code: String? = nil
    ) async {
        let reader = NativeClaudeCredentialReader(homeDirectory: root) { nil }
        await expectError(kind, code: code) {
            try await provider(reader: reader).session(allowsRefresh: false, rejectedAccessToken: nil)
        }
    }

    /// Writes an executable `/bin/sh` script that stands in for `/usr/bin/security`.
    private func script(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent("fake-security-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func provider(
        reader: any ClaudeCredentialReading,
        refresher: any ClaudeAuthRefreshing = RecordingClaudeRefresher()
    ) -> ClaudeCodeSessionProvider {
        ClaudeCodeSessionProvider(clock: ManualClock(now: now), credentials: reader, refresher: refresher)
    }

    private func credentials(
        token: String,
        expiry: Date,
        scopes: [String] = ["user:profile"]
    ) -> Data {
        rawCredentials(
            token: token,
            expiry: Int64((expiry.timeIntervalSince1970 * 1_000).rounded()),
            scopes: scopes
        )
    }

    private func rawCredentials(token: String, expiry: Any, scopes: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": token,
                "expiresAt": expiry,
                "scopes": scopes,
                "subscriptionType": "max",
                "rateLimitTier": "default_claude_max_20x",
                "refreshToken": "must-never-be-read",
            ],
        ])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func expectError<T>(
        _ kind: CollectionErrorKind,
        code: String? = nil,
        recoveryAction: RecoveryAction? = nil,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected CollectionError")
        } catch let error as CollectionError {
            #expect(error.kind == kind)
            if let code { #expect(error.diagnosticCode == code) }
            if let recoveryAction { #expect(error.recoveryAction == recoveryAction) }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectCancellation<T>(operation: () async throws -> T) async {
        do {
            _ = try await operation()
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Claude sign-ins are discovered per config directory, deduplicated, and dropped when removed")
    func claudeAccountDiscovery() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileManager = FileManager.default
        func write(_ relativePath: String, _ text: String) throws {
            let url = home.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func oauth(_ uuid: String, _ email: String) -> String {
            "{\"oauthAccount\":{\"accountUuid\":\"\(uuid)\",\"emailAddress\":\"\(email)\"}}"
        }
        try write(".claude.json", oauth("uuid-default", "default@example.com"))
        try write(".claude-work/.claude.json", oauth("uuid-work", "work@example.com"))
        try write(".claude-alias/.claude.json", oauth("uuid-work", "work@example.com"))
        try write(".claude-personal/.credentials.json", "{}")
        try write("custom-claude/.claude.json", oauth("uuid-custom", "custom@example.com"))
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".claude-empty"),
            withIntermediateDirectories: true
        )
        let customPath = home.appendingPathComponent("custom-claude").path
        let environment = ["CLAUDE_CONFIG_DIR": customPath]

        let locations = ClaudeCodeSessionProvider.locations(homeDirectory: home, environment: environment)
        #expect(locations.map(\.sourceID) == [
            "claude.oauth",
            "claude.oauth.dir-\(SHA256Hex.digest(customPath).prefix(8))",
            "claude.oauth.claude-alias",
            "claude.oauth.claude-personal",
            "claude.oauth.claude-work",
        ])
        let workPath = home.standardizedFileURL.path + "/.claude-work"
        let work = try #require(locations.first { $0.sourceID == "claude.oauth.claude-work" })
        #expect(work.keychainService == "Claude Code-credentials-\(SHA256Hex.digest(workPath).prefix(8))")
        #expect(work.credentialsRelativePath == ".claude-work/.credentials.json")
        #expect(work.configDirectory == workPath)
        #expect(locations[0].keychainService == "Claude Code-credentials")

        let provider = ClaudeCodeSessionProvider(clock: ManualClock(now: now), homeDirectory: home, environment: environment)
        let accounts = try await provider.accounts()
        #expect(accounts.map(\.sourceID) == [
            "claude.oauth",
            "claude.oauth.dir-\(SHA256Hex.digest(customPath).prefix(8))",
            "claude.oauth.claude-alias",
            "claude.oauth.claude-personal",
        ])
        #expect(accounts.map(\.email) == ["default@example.com", "custom@example.com", "work@example.com", nil])

        try fileManager.removeItem(at: home.appendingPathComponent(".claude-personal"))
        #expect(try await provider.accounts().map(\.sourceID).contains("claude.oauth.claude-personal") == false)

        // Repair must receive the exact string whose hash names the Keychain item.
        let slashed = customPath + "/"
        let slashedLocations = ClaudeCodeSessionProvider.locations(
            homeDirectory: home,
            environment: ["CLAUDE_CONFIG_DIR": slashed]
        )
        let custom = try #require(slashedLocations.dropFirst().first)
        #expect(custom.configDirectory == slashed)
        #expect(custom.keychainService == "Claude Code-credentials-\(SHA256Hex.digest(slashed).prefix(8))")
    }

    @Test("A default Claude location without a sign-in is listed only when it is the only location")
    func claudeDefaultWithoutSignInIsSkippedBesideOthers() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = ClaudeCodeSessionProvider(clock: ManualClock(now: now), homeDirectory: home, environment: [:])
        #expect(try await provider.accounts().map(\.sourceID) == ["claude.oauth"])

        let work = home.appendingPathComponent(".claude-work/.claude.json")
        try FileManager.default.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"oauthAccount\":{\"accountUuid\":\"uuid-work\"}}".utf8).write(to: work)
        #expect(try await provider.accounts().map(\.sourceID) == ["claude.oauth.claude-work"])

        let credentials = home.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: credentials)
        #expect(try await provider.accounts().map(\.sourceID) == ["claude.oauth", "claude.oauth.claude-work"])
    }

    @Test("Claude Code repair for a config directory receives that CLAUDE_CONFIG_DIR")
    func repairEnvironmentTargetsAccountDirectory() {
        let home = URL(fileURLWithPath: "/Users/example")
        let scoped = ClaudeCLIAuthRefresher.safeEnvironment(
            homeDirectory: home,
            workingDirectory: URL(fileURLWithPath: "/tmp/probe"),
            configDirectory: "/Users/example/.claude-work/"
        )
        #expect(scoped["CLAUDE_CONFIG_DIR"] == "/Users/example/.claude-work/")
        let defaultAccount = ClaudeCLIAuthRefresher.safeEnvironment(
            homeDirectory: home,
            workingDirectory: URL(fileURLWithPath: "/tmp/probe")
        )
        #expect(defaultAccount["CLAUDE_CONFIG_DIR"] == nil)
    }

}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private actor SequencedClaudeCredentialReader: ClaudeCredentialReading {
    private let files: [Data]
    private var index = 0
    private(set) var keychainReads = 0

    init(files: [Data]) {
        self.files = files
    }

    func readFile() async throws -> Data? {
        guard !files.isEmpty else { return nil }
        defer {
            if index < files.count - 1 {
                index += 1
            }
        }
        return files[index]
    }

    func readKeychain() async throws -> Data? {
        keychainReads += 1
        return nil
    }
}

/// Blocks the first Keychain read until released, then reads nothing from the Keychain.
private actor FirstKeychainReadGatedReader: ClaudeCredentialReading {
    private var file: Data
    private var readReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var keychainReads = 0

    init(file: Data) {
        self.file = file
    }

    func readFile() async throws -> Data? { file }

    func readKeychain() async throws -> Data? {
        keychainReads += 1
        guard !readReleased else { return nil }
        let current = observers
        observers.removeAll()
        current.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
        return nil
    }

    func setFile(_ data: Data) {
        file = data
    }

    func waitUntilReadStarted() async {
        if keychainReads > 0 { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func releaseRead() {
        readReleased = true
        let current = releaseWaiters
        releaseWaiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor ClaudeTestCredentialReader: ClaudeCredentialReading {
    private var file: Result<Data?, CollectionError>
    private var keychain: Result<Data?, CollectionError>
    private(set) var fileReads = 0
    private(set) var keychainReads = 0

    init(file: Result<Data?, CollectionError>, keychain: Result<Data?, CollectionError>) {
        self.file = file
        self.keychain = keychain
    }

    func readFile() async throws -> Data? {
        fileReads += 1
        return try file.get()
    }

    func readKeychain() async throws -> Data? {
        keychainReads += 1
        return try keychain.get()
    }

    func setFile(_ data: Data?) {
        file = .success(data)
    }

    func setKeychain(_ data: Data?) {
        keychain = .success(data)
    }
}

private struct AdvancingClaudeCredentialReader: ClaudeCredentialReading {
    let clock: ManualClock
    let data: Data

    func readFile() async throws -> Data? { nil }

    func readKeychain() async throws -> Data? {
        await clock.advance(by: .seconds(2))
        return data
    }
}

private actor RecordingClaudeRefresher: ClaudeAuthRefreshing {
    private let action: @Sendable () async throws -> Void
    private(set) var count = 0

    init(action: @escaping @Sendable () async throws -> Void = {}) {
        self.action = action
    }

    func refresh() async throws {
        count += 1
        try await action()
    }
}

private actor GatedClaudeRefresher: ClaudeAuthRefreshing {
    private let action: @Sendable () async throws -> Void
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0

    init(action: @escaping @Sendable () async throws -> Void) {
        self.action = action
    }

    func refresh() async throws {
        count += 1
        started = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        try await action()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let current = releaseWaiters
        releaseWaiters.removeAll()
        current.forEach { $0.resume() }
    }
}
