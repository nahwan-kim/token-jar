import Darwin
import Foundation
import TokenTankDomain

public protocol ClaudeAuthRefreshing: Sendable {
    func refresh() async throws
}

/// Gives Claude Code one bounded opportunity to repair its own OAuth credentials.
/// A return only means `/status` completed; callers must reload and validate credentials.
public actor ClaudeCLIAuthRefresher: ClaudeAuthRefreshing {
    private static let maximumOutputBytes = 256 * 1024
    private static let maximumTimeout: Duration = .seconds(15)
    /// A PTY write fails with EIO once the child closes its side, which happens during exit slightly
    /// before the kernel publishes the exit status. This bounds how long a failed write waits for
    /// that status before it is reported as an I/O failure rather than a process exit.
    private static let exitGracePeriod: Duration = .milliseconds(250)
    private static let arguments = [
        "--safe-mode",
        "--tools", "",
        "--allowed-tools", "",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--mcp-config", #"{"mcpServers":{}}"#,
    ]
    private static let trustPrompts = [
        "Do you trust the files in this folder?",
        "Is this a project you created or one you trust?",
    ]
    private static let readyMarkers = ["Welcome to Claude Code", "Claude Code v", "Tips for getting started"]
    private static let statusMarkers = ["Claude Code Status", "Login method:", "Account:"]
    private static let rejectedPromptMarkers = [
        "log in", "login", "sign in", "permission", "approve", "allow access", "yes/no", "y/n",
    ]

    private let executableCandidates: [URL]
    private let workingDirectory: URL?
    private let timeout: Duration
    private let homeDirectory: URL
    private let fileManager: FileManager

    private var childPID: pid_t?
    private var processGroup: pid_t?
    private var primaryHandle: FileHandle?
    private var secondaryHandle: FileHandle?

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.executableCandidates = [
            homeDirectory.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        self.workingDirectory = nil
        self.timeout = Self.maximumTimeout
        self.homeDirectory = homeDirectory
        self.fileManager = .default
    }

    init(
        executableCandidates: [URL],
        workingDirectory: URL,
        timeout: Duration,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.executableCandidates = executableCandidates
        self.workingDirectory = workingDirectory
        self.timeout = min(max(timeout, .milliseconds(1)), Self.maximumTimeout)
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    public func refresh() async throws {
        try Task.checkCancellation()
        guard let executable = executableCandidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw failure(.sourceUnavailable, "claude.auth-refresh.executable-missing")
        }
        try Task.checkCancellation()

        let ownsDirectory = workingDirectory == nil
        let directory = workingDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("TokenTank-ClaudeAuthProbe-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw failure(.sourceUnavailable, "claude.auth-refresh.workspace-unavailable")
        }
        defer {
            if ownsDirectory { try? fileManager.removeItem(at: directory) }
        }

        do {
            try Task.checkCancellation()
            try await run(executable: executable, directory: directory)
        } catch is CancellationError {
            await cleanup()
            throw CancellationError()
        } catch let error as CollectionError {
            await cleanup()
            throw error
        } catch {
            await cleanup()
            throw failure(.sourceUnavailable, "claude.auth-refresh.failed")
        }
        await cleanup()
    }

    private func run(executable: URL, directory: URL) async throws {
        let workspaceWasEmpty = try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty
        let descriptors = try Self.openPTY()
        let primaryHandle = FileHandle(fileDescriptor: descriptors.primary, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: descriptors.secondary, closeOnDealloc: true)
        self.primaryHandle = primaryHandle
        self.secondaryHandle = secondaryHandle

        let environment = Self.safeEnvironment(homeDirectory: homeDirectory, workingDirectory: directory)
        let pid: pid_t
        do {
            pid = try Self.spawn(
                executable: executable,
                arguments: Self.arguments,
                environment: environment,
                workingDirectory: directory,
                primaryFD: descriptors.primary,
                secondaryFD: descriptors.secondary
            )
        } catch {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            self.primaryHandle = nil
            self.secondaryHandle = nil
            throw failure(.sourceUnavailable, "claude.auth-refresh.launch-failed")
        }
        childPID = pid
        processGroup = pid
        try? secondaryHandle.close()
        self.secondaryHandle = nil

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var outputCount = 0
        var scanTail = ""
        var statusSent = false
        var trustAcknowledged = false
        var statusObserved = false

        while clock.now < deadline {
            try Task.checkCancellation()
            guard Self.childIsRunning(pid) else {
                throw failure(.sourceUnavailable, "claude.auth-refresh.process-exited")
            }
            let chunk = try readAvailable(
                from: descriptors.primary,
                maximumBytes: Self.maximumOutputBytes - outputCount
            )
            if !chunk.isEmpty {
                outputCount += chunk.count
                Self.appendSanitizedScanText(chunk, to: &scanTail)

                let normalized = Self.normalized(scanTail)
                if statusSent, Self.statusMarkers.map(Self.normalized).contains(where: normalized.contains) {
                    statusObserved = true
                }
                if Self.trustPrompts.map(Self.normalized).contains(where: normalized.contains),
                   !trustAcknowledged {
                    guard workspaceWasEmpty else {
                        throw failure(.sourceUnavailable, "claude.auth-refresh.interaction-rejected")
                    }
                    try await send(Data("\r".utf8), to: descriptors.primary, pid: pid)
                    trustAcknowledged = true
                    scanTail.removeAll(keepingCapacity: true)
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                }
                let plain = Self.plainText(scanTail).lowercased()
                if !statusSent, let marker = Self.rejectedPromptMarkers.first(where: plain.contains) {
                    // Only a fixed allowlisted marker enters diagnostics, never TUI text.
                    throw failure(
                        .sourceUnavailable,
                        "claude.auth-refresh.interaction-rejected.\(Self.normalized(marker))"
                    )
                }
                if !statusSent, Self.readyMarkers.map(Self.normalized).contains(where: normalized.contains) {
                    try await send(Data("/status\r".utf8), to: descriptors.primary, pid: pid)
                    statusSent = true
                    scanTail.removeAll(keepingCapacity: true)
                }
            }

            if statusObserved {
                try? Self.writeFully(Data("\u{1b}/exit\r".utf8), to: descriptors.primary)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw failure(.sourceUnavailable, "claude.auth-refresh.timeout")
    }

    private static func openPTY() throws -> (primary: Int32, secondary: Int32) {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        var window = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &window) == 0 else {
            throw POSIXError(.ENXIO)
        }
        guard fcntl(primary, F_SETFL, O_NONBLOCK) != -1 else {
            Darwin.close(primary)
            Darwin.close(secondary)
            throw POSIXError(.EIO)
        }
        return (primary, secondary)
    }

    private nonisolated static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        primaryFD: Int32,
        secondaryFD: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, secondaryFD, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, secondaryFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, secondaryFD, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, primaryFD) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path) == 0
        else { throw POSIXError(.EIO) }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else { throw POSIXError(.EIO) }

        let argv = CStringVector([executable.path] + arguments)
        let envp = CStringVector(environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" })
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv.pointer, envp.pointer)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }

    private func readAvailable(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        while true {
            var buffer = [UInt8](repeating: 0, count: min(8 * 1024, maximumBytes - result.count + 1))
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                guard result.count <= maximumBytes else {
                    throw failure(.malformedResponse, "claude.auth-refresh.output-size-limit")
                }
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return result }
            if errno == EINTR { continue }
            if errno == EIO { return result }
            throw failure(.sourceUnavailable, "claude.auth-refresh.io-failed")
        }
    }

    /// Writes to the PTY and classifies a failure by the child's state: a write that failed because
    /// the child tore down its PTY on exit is a process exit, not an I/O failure.
    private func send(_ data: Data, to descriptor: Int32, pid: pid_t) async throws {
        do {
            try Self.writeFully(data, to: descriptor)
        } catch {
            if try await Self.childExited(pid, within: Self.exitGracePeriod) {
                throw failure(.sourceUnavailable, "claude.auth-refresh.process-exited")
            }
            throw failure(.sourceUnavailable, "claude.auth-refresh.io-failed")
        }
    }

    private nonisolated static func writeFully(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw POSIXError(.EIO) }
            }
        }
    }

    /// Polls for the child's exit status for at most `gracePeriod`; reaps it when it has exited.
    private nonisolated static func childExited(_ pid: pid_t, within gracePeriod: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while childIsRunning(pid) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func cleanup() async {

        let pid = childPID
        let group = processGroup
        childPID = nil
        processGroup = nil
        let primary = primaryHandle
        let secondary = secondaryHandle
        primaryHandle = nil
        secondaryHandle = nil

        if let primary { try? primary.close() }
        if let secondary { try? secondary.close() }
        guard let pid else { return }

        if let group { _ = Darwin.kill(-group, SIGTERM) }
        let termDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while Self.childIsRunning(pid), ContinuousClock.now < termDeadline {
            Self.pauseForCleanup()
        }
        if let group { _ = Darwin.kill(-group, SIGKILL) }
        else { _ = Darwin.kill(pid, SIGKILL) }

        let reapDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while Self.childIsRunning(pid), ContinuousClock.now < reapDeadline {
            Self.pauseForCleanup()
        }
    }

    private nonisolated static func childIsRunning(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == 0
    }

    private nonisolated static func pauseForCleanup() {
        _ = Darwin.poll(nil, 0, 10)
    }

    private nonisolated static func appendSanitizedScanText(_ data: Data, to text: inout String) {
        text.append(String(decoding: data, as: UTF8.self))
        if text.utf8.count > 8 * 1024 { text = String(text.suffix(8 * 1024)) }
    }

    private nonisolated static func normalized(_ text: String) -> String {
        String(plainText(text).lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private nonisolated static func plainText(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression
        )
    }

    private nonisolated static func safeEnvironment(
        homeDirectory: URL,
        workingDirectory: URL
    ) -> [String: String] {
        let temporary = FileManager.default.temporaryDirectory.path
        let username = NSUserName()
        return [
            "HOME": homeDirectory.path,
            // Claude's native Keychain account lookup depends on USER. Keep it
            // aligned with the OS account rather than inheriting arbitrary env.
            "USER": username,
            "LOGNAME": username,
            "PATH": "\(homeDirectory.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": workingDirectory.path,
            "TMPDIR": temporary,
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_SAFE_MODE": "1",
        ]
    }

    private nonisolated func failure(_ kind: CollectionErrorKind, _ code: String) -> CollectionError {
        CollectionError(kind: kind, diagnosticCode: code, recoveryAction: .signInSourceApp)
    }
}

private final class CStringVector: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { pointer[index] = strdup(string) }
        pointer[strings.count] = nil
    }

    deinit {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}
