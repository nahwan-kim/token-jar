import CoreFoundation
import CoreGraphics
import Dispatch
import Foundation
import LocalAuthentication
@preconcurrency import Security
import TokenTankDomain

public struct ClaudeSession: Sendable, Equatable {
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

public protocol ClaudeSessionProviding: Sendable {
    func session(allowInteraction: Bool) async throws -> ClaudeSession
}

public struct NoClaudeSessionProvider: ClaudeSessionProviding {
    public init() {}

    public func session(allowInteraction: Bool) async throws -> ClaudeSession {
        _ = allowInteraction
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "claude.session.disabled")
    }
}

protocol ClaudeCredentialReading: Sendable {
    func readFile() async throws -> Data?
    func readKeychain(allowInteraction: Bool) async throws -> Data?
}

final class ClaudeKeychainQueryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var acceptingWaiters = true
    private var result: Result<Data?, Error>?
    private var waiters: [UUID: CheckedContinuation<Data?, Error>] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var timedOutBeforeRegistration: Set<UUID> = []

    var isCompleted: Bool {
        lock.withLock { completed }
    }

    func wait(id: UUID) async throws -> Data? {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Data?, Error>? = lock.withLock {
                    if cancelledBeforeRegistration.remove(id) != nil {
                        return .failure(CancellationError())
                    }
                    if timedOutBeforeRegistration.remove(id) != nil {
                        return .failure(Self.timeoutError())
                    }
                    if !acceptingWaiters {
                        return .failure(Self.inFlightError())
                    }
                    if let result { return result }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    func scheduleTimeout(for id: UUID, after timeout: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            self.timeout(id)
        }
    }

    func complete(_ result: Result<Data?, Error>) {
        let completion: (
            continuations: [CheckedContinuation<Data?, Error>],
            result: Result<Data?, Error>
        ) = lock.withLock {
            guard !completed else { return ([], result) }
            completed = true
            let effectiveResult = acceptingWaiters
                ? result
                : .failure(Self.inFlightError())
            self.result = effectiveResult
            let current = Array(waiters.values)
            waiters.removeAll()
            cancelledBeforeRegistration.removeAll()
            timedOutBeforeRegistration.removeAll()
            return (current, effectiveResult)
        }
        completion.continuations.forEach { $0.resume(with: completion.result) }
    }

    private func cancel(_ id: UUID) {
        let continuation: CheckedContinuation<Data?, Error>? = lock.withLock {
            if completed { return nil }
            acceptingWaiters = false
            if let continuation = waiters.removeValue(forKey: id) {
                return continuation
            }
            cancelledBeforeRegistration.insert(id)
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func timeout(_ id: UUID) {
        let continuation: CheckedContinuation<Data?, Error>? = lock.withLock {
            if completed { return nil }
            acceptingWaiters = false
            if let continuation = waiters.removeValue(forKey: id) {
                return continuation
            }
            timedOutBeforeRegistration.insert(id)
            return nil
        }
        continuation?.resume(throwing: Self.timeoutError())
    }

    private static func timeoutError() -> CollectionError {
        CollectionError(
            kind: .keychainUnavailable,
            diagnosticCode: "claude.session.keychain.timeout",
            recoveryAction: .retry
        )
    }

    private static func inFlightError() -> CollectionError {
        CollectionError(
            kind: .keychainUnavailable,
            diagnosticCode: "claude.session.keychain.query-in-flight",
            recoveryAction: .retry
        )
    }
}

actor NativeClaudeCredentialReader: ClaudeCredentialReading {
    private static let maximumBytes = 64 * 1024
    private static let service = "Claude Code-credentials"

    private let policy: FilesystemAccessPolicy
    private let keychainLookup: @Sendable (Bool) throws -> Data?
    private let screenIsUnlocked: @Sendable () -> Bool
    private let backgroundTimeout: TimeInterval
    private let manualTimeout: TimeInterval
    private var keychainQuery: ClaudeKeychainQueryGate?

    init(homeDirectory: URL) {
        self.policy = FilesystemAccessPolicy(homeDirectory: homeDirectory)
        self.keychainLookup = { try Self.readNativeKeychain(allowInteraction: $0) }
        self.screenIsUnlocked = Self.consoleIsUnlocked
        self.backgroundTimeout = 5
        // Explicit macOS authorization includes human password/biometric entry.
        // Keep it bounded without giving it the background I/O time budget.
        self.manualTimeout = 120
    }

    init(
        homeDirectory: URL,
        screenIsUnlocked: @escaping @Sendable () -> Bool = { true },
        backgroundTimeout: TimeInterval = 5,
        manualTimeout: TimeInterval = 120,
        keychainLookup: @escaping @Sendable (Bool) throws -> Data?
    ) {
        self.policy = FilesystemAccessPolicy(homeDirectory: homeDirectory)
        self.keychainLookup = keychainLookup
        self.screenIsUnlocked = screenIsUnlocked
        self.backgroundTimeout = backgroundTimeout
        self.manualTimeout = manualTimeout
    }

    func readFile() async throws -> Data? {
        do {
            return try await policy.read(ExternalFileRequest(
                providerID: .claude,
                relativePath: ".claude/.credentials.json",
                maximumBytes: Self.maximumBytes
            ))
        } catch let error as CollectionError where error.kind == .externalSessionMissing {
            return nil
        }
    }

    func readKeychain(allowInteraction: Bool) async throws -> Data? {
        try Task.checkCancellation()
        guard screenIsUnlocked() else {
            throw CollectionError(
                kind: .keychainUnavailable,
                diagnosticCode: "claude.session.keychain.screen-locked",
                recoveryAction: .retry
            )
        }

        if keychainQuery?.isCompleted == true {
            keychainQuery = nil
        }
        let gate: ClaudeKeychainQueryGate
        if let keychainQuery {
            gate = keychainQuery
        } else {
            let lookup = keychainLookup
            let newGate = ClaudeKeychainQueryGate()
            keychainQuery = newGate
            gate = newGate
            DispatchQueue.global(qos: .utility).async {
                newGate.complete(Result { try lookup(allowInteraction) })
            }
        }

        let timeout = allowInteraction ? manualTimeout : backgroundTimeout
        return try await wait(for: gate, timeout: timeout)
    }

    private func wait(for gate: ClaudeKeychainQueryGate, timeout: TimeInterval) async throws -> Data? {
        let id = UUID()
        gate.scheduleTimeout(for: id, after: timeout)
        return try await gate.wait(id: id)
    }

    private static func consoleIsUnlocked() -> Bool {
        // On a locked console, even a no-UI legacy Keychain query can block in
        // securityd. Do not start a foreign-item lookup until the session returns.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true
        else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    static func readNativeKeychain(
        allowInteraction: Bool,
        matching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    ) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: allowInteraction
                ? kSecUseAuthenticationUIAllow
                : kSecUseAuthenticationUIFail,
        ]

        var result: CFTypeRef?
        let status = try ClaudeNativeKeychainAccess.perform(allowInteraction: allowInteraction) {
            matching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty, data.count <= maximumBytes else {
                throw malformed("claude.session.keychain.value-invalid")
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed, errSecUserCanceled:
            throw CollectionError(
                kind: .keychainUnavailable,
                diagnosticCode: "claude.session.keychain.unavailable",
                recoveryAction: .retry
            )
        default:
            throw CollectionError(
                kind: .keychainUnavailable,
                diagnosticCode: "claude.session.keychain.status-\(status)",
                recoveryAction: .retry
            )
        }
    }
}

enum ClaudeNativeKeychainAccess {
    private static let lock = NSLock()

    static func perform<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        // The legacy login Keychain ignores LAContext/no-UI query flags for
        // foreign ACL prompts. Serialize and restore the process-local policy;
        // this does not change any item's ACL or the user's Keychain settings.
        lock.lock()
        defer { lock.unlock() }
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess else {
            throw policyError()
        }
        if !allowInteraction {
            guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                throw policyError()
            }
        }
        let result = Result { try operation() }
        if !allowInteraction {
            guard SecKeychainSetUserInteractionAllowed(previous.boolValue) == errSecSuccess else {
                throw policyError()
            }
        }
        return try result.get()
    }

    private static func policyError() -> CollectionError {
        CollectionError(
            kind: .keychainUnavailable,
            diagnosticCode: "claude.session.keychain.interaction-policy-unavailable",
            recoveryAction: .retry
        )
    }
}

public actor ClaudeCodeSessionProvider: ClaudeSessionProviding {
    private let clock: any TokenTankClock
    private let credentials: any ClaudeCredentialReading
    private let refresher: any ClaudeAuthRefreshing
    private var renewalTask: Task<ClaudeSession, Error>?

    public init(
        clock: any TokenTankClock = SystemClock(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.clock = clock
        self.credentials = NativeClaudeCredentialReader(homeDirectory: homeDirectory)
        self.refresher = ClaudeCLIAuthRefresher(homeDirectory: homeDirectory)
    }

    init(
        clock: any TokenTankClock,
        credentials: any ClaudeCredentialReading,
        refresher: any ClaudeAuthRefreshing
    ) {
        self.clock = clock
        self.credentials = credentials
        self.refresher = refresher
    }

    public func session(allowInteraction: Bool) async throws -> ClaudeSession {
        try Task.checkCancellation()
        let state = try await credentialState(allowInteraction: allowInteraction)
        if let fresh = state.fresh { return fresh }
        guard !state.expiredTokens.isEmpty else {
            throw CollectionError(
                kind: .externalSessionMissing,
                diagnosticCode: "claude.session.credentials-missing",
                recoveryAction: .signInSourceApp
            )
        }
        guard allowInteraction else { throw retryAuthenticationRequired("claude.session.expired") }

        if let renewalTask {
            return try await waitForRenewal(renewalTask)
        }
        try Task.checkCancellation()
        let expiredTokens = state.expiredTokens
        let task = Task { try await self.renew(previousTokens: expiredTokens) }
        renewalTask = task
        do {
            let result = try await waitForRenewal(task)
            renewalTask = nil
            return result
        } catch {
            renewalTask = nil
            throw error
        }
    }

    private func waitForRenewal(_ task: Task<ClaudeSession, Error>) async throws -> ClaudeSession {
        let session = try await task.value
        try Task.checkCancellation()
        return session
    }

    private func renew(previousTokens: Set<String>) async throws -> ClaudeSession {
        try await refresher.refresh()
        let state = try await credentialState(allowInteraction: true)
        guard let session = state.fresh else {
            if state.expiredTokens.isEmpty {
                throw CollectionError(
                    kind: .externalSessionMissing,
                    diagnosticCode: "claude.session.refresh.credentials-missing",
                    recoveryAction: .signInSourceApp
                )
            }
            throw authenticationRequired("claude.session.refresh.credentials-expired")
        }
        guard !previousTokens.contains(session.accessToken) else {
            throw authenticationRequired("claude.session.refresh.token-unchanged")
        }
        return session
    }

    private func credentialState(allowInteraction: Bool) async throws -> CredentialState {
        var expiredTokens: Set<String> = []
        if let data = try await credentials.readFile(),
           let session = try decodeClaudeSession(data) {
            let now = await clock.now()
            if session.expiresAt > now { return CredentialState(fresh: session, expiredTokens: []) }
            expiredTokens.insert(session.accessToken)
        }

        do {
            if let data = try await credentials.readKeychain(allowInteraction: allowInteraction),
               let session = try decodeClaudeSession(data) {
                let now = await clock.now()
                if session.expiresAt > now {
                    return CredentialState(fresh: session, expiredTokens: expiredTokens)
                }
                expiredTokens.insert(session.accessToken)
            }
        } catch let error as CollectionError where error.kind == .keychainUnavailable {
            throw CollectionError(
                kind: .keychainUnavailable,
                diagnosticCode: error.diagnosticCode,
                recoveryAction: .retry,
                retryAfter: error.retryAfter
            )
        }
        return CredentialState(fresh: nil, expiredTokens: expiredTokens)
    }
}

private struct CredentialState {
    let fresh: ClaudeSession?
    let expiredTokens: Set<String>
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

private func retryAuthenticationRequired(_ code: String) -> CollectionError {
    CollectionError(kind: .authenticationRejected, diagnosticCode: code, recoveryAction: .retry)
}

private func malformed(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
