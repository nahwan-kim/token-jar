import Darwin
import Foundation
import TokenTankDomain

/// Runs the official Antigravity CLI's read-only `/usage` command, which answers from the CLI's own
/// Keychain sign-in without a model turn. The CLI renews its own token; Token Jar never reads the
/// token, only the sign-in item's attributes.
///
/// Without a usable sign-in `agy` starts a browser sign-in instead, so the reader launches it only
/// while that Keychain item exists, and after `agy` asked for a sign-in it waits until the item
/// changes (the user signed in again) rather than reopening the sign-in on every refresh.
public actor AgyCLIUsageReader: AntigravityUsageReader {
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    static let maximumTimeout: Duration = .seconds(30)
    static let securityTool = URL(fileURLWithPath: "/usr/bin/security")
    /// `security` exits with `errSecItemNotFound` truncated to its low byte.
    private static let itemNotFoundExitStatus: Int32 = 44

    private let executableCandidates: [URL]
    private let homeDirectory: URL
    private let timeout: Duration
    private let workingDirectoryParent: URL
    private let screenIsUnlocked: @Sendable () -> Bool
    private let signInStamp: @Sendable () async throws -> String?
    /// The sign-in item's modification stamp when `agy` last asked for a new sign-in.
    private var rejectedSignIn: String?

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(
            executableCandidates: [
                homeDirectory.appendingPathComponent(".local/bin/agy"),
                URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
                URL(fileURLWithPath: "/usr/local/bin/agy"),
            ],
            homeDirectory: homeDirectory,
            timeout: Self.maximumTimeout,
            screenIsUnlocked: consoleSessionIsUnlocked,
            signInStamp: { try await Self.keychainSignInStamp() }
        )
    }

    init(
        executableCandidates: [URL],
        homeDirectory: URL,
        timeout: Duration,
        workingDirectoryParent: URL = FileManager.default.temporaryDirectory,
        screenIsUnlocked: @escaping @Sendable () -> Bool,
        signInStamp: @escaping @Sendable () async throws -> String?
    ) {
        self.executableCandidates = executableCandidates
        self.homeDirectory = homeDirectory
        self.timeout = min(max(timeout, .milliseconds(1)), Self.maximumTimeout)
        self.workingDirectoryParent = workingDirectoryParent
        self.screenIsUnlocked = screenIsUnlocked
        self.signInStamp = signInStamp
    }

    public func readUsage() async throws -> Data {
        try Task.checkCancellation()
        guard screenIsUnlocked() else { throw Self.screenLocked }
        guard let signIn = try await signInStamp() else { throw Self.signInMissing }
        guard signIn != rejectedSignIn else { throw Self.signInRequired }
        // agy reads the Keychain itself, so a console that locked during the lookup also skips it.
        guard screenIsUnlocked() else { throw Self.screenLocked }
        try Task.checkCancellation()
        guard let executable = executableCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.agy.executable-missing")
        }
        let run = try await runAgy(executable)
        do {
            return try Self.usageData(from: run)
        } catch let error as CollectionError where error == Self.signInRequired {
            // agy may rewrite its item while failing; remember the stamp it left behind, unless the
            // console locked meanwhile (no Keychain lookups then). A failed lookup keeps the pre-run
            // stamp; cancellation still ends the refresh as cancelled.
            var after: String?
            if screenIsUnlocked() {
                do {
                    after = try await signInStamp()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    after = nil
                }
            }
            rejectedSignIn = after ?? signIn
            throw error
        }
    }

    /// `command.data` of a successful `/usage` envelope that took no model turn. A sign-in prompt
    /// on stderr or an authentication error in the envelope means the CLI's sign-in no longer works.
    static func usageData(from run: BoundedRun) throws -> Data {
        let root = try? JSONSerialization.jsonObject(with: run.stdout) as? [String: Any]
        if String(decoding: run.stderr, as: UTF8.self).lowercased().contains("authentication required")
            || (root?["error"] as? String)?.localizedCaseInsensitiveContains("authentication") == true {
            throw signInRequired
        }
        if let failure = run.failure { throw failure }
        guard run.status == 0 else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.agy.exit-\(run.status)")
        }
        guard let root else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "antigravity.agy.invalid-json")
        }
        guard root["status"] as? String == "SUCCESS" else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.agy.command-failed")
        }
        guard let command = root["command"] as? [String: Any],
              command["name"] as? String == "usage",
              let data = command["data"] as? [String: Any]
        else {
            throw CollectionError(kind: .schemaChanged, diagnosticCode: "antigravity.agy.usage-missing")
        }
        guard root["num_turns"] as? Int == 0 else {
            throw CollectionError(kind: .schemaChanged, diagnosticCode: "antigravity.agy.model-turn")
        }
        return try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
    }

    /// The log goes to `/dev/null` so the CLI writes no file Token Jar has to bound.
    static let arguments = ["--output-format", "json", "--log-file", "/dev/null", "-p", "/usage"]

    static func environment(homeDirectory: URL, workingDirectory: URL) -> [String: String] {
        let username = NSUserName()
        // No GEMINI_API_KEY or other overrides: agy must answer from its own Keychain sign-in.
        return [
            "HOME": homeDirectory.path,
            "USER": username,
            "LOGNAME": username,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": workingDirectory.path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "TERM": "dumb",
            "NO_COLOR": "1",
            "LANG": "en_US.UTF-8",
        ]
    }

    /// The modification stamp of agy's sign-in item, or `nil` when the CLI is not signed in.
    /// `/usr/bin/security` without `-w` prints only attributes, so no Keychain dialog can appear,
    /// and a stalled lookup is terminated at the deadline instead of blocking collection.
    static func keychainSignInStamp(securityTool: URL = securityTool, timeout: Duration = .seconds(5)) async throws -> String? {
        let process = Process()
        process.executableURL = securityTool
        process.arguments = ["find-generic-password", "-s", keychainService, "-a", keychainAccount]
        let run: BoundedRun
        do {
            run = try await runBounded(process, timeout: timeout, diagnosticPrefix: "antigravity.agy.keychain")
        } catch let error as CollectionError {
            throw keychainError(error.diagnosticCode)
        }
        if let failure = run.failure { throw keychainError(failure.diagnosticCode) }
        switch run.status {
        case 0:
            guard let stamp = signInStamp(fromSecurityOutput: run.stdout) else {
                throw keychainError("antigravity.agy.keychain.attributes-invalid")
            }
            return stamp
        case itemNotFoundExitStatus:
            return nil
        case let status:
            throw keychainError("antigravity.agy.keychain.status-\(status)")
        }
    }

    /// The raw `mdat` attribute (`"mdat"<timedate>=0x3230…5A00`) of a `security` attribute listing.
    static func signInStamp(fromSecurityOutput output: Data) -> String? {
        let text = String(decoding: output, as: UTF8.self)
        guard let range = text.range(of: #""mdat"<timedate>=0x[0-9A-Fa-f]+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range].split(separator: "=").last ?? "")
    }

    private func runAgy(_ executable: URL) async throws -> BoundedRun {
        // mkdtemp creates a new owner-only (0700) directory atomically and fails rather than reuse a path.
        var template = Array(
            workingDirectoryParent.appendingPathComponent("TokenTank-Agy-XXXXXXXX").path.utf8CString
        )
        guard let created = mkdtemp(&template) else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.agy.workspace-unavailable")
        }
        let directory = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments
        process.currentDirectoryURL = directory
        process.environment = Self.environment(homeDirectory: homeDirectory, workingDirectory: directory)
        return try await Self.runBounded(process, timeout: timeout, diagnosticPrefix: "antigravity.agy")
    }

    private static func keychainError(_ code: String) -> CollectionError {
        CollectionError(kind: .keychainUnavailable, diagnosticCode: code, recoveryAction: .retry)
    }

    private static let screenLocked = keychainError("antigravity.agy.screen-locked")

    private static let signInMissing = CollectionError(
        kind: .externalSessionMissing,
        diagnosticCode: "antigravity.agy.sign-in-missing",
        recoveryAction: .signInSourceApp
    )

    private static let signInRequired = CollectionError(
        kind: .authenticationRejected,
        diagnosticCode: "antigravity.agy.sign-in-required",
        recoveryAction: .signInSourceApp
    )
}

/// One finished child: stdout and stderr as far as they were read (each within 4 MiB), and why the
/// run did not end cleanly at EOF before the deadline (read failure, timeout, size cap), if it did not.
struct BoundedRun: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
    let failure: CollectionError?
}

extension AgyCLIUsageReader {
    /// Runs `process` with closed stdin, draining stdout and stderr concurrently under one deadline,
    /// then terminates it (also on cancellation) before returning.
    static func runBounded(_ process: Process, timeout: Duration, diagnosticPrefix: String) async throws -> BoundedRun {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let termination = ProcessTermination()
        process.terminationHandler = { _ in
            Task { await termination.didExit() }
        }
        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "\(diagnosticPrefix).launch-failed")
        }

        func reader(_ pipe: Pipe) -> Task<BoundedOutput, Error> {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            return Task.detached(priority: .utility) {
                try readBoundedProcessOutputPrefix(
                    fileDescriptor: descriptor,
                    deadline: deadline,
                    diagnosticPrefix: diagnosticPrefix
                )
            }
        }
        let stdoutReader = reader(output)
        let stderrReader = reader(errors)
        /// The bytes and the failure (if any) of one reader, or nil when it was cancelled.
        func collect(_ task: Task<BoundedOutput, Error>) async -> (data: Data, failure: CollectionError?)? {
            do {
                let read = try await task.value
                return (read.data, read.cutShort)
            } catch let error as CollectionError {
                return (Data(), error)
            } catch {
                return nil
            }
        }
        let results = await withTaskCancellationHandler {
            let stdout = await collect(stdoutReader)
            // A stdout failure (size cap, deadline) ends the run; stopping the child closes stderr too.
            if stdout?.failure != nil { await termination.stop(process) }
            return (stdout, await collect(stderrReader))
        } onCancel: {
            stdoutReader.cancel()
            stderrReader.cancel()
        }
        await termination.stop(process)
        output.fileHandleForReading.closeFile()
        errors.fileHandleForReading.closeFile()
        guard let stdout = results.0, let stderr = results.1 else { throw CancellationError() }
        return BoundedRun(
            stdout: stdout.data,
            stderr: stderr.data,
            status: process.terminationReason == .exit ? process.terminationStatus : -1,
            failure: stdout.failure ?? stderr.failure
        )
    }
}
