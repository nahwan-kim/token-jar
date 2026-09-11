import Darwin
import Foundation
import Testing
@testable import TokenTankCore
import TokenTankDomain

@Suite("Claude CLI OAuth refresher", .serialized)
struct ClaudeCLIAuthRefresherTests {
    @Test("uses fixed safe arguments, environment, working directory, and only sends status then exit")
    func fixedInvocation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("success", body: """
        printf '%s\n' "$@" > "$PWD/arguments"
        env > "$PWD/environment"
        pwd > "$PWD/directory"
        printf 'Welcome to Claude Code\n'
        IFS= read -r command
        printf '%s\n' "$command" > "$PWD/input"
        printf 'Claude Code Status\n'
        IFS= read -r command
        printf '%s\n' "$command" >> "$PWD/input"
        """)
        let refresher = fixture.refresher(executable: executable)

        try await refresher.refresh()

        let input = try fixture.text("input")
        #expect(input.contains("/status"))
        #expect(input.contains("/exit"))
        #expect(!input.contains("prompt"))
        #expect(try fixture.lines("arguments") == [
            "--safe-mode", "--tools", "", "--allowed-tools", "", "--setting-sources", "",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        ])
        let environment = try fixture.text("environment")
        #expect(environment.contains("CLAUDE_CODE_SAFE_MODE=1"))
        #expect(environment.contains("DISABLE_AUTOUPDATER=1"))
        #expect(!environment.contains("ANTHROPIC_API_KEY"))
        let lines = environment.split(separator: "\n").map(String.init)
        let username = NSUserName()
        let ownerIdentityMatches = !username.isEmpty
            && lines.contains("USER=\(username)") && lines.contains("LOGNAME=\(username)")
        #expect(ownerIdentityMatches)
        #expect(try fixture.text("directory").trimmingCharacters(in: .whitespacesAndNewlines) == fixture.workspace.path)
    }

    @Test("acknowledges only the exact trust prompt for its empty workspace")
    func trustPromptAllowlist() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("trust", body: """
        printf 'Do you trust the files in this folder?\n'
        IFS= read -r trust
        printf '%s\n' "$trust" > "$PWD/trust-input"
        printf 'Welcome to Claude Code\n'
        IFS= read -r status
        printf '%s\n' "$status" >> "$PWD/trust-input"
        printf 'Claude Code Status\n'
        IFS= read -r exit_command
        """)

        try await fixture.refresher(executable: executable).refresh()

        let lines = try fixture.lines("trust-input")
        #expect(lines.first == "")
        #expect(lines.dropFirst().contains("/status"))
    }

    @Test("current Claude ANSI cursor layout preserves exact trust, ready, and status markers")
    func ansiWorkspaceTrustAndStatus() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("ansi-status", body: """
        printf '\\033[1mIs\\033[1Cthis\\033[1Ca\\033[1Cproject\\033[1Cyou\\033[1Ccreated\\033[1Cor\\033[1Cone\\033[1Cyou\\033[1Ctrust?\\033[0m\\n'
        IFS= read -r trust
        printf '%s\\n' "$trust" > "$PWD/ansi-input"
        printf 'Directory name: temporary\\n'
        printf '\\033[38;2;200;200;200mClaude\\033[1CCode\\033[1Cv2.1.234\\033[0m\\n'
        IFS= read -r status
        printf '%s\\n' "$status" >> "$PWD/ansi-input"
        printf '\\033[1mLogin\\033[1Cmethod:\\033[0m\\n'
        IFS= read -r exit_command
        """)
        try await fixture.refresher(executable: executable).refresh()
        #expect(try fixture.lines("ansi-input") == ["", "/status"])
    }

    @Test("does not answer an unrecognized prompt")
    func unexpectedPromptFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The marker is written before the prompt so a slow shell start cannot lose it, and it is
        // overwritten only if the refresher answers the prompt with anything at all.
        let executable = try fixture.script("prompt", body: """
        printf 'untouched\n' > "$PWD/marker"
        printf 'Approve arbitrary operation?\n'
        if IFS= read -r answer; then
          printf 'answered\n' > "$PWD/marker"
        fi
        sleep 5
        """)
        let refresher = fixture.refresher(executable: executable, timeout: .seconds(2))

        let error = await collectionError { try await refresher.refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.interaction-rejected.approve")
        #expect(try fixture.lines("marker") == ["untouched"])
    }

    @Test("pre-cancelled refresh creates no workspace and launches no process")
    func preCancelledRefreshHasNoSideEffects() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("must-not-launch", body: """
        touch "$HOME/launched"
        """)
        let absentWorkspace = fixture.root.appendingPathComponent("absent-probe", isDirectory: true)
        let refresher = ClaudeCLIAuthRefresher(
            executableCandidates: [executable],
            workingDirectory: absentWorkspace,
            timeout: .seconds(1),
            homeDirectory: fixture.home
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await refresher.refresh()
        }
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(!FileManager.default.fileExists(atPath: absentWorkspace.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("launched").path))
    }

    @Test("timeout terminates the CLI")
    func timeoutCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("timeout", body: """
        printf '%s\\n' $$ > "$PWD/pid"
        printf 'Welcome to Claude Code\n'
        sleep 30
        """)
        let refresher = fixture.refresher(executable: executable, timeout: .seconds(1))

        let error = await collectionError { try await refresher.refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.timeout")
        try await assertProcessExited(pidAt: fixture.workspace.appendingPathComponent("pid"))
    }

    @Test("timeout terminates descendants even when the root exits during cleanup")
    func descendantCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("descendant", body: """
        sleep 30 &
        printf '%s\n' "$!" > "$PWD/child-pid"
        printf 'Welcome to Claude Code\n'
        sleep 30
        """)
        let refresher = fixture.refresher(executable: executable, timeout: .seconds(1))

        let error = await collectionError { try await refresher.refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.timeout")
        try await assertProcessExited(pidAt: fixture.workspace.appendingPathComponent("child-pid"))
    }

    @Test("early process exit is not treated as refreshed and is reaped")
    func earlyExitCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("early-exit", body: """
        printf '%s\\n' $$ > "$PWD/pid"
        printf 'Welcome to Claude Code\n'
        exit 0
        """)

        let error = await collectionError { try await fixture.refresher(executable: executable).refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.process-exited")
        try await assertProcessExited(pidAt: fixture.workspace.appendingPathComponent("pid"))
    }

    @Test("repeated fast exits are classified as process exit whether they race the status write or not")
    func repeatedFastExitClassification() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Exits right after the banner: the child may tear down its PTY between the refresher
        // reading the banner and writing `/status`, which must still surface as a process exit.
        let exitAfterBanner = try fixture.script("exit-after-banner", body: """
        printf '%s\\n' $$ > "$PWD/pid"
        printf 'Welcome to Claude Code\n'
        exit 0
        """)
        // Exits right after consuming `/status`: the write succeeds and the exit is seen by polling.
        let exitAfterStatus = try fixture.script("exit-after-status", body: """
        printf '%s\\n' $$ > "$PWD/pid"
        printf 'Welcome to Claude Code\n'
        IFS= read -r command
        exit 0
        """)
        let pidFile = fixture.workspace.appendingPathComponent("pid")

        for iteration in 0..<30 {
            try? FileManager.default.removeItem(at: pidFile)
            let executable = iteration.isMultiple(of: 2) ? exitAfterBanner : exitAfterStatus
            let refresher = fixture.refresher(executable: executable, timeout: .seconds(2))

            let error = await collectionError { try await refresher.refresh() }

            #expect(error?.diagnosticCode == "claude.auth-refresh.process-exited", "iteration \(iteration)")
            try await assertProcessExited(pidAt: pidFile)
        }
    }

    @Test("task cancellation terminates the CLI and preserves cancellation")
    func cancellationCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("cancel", body: """
        printf '%s\\n' $$ > "$PWD/pid"
        printf 'Welcome to Claude Code\n'
        sleep 30
        """)
        let refresher = fixture.refresher(executable: executable, timeout: .seconds(5))
        let task = Task { try await refresher.refresh() }
        try await waitForFile(fixture.workspace.appendingPathComponent("pid"))

        task.cancel()
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected sanitized error: \(error)")
        }
        try await assertProcessExited(pidAt: fixture.workspace.appendingPathComponent("pid"))
    }

    @Test("rejects oversized PTY output without including it in the error")
    func oversizedOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("oversized", body: """
        exec /usr/bin/yes 'SECRET-RAW-TUI-OUTPUT-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
        """)

        let error = await collectionError { try await fixture.refresher(executable: executable).refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.output-size-limit")
        #expect(!String(describing: error).contains("SECRET-RAW-TUI-OUTPUT"))
    }

    @Test("missing executable fails without searching PATH")
    func missingExecutable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("not-claude")

        let error = await collectionError { try await fixture.refresher(executable: missing).refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.executable-missing")
    }
}

private struct Fixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCLIAuthRefresherTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func script(_ name: String, body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func refresher(executable: URL, timeout: Duration = .seconds(2)) -> ClaudeCLIAuthRefresher {
        ClaudeCLIAuthRefresher(
            executableCandidates: [executable],
            workingDirectory: workspace,
            timeout: timeout,
            homeDirectory: home
        )
    }

    func text(_ name: String) throws -> String {
        try String(contentsOf: workspace.appendingPathComponent(name), encoding: .utf8)
    }

    func lines(_ name: String) throws -> [String] {
        try text(name).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func collectionError(
    _ operation: () async throws -> Void
) async -> CollectionError? {
    do {
        try await operation()
        Issue.record("Expected CollectionError")
        return nil
    } catch let error as CollectionError {
        return error
    } catch {
        Issue.record("Unexpected sanitized error: \(error)")
        return nil
    }
}

private func waitForFile(_ url: URL) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: url.path))
}

private func assertProcessExited(pidAt url: URL) async throws {
    try await waitForFile(url)
    let raw = try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(pid_t(raw))
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while Darwin.kill(pid, 0) == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
}
