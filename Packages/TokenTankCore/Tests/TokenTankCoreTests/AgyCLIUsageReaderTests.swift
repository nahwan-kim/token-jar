import Foundation
import Testing
@testable import TokenTankCore
import TokenTankDomain

@Suite("Antigravity CLI usage reader", .serialized)
struct AgyCLIUsageReaderTests {
    /// Successive sign-in stamps: each read takes the next one and the last one repeats.
    private final class SignInStamp: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String?]

        init(_ values: String?...) { self.values = values }

        func set(_ newValue: String?) { lock.withLock { values = [newValue] } }
        func get() -> String? { lock.withLock { values.count > 1 ? values.removeFirst() : values[0] } }
    }

    private let envelope = #"{"conversation_id":"","status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.5}]}]}}}"#

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenTankAgyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fake `agy` that appends its arguments, one per line, to `launches` and then runs `body`.
    private func makeExecutable(in directory: URL, body: String) throws -> URL {
        let executable = directory.appendingPathComponent("agy")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" >> "\(directory.path)/launches"
        printf '%s\\n' '--' >> "\(directory.path)/launches"
        \(body)
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func launches(in directory: URL) -> [[String]] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8) else {
            return []
        }
        return text.split(separator: "--\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\n").map(String.init) }
    }

    private func reader(
        _ executable: URL,
        in directory: URL,
        stamp: SignInStamp,
        timeout: Duration = .seconds(5),
        screenIsUnlocked: @escaping @Sendable () -> Bool = { true }
    ) -> AgyCLIUsageReader {
        AgyCLIUsageReader(
            executableCandidates: [executable],
            homeDirectory: directory,
            timeout: timeout,
            workingDirectoryParent: directory,
            screenIsUnlocked: screenIsUnlocked,
            signInStamp: { stamp.get() }
        )
    }

    @Test("runs only the read-only /usage command and returns its command data")
    func usageCommand() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "printf '%s\\n' '\(envelope)'")

        let data = try await reader(executable, in: directory, stamp: SignInStamp("0x01")).readUsage()

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["groups"] as? [Any])?.count == 1)
        #expect(launches(in: directory) == [["--output-format", "json", "--log-file", "/dev/null", "-p", "/usage"]])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(leftovers) == ["agy", "launches"], "the temporary workspace is removed")
    }

    @Test("without agy's Keychain sign-in the CLI is never started")
    func missingSignIn() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "printf '%s\\n' '\(envelope)'")

        await #expect(throws: CollectionError(
            kind: .externalSessionMissing,
            diagnosticCode: "antigravity.agy.sign-in-missing",
            recoveryAction: .signInSourceApp
        )) {
            try await reader(executable, in: directory, stamp: SignInStamp(nil)).readUsage()
        }
        #expect(launches(in: directory).isEmpty)
    }

    @Test("a refresh cancelled during the Keychain lookup never starts agy")
    func cancellationDuringLookupSkipsLaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "printf '%s\\n' '\(envelope)'")
        let reader = AgyCLIUsageReader(
            executableCandidates: [executable],
            homeDirectory: directory,
            timeout: .seconds(5),
            workingDirectoryParent: directory,
            screenIsUnlocked: { true },
            signInStamp: {
                // The refresh is cancelled while the lookup is in flight; the lookup still answers.
                withUnsafeCurrentTask { $0?.cancel() }
                return "0x01"
            }
        )

        await #expect(throws: CancellationError.self) { try await reader.readUsage() }
        #expect(launches(in: directory).isEmpty)
    }

    @Test("a hung sign-in prompt is stopped and not reopened until the sign-in item changes")
    func signInPromptPausesLaunches() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            body: "printf '%s\\n' 'Authentication required. Please visit the URL to log in:' >&2\nexec sleep 10"
        )
        let stamp = SignInStamp("0x01")
        // The prompt is written at once; the deadline leaves room for a slow fork on a loaded machine.
        let reader = reader(executable, in: directory, stamp: stamp, timeout: .seconds(2))
        let required = CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "antigravity.agy.sign-in-required",
            recoveryAction: .signInSourceApp
        )

        await #expect(throws: required) { try await reader.readUsage() }
        await #expect(throws: required) { try await reader.readUsage() }
        #expect(launches(in: directory).count == 1)

        stamp.set("0x02")
        await #expect(throws: required) { try await reader.readUsage() }
        #expect(launches(in: directory).count == 2)
    }

    @Test("a sign-in item agy rewrites during the failing run is the one that pauses launches")
    func stampAfterFailureIsRemembered() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            body: #"printf '%s\n' '{"status":"ERROR","error":"authentication failed or timed out","num_turns":0}'"#
        )
        let reader = reader(executable, in: directory, stamp: SignInStamp("0x01", "0x02"))

        await #expect(throws: CollectionError.self) { try await reader.readUsage() }
        await #expect(throws: CollectionError.self) { try await reader.readUsage() }
        #expect(launches(in: directory).count == 1)
    }

    @Test("a console locked during the failing run skips the second Keychain lookup")
    func lockDuringRunKeepsPreRunStamp() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            body: #"printf '%s\n' '{"status":"ERROR","error":"authentication failed or timed out","num_turns":0}'"#
        )
        // Before the lookup, before the launch, after the failure, then the next refresh.
        let unlockChecks = SignInStamp("unlocked", "unlocked", "locked", "unlocked")
        let stamp = SignInStamp("0x01", "0x02")
        let reader = reader(executable, in: directory, stamp: stamp) { unlockChecks.get() == "unlocked" }

        await #expect(throws: CollectionError.self) { try await reader.readUsage() }
        // The locked check skipped the post-run lookup, so 0x02 is new to the reader and agy runs again.
        await #expect(throws: CollectionError.self) { try await reader.readUsage() }
        #expect(launches(in: directory).count == 2)
    }

    @Test("a refresh cancelled during the post-failure Keychain lookup ends as cancelled")
    func cancellationDuringPostFailureLookup() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            body: #"printf '%s\n' '{"status":"ERROR","error":"authentication failed or timed out","num_turns":0}'"#
        )
        let lookups = SignInStamp("first", "second")
        let reader = AgyCLIUsageReader(
            executableCandidates: [executable],
            homeDirectory: directory,
            timeout: .seconds(5),
            workingDirectoryParent: directory,
            screenIsUnlocked: { true },
            signInStamp: {
                if lookups.get() == "second" {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                }
                return "0x01"
            }
        )

        await #expect(throws: CancellationError.self) { try await reader.readUsage() }
        #expect(launches(in: directory).count == 1)
    }

    @Test("cancelling a refresh stops agy and removes its workspace")
    func cancellationStopsTheChild() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        #expect(mkfifo(started.path, 0o600) == 0)
        let executable = try makeExecutable(in: directory, body: "printf 'up' > '\(started.path)'\nexec sleep 30")
        let reader = reader(executable, in: directory, stamp: SignInStamp("0x01"), timeout: .seconds(30))
        let clock = ContinuousClock()
        let begin = clock.now
        let task = Task { try await reader.readUsage() }
        // Opening the FIFO blocks until the fake agy writes to it, so the child is running after this.
        _ = try await Task.detached { try FileHandle(forReadingFrom: started).readToEnd() }.value
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(begin.duration(to: clock.now) < .seconds(10))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(leftovers) == ["agy", "launches", "started"])
    }

    @Test("a flood on stderr is capped and the run still ends at the deadline")
    func stderrIsBounded() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "head -c 5000000 /dev/zero >&2\nexec sleep 10")

        await #expect(throws: CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.agy.timeout")) {
            try await reader(executable, in: directory, stamp: SignInStamp("0x01"), timeout: .seconds(1)).readUsage()
        }
    }

    @Test("a valid envelope from a child that then hangs with stderr open is a timeout")
    func envelopeThenHangIsTimeout() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "printf '%s\\n' '\(envelope)'\nexec >&-\nexec sleep 10")

        await #expect(throws: CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.agy.timeout")) {
            try await reader(executable, in: directory, stamp: SignInStamp("0x01"), timeout: .seconds(1)).readUsage()
        }
    }

    @Test("stdout beyond 4 MiB is a size failure, not usage")
    func stdoutIsBounded() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "head -c 5000000 /dev/zero")

        await #expect(throws: CollectionError(kind: .malformedResponse, diagnosticCode: "antigravity.agy.response-size-limit")) {
            try await reader(executable, in: directory, stamp: SignInStamp("0x01")).readUsage()
        }
    }

    @Test("a console that locks during the Keychain lookup does not start agy")
    func lockDuringLookupSkipsLaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "printf '%s\\n' '\(envelope)'")
        let unlockChecks = SignInStamp("unlocked", "locked")

        await #expect(throws: CollectionError(kind: .keychainUnavailable, diagnosticCode: "antigravity.agy.screen-locked", recoveryAction: .retry)) {
            try await reader(executable, in: directory, stamp: SignInStamp("0x01")) { unlockChecks.get() == "unlocked" }.readUsage()
        }
        #expect(launches(in: directory).isEmpty)
    }

    @Test("an envelope that is not the usage command, took a model turn, or failed is not usage")
    func envelopeContract() throws {
        func run(_ stdout: String, status: Int32 = 0, stderr: String = "") -> BoundedRun {
            BoundedRun(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), status: status, failure: nil)
        }
        let modelReply = #"{"conversation_id":"c1","status":"SUCCESS","response":"/usage is not supported","num_turns":1}"#
        let usageWithTurn = envelope.replacingOccurrences(of: #""num_turns":0"#, with: #""num_turns":1"#)
        let authError = #"{"status":"ERROR","error":"authentication failed or timed out","num_turns":0}"#
        #expect(throws: CollectionError(kind: .schemaChanged, diagnosticCode: "antigravity.agy.usage-missing")) {
            try AgyCLIUsageReader.usageData(from: run(modelReply))
        }
        #expect(throws: CollectionError(kind: .schemaChanged, diagnosticCode: "antigravity.agy.model-turn")) {
            try AgyCLIUsageReader.usageData(from: run(usageWithTurn))
        }
        #expect(throws: CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.agy.exit-2")) {
            try AgyCLIUsageReader.usageData(from: run("", status: 2))
        }
        #expect(throws: CollectionError(kind: .authenticationRejected, diagnosticCode: "antigravity.agy.sign-in-required", recoveryAction: .signInSourceApp)) {
            try AgyCLIUsageReader.usageData(from: run(authError))
        }
        #expect(throws: CollectionError(kind: .authenticationRejected, diagnosticCode: "antigravity.agy.sign-in-required", recoveryAction: .signInSourceApp)) {
            try AgyCLIUsageReader.usageData(from: run("", status: 1, stderr: "\u{1B}[1mAUTHENTICATION REQUIRED.\u{1B}[0m Please visit"))
        }
        #expect(throws: Never.self) { try AgyCLIUsageReader.usageData(from: run(envelope)) }
    }

    @Test("the sign-in stamp is the mdat attribute the security tool lists; exit 44 is no sign-in")
    func securityToolStamp() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func tool(_ body: String) throws -> URL {
            let url = directory.appendingPathComponent("security-\(UUID().uuidString)")
            try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(directory.path)/security-args'\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let listing = #"""
        cat <<'EOF'
        keychain: "/Users/u/Library/Keychains/login.keychain-db"
            "acct"<blob>="antigravity"
            "mdat"<timedate>=0x32303236313132333038353830335A00  "20261123085803Z\000"
            "svce"<blob>="gemini"
        EOF
        """#
        func stamp(_ body: String) async throws -> String? {
            try await AgyCLIUsageReader.keychainSignInStamp(securityTool: try tool(body), timeout: .seconds(2))
        }
        func keychainError(_ code: String) -> CollectionError {
            CollectionError(kind: .keychainUnavailable, diagnosticCode: code, recoveryAction: .retry)
        }

        #expect(try await stamp(listing) == "0x32303236313132333038353830335A00")
        let arguments = try String(contentsOf: directory.appendingPathComponent("security-args"), encoding: .utf8)
        #expect(arguments == "find-generic-password\n-s\ngemini\n-a\nantigravity\n", "attributes only, never -w")
        #expect(try await stamp("exit 44") == nil)
        await #expect(throws: keychainError("antigravity.agy.keychain.status-51")) { try await stamp("exit 51") }
        await #expect(throws: keychainError("antigravity.agy.keychain.attributes-invalid")) { try await stamp("echo 'keychain: x'") }
        await #expect(throws: keychainError("antigravity.agy.keychain.timeout")) { try await stamp("exec sleep 10") }
        await #expect(throws: keychainError("antigravity.agy.keychain.launch-failed")) {
            try await AgyCLIUsageReader.keychainSignInStamp(securityTool: directory.appendingPathComponent("missing"))
        }
    }

    @Test("Antigravity sends no HTTP request of its own")
    func noNetworkRoute() {
        for url in [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            "https://oauth2.googleapis.com/token",
        ] {
            let request = NetworkRequest(
                providerID: .antigravity,
                url: URL(string: url)!,
                method: .post,
                body: Data("{}".utf8),
                timeout: 15
            )
            #expect(!URLSessionNetworkClient.isAllowed(request))
        }
    }
}
