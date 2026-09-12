import Darwin
import Foundation
import Testing
@testable import TokenTankCore
import TokenTankDomain

@Suite("Claude CLI OAuth refresher", .serialized)
struct ClaudeCLIAuthRefresherTests {
    @Test("uses fixed safe arguments, environment, working directory, and only sends usage then exit")
    func fixedInvocation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("success", body: """
        printf '%s\n' "$@" > "$PWD/arguments"
        env > "$PWD/environment"
        pwd > "$PWD/directory"
        printf 'Welcome to Claude Code\n'
        printf 'shift+tab to cycle modes\\n'
        IFS= read -r command
        printf '%s\n' "$command" > "$PWD/input"
        printf 'Currentsession12%%used\\nCurrentweek34%%left\\nEsctocancel\\n'
        sleep 0.1
        IFS= read -r command
        printf '%s\n' "$command" >> "$PWD/input"
        """)
        let refresher = fixture.refresher(executable: executable)

        try await refresher.refresh()

        let input = try fixture.text("input")
        #expect(input.contains("/usage"))
        #expect(input.contains("/exit"))
        #expect(try fixture.lines("input").count == 2)
        #expect(!input.contains("prompt"))
        #expect(try fixture.lines("arguments") == [
            "--safe-mode", "--tools", "", "--allowed-tools", "", "--setting-sources", "",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        ])
        let environment = try fixture.text("environment")
        #expect(environment.contains("CLAUDE_CODE_SAFE_MODE=1"))
        #expect(environment.contains("DISABLE_AUTOUPDATER=1"))
        #expect(environment.contains("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"))
        #expect(!environment.contains("ANTHROPIC_API_KEY"))
        let lines = environment.split(separator: "\n").map(String.init)
        let username = NSUserName()
        let ownerIdentityMatches = !username.isEmpty
            && lines.contains("USER=\(username)") && lines.contains("LOGNAME=\(username)")
        #expect(ownerIdentityMatches)
        #expect(try fixture.text("directory").trimmingCharacters(in: .whitespacesAndNewlines) == fixture.workspace.path)
    }

    @Test("waits for complete trust and input screens before sending any command")
    func streamedTerminalReadiness() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("streamed-readiness", body: """
        printf 'Permission check before workspace prompt\\n'
        sleep 0.05
        printf 'Is this a project you created or one you trust?\\n'
        if IFS= read -r -t 1 early; then
          printf 'premature-trust\\n' > "$PWD/readiness"
          exit 1
        fi
        printf 'Enter to confirm\\n'
        printf 'waiting-trust\\n' > "$PWD/readiness"
        IFS= read -r trust
        printf '%s\\n' "$trust" > "$PWD/readiness-input"
        printf 'Claude Code v2.1.234\\n'
        if IFS= read -r -t 1 early; then
          printf 'premature-usage\\n' > "$PWD/readiness"
          exit 1
        fi
        printf 'shift+tab to cycle modes\\n'
        printf 'waiting-usage\\n' > "$PWD/readiness"
        IFS= read -r usage
        printf '%s\\n' "$usage" >> "$PWD/readiness-input"
        printf 'Usage\\nLoading...\\n'
        if IFS= read -r -t 1 early_exit; then
          printf 'premature-completion\\n' > "$PWD/readiness"
          exit 1
        fi
        printf 'Current session 1%% used\\nCurrent week 99%% left\\nEsc to go back\\n'
        printf 'waiting-exit\\n' > "$PWD/readiness"
        IFS= read -r exit_command
        printf '%s\\n' "$exit_command" >> "$PWD/readiness-input"
        printf 'complete\\n' > "$PWD/readiness"
        """)

        do {
            try await fixture.refresher(executable: executable, timeout: .seconds(6)).refresh()
        } catch {
            #expect(try fixture.lines("readiness") == ["complete"])
            throw error
        }

        let input = try fixture.lines("readiness-input")
        #expect(input.first == "")
        #expect(input.dropFirst().first == "/usage")
        #expect(input.last?.contains("/exit") == true)
        #expect(try fixture.lines("readiness") == ["complete"])
    }

    @Test("bounds graceful exit when the owner ignores exit and termination")
    func unresponsiveGracefulExitIsBounded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("ignores-exit", body: """
        trap '' HUP TERM
        printf '%s\\n' "$$" > "$PWD/owner-pid"
        printf 'Welcome to Claude Code\\n'
        printf 'shift+tab to cycle modes\\n'
        IFS= read -r usage
        printf 'Current session 0%% used\\nCurrent week 100%% left\\nEsc to go back\\n'
        while :; do sleep 1; done
        """)
        let start = ContinuousClock.now

        try await fixture.refresher(executable: executable).refresh()

        #expect(start.duration(to: .now) < .seconds(8))
        try await assertProcessExited(pidAt: fixture.workspace.appendingPathComponent("owner-pid"))
    }

    @Test("acknowledges only the exact trust prompt for its empty workspace")
    func trustPromptAllowlist() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("trust", body: """
        printf 'Do you trust the files in this folder?\n'
        printf 'Enter to confirm\\n'
        IFS= read -r trust
        printf '%s\n' "$trust" > "$PWD/trust-input"
        printf 'Welcome to Claude Code\n'
        printf 'shift+tab to cycle modes\\n'
        IFS= read -r usage
        printf '%s\n' "$usage" >> "$PWD/trust-input"
        printf 'Current session 10%% used\nCurrent week 90%% left\nEsc to go back\n'
        IFS= read -r exit_command
        """)

        try await fixture.refresher(executable: executable).refresh()

        let lines = try fixture.lines("trust-input")
        #expect(lines.first == "")
        #expect(lines.dropFirst().contains("/usage"))
    }

    @Test("current Claude ANSI cursor layout preserves exact trust, ready, and usage markers")
    func ansiWorkspaceTrustAndUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("ansi-status", body: """
        printf '\\033[1mIs\\033[1Cthis\\033[1Ca\\033[1Cproject\\033[1Cyou\\033[1Ccreated\\033[1Cor\\033[1Cone\\033[1Cyou\\033[1Ctrust?\\033[0m\\n'
        printf '\\033[1mEnter\\033[1Cto\\033[1Cconfirm\\033[0m\\n'
        IFS= read -r trust
        printf '%s\\n' "$trust" > "$PWD/ansi-input"
        printf 'Directory name: temporary\\n'
        printf '\\033[38;2;200;200;200mClaude\\033[1CCode\\033[1Cv2.1.234\\033[0m\\n'
        printf 'shift+tab to cycle modes\\n'
        IFS= read -r usage
        printf '%s\\n' "$usage" >> "$PWD/ansi-input"
        printf '\\033[1mCurrent\\033[1Csession:\\033[1C10%%\\033[1Cused\\033[0m\\n'
        printf 'Current week: 90%% left\\nEsc to go back\\n'
        IFS= read -r exit_command
        """)
        try await fixture.refresher(executable: executable).refresh()
        #expect(try fixture.lines("ansi-input") == ["", "/usage"])
    }

    @Test("changed trust-question punctuation is never acknowledged")
    func changedTrustPunctuationIsDenied() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("changed-trust", body: """
        printf 'untouched\\n' > "$PWD/marker"
        printf 'Do you trust the files in this folder!\\nEnter to confirm\\n'
        if IFS= read -r answer; then
          printf 'answered\\n' > "$PWD/marker"
        fi
        sleep 5
        """)

        let error = await collectionError {
            try await fixture.refresher(executable: executable, timeout: .seconds(1)).refresh()
        }

        #expect(error?.diagnosticCode == "claude.auth-refresh.timeout")
        #expect(error?.recoveryAction == .retry)
        #expect(try fixture.lines("marker") == ["untouched"])
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
        #expect(error?.recoveryAction == .retry)
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
        printf 'shift+tab to cycle modes\\n'
        sleep 30
        """)
        let refresher = fixture.refresher(executable: executable, timeout: .seconds(1))

        let error = await collectionError { try await refresher.refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.timeout")
        #expect(error?.recoveryAction == .retry)
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
        printf 'shift+tab to cycle modes\\n'
        sleep 30
        """)
        let refresher = fixture.refresher(executable: executable, timeout: .seconds(1))

        let error = await collectionError { try await refresher.refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.timeout")
        #expect(error?.recoveryAction == .retry)
        try await assertProcessExited(pidAt: fixture.workspace.appendingPathComponent("child-pid"))
    }

    @Test("early process exit is not treated as refreshed and is reaped")
    func earlyExitCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("early-exit", body: """
        printf '%s\\n' $$ > "$PWD/pid"
        printf 'Welcome to Claude Code\n'
        printf 'shift+tab to cycle modes\\n'
        exit 0
        """)

        let error = await collectionError { try await fixture.refresher(executable: executable).refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.process-exited")
        #expect(error?.recoveryAction == .retry)
        try await assertProcessExited(pidAt: fixture.workspace.appendingPathComponent("pid"))
    }

    @Test("repeated fast exits are classified as process exit whether they race the usage write or not")
    func repeatedFastExitClassification() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Exits right after the banner: the child may tear down its PTY between the refresher
        // reading the banner and writing `/usage`, which must still surface as a process exit.
        let exitAfterBanner = try fixture.script("exit-after-banner", body: """
        printf '%s\\n' $$ > "$PWD/pid"
        printf 'Welcome to Claude Code\n'
        printf 'shift+tab to cycle modes\\n'
        exit 0
        """)
        // Exits right after consuming `/usage`: the write succeeds and the exit is seen by polling.
        let exitAfterStatus = try fixture.script("exit-after-usage", body: """
        printf '%s\\n' $$ > "$PWD/pid"
        printf 'Welcome to Claude Code\n'
        printf 'shift+tab to cycle modes\\n'
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
        printf 'shift+tab to cycle modes\\n'
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
        printf 'SECRET-RAW-TUI-OUTPUT'
        printf '%262145s' ''
        sleep 30
        """)

        let error = await collectionError {
            try await fixture.refresher(executable: executable, timeout: .seconds(15)).refresh()
        }

        #expect(error?.diagnosticCode == "claude.auth-refresh.output-size-limit")
        #expect(error?.recoveryAction == .retry)
        #expect(!String(describing: error).contains("SECRET-RAW-TUI-OUTPUT"))
    }

    @Test("classifies a completed authentication failure without exposing terminal text")
    func completedAuthenticationFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("auth-failure", body: """
        printf 'Welcome to Claude Code\nshift+tab to cycle modes\n'
        IFS= read -r usage
        printf '%s\n' "$usage" > "$PWD/failure-input"
        printf 'Notloggedin.Run/login.SECRET-OWNER-TEXT\n'
        IFS= read -r exit_command
        printf '%s\n' "$exit_command" >> "$PWD/failure-input"
        """)

        let error = await collectionError {
            try await fixture.refresher(executable: executable).refresh()
        }

        #expect(error?.diagnosticCode == "claude.auth-refresh.login-required")
        #expect(error?.recoveryAction == .signInSourceApp)
        #expect(!String(describing: error).contains("SECRET-OWNER-TEXT"))
        #expect(try fixture.lines("failure-input").first == "/usage")
    }
    @Test("classifies a completed generic usage failure as retryable")
    func completedTransientUsageFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("usage-failure", body: """
        printf 'Welcome to Claude Code\nshift+tab to cycle modes\n'
        IFS= read -r usage
        printf '%s\n' "$usage" > "$PWD/usage-failure-input"
        printf 'Unabletoloadusage\n'
        sleep 5
        """)

        let error = await collectionError {
            try await fixture.refresher(executable: executable, timeout: .seconds(3)).refresh()
        }

        #expect(error?.diagnosticCode == "claude.auth-refresh.usage-failed")
        #expect(error?.recoveryAction == .retry)
        #expect(try fixture.lines("usage-failure-input") == ["/usage"])
    }

    @Test("accepts explicit plan notice only after its panel footer")
    func completedPlanNotice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("plan-notice", body: """
        printf 'Welcome to Claude Code\nshift+tab to cycle modes\n'
        IFS= read -r usage
        printf 'Usage data is not available for your plan\nEsc to close\n'
        IFS= read -r exit_command
        printf '%s\n%s\n' "$usage" "$exit_command" > "$PWD/plan-input"
        """)

        try await fixture.refresher(executable: executable).refresh()

        #expect(try fixture.lines("plan-input").first == "/usage")
    }

    @Test("accepts the completed credential-less local usage panel")
    func completedLocalUsagePanel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("local-usage", body: """
        printf 'Welcome to Claude Code\nshift+tab to cycle modes\n'
        IFS= read -r usage
        printf 'SettingsStatusConfigUsageStats\nSession\nTotalcost:$0.0000\n'
        printf 'Usage:0input,0output,0cacheread,0cachewrite\nEsctocancel\n'
        IFS= read -r exit_command
        printf '%s\n%s\n' "$usage" "$exit_command" > "$PWD/local-input"
        """)

        try await fixture.refresher(executable: executable).refresh()

        #expect(try fixture.lines("local-input").first == "/usage")
    }

    @Test("rejects an interactive prompt after usage without answering it")
    func postCommandPromptFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("post-command-prompt", body: """
        printf 'Welcome to Claude Code\nshift+tab to cycle modes\n'
        IFS= read -r usage
        printf '%s\n' "$usage" > "$PWD/post-prompt-input"
        printf 'Approve this action? SECRET-PROMPT\n'
        if IFS= read -r answer; then
          printf '%s\n' "$answer" >> "$PWD/post-prompt-input"
        fi
        sleep 5
        """)

        let error = await collectionError {
            try await fixture.refresher(executable: executable, timeout: .seconds(2)).refresh()
        }

        #expect(error?.diagnosticCode == "claude.auth-refresh.interaction-rejected.approve")
        #expect(error?.recoveryAction == .retry)
        #expect(!String(describing: error).contains("SECRET-PROMPT"))
        #expect(try fixture.lines("post-prompt-input") == ["/usage"])
    }

    @Test("ready or completed output never overrides a simultaneous approval prompt")
    func promptOverridesReadyAndCompletedOutput() async throws {
        for afterUsage in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let body = afterUsage
                ? """
                printf 'Welcome to Claude Code\\nshift+tab to cycle modes\\n'
                IFS= read -r usage
                printf '%s\\n' "$usage" > "$PWD/guard-input"
                printf 'Current session: 10%% used\\nCurrent week: 20%% used\\nEsc to cancel\\n'
                """
                : """
                printf '' > "$PWD/guard-input"
                printf 'Welcome to Claude Code\\nshift+tab to cycle modes\\n'
                """
            let executable = try fixture.script("prompt-overrides-panel", body: body + """

            printf 'Approve this action?\\n'
            if IFS= read -r answer; then
              printf '%s\\n' "$answer" >> "$PWD/guard-input"
            fi
            sleep 5
            """)
            let error = await collectionError {
                try await fixture.refresher(executable: executable).refresh()
            }
            #expect(error?.diagnosticCode == "claude.auth-refresh.interaction-rejected.approve")
            #expect(try fixture.lines("guard-input") == (afterUsage ? ["/usage"] : []))
        }
    }

    @Test("trust approval is never sent after the usage command")
    func postUsageTrustPromptIsDenied() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("post-usage-trust", body: """
        printf 'Welcome to Claude Code\\nshift+tab to cycle modes\\n'
        IFS= read -r usage
        printf '%s\\n' "$usage" > "$PWD/guard-input"
        printf 'Do you trust the files in this folder?\\nEnter to confirm\\n'
        if IFS= read -r answer; then
          printf '%s\\n' "$answer" >> "$PWD/guard-input"
        fi
        sleep 5
        """)
        let error = await collectionError {
            try await fixture.refresher(executable: executable).refresh()
        }
        #expect(error?.diagnosticCode == "claude.auth-refresh.interaction-rejected")
        #expect(try fixture.lines("guard-input") == ["/usage"])
    }

    @Test("an unknown post-usage prompt receives no input even at the hard deadline")
    func unknownPromptAtDeadlineReceivesNoInput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("unknown-post-usage-prompt", body: """
        printf 'Welcome to Claude Code\\nshift+tab to cycle modes\\n'
        IFS= read -r usage
        printf '%s\\n' "$usage" > "$PWD/guard-input"
        printf 'Choose a new workspace?\\n'
        if IFS= read -r answer; then
          printf '%s\\n' "$answer" >> "$PWD/guard-input"
        fi
        sleep 5
        """)
        let error = await collectionError {
            try await fixture.refresher(executable: executable, timeout: .seconds(1)).refresh()
        }
        #expect(error?.diagnosticCode == "claude.auth-refresh.timeout")
        #expect(try fixture.lines("guard-input") == ["/usage"])
    }
    @Test("login-required prompt directs the user to Claude")
    func loginPromptUsesSignInRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("login-prompt", body: """
        printf 'Log in to continue\n'
        sleep 5
        """)

        let error = await collectionError {
            try await fixture.refresher(executable: executable, timeout: .seconds(1)).refresh()
        }

        #expect(error?.diagnosticCode == "claude.auth-refresh.interaction-rejected.login")
        #expect(error?.recoveryAction == .signInSourceApp)
    }

    @Test("locked console creates no workspace and launches no process")
    func lockedConsoleHasNoSideEffects() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.script("locked-must-not-launch", body: """
        touch "$HOME/launched"
        """)
        let absentWorkspace = fixture.root.appendingPathComponent("locked-probe", isDirectory: true)
        let refresher = ClaudeCLIAuthRefresher(
            executableCandidates: [executable],
            workingDirectory: absentWorkspace,
            timeout: .seconds(1),
            homeDirectory: fixture.home,
            screenIsUnlocked: { false }
        )

        let error = await collectionError { try await refresher.refresh() }

        #expect(error?.diagnosticCode == "claude.auth-refresh.screen-locked")
        #expect(error?.recoveryAction == .retry)
        #expect(!FileManager.default.fileExists(atPath: absentWorkspace.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("launched").path))
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
        try Data("#!/bin/sh\nset -e\n\(body)\n".utf8).write(to: url, options: .atomic)
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
