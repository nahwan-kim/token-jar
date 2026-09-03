import Foundation
import TokenTankCore
import TokenTankDomain

public actor QueueNetworkClient: NetworkClient {
    private var results: [Result<NetworkResponse, CollectionError>]
    public private(set) var requests: [NetworkRequest] = []

    public init(results: [Result<NetworkResponse, CollectionError>]) {
        self.results = results
    }

    public func send(_ request: NetworkRequest) throws -> NetworkResponse {
        requests.append(request)
        guard !results.isEmpty else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "test.network.empty-queue")
        }
        return try results.removeFirst().get()
    }
}

public actor MemoryExternalSessionReader: ExternalSessionReader {
    private var files: [ExternalFileRequest: Data]

    public init(files: [ExternalFileRequest: Data] = [:]) {
        self.files = files
    }

    public func exists(_ request: ExternalFileRequest) -> Bool {
        files[request] != nil
    }

    public func read(_ request: ExternalFileRequest) throws -> Data {
        guard let data = files[request] else {
            throw CollectionError(kind: .externalSessionMissing, diagnosticCode: "test.external.missing")
        }
        return data
    }

    public func set(_ data: Data?, for request: ExternalFileRequest) {
        files[request] = data
    }
}

public actor MemorySQLiteReader: ReadOnlySQLiteReader {
    private var storedValues: [String: String]

    public init(values: [String: String] = [:]) {
        self.storedValues = values
    }

    public func values(
        in request: ExternalFileRequest,
        table: String,
        keyColumn: String,
        valueColumn: String,
        keys: [String]
    ) -> [String: String] {
        storedValues.filter { keys.contains($0.key) }
    }

    public func set(_ value: String?, for key: String) {
        storedValues[key] = value
    }
}

public actor MemoryCodexAccountUsageReader: CodexAccountUsageReader {
    private var results: [Result<Data, CollectionError>]

    public init(results: [Result<Data, CollectionError>]) {
        self.results = results
    }

    public func readRateLimits() throws -> Data {
        guard !results.isEmpty else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "test.codex.empty-queue")
        }
        return try results.removeFirst().get()
    }
}

public actor ManualClock: TokenTankClock {
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var date: Date
    private var monotonic: Duration = .zero
    private var waiters: [UUID: Waiter] = [:]

    public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.date = now
    }

    public func now() -> Date { date }
    public func monotonicNow() -> Duration { monotonic }
    public var waitingCount: Int { waiters.count }

    public func sleep(for duration: Duration) async throws {
        let deadline = date.addingTimeInterval(duration.timeInterval)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[UUID()] = Waiter(deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiters() }
        }
    }

    public func advance(by duration: Duration) {
        date = date.addingTimeInterval(duration.timeInterval)
        monotonic += duration
        let ready = waiters.filter { $0.value.deadline <= date }
        for id in ready.keys {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func cancelWaiters() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

public actor RecordingDiagnostics: DiagnosticsSink {
    public private(set) var events: [DiagnosticEvent] = []

    public init() {}

    public func record(_ event: DiagnosticEvent) {
        events.append(event)
    }
}

public actor QueueProviderAdapter: ProviderAdapter {
    public nonisolated let id: ProviderID
    public nonisolated let displayName: String
    public nonisolated let defaultAbbreviation: String
    public nonisolated let sourceDescriptor: ProviderSourceDescriptor

    private var availability: ProviderAvailability
    private var results: [Result<ProviderSnapshot, CollectionError>]
    public private(set) var fetchCount = 0

    public init(
        id: ProviderID,
        availability: ProviderAvailability? = nil,
        results: [Result<ProviderSnapshot, CollectionError>]
    ) {
        let descriptor = ProviderSourceDescriptor(
            id: "test.\(id.rawValue)",
            name: "Test \(id.displayName)",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: nil,
            detail: "Test source"
        )
        self.id = id
        self.displayName = id.displayName
        self.defaultAbbreviation = id.defaultAbbreviation
        self.sourceDescriptor = descriptor
        self.availability = availability ?? .available(descriptor)
        self.results = results
    }

    public func probeAvailability(context: CollectionContext) -> ProviderAvailability {
        availability
    }

    public func fetchSnapshot(context: CollectionContext) throws -> ProviderSnapshot {
        fetchCount += 1
        guard !results.isEmpty else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "test.adapter.empty-queue")
        }
        return try results.removeFirst().get()
    }
}

public enum TestContextFactory {
    public static func make(
        network: any NetworkClient = QueueNetworkClient(results: []),
        credentials: any AppCredentialStore = InMemoryCredentialStore(),
        externalSessions: any ExternalSessionReader = MemoryExternalSessionReader(),
        sqlite: any ReadOnlySQLiteReader = MemorySQLiteReader(),
        codexAccount: any CodexAccountUsageReader = MemoryCodexAccountUsageReader(results: []),
        clock: any TokenTankClock = ManualClock(),
        diagnostics: any DiagnosticsSink = RecordingDiagnostics()
    ) -> CollectionContext {
        CollectionContext(
            network: network,
            credentials: credentials,
            externalSessions: externalSessions,
            sqlite: sqlite,
            codexAccount: codexAccount,
            clock: clock,
            diagnostics: diagnostics
        )
    }

    public static func snapshot(
        providerID: ProviderID,
        refreshedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        percentage: Decimal = 25
    ) -> ProviderSnapshot {
        let source = ProviderSourceDescriptor(
            id: "test.\(providerID.rawValue)",
            name: "Test \(providerID.displayName)",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: nil,
            detail: "Test source"
        )
        return ProviderSnapshot(
            providerID: providerID,
            source: source,
            quotas: [
                RawQuotaItem(
                    id: "primary",
                    originalName: "Primary",
                    used: SourceValue(value: percentage, rawText: "\(percentage)", unit: "%"),
                    remaining: nil,
                    percentage: SourcePercentage(value: percentage, rawText: "\(percentage)", meaning: .used),
                    resetsAt: nil
                ),
            ],
            refreshedAt: refreshedAt
        )
    }
}
