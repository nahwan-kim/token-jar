import Darwin
import Foundation
import Security
import Testing
@testable import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Claude Code native session", .serialized)
struct ClaudeSessionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("native lookup selects the current OS account among same-service records")
    func nativeAccountSelection() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = credentials(token: "current-owner-token", expiry: now.addingTimeInterval(60))
        let other = credentials(token: "other-account-token", expiry: now.addingTimeInterval(60))
        let reader = NativeClaudeCredentialReader(homeDirectory: root, keychainLookup: { interaction in
            try NativeClaudeCredentialReader.readNativeKeychain(allowInteraction: interaction) { query, result in
                let fields = query as! [String: Any]
                let currentAccount = fields[kSecAttrAccount as String] as? String == NSUserName()
                let exactService = fields[kSecAttrService as String] as? String == "Claude Code-credentials"
                let correctlyScoped = currentAccount && exactService
                #expect(correctlyScoped)
                result?.pointee = (correctlyScoped ? current : other) as NSData
                return errSecSuccess
            }
        })
        #expect(try await provider(reader: reader).session(allowInteraction: false).accessToken == "current-owner-token")
    }

    @Test("missing current OS account never falls back to another same-service record")
    func missingNativeAccountDoesNotBroadenLookup() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = credentials(token: "other-account-token", expiry: now.addingTimeInterval(60))
        let reader = NativeClaudeCredentialReader(homeDirectory: root, keychainLookup: { interaction in
            try NativeClaudeCredentialReader.readNativeKeychain(allowInteraction: interaction) { query, result in
                let fields = query as! [String: Any]
                if fields[kSecAttrAccount as String] as? String == NSUserName() {
                    return errSecItemNotFound
                }
                result?.pointee = other as NSData
                return errSecSuccess
            }
        })
        await expectError(.externalSessionMissing, code: "claude.session.credentials-missing") {
            try await provider(reader: reader).session(allowInteraction: false)
        }
    }
    @Test("legacy no-prompt policy restores prior interaction state after success and failure")
    func legacyKeychainInteractionPolicy() throws {
        var previous: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess)
        let value = try ClaudeNativeKeychainAccess.perform(allowInteraction: false) {
            var current: DarwinBoolean = true
            #expect(SecKeychainGetUserInteractionAllowed(&current) == errSecSuccess)
            #expect(!current.boolValue)
            return "read-only"
        }
        #expect(value == "read-only")
        var restored: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
        #expect(restored.boolValue == previous.boolValue)
        enum Failure: Error { case expected }
        #expect(throws: Failure.self) {
            try ClaudeNativeKeychainAccess.perform(allowInteraction: false) {
                throw Failure.expected
            }
        }
        #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
        #expect(restored.boolValue == previous.boolValue)
        try ClaudeNativeKeychainAccess.perform(allowInteraction: true) {
            var manual: DarwinBoolean = false
            #expect(SecKeychainGetUserInteractionAllowed(&manual) == errSecSuccess)
            #expect(manual.boolValue == previous.boolValue)
        }
    }
    @Test("MCP-only file permits the separate native Claude AI Keychain session")
    func mcpOnlyFileUsesKeychain() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(Data(#"{"mcpOAuth":{"server":{"accessToken":"never-use"}}}"#.utf8)),
            keychain: .success(credentials(token: "native-ai", expiry: now.addingTimeInterval(60)))
        )
        let refresher = RecordingClaudeRefresher()
        #expect(try await provider(reader: reader, refresher: refresher)
            .session(allowInteraction: false).accessToken == "native-ai")
        #expect(await refresher.count == 0)
        #expect(await reader.interactionFlags == [false])
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
        await expectError(.authenticationRejected, code: "claude.session.expired") {
            try await provider.session(allowInteraction: false)
        }
    }

    @Test("locked console skips native Keychain for both timer and manual collection")
    func lockedConsoleNeverStartsKeychainLookup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = NativeClaudeCredentialReader(
            homeDirectory: root, screenIsUnlocked: { false },
            keychainLookup: { _ in
                Issue.record("Locked-screen lookup must not reach Security")
                return nil
            }
        )
        for allowInteraction in [false, true] {
            await expectError(
                .keychainUnavailable,
                code: "claude.session.keychain.screen-locked",
                recoveryAction: .retry
            ) {
                try await provider(reader: reader).session(allowInteraction: allowInteraction)
            }
        }

        let directory = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try credentials(token: "fresh-file", expiry: now.addingTimeInterval(60))
            .write(to: directory.appendingPathComponent(".credentials.json"))
        #expect(try await provider(reader: reader).session(allowInteraction: false).accessToken == "fresh-file")
    }

    @Test("bounded Keychain worker suppresses duplicates, discards late data, and recovers")
    func boundedKeychainLookup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lookup = GatedNativeKeychainLookup(
            late: Data("late".utf8),
            recovered: Data("recovered".utf8)
        )
        let reader = NativeClaudeCredentialReader(
            homeDirectory: root,
            backgroundTimeout: 0.1,
            manualTimeout: 0.15,
            keychainLookup: { allowInteraction in
                lookup.read(allowInteraction: allowInteraction)
            }
        )

        let first = Task { try await reader.readKeychain(allowInteraction: false) }
        await lookup.waitForCalls(1)
        let duplicate = Task { try await reader.readKeychain(allowInteraction: true) }

        await expectError(
            .keychainUnavailable,
            code: "claude.session.keychain.timeout",
            recoveryAction: .retry
        ) {
            try await first.value
        }
        await expectError(
            .keychainUnavailable,
            code: "claude.session.keychain.timeout",
            recoveryAction: .retry
        ) {
            try await duplicate.value
        }
        #expect(lookup.callCount == 1)

        lookup.releaseFirst()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var recovered: Data?
        while ContinuousClock.now < deadline {
            do {
                recovered = try await reader.readKeychain(allowInteraction: false)
                break
            } catch let error as CollectionError
                where error.diagnosticCode == "claude.session.keychain.query-in-flight" {
                // The injected closure has returned, but the worker may not yet
                // have published completion to its continuation gate.
                await Task.yield()
            }
        }
        #expect(recovered == Data("recovered".utf8))
        #expect(lookup.callCount == 2)
        #expect(lookup.interactionFlags == [false, false])
    }

    @Test("cancelled Keychain waiter returns promptly without starting a replacement query")
    func cancelledKeychainWaiter() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lookup = GatedNativeKeychainLookup(late: nil, recovered: nil)
        let reader = NativeClaudeCredentialReader(
            homeDirectory: root,
            backgroundTimeout: 1,
            manualTimeout: 1,
            keychainLookup: { allowInteraction in
                lookup.read(allowInteraction: allowInteraction)
            }
        )
        let task = Task { try await reader.readKeychain(allowInteraction: false) }
        await lookup.waitForCalls(1)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch {
            Issue.record("Unexpected error: \(error)")
        }

        await expectError(
            .keychainUnavailable,
            code: "claude.session.keychain.query-in-flight",
            recoveryAction: .retry
        ) {
            try await reader.readKeychain(allowInteraction: false)
        }
        #expect(lookup.callCount == 1)
        lookup.releaseFirst()
    }

    @Test("pre-cancelled and locked reads start no Keychain worker")
    func guardedKeychainReadStartsNoWorker() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lookup = GatedNativeKeychainLookup(late: nil, recovered: nil)
        let reader = NativeClaudeCredentialReader(
            homeDirectory: root,
            screenIsUnlocked: { true },
            keychainLookup: { allowInteraction in
                lookup.read(allowInteraction: allowInteraction)
            }
        )
        let cancelled = Task {
            await Task.yield()
            return try await reader.readKeychain(allowInteraction: false)
        }
        cancelled.cancel()
        _ = try? await cancelled.value
        #expect(lookup.callCount == 0)

        let lockedReader = NativeClaudeCredentialReader(
            homeDirectory: root,
            screenIsUnlocked: { false },
            keychainLookup: { allowInteraction in
                lookup.read(allowInteraction: allowInteraction)
            }
        )
        _ = try? await lockedReader.readKeychain(allowInteraction: true)
        #expect(lookup.callCount == 0)
    }
    @Test("fresh credential file is authoritative over Keychain")
    func freshFilePrecedence() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "file-token", expiry: now.addingTimeInterval(60))),
            keychain: .success(credentials(token: "keychain-token", expiry: now.addingTimeInterval(120)))
        )
        let provider = provider(reader: reader)

        let session = try await provider.session(allowInteraction: false)

        #expect(session.accessToken == "file-token")
        #expect(session.subscriptionType == "max")
        #expect(session.rateLimitTier == "default_claude_max_20x")
        #expect(await reader.keychainReads == 0)
    }

    @Test("expiresAt is interpreted exclusively as epoch milliseconds")
    func expiryUsesMilliseconds() async {
        let secondsValue = Int64(now.addingTimeInterval(60).timeIntervalSince1970)
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
            code: "claude.session.expired",
            recoveryAction: .retry
        ) {
            try await provider(reader: reader).session(allowInteraction: false)
        }
    }

    @Test("fresh Keychain replaces an expired file without owner refresh")
    func expiredFileFreshKeychain() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "file-old", expiry: now.addingTimeInterval(-1))),
            keychain: .success(credentials(token: "keychain-new", expiry: now.addingTimeInterval(60)))
        )
        let refresher = RecordingClaudeRefresher()
        let provider = provider(reader: reader, refresher: refresher)

        #expect(try await provider.session(allowInteraction: false).accessToken == "keychain-new")
        #expect(await refresher.count == 0)
    }

    @Test("expired credentials require authentication in the background")
    func expiredBackground() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now)),
            keychain: .success(nil)
        )
        let refresher = RecordingClaudeRefresher()

        await expectError(
            .authenticationRejected,
            code: "claude.session.expired",
            recoveryAction: .retry
        ) {
            try await provider(reader: reader, refresher: refresher).session(allowInteraction: false)
        }
        #expect(await refresher.count == 0)
        #expect(await reader.interactionFlags == [false])
    }

    @Test("manual refresh must produce a fresh changed access token")
    func manualRefreshSuccess() async throws {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now)),
            keychain: .success(nil)
        )
        let replacement = credentials(token: "new", expiry: now.addingTimeInterval(300))
        let refresher = RecordingClaudeRefresher {
            await reader.setFile(replacement)
        }

        let session = try await provider(reader: reader, refresher: refresher)
            .session(allowInteraction: true)

        #expect(session.accessToken == "new")
        #expect(await refresher.count == 1)
        #expect(await reader.interactionFlags == [true])
    }

    @Test("manual refresh rejects an unchanged access token")
    func manualRefreshUnchanged() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "same", expiry: now)),
            keychain: .success(nil)
        )
        let replacement = credentials(token: "same", expiry: now.addingTimeInterval(300))
        let refresher = RecordingClaudeRefresher {
            await reader.setFile(replacement)
        }

        await expectError(.authenticationRejected, code: "claude.session.refresh.token-unchanged") {
            try await provider(reader: reader, refresher: refresher).session(allowInteraction: true)
        }
        #expect(await refresher.count == 1)
    }

    @Test("manual refresh surfaces malformed replacement credentials")
    func manualRefreshMalformed() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now)),
            keychain: .success(nil)
        )
        let refresher = RecordingClaudeRefresher {
            await reader.setFile(Data("{bad".utf8))
        }

        await expectError(.malformedResponse, code: "claude.session.credentials.invalid-json") {
            try await provider(reader: reader, refresher: refresher).session(allowInteraction: true)
        }
    }

    @Test("manual refresh surfaces credentials removed by the owner")
    func manualRefreshMissing() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "old", expiry: now)),
            keychain: .success(nil)
        )
        let refresher = RecordingClaudeRefresher {
            await reader.setFile(nil)
        }

        await expectError(
            .externalSessionMissing,
            code: "claude.session.refresh.credentials-missing",
            recoveryAction: .signInSourceApp
        ) {
            try await provider(reader: reader, refresher: refresher).session(allowInteraction: true)
        }
    }

    @Test("missing credentials never launches the owner refresher")
    func missingDoesNotRefresh() async {
        let reader = ClaudeTestCredentialReader(file: .success(nil), keychain: .success(nil))
        let refresher = RecordingClaudeRefresher()

        await expectError(.externalSessionMissing, recoveryAction: .signInSourceApp) {
            try await provider(reader: reader, refresher: refresher).session(allowInteraction: true)
        }
        #expect(await refresher.count == 0)
    }

    @Test("missing user profile scope is rejected without fallback or refresh")
    func missingProfileScope() async {
        let reader = ClaudeTestCredentialReader(
            file: .success(credentials(token: "token", expiry: now.addingTimeInterval(60), scopes: ["org:create_api_key"])),
            keychain: .success(credentials(token: "hidden", expiry: now.addingTimeInterval(60)))
        )
        let refresher = RecordingClaudeRefresher()

        await expectError(
            .authenticationRejected,
            code: "claude.session.profile-scope-missing",
            recoveryAction: .signInSourceApp
        ) {
            try await provider(reader: reader, refresher: refresher).session(allowInteraction: true)
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
            try await provider(reader: reader, refresher: refresher).session(allowInteraction: true)
        }
        #expect(await reader.keychainReads == 1)
        #expect(await refresher.count == 0)
    }

    @Test("background Keychain reads prohibit UI and manual reads allow it")
    func keychainInteractionMode() async {
        let backgroundReader = ClaudeTestCredentialReader(file: .success(nil), keychain: .success(nil))
        await expectError(.externalSessionMissing, recoveryAction: .signInSourceApp) {
            try await provider(reader: backgroundReader).session(allowInteraction: false)
        }
        #expect(await backgroundReader.interactionFlags == [false])

        let manualReader = ClaudeTestCredentialReader(file: .success(nil), keychain: .success(nil))
        await expectError(.externalSessionMissing, recoveryAction: .signInSourceApp) {
            try await provider(reader: manualReader).session(allowInteraction: true)
        }
        #expect(await manualReader.interactionFlags == [true])
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
                keychain: .success(credentials(token: "hidden", expiry: now.addingTimeInterval(60)))
            )
            await expectError(failure.kind, code: failure.diagnosticCode) {
                try await provider(reader: reader).session(allowInteraction: true)
            }
            #expect(await reader.keychainReads == 0)
        }
    }

    @Test("Keychain denial remains non-authentication unavailability")
    func keychainUnavailableMapping() async {
        let failure = CollectionError(kind: .keychainUnavailable, diagnosticCode: "test.locked")
        let reader = ClaudeTestCredentialReader(file: .success(nil), keychain: .failure(failure))
        await expectError(.keychainUnavailable, code: "test.locked", recoveryAction: .retry) {
            try await provider(reader: reader).session(allowInteraction: false)
        }
    }

    @Test("invalid expiry representations and unsafe tokens are rejected")
    func strictFields() async {
        let invalidValues: [Any] = [true, false, 0, -1, "1800000000000"]
        for expiry in invalidValues {
            let data = rawCredentials(token: "token", expiry: expiry, scopes: ["user:profile"])
            let reader = ClaudeTestCredentialReader(file: .success(data), keychain: .success(nil))
            await expectError(.malformedResponse, code: "claude.session.expiry-invalid") {
                try await provider(reader: reader).session(allowInteraction: false)
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
                file: .success(credentials(token: token, expiry: now.addingTimeInterval(60))),
                keychain: .success(nil)
            )
            await expectError(.authenticationRejected, code: "claude.session.access-token-invalid") {
                try await provider(reader: reader).session(allowInteraction: false)
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
            await Task.yield()
            return try await provider.session(allowInteraction: true)
        }
        task.cancel()

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
        let replacement = credentials(token: "new", expiry: now.addingTimeInterval(60))
        let refresher = GatedClaudeRefresher {
            await reader.setFile(replacement)
        }
        let provider = provider(reader: reader, refresher: refresher)
        let owner = Task { try await provider.session(allowInteraction: true) }
        await refresher.waitUntilStarted()
        let observers = (0..<8).map { _ in
            Task { try await provider.session(allowInteraction: true) }
        }
        for _ in 0..<1_000 {
            if await reader.fileReads >= 9 { break }
            await Task.yield()
        }
        #expect(await reader.fileReads >= 9)
        observers[0].cancel()
        await refresher.release()

        #expect(try await owner.value.accessToken == "new")
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
    }

    @Test("credential file rejects symlinks, non-regular files, and oversized data")
    func secureCredentialFileReads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let file = claude.appendingPathComponent(".credentials.json")
        let outside = root.appendingPathComponent("outside.json")
        try credentials(token: "token", expiry: now.addingTimeInterval(60)).write(to: outside)
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
        let reader = NativeClaudeCredentialReader(homeDirectory: root) { _ in nil }
        await expectError(kind, code: code) {
            try await provider(reader: reader).session(allowInteraction: false)
        }
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
}

private final class GatedNativeKeychainLookup: @unchecked Sendable {
    private let lock = NSLock()
    private let firstRelease = DispatchSemaphore(value: 0)
    private let late: Data?
    private let recovered: Data?
    private var calls = 0
    private var completions = 0
    private var flags: [Bool] = []

    init(late: Data?, recovered: Data?) {
        self.late = late
        self.recovered = recovered
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var interactionFlags: [Bool] {
        lock.withLock { flags }
    }

    func read(allowInteraction: Bool) -> Data? {
        let call = lock.withLock {
            calls += 1
            flags.append(allowInteraction)
            return calls
        }
        let value: Data?
        if call == 1 {
            firstRelease.wait()
            value = late
        } else {
            value = recovered
        }
        lock.withLock { completions += 1 }
        return value
    }

    func releaseFirst() {
        firstRelease.signal()
    }

    func waitForCalls(_ expected: Int) async {
        for _ in 0..<10_000 {
            if callCount >= expected { return }
            await Task.yield()
        }
        Issue.record("Keychain lookup did not start")
    }

    func waitForCompletions(_ expected: Int) async {
        for _ in 0..<10_000 {
            if lock.withLock({ completions }) >= expected { return }
            await Task.yield()
        }
        Issue.record("Keychain lookup did not complete")
    }
}

private actor ClaudeTestCredentialReader: ClaudeCredentialReading {
    private var file: Result<Data?, CollectionError>
    private var keychain: Result<Data?, CollectionError>
    private(set) var fileReads = 0
    private(set) var keychainReads = 0
    private(set) var interactionFlags: [Bool] = []

    init(file: Result<Data?, CollectionError>, keychain: Result<Data?, CollectionError>) {
        self.file = file
        self.keychain = keychain
    }

    func readFile() async throws -> Data? {
        fileReads += 1
        return try file.get()
    }

    func readKeychain(allowInteraction: Bool) async throws -> Data? {
        keychainReads += 1
        interactionFlags.append(allowInteraction)
        return try keychain.get()
    }

    func setFile(_ data: Data?) {
        file = .success(data)
    }
}

private struct AdvancingClaudeCredentialReader: ClaudeCredentialReading {
    let clock: ManualClock
    let data: Data

    func readFile() async throws -> Data? { nil }

    func readKeychain(allowInteraction: Bool) async throws -> Data? {
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
