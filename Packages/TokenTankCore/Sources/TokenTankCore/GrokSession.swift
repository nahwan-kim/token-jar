import CoreFoundation
import Foundation
import TokenTankDomain

public struct GrokSession: Sendable, Equatable {
    public let accessToken: String
    public let accountEmail: String?
    public let expiresAt: Date?

    public init(accessToken: String, accountEmail: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.accountEmail = accountEmail
        self.expiresAt = expiresAt
    }
}

/// One Grok CLI sign-in (one `auth.json` scope entry) and either its usable session or why not.
public struct GrokAccountRead: Sendable, Equatable {
    public static let defaultSourceID = "grok.cli"

    public let sourceID: String
    public let accountEmail: String?
    public let session: GrokSession?
    public let failure: CollectionError?

    public init(sourceID: String, accountEmail: String? = nil, session: GrokSession?, failure: CollectionError? = nil) {
        self.sourceID = sourceID
        self.accountEmail = accountEmail ?? session?.accountEmail
        self.session = session
        self.failure = failure
    }
}

public struct GrokAccountsRead: Sendable, Equatable {
    public let accounts: [GrokAccountRead]
    /// Whether this read ran the Grok CLI to let it renew its own session.
    public let ranCLIRefresh: Bool

    public init(accounts: [GrokAccountRead], ranCLIRefresh: Bool) {
        self.accounts = accounts
        self.ranCLIRefresh = ranCLIRefresh
    }
}

public protocol GrokSessionProviding: Sendable {
    func session(rejectedAccessToken: String?) async throws -> GrokSession
    /// Every Grok CLI sign-in. With `allowsCLIRefresh`, an expired or rejected session may run the
    /// Grok CLI once so it renews its own tokens; Token Jar itself never renews or writes them.
    func accounts(rejectedAccessTokens: Set<String>, allowsCLIRefresh: Bool) async throws -> GrokAccountsRead
}

public extension GrokSessionProviding {
    func accounts(rejectedAccessTokens: Set<String>, allowsCLIRefresh: Bool) async throws -> GrokAccountsRead {
        let session = try await session(rejectedAccessToken: rejectedAccessTokens.sorted().first)
        return GrokAccountsRead(
            accounts: [GrokAccountRead(sourceID: GrokAccountRead.defaultSourceID, session: session)],
            ranCLIRefresh: false
        )
    }
}

public struct NoGrokSessionProvider: GrokSessionProviding {
    public init() {}

    public func session(rejectedAccessToken: String?) async throws -> GrokSession {
        _ = rejectedAccessToken
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.session.disabled")
    }
}

/// Reads `~/.grok/auth.json` without modifying it. When a session is expired or was rejected,
/// the Grok CLI is run once (`grok models`) so the CLI renews under its own lock, then the
/// file is read again. Token Jar sends no refresh grant and never writes the file.
public actor GrokOAuthSessionProvider: GrokSessionProviding {
    private static let minimumValidity: TimeInterval = 60

    private let clock: any TokenTankClock
    private let store: any GrokAuthFileStoring
    private let refresher: any GrokAuthRefreshing

    public init(
        clock: any TokenTankClock,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.clock = clock
        self.store = GrokAuthFileStore(homeDirectory: homeDirectory)
        self.refresher = GrokCLIAuthRefresher(homeDirectory: homeDirectory)
    }

    init(clock: any TokenTankClock, store: any GrokAuthFileStoring, refresher: any GrokAuthRefreshing) {
        self.clock = clock
        self.store = store
        self.refresher = refresher
    }

    public func session(rejectedAccessToken: String?) async throws -> GrokSession {
        let read = try await accounts(
            rejectedAccessTokens: rejectedAccessToken.map { [$0] } ?? [],
            allowsCLIRefresh: true
        )
        guard let first = read.accounts.first else { throw sourceAuthenticationError("grok.session.token-missing") }
        if let session = first.session { return session }
        throw first.failure ?? sourceAuthenticationError("grok.session.token-missing")
    }

    public func accounts(rejectedAccessTokens: Set<String>, allowsCLIRefresh: Bool) async throws -> GrokAccountsRead {
        try Task.checkCancellation()
        var entries = try await validatedEntries()
        var now = await clock.now()
        guard allowsCLIRefresh,
              entries.contains(where: { !isUsable($0, now: now, rejected: rejectedAccessTokens) })
        else {
            return GrokAccountsRead(
                accounts: entries.map { read($0, now: now, rejected: rejectedAccessTokens, refreshFailure: nil) },
                ranCLIRefresh: false
            )
        }

        var refreshFailure: CollectionError?
        do {
            try await refresher.refresh()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError {
            refreshFailure = error
        } catch {
            refreshFailure = CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.cli-refresh.failed")
        }
        try Task.checkCancellation()
        entries = try await validatedEntries()
        now = await clock.now()
        return GrokAccountsRead(
            accounts: entries.map { read($0, now: now, rejected: rejectedAccessTokens, refreshFailure: refreshFailure) },
            ranCLIRefresh: true
        )
    }

    private struct Entry {
        let sourceID: String
        let userID: String?
        let session: GrokSession
    }

    private func validatedEntries() async throws -> [Entry] {
        let document = try await store.load()
        var entries: [Entry] = []
        var seenUsers: Set<String> = []
        var firstFailure: CollectionError?
        for (key, value) in document.entries {
            do {
                let entry = try decodedEntry(key: key, value: value)
                if let userID = entry.userID, !seenUsers.insert(userID).inserted { continue }
                entries.append(entry)
            } catch let error as CollectionError {
                firstFailure = firstFailure ?? error
            }
        }
        guard !entries.isEmpty else {
            throw firstFailure ?? sourceAuthenticationError("grok.session.token-missing")
        }
        return entries
    }

    private func isUsable(_ entry: Entry, now: Date, rejected: Set<String>) -> Bool {
        !rejected.contains(entry.session.accessToken)
            && entry.session.expiresAt.map { $0.timeIntervalSince(now) > Self.minimumValidity } != false
    }

    private func read(
        _ entry: Entry,
        now: Date,
        rejected: Set<String>,
        refreshFailure: CollectionError?
    ) -> GrokAccountRead {
        if isUsable(entry, now: now, rejected: rejected) {
            return GrokAccountRead(sourceID: entry.sourceID, session: entry.session)
        }
        // Expired or refused: the owner CLI renews it the next time it runs.
        let code = refreshFailure?.diagnosticCode ?? (rejected.contains(entry.session.accessToken)
            ? "grok.session.rejected"
            : "grok.session.expired")
        return GrokAccountRead(
            sourceID: entry.sourceID,
            accountEmail: entry.session.accountEmail,
            session: nil,
            failure: CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: code,
                recoveryAction: .runSourceCLI
            )
        )
    }

    private func decodedEntry(key: String, value: [String: Any]) throws -> Entry {
        guard key == "https://accounts.x.ai/sign-in" || isOfficialOIDC(key: key, entry: value) else {
            throw sourceAuthenticationError("grok.session.identity-invalid")
        }
        guard let token = value["key"] as? String, grokAccessTokenIsSafe(token) else {
            throw sourceAuthenticationError("grok.session.token-missing")
        }
        let expiresAt = expiryDate(value["expires_at"])
        if value["expires_at"] != nil, expiresAt == nil {
            throw malformedResponse("grok.session.invalid-expiry")
        }
        return Entry(
            sourceID: Self.sourceID(forScope: key),
            userID: nonempty(value["user_id"]),
            session: GrokSession(accessToken: token, accountEmail: nonempty(value["email"]), expiresAt: expiresAt)
        )
    }

    static func sourceID(forScope key: String) -> String {
        let prefix = "https://auth.x.ai::"
        guard key.hasPrefix(prefix) else { return "grok.sign-in" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let client = String(key.dropFirst(prefix.count)).lowercased()
        guard !client.isEmpty, client.count <= 64, client.allSatisfy(allowed.contains) else {
            return "grok.oidc.\(SHA256Hex.digest(client).prefix(8))"
        }
        return "grok.oidc.\(client)"
    }

    private func isOfficialOIDC(key: String, entry: [String: Any]) -> Bool {
        let prefix = "https://auth.x.ai::"
        guard key.hasPrefix(prefix),
              entry["auth_mode"] as? String == "oidc",
              entry["oidc_issuer"] as? String == "https://auth.x.ai",
              let clientID = nonempty(entry["oidc_client_id"]),
              clientID == String(key.dropFirst(prefix.count))
        else { return false }
        return true
    }
}

private func nonempty(_ value: Any?) -> String? {
    guard let value = value as? String,
          value == value.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    return value
}

private func expiryDate(_ value: Any?) -> Date? {
    let raw: Double
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        raw = number.doubleValue
    } else if let string = value as? String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        guard let number = Double(string) else { return nil }
        raw = number
    } else {
        return nil
    }
    guard raw.isFinite, raw > 0 else { return nil }
    let seconds = raw >= 100_000_000_000 ? raw / 1_000 : raw
    guard seconds <= Date.distantFuture.timeIntervalSince1970 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

private func sourceAuthenticationError(_ code: String) -> CollectionError {
    CollectionError(kind: .authenticationRejected, diagnosticCode: code, recoveryAction: .signInSourceApp)
}

private func malformedResponse(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
