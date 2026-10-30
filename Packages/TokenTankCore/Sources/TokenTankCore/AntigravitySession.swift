import Darwin
import Foundation
import TokenTankDomain

/// The only Google Code Assist requests Token Jar sends for Antigravity, shared by the adapter
/// and the network allowlist.
public enum AntigravityRequestPolicy {
    public static let quotaSummaryURL = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    )!
    public static let loadCodeAssistURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    )!
    public static let loadCodeAssistBody = Data(
        #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8
    )
    public static let maximumBodyBytes = 512
    public static let timeout: TimeInterval = 15
    #if arch(arm64)
    public static let userAgent = "antigravity/hub/2.9.1 darwin/arm64"
    #else
    public static let userAgent = "antigravity/hub/2.9.1 darwin/amd64"
    #endif

    /// `{"project":"<id>"}`, or `{}` when CLIProxyAPI has not stored a project.
    public static func quotaSummaryBody(projectID: String?) -> Data {
        guard let projectID, let data = try? JSONSerialization.data(
            withJSONObject: ["project": projectID],
            options: [.sortedKeys]
        ) else { return Data("{}".utf8) }
        return data
    }

    /// Exactly a body `quotaSummaryBody` builds: `{}` or one valid project ID.
    public static func isQuotaSummaryBody(_ body: Data) -> Bool {
        if body == quotaSummaryBody(projectID: nil) { return true }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object.count == 1,
              let project = object["project"] as? String,
              antigravityProjectID(project) != nil
        else { return false }
        return body == quotaSummaryBody(projectID: project)
    }
}

public struct AntigravitySession: Sendable, Equatable {
    public let accessToken: String
    public let accountEmail: String?
    public let projectID: String?
    public let expiresAt: Date?

    public init(accessToken: String, accountEmail: String? = nil, projectID: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.accountEmail = accountEmail
        self.projectID = projectID
        self.expiresAt = expiresAt
    }
}

/// One Antigravity sign-in (one CLIProxyAPI auth file) and either its usable session or why not.
public struct AntigravityAccountRead: Sendable, Equatable {
    public let sourceID: String
    public let accountEmail: String?
    public let session: AntigravitySession?
    public let failure: CollectionError?

    public init(
        sourceID: String,
        accountEmail: String? = nil,
        session: AntigravitySession?,
        failure: CollectionError? = nil
    ) {
        self.sourceID = sourceID
        self.accountEmail = accountEmail
        self.session = session
        self.failure = failure
    }
}

public protocol AntigravitySessionProviding: Sendable {
    /// Every enabled Antigravity sign-in, in a stable order.
    func accounts() async throws -> [AntigravityAccountRead]
}

public struct NoAntigravitySessionProvider: AntigravitySessionProviding {
    public init() {}

    public func accounts() async throws -> [AntigravityAccountRead] {
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.session.disabled")
    }
}

/// Reads the Antigravity OAuth files CLIProxyAPI keeps (`~/.cli-proxy-api/auths/antigravity-*.json`,
/// or the default auth directory `~/.cli-proxy-api`) without modifying them. CLIProxyAPI renews each
/// access token 30 minutes before it expires, so Token Jar sends no refresh grant and never writes.
public actor CLIProxyAntigravitySessionProvider: AntigravitySessionProviding {
    private static let minimumValidity: TimeInterval = 60

    private let clock: any TokenTankClock
    private let store: any AntigravityAuthFileStoring

    public init(
        clock: any TokenTankClock,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.clock = clock
        self.store = AntigravityAuthFileStore(homeDirectory: homeDirectory)
    }

    init(clock: any TokenTankClock, store: any AntigravityAuthFileStoring) {
        self.clock = clock
        self.store = store
    }

    public func accounts() async throws -> [AntigravityAccountRead] {
        try Task.checkCancellation()
        let files = try await store.load()
        let now = await clock.now()
        var reads: [AntigravityAccountRead] = []
        var indexBySourceID: [String: Int] = [:]
        var firstFailure: CollectionError?
        for file in files {
            do {
                guard let read = try Self.read(file.root, now: now) else { continue }
                if let index = indexBySourceID[read.sourceID] {
                    // The same sign-in in both directories: a usable copy beats an expired one.
                    if reads[index].session == nil, read.session != nil { reads[index] = read }
                } else {
                    indexBySourceID[read.sourceID] = reads.count
                    reads.append(read)
                }
            } catch let error as CollectionError {
                firstFailure = firstFailure ?? error
            }
        }
        guard !reads.isEmpty else {
            throw firstFailure ?? missingSession()
        }
        return reads
    }

    /// `nil` for a file the user disabled in CLIProxyAPI.
    static func read(_ root: [String: Any], now: Date) throws -> AntigravityAccountRead? {
        guard root["type"] as? String == "antigravity" else {
            throw malformed("antigravity.session.type-invalid")
        }
        if root["disabled"] as? Bool == true { return nil }
        guard let token = root["access_token"] as? String, antigravityAccessTokenIsSafe(token) else {
            throw missingSession()
        }
        let email = ProviderSnapshot.validatedAccountEmail(root["email"] as? String)
        let projectID = (root["project_id"] as? String).flatMap(antigravityProjectID)
        let expiresAt = try expiryDate(root)
        let sourceID = Self.sourceID(email: email, refreshToken: root["refresh_token"] as? String, accessToken: token)
        if let expiresAt, expiresAt.timeIntervalSince(now) <= Self.minimumValidity {
            // CLIProxyAPI renews ahead of expiry while it runs; an expired file means it is stopped.
            return AntigravityAccountRead(
                sourceID: sourceID,
                accountEmail: email,
                session: nil,
                failure: CollectionError(
                    kind: .sourceUnavailable,
                    diagnosticCode: "antigravity.session.expired",
                    recoveryAction: .runSourceCLI
                )
            )
        }
        return AntigravityAccountRead(
            sourceID: sourceID,
            accountEmail: email,
            session: AntigravitySession(
                accessToken: token,
                accountEmail: email,
                projectID: projectID,
                expiresAt: expiresAt
            )
        )
    }

    /// Stable per sign-in: the account email, else a digest of the long-lived refresh token.
    static func sourceID(email: String?, refreshToken: String?, accessToken: String) -> String {
        if let email {
            return "antigravity.\(SHA256Hex.digest(email.lowercased()).prefix(12))"
        }
        return "antigravity.\(SHA256Hex.digest(refreshToken ?? accessToken).prefix(12))"
    }

    /// CLIProxyAPI writes `expired` (RFC 3339) plus `timestamp` (ms) and `expires_in` (s). A present
    /// but unreadable expiry fails closed instead of passing for a token without one.
    private static func expiryDate(_ root: [String: Any]) throws -> Date? {
        if let value = root["expired"], !(value is NSNull) {
            guard let raw = value as? String, let date = antigravityRFC3339Date(raw) else {
                throw malformed("antigravity.session.expiry-invalid")
            }
            return date
        }
        guard let expiresIn = root["expires_in"], !(expiresIn is NSNull) else { return nil }
        guard let seconds = antigravityPositiveNumber(expiresIn),
              let timestamp = antigravityPositiveNumber(root["timestamp"])
        else { throw malformed("antigravity.session.expiry-invalid") }
        return Date(timeIntervalSince1970: timestamp / 1_000 + seconds)
    }
}

struct AntigravityAuthFile: @unchecked Sendable {
    let name: String
    let root: [String: Any]
}

protocol AntigravityAuthFileStoring: Sendable {
    func load() async throws -> [AntigravityAuthFile]
}

/// Read-only access to CLIProxyAPI's `antigravity-*.json` files. CLIProxyAPI owns and rewrites them.
final class AntigravityAuthFileStore: AntigravityAuthFileStoring, @unchecked Sendable {
    private static let maximumBytes = 64 * 1024
    /// One budget across both directories.
    private static let maximumFiles = 32
    /// CLIProxyAPI's default auth directory, and the `auths` subdirectory a typical install configures.
    static let baseDirectory = ".cli-proxy-api"
    static let authDirectory = "auths"
    private let homeDirectory: URL

    init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    func load() async throws -> [AntigravityAuthFile] {
        let home = open(homeDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard home >= 0 else { throw unsafe("antigravity.session.home-unsafe") }
        defer { close(home) }
        try validateDirectory(home, code: "antigravity.session.home-unsafe")

        // Each component opens from its verified parent without following a link.
        guard let base = try openDirectory(Self.baseDirectory, in: home) else { throw missingFile() }
        defer { close(base) }
        var files: [AntigravityAuthFile] = []
        var firstFailure: CollectionError?
        let auths: Int32?
        do {
            auths = try openDirectory(Self.authDirectory, in: base)
        } catch let error as CollectionError {
            auths = nil
            firstFailure = error
        }
        defer { if let auths { close(auths) } }

        var budget = Self.maximumFiles
        for directory in [auths, base].compactMap({ $0 }) {
            do {
                for name in try fileNames(in: directory).prefix(budget) {
                    budget -= 1
                    do {
                        files.append(AntigravityAuthFile(name: name, root: try load(name, from: directory)))
                    } catch let error as CollectionError {
                        firstFailure = firstFailure ?? error
                    }
                }
            } catch let error as CollectionError {
                firstFailure = firstFailure ?? error
            }
        }
        guard !files.isEmpty else { throw firstFailure ?? missingFile() }
        return files
    }

    /// A verified child directory descriptor, or `nil` when the directory does not exist.
    private func openDirectory(_ name: String, in parent: Int32) throws -> Int32? {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw unsafe("antigravity.session.directory-unsafe")
        }
        do {
            try validateDirectory(descriptor, code: "antigravity.session.directory-unsafe")
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    /// Lists the opened directory itself, so the names match the descriptor files are read from.
    private func fileNames(in directory: Int32) throws -> [String] {
        let listing = dup(directory)
        guard listing >= 0 else { throw unavailable("antigravity.session.directory-list-failed") }
        guard let stream = fdopendir(listing) else {
            close(listing)
            throw unavailable("antigravity.session.directory-list-failed")
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            if name.hasPrefix("antigravity-"), name.hasSuffix(".json"), name.utf8.count <= 255 {
                names.append(name)
            }
        }
        return names.sorted()
    }

    private func validateDirectory(_ descriptor: Int32, code: String) throws {
        let info = try metadata(descriptor)
        guard info.type == .typeDirectory, info.owner == UInt64(geteuid()),
              info.permissions & 0o022 == 0 else { throw unsafe(code) }
    }

    private func load(_ name: String, from directory: Int32) throws -> [String: Any] {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw unsafe("antigravity.session.auth-file.open-denied") }
        defer { close(descriptor) }
        let info = try metadata(descriptor)
        guard info.type == .typeRegular,
              info.owner == UInt64(geteuid()),
              info.links == 1,
              info.permissions & 0o077 == 0,
              info.size <= Self.maximumBytes
        else { throw unsafe("antigravity.session.auth-file.unsafe") }

        var data = Data()
        data.reserveCapacity(Int(info.size))
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw unavailable("antigravity.session.auth-file.read-failed")
            }
            guard data.count + count <= Self.maximumBytes else {
                throw unsafe("antigravity.session.auth-file.oversize")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw malformed("antigravity.session.auth-file.invalid-json")
        }
        return root
    }

    private struct FileMetadata {
        let type: FileAttributeType
        let owner: UInt64
        let links: UInt64
        let permissions: UInt64
        let size: UInt64
    }

    private func metadata(_ descriptor: Int32) throws -> FileMetadata {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: "/dev/fd/\(descriptor)")
        } catch {
            throw unavailable("antigravity.session.auth-file.metadata-failed")
        }
        guard let type = attributes[.type] as? FileAttributeType,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let links = attributes[.referenceCount] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              let size = attributes[.size] as? NSNumber else {
            throw unsafe("antigravity.session.auth-file.metadata-invalid")
        }
        return FileMetadata(
            type: type, owner: owner.uint64Value, links: links.uint64Value,
            permissions: permissions.uint64Value, size: size.uint64Value
        )
    }
}

private func antigravityRFC3339Date(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: raw)
}

/// A finite positive JSON number; booleans and strings are not numbers here.
private func antigravityPositiveNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    return double.isFinite && double > 0 ? double : nil
}

/// A Google OAuth access token usable only as a bearer value.
public func antigravityAccessTokenIsSafe(_ token: String) -> Bool {
    guard !token.isEmpty, token.utf8.count <= 8_192 else { return false }
    return token.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value < 0x7f }
}

/// A Google Cloud project ID (`aicode-consumers`, `my-project-123`), else `nil`.
private func antigravityProjectID(_ raw: String) -> String? {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-:.")
    guard !raw.isEmpty, raw.count <= 128, raw.allSatisfy(allowed.contains) else { return nil }
    return raw
}

private func missingSession() -> CollectionError {
    CollectionError(
        kind: .externalSessionMissing,
        diagnosticCode: "antigravity.session.token-missing",
        recoveryAction: .signInSourceApp
    )
}

private func missingFile() -> CollectionError {
    CollectionError(
        kind: .externalSessionMissing,
        diagnosticCode: "antigravity.session.auth-file.missing",
        recoveryAction: .signInSourceApp
    )
}

private func unsafe(_ code: String) -> CollectionError {
    CollectionError(kind: .unsafePath, diagnosticCode: code)
}

private func malformed(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}

private func unavailable(_ code: String) -> CollectionError {
    CollectionError(kind: .sourceUnavailable, diagnosticCode: code)
}
