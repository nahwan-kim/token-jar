import CoreFoundation
import CryptoKit
import CoreGraphics
import Dispatch
import Foundation
import TokenTankDomain

public struct ClaudeSession: Sendable, Equatable {
    /// A readable sign-in whose token is expired or rejected; Claude Code may renew it.
    public static let refreshRequiredDiagnosticCode = "claude.session.refresh-required"

    public let accessToken: String
    public let expiresAt: Date
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(
        accessToken: String,
        expiresAt: Date,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }
}

/// One Claude Code sign-in: the default login, or one per `CLAUDE_CONFIG_DIR`-style directory.
public struct ClaudeAccount: Sendable, Equatable, Identifiable {
    public static let defaultSourceID = "claude.oauth"
    public static let `default` = ClaudeAccount(sourceID: defaultSourceID)

    public let sourceID: String
    /// `oauthAccount.accountUuid` from the directory's `.claude.json`, when present.
    public let accountUUID: String?
    public let email: String?

    public var id: String { sourceID }

    public init(sourceID: String, accountUUID: String? = nil, email: String? = nil) {
        self.sourceID = sourceID
        self.accountUUID = accountUUID
        self.email = ProviderSnapshot.validatedAccountEmail(email)
    }

    /// The source for a directory directly under the home directory (".claude-work"); `nil`
    /// for other names, which are identified by a path hash instead.
    public static func homeDirectorySourceID(named name: String) -> String? {
        guard name.hasPrefix(".claude-") else { return nil }
        let directory = String(name.dropFirst()).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard directory.count <= 64, directory.allSatisfy(allowed.contains) else { return nil }
        return "\(defaultSourceID).\(directory)"
    }
}

public protocol ClaudeSessionProviding: Sendable {
    /// `false` only rereads the sign-in. `true` also lets Claude Code renew an expired or
    /// rejected session once (`claude /usage`).
    func session(allowsRefresh: Bool, rejectedAccessToken: String?) async throws -> ClaudeSession
    /// Every Claude Code sign-in on this Mac, default first.
    func accounts() async throws -> [ClaudeAccount]
    func session(
        account sourceID: String,
        allowsRefresh: Bool,
        rejectedAccessToken: String?
    ) async throws -> ClaudeSession
}

public extension ClaudeSessionProviding {
    func accounts() async throws -> [ClaudeAccount] {
        [.default]
    }

    func session(
        account sourceID: String,
        allowsRefresh: Bool,
        rejectedAccessToken: String?
    ) async throws -> ClaudeSession {
        guard sourceID == ClaudeAccount.defaultSourceID else {
            throw CollectionError(
                kind: .externalSessionMissing,
                diagnosticCode: "claude.session.account-missing",
                recoveryAction: .signInSourceApp
            )
        }
        return try await session(allowsRefresh: allowsRefresh, rejectedAccessToken: rejectedAccessToken)
    }
}

public struct NoClaudeSessionProvider: ClaudeSessionProviding {
    public init() {}

    public func session(
        allowsRefresh: Bool,
        rejectedAccessToken: String?
    ) async throws -> ClaudeSession {
        _ = allowsRefresh
        _ = rejectedAccessToken
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "claude.session.disabled")
    }
}

protocol ClaudeCredentialReading: Sendable {
    func readFile() async throws -> Data?
    func readKeychain() async throws -> Data?
}

actor NativeClaudeCredentialReader: ClaudeCredentialReading {
    private static let maximumBytes = 64 * 1024
    static let defaultService = "Claude Code-credentials"
    static let defaultCredentialsPath = ".claude/.credentials.json"
    static let securityTool = URL(fileURLWithPath: "/usr/bin/security")
    /// `security` exits with `errSecItemNotFound` truncated to its low byte.
    private static let itemNotFoundExitStatus: Int32 = 44

    private let policy: FilesystemAccessPolicy
    private let credentialsRelativePath: String
    private let keychainLookup: @Sendable () async throws -> Data?
    private let screenIsUnlocked: @Sendable () -> Bool

    init(
        homeDirectory: URL,
        service: String = NativeClaudeCredentialReader.defaultService,
        credentialsRelativePath: String = NativeClaudeCredentialReader.defaultCredentialsPath
    ) {
        self.policy = FilesystemAccessPolicy(homeDirectory: homeDirectory)
        self.credentialsRelativePath = credentialsRelativePath
        let account = NSUserName()
        self.keychainLookup = {
            try await Self.readWithSecurityTool(service: service, account: account, timeout: 5)
        }
        self.screenIsUnlocked = Self.consoleIsUnlocked
    }

    init(
        homeDirectory: URL,
        screenIsUnlocked: @escaping @Sendable () -> Bool = { true },
        credentialsRelativePath: String = NativeClaudeCredentialReader.defaultCredentialsPath,
        keychainLookup: @escaping @Sendable () async throws -> Data?
    ) {
        self.policy = FilesystemAccessPolicy(homeDirectory: homeDirectory)
        self.credentialsRelativePath = credentialsRelativePath
        self.keychainLookup = keychainLookup
        self.screenIsUnlocked = screenIsUnlocked
    }

    func readFile() async throws -> Data? {
        do {
            return try await policy.read(ExternalFileRequest(
                providerID: .claude,
                relativePath: credentialsRelativePath,
                maximumBytes: Self.maximumBytes
            ))
        } catch let error as CollectionError where error.kind == .externalSessionMissing {
            return nil
        }
    }

    func readKeychain() async throws -> Data? {
        try Task.checkCancellation()
        guard screenIsUnlocked() else {
            throw CollectionError(
                kind: .keychainUnavailable,
                diagnosticCode: "claude.session.keychain.screen-locked",
                recoveryAction: .retry
            )
        }
        return try await keychainLookup()
    }

    private static func consoleIsUnlocked() -> Bool {
        // On a locked console, even a no-UI legacy Keychain query can block in
        // securityd. Do not start a foreign-item lookup until the session returns.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true
        else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    /// Reads a generic-password item through `/usr/bin/security`. Claude Code writes its
    /// credentials with that tool, so every rewrite keeps it in the item's ACL and `apple-tool:`
    /// partition: the read never shows the Keychain dialog, and a token renewal cannot revoke it
    /// the way it revokes an "Always Allow" grant to Token Jar itself. A tool still running at
    /// `timeout` (an item whose ACL does not trust it would wait on a dialog) is terminated.
    static func readWithSecurityTool(
        service: String,
        account: String,
        executable: URL = NativeClaudeCredentialReader.securityTool,
        timeout: TimeInterval
    ) async throws -> Data? {
        let run = SecurityToolRun(
            executable: executable,
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"]
        )
        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try run.execute(timeout: timeout) })
                }
            }
        } onCancel: {
            run.cancel()
        }
        try Task.checkCancellation()
        switch outcome.status {
        case 0:
            guard let data = decodedPassword(outcome.output), !data.isEmpty, data.count <= maximumBytes else {
                throw malformed("claude.session.keychain.value-invalid")
            }
            return data
        case itemNotFoundExitStatus:
            return nil
        default:
            throw CollectionError(
                kind: .keychainUnavailable,
                diagnosticCode: "claude.session.keychain.status-\(outcome.status)",
                recoveryAction: .retry
            )
        }
    }

    /// `security -w` prints the value and a newline, or its hex encoding when it is not printable.
    private static func decodedPassword(_ output: Data) -> Data? {
        var value = output
        if value.last == UInt8(ascii: "\n") { value.removeLast() }
        guard !value.isEmpty, value.count.isMultiple(of: 2),
              value.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { return value }
        var bytes = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            guard let byte = UInt8(String(decoding: value[index..<value.index(index, offsetBy: 2)], as: UTF8.self), radix: 16)
            else { return nil }
            bytes.append(byte)
            index = value.index(index, offsetBy: 2)
        }
        return bytes
    }
}

/// One bounded `/usr/bin/security` launch that a timeout or task cancellation terminates.
private final class SecurityToolRun: @unchecked Sendable {
    struct Outcome {
        let status: Int32
        let output: Data
    }

    private static let maximumOutputBytes = 256 * 1024

    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    private var timedOut = false
    private var started = false
    private var finished = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func execute(timeout: TimeInterval) throws -> Outcome {
        let output = Pipe()
        process.standardOutput = output
        let launched: Bool = try lock.withLock {
            guard !cancelled else { return false }
            do {
                try process.run()
                started = true
            } catch {
                throw CollectionError(
                    kind: .keychainUnavailable,
                    diagnosticCode: "claude.session.keychain.launch-failed",
                    recoveryAction: .retry
                )
            }
            return true
        }
        guard launched else { throw CancellationError() }
        let deadline = DispatchWorkItem { [self] in
            lock.withLock {
                timedOut = true
                if started, !finished { process.terminate() }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        var data = Data()
        let reader = output.fileHandleForReading
        while case let chunk = reader.availableData, !chunk.isEmpty {
            data.append(chunk)
            if data.count > Self.maximumOutputBytes {
                lock.withLock {
                    if started, !finished { process.terminate() }
                }
                break
            }
        }
        process.waitUntilExit()
        lock.withLock { finished = true }
        deadline.cancel()
        let (wasCancelled, wasTimedOut) = lock.withLock { (cancelled, timedOut) }
        if wasCancelled { throw CancellationError() }
        if wasTimedOut {
            throw CollectionError(
                kind: .keychainUnavailable,
                diagnosticCode: "claude.session.keychain.timeout",
                recoveryAction: .retry
            )
        }
        guard data.count <= Self.maximumOutputBytes else {
            throw malformed("claude.session.keychain.value-invalid")
        }
        return Outcome(
            status: process.terminationReason == .exit ? process.terminationStatus : -1,
            output: data
        )
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if started, !finished { process.terminate() }
        }
    }
}

private final class ClaudeRepairWaiters: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []
    private var task: Task<ClaudeSession, Error>?

    func insert(_ id: UUID) {
        _ = lock.withLock { ids.insert(id) }
    }

    func setTask(_ task: Task<ClaudeSession, Error>) {
        let shouldCancel = lock.withLock {
            self.task = task
            return ids.isEmpty
        }
        if shouldCancel { task.cancel() }
    }

    func remove(_ id: UUID) {
        _ = lock.withLock { ids.remove(id) }
    }

    func cancel(_ id: UUID) {
        let taskToCancel = lock.withLock {
            ids.remove(id)
            return ids.isEmpty ? task : nil
        }
        taskToCancel?.cancel()
    }

    func finish() {
        lock.withLock {
            ids.removeAll()
            task = nil
        }
    }
}

/// Session state for one Claude Code sign-in: its credential slots, rejected-token memory,
/// and the single in-flight Claude Code owner refresh.
actor ClaudeAccountSessionProvider {
    private static let minimumValidity: TimeInterval = 60

    private let clock: any TokenTankClock
    private let credentials: any ClaudeCredentialReading
    private let refresher: any ClaudeAuthRefreshing
    private var repairTask: Task<ClaudeSession, Error>?
    private var repairID: UUID?
    private var repairWaiters: ClaudeRepairWaiters?
    private var rejectedFileToken: String?
    private var rejectedKeychainToken: String?

    init(
        clock: any TokenTankClock,
        credentials: any ClaudeCredentialReading,
        refresher: any ClaudeAuthRefreshing
    ) {
        self.clock = clock
        self.credentials = credentials
        self.refresher = refresher
    }

    func session(allowsRefresh: Bool, rejectedAccessToken: String?) async throws -> ClaudeSession {
        try Task.checkCancellation()
        guard allowsRefresh else {
            let state = try await credentialState(rejectedAccessToken: rejectedAccessToken)
            if let fresh = state.fresh {
                return fresh
            }
            guard !state.unusableTokens.isEmpty else {
                throw missingCredentials()
            }
            throw refreshRequired()
        }

        if let repairTask, let repairWaiters {
            return try await waitForRepair(
                repairTask,
                waiters: repairWaiters,
                rejectedAccessToken: rejectedAccessToken
            )
        }

        let id = UUID()
        let waiterID = UUID()
        let waiters = ClaudeRepairWaiters()
        waiters.insert(waiterID)
        repairID = id
        repairWaiters = waiters
        let task = Task {
            do {
                let session = try await self.repair(rejectedAccessToken: rejectedAccessToken)
                self.settleRepair(id: id)
                return session
            } catch {
                self.settleRepair(id: id)
                throw error
            }
        }
        repairTask = task
        waiters.setTask(task)
        return try await waitForRepair(
            task,
            waiters: waiters,
            waiterID: waiterID,
            rejectedAccessToken: rejectedAccessToken
        )
    }

    private func settleRepair(id: UUID) {
        guard repairID == id else { return }
        repairTask = nil
        repairID = nil
        repairWaiters?.finish()
        repairWaiters = nil
    }

    private func waitForRepair(
        _ task: Task<ClaudeSession, Error>,
        waiters: ClaudeRepairWaiters,
        waiterID: UUID = UUID(),
        rejectedAccessToken: String?
    ) async throws -> ClaudeSession {
        waiters.insert(waiterID)
        return try await withTaskCancellationHandler {
            defer { waiters.remove(waiterID) }
            let session = try await task.value
            try Task.checkCancellation()
            guard !tokenIsRejected(session.accessToken, explicit: rejectedAccessToken) else {
                throw refreshRequired()
            }
            return session
        } onCancel: {
            waiters.cancel(waiterID)
        }
    }

    private func repair(rejectedAccessToken: String?) async throws -> ClaudeSession {
        let initialState = try await credentialState(rejectedAccessToken: rejectedAccessToken)
        try Task.checkCancellation()
        if let fresh = initialState.fresh {
            return fresh
        }
        guard !initialState.unusableTokens.isEmpty else {
            throw missingCredentials()
        }
        let previousTokens = initialState.unusableTokens
        try Task.checkCancellation()

        do {
            try await refresher.refresh()
        } catch let refreshError {
            do {
                let state = try await credentialState(rejectedAccessToken: rejectedAccessToken)
                if let session = state.fresh,
                   !previousTokens.contains(session.accessToken) {
                    return session
                }
            } catch {}
            throw refreshError
        }

        let state = try await credentialState(rejectedAccessToken: rejectedAccessToken)
        guard let session = state.fresh else {
            if state.unusableTokens.isEmpty {
                throw CollectionError(
                    kind: .externalSessionMissing,
                    diagnosticCode: "claude.session.refresh.credentials-missing",
                    recoveryAction: .signInSourceApp
                )
            }
            throw refreshRequired()
        }
        guard !previousTokens.contains(session.accessToken) else {
            throw refreshRequired()
        }
        return session
    }

    private func tokenIsRejected(_ token: String, explicit: String?) -> Bool {
        token == explicit
            || token == rejectedFileToken
            || token == rejectedKeychainToken
    }
    private func credentialState(rejectedAccessToken: String?) async throws -> CredentialState {
        var unusableTokens: Set<String> = []
        if let data = try await credentials.readFile() {
            if let session = try decodeClaudeSession(data) {
                if rejectedFileToken != session.accessToken {
                    rejectedFileToken = nil
                }
                if session.accessToken == rejectedAccessToken {
                    rejectedFileToken = session.accessToken
                }
                let now = await clock.now()
                if !tokenIsRejected(session.accessToken, explicit: rejectedAccessToken),
                   session.expiresAt > now.addingTimeInterval(Self.minimumValidity) {
                    return CredentialState(fresh: session, unusableTokens: [])
                }
                unusableTokens.insert(session.accessToken)
            } else {
                rejectedFileToken = nil
            }
        } else {
            rejectedFileToken = nil
        }

        if let data = try await credentials.readKeychain() {
            if let session = try decodeClaudeSession(data) {
                if rejectedKeychainToken != session.accessToken {
                    rejectedKeychainToken = nil
                }
                if session.accessToken == rejectedAccessToken {
                    rejectedKeychainToken = session.accessToken
                }
                let now = await clock.now()
                if !tokenIsRejected(session.accessToken, explicit: rejectedAccessToken),
                   session.expiresAt > now.addingTimeInterval(Self.minimumValidity) {
                    return CredentialState(fresh: session, unusableTokens: unusableTokens)
                }
                unusableTokens.insert(session.accessToken)
            } else {
                rejectedKeychainToken = nil
            }
        } else {
            rejectedKeychainToken = nil
        }
        return CredentialState(fresh: nil, unusableTokens: unusableTokens)
    }
}


/// Every Claude Code sign-in on this Mac. The default login uses the `Claude Code-credentials`
/// Keychain item or `~/.claude/.credentials.json`; each `CLAUDE_CONFIG_DIR` and `~/.claude-*`
/// directory uses `Claude Code-credentials-<first 8 hex of SHA-256(directory path)>` or
/// `<directory>/.credentials.json`. Identity comes from that directory's `.claude.json`.
public actor ClaudeCodeSessionProvider: ClaudeSessionProviding {
    private static let configMaximumBytes = 16 * 1024 * 1024

    private let clock: any TokenTankClock
    private let homeDirectory: URL?
    private let environment: [String: String]
    private let policy: FilesystemAccessPolicy?
    private var accountProviders: [String: ClaudeAccountSessionProvider] = [:]

    public init(
        clock: any TokenTankClock = SystemClock(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.clock = clock
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.policy = FilesystemAccessPolicy(homeDirectory: homeDirectory)
    }

    /// A single default account backed by injected credential and repair sources.
    init(
        clock: any TokenTankClock,
        credentials: any ClaudeCredentialReading,
        refresher: any ClaudeAuthRefreshing
    ) {
        self.clock = clock
        self.homeDirectory = nil
        self.environment = [:]
        self.policy = nil
        self.accountProviders[ClaudeAccount.defaultSourceID] = ClaudeAccountSessionProvider(
            clock: clock,
            credentials: credentials,
            refresher: refresher
        )
    }

    public func accounts() async throws -> [ClaudeAccount] {
        guard let homeDirectory, let policy else { return [.default] }
        let locations = Self.locations(homeDirectory: homeDirectory, environment: environment)
        var accounts: [ClaudeAccount] = []
        var seenAccountUUIDs: Set<String> = []
        for location in locations {
            let identity = await Self.identity(in: location.configRelativePath, policy: policy)
            // Beside other sign-ins, a default login with no account record or credentials file
            // is not a sign-in; listing it would only add a permanent sign-in failure.
            if location.sourceID == ClaudeAccount.defaultSourceID, locations.count > 1, identity.uuid == nil,
               !FileManager.default.fileExists(
                   atPath: homeDirectory.appendingPathComponent(location.credentialsRelativePath).path
               ) {
                continue
            }
            if let uuid = identity.uuid, !seenAccountUUIDs.insert(uuid).inserted { continue }
            accounts.append(ClaudeAccount(
                sourceID: location.sourceID,
                accountUUID: identity.uuid,
                email: identity.email
            ))
            if accountProviders[location.sourceID] == nil {
                accountProviders[location.sourceID] = ClaudeAccountSessionProvider(
                    clock: clock,
                    credentials: NativeClaudeCredentialReader(
                        homeDirectory: homeDirectory,
                        service: location.keychainService,
                        credentialsRelativePath: location.credentialsRelativePath
                    ),
                    refresher: ClaudeCLIAuthRefresher(
                        homeDirectory: homeDirectory,
                        configDirectory: location.configDirectory
                    )
                )
            }
        }
        let current = Set(accounts.map(\.sourceID))
        accountProviders = accountProviders.filter { current.contains($0.key) }
        return accounts
    }

    public func session(
        account sourceID: String,
        allowsRefresh: Bool,
        rejectedAccessToken: String?
    ) async throws -> ClaudeSession {
        guard let provider = accountProviders[sourceID] ?? defaultProviderIfUndiscovered(sourceID) else {
            throw CollectionError(
                kind: .externalSessionMissing,
                diagnosticCode: "claude.session.account-missing",
                recoveryAction: .signInSourceApp
            )
        }
        return try await provider.session(
            allowsRefresh: allowsRefresh,
            rejectedAccessToken: rejectedAccessToken
        )
    }

    public func session(allowsRefresh: Bool, rejectedAccessToken: String?) async throws -> ClaudeSession {
        try await session(
            account: ClaudeAccount.defaultSourceID,
            allowsRefresh: allowsRefresh,
            rejectedAccessToken: rejectedAccessToken
        )
    }

    private func defaultProviderIfUndiscovered(_ sourceID: String) -> ClaudeAccountSessionProvider? {
        guard sourceID == ClaudeAccount.defaultSourceID, let homeDirectory else { return nil }
        let provider = ClaudeAccountSessionProvider(
            clock: clock,
            credentials: NativeClaudeCredentialReader(homeDirectory: homeDirectory),
            refresher: ClaudeCLIAuthRefresher(homeDirectory: homeDirectory)
        )
        accountProviders[sourceID] = provider
        return provider
    }

    struct Location: Equatable {
        let sourceID: String
        let keychainService: String
        let credentialsRelativePath: String
        let configRelativePath: String
        /// The exact string hashed into `keychainService`, so a repair run with it as
        /// `CLAUDE_CONFIG_DIR` renews the same Keychain item Token Jar reads.
        let configDirectory: String?
    }

    /// Default login first, then `CLAUDE_CONFIG_DIR`, then `~/.claude-*` in name order.
    /// A non-default directory counts only when it lies inside the home directory and holds a
    /// `.claude.json` or `.credentials.json`.
    static func locations(
        homeDirectory: URL,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> [Location] {
        let home = homeDirectory.standardizedFileURL.path
        var result = [Location(
            sourceID: ClaudeAccount.defaultSourceID,
            keychainService: NativeClaudeCredentialReader.defaultService,
            credentialsRelativePath: NativeClaudeCredentialReader.defaultCredentialsPath,
            configRelativePath: ".claude.json",
            configDirectory: nil
        )]
        var candidates: [String] = []
        if let configured = environment["CLAUDE_CONFIG_DIR"], configured.hasPrefix("/") {
            candidates.append(configured)
        }
        let siblings = ((try? fileManager.contentsOfDirectory(atPath: home)) ?? [])
            .filter { $0.hasPrefix(".claude-") }
            .sorted()
            .map { "\(home)/\($0)" }
        candidates.append(contentsOf: siblings)

        var seen: Set<String> = ["\(home)/.claude"]
        for path in candidates {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(standardized).inserted,
                  standardized.hasPrefix(home + "/")
            else { continue }
            let relative = String(standardized.dropFirst(home.count + 1))
            guard !relative.isEmpty, !relative.contains("..") else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  (try? fileManager.destinationOfSymbolicLink(atPath: standardized)) == nil,
                  fileManager.fileExists(atPath: "\(standardized)/.claude.json")
                    || fileManager.fileExists(atPath: "\(standardized)/.credentials.json")
            else { continue }
            let hash = SHA256Hex.digest(path).prefix(8)
            result.append(Location(
                sourceID: sourceID(forRelativeDirectory: relative, hash: String(hash)),
                keychainService: "\(NativeClaudeCredentialReader.defaultService)-\(hash)",
                credentialsRelativePath: "\(relative)/.credentials.json",
                configRelativePath: "\(relative)/.claude.json",
                configDirectory: path
            ))
        }
        return result
    }

    private static func sourceID(forRelativeDirectory relative: String, hash: String) -> String {
        guard !relative.contains("/"), let sourceID = ClaudeAccount.homeDirectorySourceID(named: relative) else {
            return "\(ClaudeAccount.defaultSourceID).dir-\(hash)"
        }
        return sourceID
    }

    static func identity(
        in relativePath: String,
        policy: FilesystemAccessPolicy
    ) async -> (uuid: String?, email: String?) {
        guard let data = try? await policy.read(ExternalFileRequest(
            providerID: .claude,
            relativePath: relativePath,
            maximumBytes: configMaximumBytes
        )),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["oauthAccount"] as? [String: Any]
        else { return (nil, nil) }
        let uuid = (oauth["accountUuid"] as? String).flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.utf8.count > 128 ? nil : trimmed
        }
        return (uuid, oauth["emailAddress"] as? String)
    }
}

private struct CredentialState {
    let fresh: ClaudeSession?
    let unusableTokens: Set<String>
}

private func missingCredentials() -> CollectionError {
    CollectionError(
        kind: .externalSessionMissing,
        diagnosticCode: "claude.session.credentials-missing",
        recoveryAction: .signInSourceApp
    )
}

private func refreshRequired() -> CollectionError {
    CollectionError(
        kind: .authenticationRejected,
        diagnosticCode: ClaudeSession.refreshRequiredDiagnosticCode,
        recoveryAction: .runSourceCLI
    )
}

private func decodeClaudeSession(_ data: Data) throws -> ClaudeSession? {
    guard data.count <= 64 * 1024 else { throw malformed("claude.session.credentials-oversize") }
    let root: [String: Any]
    do {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw malformed("claude.session.credentials.invalid-json")
        }
        root = object
    } catch let error as CollectionError {
        throw error
    } catch {
        throw malformed("claude.session.credentials.invalid-json")
    }

    // MCP credentials are separate sessions. An absent Claude AI record permits
    // the owner's native Keychain source, but a malformed AI record never does.
    guard root["claudeAiOauth"] != nil else { return nil }
    guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
        throw authenticationRequired("claude.session.profile-missing")
    }
    guard let accessToken = oauth["accessToken"] as? String, tokenIsSafe(accessToken) else {
        throw authenticationRequired("claude.session.access-token-invalid")
    }
    guard let scopes = oauth["scopes"] as? [Any],
          scopes.allSatisfy({ $0 is String }),
          scopes.compactMap({ $0 as? String }).contains("user:profile")
    else {
        throw authenticationRequired("claude.session.profile-scope-missing")
    }
    guard let number = oauth["expiresAt"] as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,
          number.doubleValue > 0
    else { throw malformed("claude.session.expiry-invalid") }
    let seconds = number.doubleValue / 1_000
    guard seconds.isFinite, seconds > 0, seconds <= Date.distantFuture.timeIntervalSince1970 else {
        throw malformed("claude.session.expiry-invalid")
    }

    return ClaudeSession(
        accessToken: accessToken,
        expiresAt: Date(timeIntervalSince1970: seconds),
        subscriptionType: optionalMetadata(oauth["subscriptionType"]),
        rateLimitTier: optionalMetadata(oauth["rateLimitTier"])
    )
}

private func tokenIsSafe(_ token: String) -> Bool {
    !token.isEmpty
        && token.utf8.count <= 16 * 1024
        && token.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
}

private func optionalMetadata(_ value: Any?) -> String? {
    guard let value = value as? String,
          value == value.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty,
          value.utf8.count <= 1_024
    else { return nil }
    return value
}

private func authenticationRequired(_ code: String) -> CollectionError {
    CollectionError(kind: .authenticationRejected, diagnosticCode: code, recoveryAction: .signInSourceApp)
}


private func malformed(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}

enum SHA256Hex {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
