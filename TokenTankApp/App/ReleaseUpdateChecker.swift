import Foundation

// The release checker deliberately stops at release metadata. It never downloads,
// installs, or replaces an application bundle.
enum ReleaseUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(version: String, url: URL)
    case failed
}

enum ReleaseUpdateDefaults {
    static let automaticChecksEnabledKey = "automaticallyChecksForUpdates"
    static let lastAttemptDateKey = "releaseUpdate.lastAttemptAt"
    static let interval: TimeInterval = 24 * 60 * 60
}

struct ReleaseUpdateHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

protocol ReleaseUpdateTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ReleaseUpdateHTTPResponse
}

struct ReleaseUpdateAvailability: Equatable, Sendable {
    let version: String
    let url: URL
}

enum ReleaseUpdateResult: Equatable, Sendable {
    case notApplicable
    case upToDate
    case available(ReleaseUpdateAvailability)
}

enum ReleaseUpdateError: Error, Equatable, Sendable {
    case invalidRequest
    case malformedResponse
    case httpFailure(statusCode: Int)
    case responseTooLarge
    case nonHTTPResponse
}

struct ReleaseVersion: Comparable, Equatable, Sendable {
    enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(String)
        case text(String)
    }

    let major: String
    let minor: String
    let patch: String
    let prerelease: [PrereleaseIdentifier]
    let buildMetadata: [String]

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        var value = rawValue
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        guard !value.isEmpty else { return nil }

        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        let beforeBuild = String(buildParts[0])
        let parsedBuild: [String]
        if buildParts.count == 2 {
            parsedBuild = Self.identifiers(String(buildParts[1]))
            guard !parsedBuild.isEmpty else { return nil }
        } else {
            parsedBuild = []
        }
        guard parsedBuild.allSatisfy(Self.isValidIdentifier) else { return nil }

        let prereleaseParts = beforeBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard prereleaseParts.count <= 2 else { return nil }
        let core = String(prereleaseParts[0])
        let parsedPrerelease: [PrereleaseIdentifier]
        if prereleaseParts.count == 2 {
            let identifiers = Self.identifiers(String(prereleaseParts[1]))
            guard !identifiers.isEmpty, identifiers.allSatisfy(Self.isValidIdentifier) else { return nil }
            guard identifiers.allSatisfy({ identifier in
                !Self.isNumeric(identifier) || identifier == "0" || !identifier.hasPrefix("0")
            }) else { return nil }
            parsedPrerelease = identifiers.map { identifier in
                Self.isNumeric(identifier) ? .numeric(identifier) : .text(identifier)
            }
        } else {
            parsedPrerelease = []
        }

        let components = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(components.count), components.allSatisfy(Self.isNumeric) else {
            return nil
        }
        guard components.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }) else { return nil }

        major = components[0]
        minor = components[1]
        patch = components.count == 3 ? components[2] : "0"
        prerelease = parsedPrerelease
        buildMetadata = parsedBuild
    }

    var isDevelopmentVersion: Bool {
        let developmentMarkers: Set<String> = [
            "dev", "debug", "development", "local", "nightly", "snapshot", "test"
        ]
        return prerelease.contains {
            switch $0 {
            case let .numeric(value):
                developmentMarkers.contains(value.lowercased())
            case let .text(value):
                developmentMarkers.contains(value.lowercased())
            }
        } || buildMetadata.contains { developmentMarkers.contains($0.lowercased()) }
    }

    private static func identifiers(_ value: String) -> [String] {
        value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
        }
    }

    private static func compareNumeric(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for (left, right) in [(lhs.major, rhs.major), (lhs.minor, rhs.minor), (lhs.patch, rhs.patch)] {
            switch compareNumeric(left, right) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }

        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            switch (left, right) {
            case let (.numeric(leftValue), .numeric(rightValue)):
                switch compareNumeric(leftValue, rightValue) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            case (.numeric, .text):
                return true
            case (.text, .numeric):
                return false
            case let (.text(leftValue), .text(rightValue)):
                if leftValue != rightValue { return leftValue < rightValue }
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }
}

struct GitHubReleaseAPIClient: Sendable {
    static let officialOwner = "nahwan-kim"
    static let officialRepository = "token-jar"
    static let endpoint = URL(string: "https://api.github.com/repos/nahwan-kim/token-jar/releases")!
    static let maximumResponseBytes = 1 * 1024 * 1024
    static let requestTimeout: TimeInterval = 15

    private let transport: any ReleaseUpdateTransport

    init(transport: any ReleaseUpdateTransport = URLSessionReleaseUpdateTransport()) {
        self.transport = transport
    }

    func fetchReleases() async throws -> [GitHubRelease] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Token Jar", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let response = try await transport.send(request)
        guard response.body.count <= Self.maximumResponseBytes else {
            throw ReleaseUpdateError.responseTooLarge
        }
        guard response.statusCode == 200 else {
            throw ReleaseUpdateError.httpFailure(statusCode: response.statusCode)
        }

        let payloads: [GitHubReleasePayload]
        do {
            payloads = try JSONDecoder().decode([GitHubReleasePayload].self, from: response.body)
        } catch {
            throw ReleaseUpdateError.malformedResponse
        }

        return payloads.compactMap { payload in
            guard !payload.draft, let version = ReleaseVersion(payload.tagName) else { return nil }
            guard let url = Self.releaseURL(for: payload.tagName) else { return nil }
            return GitHubRelease(tag: payload.tagName, version: version, url: url)
        }
    }

    static func releaseURL(for tag: String) -> URL? {
        guard ReleaseVersion(tag) != nil else { return nil }
        let encodedTag = tag.utf8.map { byte -> String in
            switch byte {
            case 48...57, 65...90, 97...122, 45, 46, 126:
                return String(decoding: [byte], as: UTF8.self)
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
        guard let url = URL(string: "https://github.com/\(officialOwner)/\(officialRepository)/releases/tag/\(encodedTag)") else {
            return nil
        }
        guard
            url.scheme == "https",
            url.host == "github.com",
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else { return nil }
        return url
    }

    private struct GitHubReleasePayload: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
        }
    }
}

struct GitHubRelease: Equatable, Sendable {
    let tag: String
    let version: ReleaseVersion
    let url: URL
}

struct ReleaseUpdateChecker: Sendable {
    let client: GitHubReleaseAPIClient
    let currentVersion: ReleaseVersion?

    init(client: GitHubReleaseAPIClient = GitHubReleaseAPIClient(), currentVersion: String? = nil) {
        self.client = client
        let value = currentVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        if let value, let parsed = ReleaseVersion(value), !parsed.isDevelopmentVersion {
            self.currentVersion = parsed
        } else {
            self.currentVersion = nil
        }
    }

    init(
        transport: any ReleaseUpdateTransport,
        currentVersion: String? = nil
    ) {
        self.init(
            client: GitHubReleaseAPIClient(transport: transport),
            currentVersion: currentVersion
        )
    }

    var isApplicable: Bool { currentVersion != nil }

    func check() async throws -> ReleaseUpdateResult {
        guard let currentVersion else { return .notApplicable }
        try Task.checkCancellation()
        let releases = try await client.fetchReleases()
        try Task.checkCancellation()
        guard let newest = releases.max(by: { $0.version < $1.version }) else {
            return .upToDate
        }
        guard newest.version > currentVersion else { return .upToDate }
        return .available(
            ReleaseUpdateAvailability(version: newest.tag, url: newest.url)
        )
    }
}

actor URLSessionReleaseUpdateTransport: ReleaseUpdateTransport {
    private let session: URLSession
    private let maximumResponseBytes: Int

    init(maximumResponseBytes: Int = GitHubReleaseAPIClient.maximumResponseBytes) {
        precondition(maximumResponseBytes > 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = GitHubReleaseAPIClient.requestTimeout
        configuration.timeoutIntervalForResource = GitHubReleaseAPIClient.requestTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        self.maximumResponseBytes = maximumResponseBytes
    }

    init(session: URLSession, maximumResponseBytes: Int = GitHubReleaseAPIClient.maximumResponseBytes) {
        precondition(maximumResponseBytes > 0)
        self.session = session
        self.maximumResponseBytes = maximumResponseBytes
    }

    func send(_ request: URLRequest) async throws -> ReleaseUpdateHTTPResponse {
        guard
            request.url == GitHubReleaseAPIClient.endpoint,
            request.httpMethod?.uppercased() == "GET",
            request.httpBody == nil,
            request.httpBodyStream == nil,
            request.timeoutInterval > 0,
            request.timeoutInterval <= GitHubReleaseAPIClient.requestTimeout
        else { throw ReleaseUpdateError.invalidRequest }

        let headers = request.allHTTPHeaderFields ?? [:]
        let allowedHeaders: Set<String> = ["accept", "user-agent", "x-github-api-version"]
        guard headers.keys.allSatisfy({ allowedHeaders.contains($0.lowercased()) }) else {
            throw ReleaseUpdateError.invalidRequest
        }

        var sanitizedRequest = request
        sanitizedRequest.httpShouldHandleCookies = false
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "Cookie")

        do {
            let (bytes, response) = try await session.bytes(
                for: sanitizedRequest,
                delegate: ReleaseNoRedirectURLSessionDelegate()
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ReleaseUpdateError.nonHTTPResponse
            }
            if response.expectedContentLength > Int64(maximumResponseBytes) {
                throw ReleaseUpdateError.responseTooLarge
            }

            var body = Data()
            if response.expectedContentLength > 0 {
                body.reserveCapacity(min(Int(response.expectedContentLength), maximumResponseBytes))
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < maximumResponseBytes else {
                    throw ReleaseUpdateError.responseTooLarge
                }
                body.append(byte)
            }
            return ReleaseUpdateHTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, item in
                    if let name = item.key as? String {
                        result[name] = String(describing: item.value)
                    }
                },
                body: body
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as ReleaseUpdateError {
            throw error
        } catch {
            throw error
        }
    }
}

private final class ReleaseNoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
