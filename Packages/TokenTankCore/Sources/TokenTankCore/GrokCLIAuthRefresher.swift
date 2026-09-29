import Darwin
import Foundation
import TokenTankDomain

public protocol GrokAuthRefreshing: Sendable {
    func refresh() async throws
}

/// Runs `grok models` once so the Grok CLI renews its own OAuth session under its own
/// `auth.json.lock`. The command lists models without a prompt or model usage. Its exit status
/// does not report refresh failures, so callers must re-read `auth.json` afterwards.
public actor GrokCLIAuthRefresher: GrokAuthRefreshing {
    static let maximumOutputBytes = 256 * 1024
    static let maximumTimeout: Duration = .seconds(30)

    private let executableCandidates: [URL]
    private let homeDirectory: URL
    private let timeout: Duration
    private let workingDirectoryParent: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(
            executableCandidates: [
                homeDirectory.appendingPathComponent(".grok/bin/grok"),
                homeDirectory.appendingPathComponent(".local/bin/grok"),
                URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
                URL(fileURLWithPath: "/usr/local/bin/grok"),
            ],
            homeDirectory: homeDirectory,
            timeout: Self.maximumTimeout
        )
    }

    init(
        executableCandidates: [URL],
        homeDirectory: URL,
        timeout: Duration,
        workingDirectoryParent: URL = FileManager.default.temporaryDirectory
    ) {
        self.executableCandidates = executableCandidates
        self.homeDirectory = homeDirectory
        self.timeout = min(max(timeout, .milliseconds(1)), Self.maximumTimeout)
        self.workingDirectoryParent = workingDirectoryParent
    }

    public func refresh() async throws {
        try Task.checkCancellation()
        guard let executable = executableCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw failure("grok.cli-refresh.executable-missing")
        }
        let directory = workingDirectoryParent
            .appendingPathComponent("TokenTank-GrokRefresh-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw failure("grok.cli-refresh.workspace-unavailable")
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["models"]
        process.currentDirectoryURL = directory
        process.environment = Self.environment(homeDirectory: homeDirectory, workingDirectory: directory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let termination = ProcessTermination()
        process.terminationHandler = { _ in
            Task { await termination.didExit() }
        }
        do {
            try process.run()
        } catch {
            throw failure("grok.cli-refresh.launch-failed")
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let timeout = timeout
        let reader = Task.detached(priority: .utility) {
            try Self.drain(fileDescriptor: descriptor, timeout: timeout)
        }
        let result: Result<Void, Error>
        do {
            try await withTaskCancellationHandler {
                try await reader.value
            } onCancel: {
                reader.cancel()
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await termination.stop(process)
        output.fileHandleForReading.closeFile()
        switch result {
        case .success:
            return
        case let .failure(error as CollectionError):
            throw error
        case let .failure(error) where error is CancellationError:
            throw CancellationError()
        case .failure:
            throw failure("grok.cli-refresh.read-failed")
        }
    }

    static func environment(homeDirectory: URL, workingDirectory: URL) -> [String: String] {
        let username = NSUserName()
        // No GROK_* overrides: the CLI must use its default home, issuer, and client.
        return [
            "HOME": homeDirectory.path,
            "USER": username,
            "LOGNAME": username,
            "PATH": "\(homeDirectory.path)/.grok/bin:\(homeDirectory.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": workingDirectory.path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "TERM": "dumb",
            "NO_COLOR": "1",
            "LANG": "en_US.UTF-8",
        ]
    }

    /// Reads and discards output until EOF, enforcing the output cap and the deadline.
    private nonisolated static func drain(fileDescriptor: Int32, timeout: Duration) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var total = 0
        var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw CollectionError(
                    kind: .sourceUnavailable,
                    diagnosticCode: "grok.cli-refresh.timeout",
                    recoveryAction: .runSourceCLI
                )
            }
            let milliseconds = max(1, min(100, Int(remaining.components.seconds * 1_000
                + remaining.components.attoseconds / 1_000_000_000_000_000)))
            pollDescriptor.revents = 0
            let ready = Darwin.poll(&pollDescriptor, 1, Int32(milliseconds))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.cli-refresh.read-failed")
            }
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.cli-refresh.read-failed")
            }
            total += count
            guard total <= maximumOutputBytes else {
                throw CollectionError(kind: .malformedResponse, diagnosticCode: "grok.cli-refresh.output-size-limit")
            }
        }
    }

    private nonisolated func failure(_ code: String) -> CollectionError {
        CollectionError(kind: .sourceUnavailable, diagnosticCode: code, recoveryAction: .runSourceCLI)
    }
}
