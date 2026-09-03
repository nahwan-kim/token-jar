import Foundation
import TokenTankDomain

public protocol ProviderAdapter: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var defaultAbbreviation: String { get }
    var sourceDescriptor: ProviderSourceDescriptor { get }

    func probeAvailability(context: CollectionContext) async -> ProviderAvailability
    func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot
}

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

public struct NetworkRequest: Sendable {
    public let providerID: ProviderID
    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?
    public let timeout: TimeInterval

    public init(
        providerID: ProviderID,
        url: URL,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) {
        self.providerID = providerID
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct NetworkResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol NetworkClient: Sendable {
    func send(_ request: NetworkRequest) async throws -> NetworkResponse
}

public struct CredentialID: Hashable, Sendable {
    public let providerID: ProviderID
    public let name: String

    public init(providerID: ProviderID, name: String) {
        self.providerID = providerID
        self.name = name
    }
}

public protocol AppCredentialStore: Sendable {
    func read(_ id: CredentialID) async throws -> String?
    func write(_ value: String, for id: CredentialID) async throws
    func delete(_ id: CredentialID) async throws
}

public enum ExternalLocationRoot: String, Sendable {
    case home
}

public struct ExternalFileRequest: Hashable, Sendable {
    public let providerID: ProviderID
    public let root: ExternalLocationRoot
    public let relativePath: String
    public let maximumBytes: Int

    public init(
        providerID: ProviderID,
        root: ExternalLocationRoot = .home,
        relativePath: String,
        maximumBytes: Int = 4 * 1024 * 1024
    ) {
        self.providerID = providerID
        self.root = root
        self.relativePath = relativePath
        self.maximumBytes = maximumBytes
    }
}

public protocol ExternalSessionReader: Sendable {
    func exists(_ request: ExternalFileRequest) async -> Bool
    func read(_ request: ExternalFileRequest) async throws -> Data
}

public protocol ReadOnlySQLiteReader: Sendable {
    func values(
        in request: ExternalFileRequest,
        table: String,
        keyColumn: String,
        valueColumn: String,
        keys: [String]
    ) async throws -> [String: String]
}

public protocol CodexAccountUsageReader: Sendable {
    func readRateLimits() async throws -> Data
}
public protocol DoubaoPlanUsageReader: Sendable {
    func readPlanUsage() async throws -> Data
}

public protocol TokenTankClock: Sendable {
    func now() async -> Date
    func monotonicNow() async -> Duration
    func sleep(for duration: Duration) async throws
}

public enum DiagnosticLevel: String, Sendable {
    case debug
    case info
    case notice
    case error
}

public struct DiagnosticEvent: Sendable {
    public let level: DiagnosticLevel
    public let category: String
    public let code: String
    public let providerID: ProviderID?
    public let duration: Duration?
    public let correlationID: UUID?

    public init(
        level: DiagnosticLevel,
        category: String,
        code: String,
        providerID: ProviderID? = nil,
        duration: Duration? = nil,
        correlationID: UUID? = nil
    ) {
        self.level = level
        self.category = category
        self.code = code
        self.providerID = providerID
        self.duration = duration
        self.correlationID = correlationID
    }
}

public protocol DiagnosticsSink: Sendable {
    func record(_ event: DiagnosticEvent) async
}

public struct CollectionContext: Sendable {
    public let network: any NetworkClient
    public let credentials: any AppCredentialStore
    public let externalSessions: any ExternalSessionReader
    public let sqlite: any ReadOnlySQLiteReader
    public let codexAccount: any CodexAccountUsageReader
    public let doubaoPlan: any DoubaoPlanUsageReader
    public let clock: any TokenTankClock
    public let diagnostics: any DiagnosticsSink
    public let correlationID: UUID

    public init(
        network: any NetworkClient,
        credentials: any AppCredentialStore,
        externalSessions: any ExternalSessionReader,
        sqlite: any ReadOnlySQLiteReader,
        codexAccount: any CodexAccountUsageReader,
        doubaoPlan: any DoubaoPlanUsageReader,
        clock: any TokenTankClock,
        diagnostics: any DiagnosticsSink,
        correlationID: UUID = UUID()
    ) {
        self.network = network
        self.credentials = credentials
        self.externalSessions = externalSessions
        self.sqlite = sqlite
        self.codexAccount = codexAccount
        self.doubaoPlan = doubaoPlan
        self.clock = clock
        self.diagnostics = diagnostics
        self.correlationID = correlationID
    }
}

public struct UnavailableNetworkClient: NetworkClient {
    public init() {}

    public func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        throw CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "network.unavailable"
        )
    }
}

public actor InMemoryCredentialStore: AppCredentialStore {
    private var values: [CredentialID: String]

    public init(values: [CredentialID: String] = [:]) {
        self.values = values
    }

    public func read(_ id: CredentialID) -> String? {
        values[id]
    }

    public func write(_ value: String, for id: CredentialID) {
        values[id] = value
    }

    public func delete(_ id: CredentialID) {
        values.removeValue(forKey: id)
    }
}

public struct NoExternalSessionReader: ExternalSessionReader {
    public init() {}

    public func exists(_ request: ExternalFileRequest) async -> Bool { false }

    public func read(_ request: ExternalFileRequest) async throws -> Data {
        throw CollectionError(
            kind: .externalSessionMissing,
            diagnosticCode: "external-session.missing"
        )
    }
}

public struct NoSQLiteReader: ReadOnlySQLiteReader {
    public init() {}

    public func values(
        in request: ExternalFileRequest,
        table: String,
        keyColumn: String,
        valueColumn: String,
        keys: [String]
    ) async throws -> [String: String] {
        throw CollectionError(
            kind: .externalSessionMissing,
            diagnosticCode: "sqlite.external-session.missing"
        )
    }
}

public struct NoCodexAccountUsageReader: CodexAccountUsageReader {
    public init() {}

    public func readRateLimits() async throws -> Data {
        throw CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "codex.app-server.disabled"
        )
    }
}
public struct NoDoubaoPlanUsageReader: DoubaoPlanUsageReader {
    public init() {}

    public func readPlanUsage() async throws -> Data {
        throw CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "doubao.arkcli.disabled"
        )
    }
}

public struct SystemClock: TokenTankClock {
    private let origin: ContinuousClock.Instant

    public init() {
        self.origin = .now
    }

    public func now() async -> Date { Date() }

    public func monotonicNow() async -> Duration {
        origin.duration(to: .now)
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public struct NoDiagnostics: DiagnosticsSink {
    public init() {}
    public func record(_ event: DiagnosticEvent) async {}
}
