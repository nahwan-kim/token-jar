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

public protocol GrokSessionProviding: Sendable {
    func session(rejectedAccessToken: String?) async throws -> GrokSession
}

public struct NoGrokSessionProvider: GrokSessionProviding {
    public init() {}

    public func session(rejectedAccessToken: String?) async throws -> GrokSession {
        _ = rejectedAccessToken
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.session.disabled")
    }
}

public actor GrokOAuthSessionProvider: GrokSessionProviding {
    private let network: any NetworkClient
    private let clock: any TokenTankClock
    private let store: any GrokAuthFileStoring
    private var renewalTask: Task<GrokSession, Error>?

    public init(
        network: any NetworkClient,
        clock: any TokenTankClock,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.network = network
        self.clock = clock
        self.store = GrokAuthFileStore(homeDirectory: homeDirectory)
    }

    init(network: any NetworkClient, clock: any TokenTankClock, store: any GrokAuthFileStoring) {
        self.network = network
        self.clock = clock
        self.store = store
    }

    public func session(rejectedAccessToken: String?) async throws -> GrokSession {
        try Task.checkCancellation()
        let now = await clock.now()
        let first = try await store.load()
        let firstSession = try decodedSession(first)

        if rejectedAccessToken != firstSession.accessToken,
           firstSession.expiresAt.map({ $0.timeIntervalSince(now) > 60 }) != false {
            return firstSession
        }
        if let renewalTask {
            return try await waitForRenewal(renewalTask)
        }
        guard isRefreshable(first) else {
            throw sourceAuthenticationError("grok.session.refresh-unavailable")
        }

        try Task.checkCancellation()
        let task = Task { try await self.renew(rejectedAccessToken: rejectedAccessToken) }
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

    private func waitForRenewal(_ task: Task<GrokSession, Error>) async throws -> GrokSession {
        // Once renewal starts, let its bounded transaction settle. Cancelling any
        // observer must not abort another observer or discard a rotated token.
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func renew(rejectedAccessToken: String?) async throws -> GrokSession {
        // Hold the cross-process lock for the entire read/refresh/persist transaction.
        let lock = try await store.acquireRenewalLock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        let document = try await store.load()
        let now = await clock.now()
        let existing = try decodedSession(document)
        if rejectedAccessToken != existing.accessToken,
           existing.expiresAt.map({ $0.timeIntervalSince(now) > 60 }) != false {
            return existing
        }
        guard isRefreshable(document) else {
            throw sourceAuthenticationError("grok.session.refresh-unavailable")
        }
        let entry = document.selectedEntry
        guard let clientID = nonempty(entry["oidc_client_id"]),
              let refreshToken = nonempty(entry["refresh_token"]),
              refreshTokenIsSafe(refreshToken)
        else { throw sourceAuthenticationError("grok.session.refresh-unavailable") }

        let response: NetworkResponse
        do {
            try Task.checkCancellation()
            response = try await network.send(NetworkRequest(
                providerID: .grok,
                url: URL(string: "https://auth.x.ai/oauth2/token")!,
                method: .post,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                ],
                body: formBody([
                    ("grant_type", "refresh_token"),
                    ("client_id", clientID),
                    ("refresh_token", refreshToken),
                ]),
                timeout: 15
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError where error.kind == .cancelled {
            throw CancellationError()
        } catch let error as CollectionError {
            throw error
        } catch {
            throw CollectionError(kind: .transientNetwork, diagnosticCode: "grok.session.refresh.network-failed")
        }

        if response.statusCode == 429 {
            throw CollectionError(
                kind: .rateLimited,
                diagnosticCode: "grok.session.refresh.rate-limited",
                retryAfter: retryAfter(response.header("Retry-After"), now: now)
            )
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            return try await recoverAfterRejectedGrant(document)
        }
        guard (200..<300).contains(response.statusCode) else {
            let errorCode = oauthError(in: response.body)
            if response.statusCode == 400,
               errorCode == "invalid_grant" || errorCode == "invalid_client" {
                return try await recoverAfterRejectedGrant(document)
            }
            throw CollectionError(
                kind: .transientNetwork,
                diagnosticCode: "grok.session.refresh.http-failed"
            )
        }
        guard response.body.count <= 64 * 1024 else {
            throw malformedResponse("grok.session.refresh.response-oversize")
        }
        let token = try decodeTokenResponse(response.body, now: now)
        var replacement = entry
        replacement["key"] = token.accessToken
        if let rotatedRefreshToken = token.refreshToken {
            replacement["refresh_token"] = rotatedRefreshToken
        }
        let expiry = now.addingTimeInterval(token.expiresIn)
        replacement["expires_at"] = encodedExpiry(expiry, like: entry["expires_at"])

        // Do not inspect cancellation here: a successful rotation must be durably recorded first.
        do {
            let saved = try await store.replacingEntry(
                in: document,
                mutation: GrokAuthFileMutation(expectedEntry: entry, replacement: replacement)
            )
            return try decodedSession(saved)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError where error.diagnosticCode == "grok.session.auth-file.conflict" {
            let current = try await store.load()
            let session = try decodedSession(current)
            let recoveredAt = await clock.now()
            guard session.accessToken != (entry["key"] as? String),
                  session.expiresAt.map({ $0.timeIntervalSince(recoveredAt) > 0 }) != false
            else { throw error }
            return session
        }
    }

    private func recoverAfterRejectedGrant(_ original: GrokAuthFileDocument) async throws -> GrokSession {
        let current = try await store.load()
        let session = try decodedSession(current)
        let recoveredAt = await clock.now()
        if current.selectedKey != original.selectedKey
            || !NSDictionary(dictionary: current.selectedEntry).isEqual(to: original.selectedEntry) {
            guard session.expiresAt.map({ $0.timeIntervalSince(recoveredAt) > 0 }) != false else {
                throw CollectionError(
                    kind: .sourceUnavailable,
                    diagnosticCode: "grok.session.refresh.credentials-changed-expired"
                )
            }
            return session
        }
        throw sourceAuthenticationError("grok.session.refresh.authentication-rejected")
    }

    private func decodedSession(_ document: GrokAuthFileDocument) throws -> GrokSession {
        guard document.selectedKey == "https://accounts.x.ai/sign-in" || isOfficialOIDC(document) else {
            throw sourceAuthenticationError("grok.session.identity-invalid")
        }
        guard let token = document.selectedEntry["key"] as? String, grokAccessTokenIsSafe(token) else {
            throw sourceAuthenticationError("grok.session.token-missing")
        }
        let expiresAt = expiryDate(document.selectedEntry["expires_at"])
        if document.selectedEntry["expires_at"] != nil, expiresAt == nil {
            throw malformedResponse("grok.session.invalid-expiry")
        }
        return GrokSession(
            accessToken: token,
            accountEmail: nonempty(document.selectedEntry["email"]),
            expiresAt: expiresAt
        )
    }

    private func isOfficialOIDC(_ document: GrokAuthFileDocument) -> Bool {
        let prefix = "https://auth.x.ai::"
        guard document.selectedKey.hasPrefix(prefix),
              document.selectedEntry["auth_mode"] as? String == "oidc",
              document.selectedEntry["oidc_issuer"] as? String == "https://auth.x.ai",
              let clientID = nonempty(document.selectedEntry["oidc_client_id"]),
              clientID == String(document.selectedKey.dropFirst(prefix.count))
        else { return false }
        return true
    }

    private func isRefreshable(_ document: GrokAuthFileDocument) -> Bool {
        guard isOfficialOIDC(document),
              let refreshToken = nonempty(document.selectedEntry["refresh_token"]) else { return false }
        return refreshTokenIsSafe(refreshToken)
    }
}

private struct GrokTokenResponse {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
}

private func decodeTokenResponse(_ data: Data, now: Date) throws -> GrokTokenResponse {
    let object: [String: Any]
    do {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw malformedResponse("grok.session.refresh.invalid-json")
        }
        object = decoded
    } catch let error as CollectionError {
        throw error
    } catch {
        throw malformedResponse("grok.session.refresh.invalid-json")
    }
    guard let accessToken = nonempty(object["access_token"]), grokAccessTokenIsSafe(accessToken),
          let tokenType = nonempty(object["token_type"]), tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
          let expires = object["expires_in"] as? NSNumber,
          CFGetTypeID(expires) != CFBooleanGetTypeID(),
          expires.doubleValue.isFinite,
          expires.doubleValue > 0,
          expires.doubleValue <= Date.distantFuture.timeIntervalSince(now)
    else { throw malformedResponse("grok.session.refresh.malformed-response") }

    var refreshToken: String?
    if object.keys.contains("refresh_token") {
        guard let candidate = nonempty(object["refresh_token"]), refreshTokenIsSafe(candidate) else {
            throw malformedResponse("grok.session.refresh.malformed-response")
        }
        refreshToken = candidate
    }
    return GrokTokenResponse(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expires.doubleValue)
}

private func nonempty(_ value: Any?) -> String? {
    guard let value = value as? String,
          value == value.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    return value
}

private func refreshTokenIsSafe(_ token: String) -> Bool {
    !token.isEmpty
        && token.utf8.count <= 16_384
        && token.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value != 0x7f }
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

private func encodedExpiry(_ date: Date, like original: Any?) -> Any {
    if let number = original as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        return number.doubleValue >= 100_000_000_000
            ? Int64((date.timeIntervalSince1970 * 1_000).rounded())
            : Int64(date.timeIntervalSince1970.rounded())
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func formBody(_ fields: [(String, String)]) -> Data {
    Data(fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
}

private func formEncode(_ value: String) -> String {
    var result = ""
    for byte in value.utf8 {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2A, 0x2D, 0x2E, 0x5F:
            result.append(Character(UnicodeScalar(byte)))
        case 0x20:
            result.append("+")
        default:
            result += String(format: "%%%02X", byte)
        }
    }
    return result
}

private func oauthError(in data: Data) -> String? {
    guard data.count <= 64 * 1024,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["error"] as? String
}

private func retryAfter(_ value: String?, now: Date) -> Date? {
    guard let value else { return nil }
    if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
        return now.addingTimeInterval(seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    return formatter.date(from: value)
}

private func sourceAuthenticationError(_ code: String) -> CollectionError {
    CollectionError(kind: .authenticationRejected, diagnosticCode: code, recoveryAction: .signInSourceApp)
}

private func malformedResponse(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
