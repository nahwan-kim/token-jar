import Darwin
import Foundation
import Testing
@testable import TokenTankCore
import TokenTankDomain
import TokenTankTestSupport

@Suite("Grok OAuth session renewal", .serialized)
struct GrokSessionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a session without expiry is reused without network I/O")
    func noExpiryReusesToken() async throws {
        let store = makeStore(entry(token: "access-old", expiresAt: nil))
        let network = QueueNetworkClient(results: [])
        let provider = GrokOAuthSessionProvider(network: network, clock: ManualClock(now: now), store: store)

        let session = try await provider.session(rejectedAccessToken: nil)

        #expect(session.accessToken == "access-old")
        #expect(await network.requests.isEmpty)
    }

    @Test("ISO-8601 and epoch millisecond expiries retain a fresh session")
    func expiryFormats() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for rawExpiry: Any in [
            formatter.string(from: now.addingTimeInterval(3_600)),
            String(Int(now.addingTimeInterval(3_600).timeIntervalSince1970)),
            (now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000),
        ] {
            var value = entry(token: "access-old", expiresAt: nil)
            value["expires_at"] = rawExpiry
            let network = QueueNetworkClient(results: [])
            let provider = GrokOAuthSessionProvider(
                network: network,
                clock: ManualClock(now: now),
                store: makeStore(value)
            )
            #expect(try await provider.session(rejectedAccessToken: nil).accessToken == "access-old")
            #expect(await network.requests.isEmpty)
        }
    }

    @Test("near-expiry and expired sessions renew and preserve unrelated metadata")
    func expiryRenewsAndRotatesRefreshToken() async throws {
        for expiry in [now.addingTimeInterval(60), now.addingTimeInterval(-1)] {
            let original = entry(token: "access-old", expiresAt: expiry).merging(["custom": "preserved"]) { _, new in new }
            let store = makeStore(original)
            let network = QueueNetworkClient(results: [.success(tokenResponse(
                access: "access-new",
                refresh: "refresh-new",
                expiresIn: 3_600
            ))])
            let provider = GrokOAuthSessionProvider(network: network, clock: ManualClock(now: now), store: store)

            let session = try await provider.session(rejectedAccessToken: nil)
            let saved = await store.snapshot()

            #expect(session.accessToken == "access-new")
            #expect(saved.selectedEntry["refresh_token"] as? String == "refresh-new")
            #expect(saved.selectedEntry["custom"] as? String == "preserved")
            #expect(await network.requests.count == 1)
            let request = try #require(await network.requests.first)
            #expect(request.url.absoluteString == "https://auth.x.ai/oauth2/token")
            #expect(request.method == .post)
            #expect(request.timeout == 15)
            #expect(request.headers == [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            ])
            #expect(String(data: try #require(request.body), encoding: .utf8) == "grant_type=refresh_token&client_id=client-id&refresh_token=refresh-old")
        }
    }

    @Test("an omitted refresh token retains the previous refresh token")
    func omittedRotationIsRetained() async throws {
        let store = makeStore(entry(token: "access-old", expiresAt: now))
        let network = QueueNetworkClient(results: [.success(tokenResponse(access: "access-new", expiresIn: 100))])
        let provider = GrokOAuthSessionProvider(network: network, clock: ManualClock(now: now), store: store)

        _ = try await provider.session(rejectedAccessToken: nil)

        #expect(await store.stringValue(for: "refresh_token") == "refresh-old")
    }

    @Test("a rejected current token renews but a newer file token does not")
    func rejectedTokenComparison() async throws {
        let currentStore = makeStore(entry(token: "access-old", expiresAt: now.addingTimeInterval(3_600)))
        let currentNetwork = QueueNetworkClient(results: [.success(tokenResponse(access: "access-new", expiresIn: 3_600))])
        let currentProvider = GrokOAuthSessionProvider(network: currentNetwork, clock: ManualClock(now: now), store: currentStore)
        #expect(try await currentProvider.session(rejectedAccessToken: "access-old").accessToken == "access-new")

        let newerStore = makeStore(entry(token: "access-newer", expiresAt: now.addingTimeInterval(3_600)))
        let newerNetwork = QueueNetworkClient(results: [])
        let newerProvider = GrokOAuthSessionProvider(network: newerNetwork, clock: ManualClock(now: now), store: newerStore)
        #expect(try await newerProvider.session(rejectedAccessToken: "access-old").accessToken == "access-newer")
        #expect(await newerNetwork.requests.isEmpty)
    }

    @Test("actor serialization coalesces concurrent renewal onto the rotated file token")
    func singleFlight() async throws {
        let store = makeStore(entry(token: "access-old", expiresAt: now))
        let network = QueueNetworkClient(results: [.success(tokenResponse(access: "access-new", expiresIn: 3_600))])
        let provider = GrokOAuthSessionProvider(network: network, clock: ManualClock(now: now), store: store)

        async let first = provider.session(rejectedAccessToken: nil)
        async let second = provider.session(rejectedAccessToken: nil)
        let sessions = try await (first, second)
        #expect(sessions.0.accessToken == "access-new")
        #expect(sessions.1.accessToken == "access-new")
        #expect(await network.requests.count == 1)
    }

    @Test("cancelling a joined observer does not abort the shared renewal")
    func cancelledObserverDoesNotCancelRenewal() async throws {
        let store = makeStore(entry(token: "access-old", expiresAt: now))
        let network = GatedRefreshNetwork(
            response: tokenResponse(access: "access-new", expiresIn: 3_600),
            checksCancellation: true
        )
        let provider = GrokOAuthSessionProvider(network: network, clock: ManualClock(now: now), store: store)
        let owner = Task { try await provider.session(rejectedAccessToken: nil) }
        await network.waitForFirstRequest()
        let observer = Task { try await provider.session(rejectedAccessToken: nil) }
        for _ in 0..<1_000 {
            if await store.readCount >= 3 { break }
            await Task.yield()
        }
        let observerLoaded = await store.readCount >= 3
        observer.cancel()
        await network.release()
        #expect(try await owner.value.accessToken == "access-new")
        do {
            _ = try await observer.value
            Issue.record("Expected cancelled observer")
        } catch is CancellationError {}
        #expect(observerLoaded)
        #expect(await network.requestCount == 1)
        #expect(await store.stringValue(for: "key") == "access-new")
    }

    @Test("fresh credentials remain usable while another caller renews a rejected token")
    func freshSessionDoesNotJoinRenewal() async throws {
        let store = makeStore(entry(token: "access-old", expiresAt: now.addingTimeInterval(3_600)))
        let network = GatedRefreshNetwork(response: tokenResponse(access: "access-new", expiresIn: 3_600))
        let provider = GrokOAuthSessionProvider(network: network, clock: ManualClock(now: now), store: store)
        let renewal = Task { try await provider.session(rejectedAccessToken: "access-old") }
        await network.waitForFirstRequest()
        let lookup = Task { try await provider.session(rejectedAccessToken: nil) }
        for _ in 0..<1_000 {
            if await store.readCount >= 3 { break }
            await Task.yield()
        }
        let lookupLoaded = await store.readCount >= 3
        await network.release()
        #expect(try await lookup.value.accessToken == "access-old")
        #expect(try await renewal.value.accessToken == "access-new")
        #expect(lookupLoaded)
    }

    @Test("fresh tokens from unofficial issuer metadata are rejected before network access")
    func freshUnofficialIdentityRejected() async {
        var value = entry(token: "access-old", expiresAt: now.addingTimeInterval(3_600))
        value["oidc_issuer"] = "https://unrelated.invalid"
        let network = QueueNetworkClient(results: [])
        let provider = GrokOAuthSessionProvider(
            network: network, clock: ManualClock(now: now), store: makeStore(value)
        )
        await expectError(.authenticationRejected) {
            try await provider.session(rejectedAccessToken: nil)
        }
        #expect(await network.requests.isEmpty)
    }

    @Test("independent providers sharing the canonical file send one refresh")
    func crossProviderSingleFlight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let grok = directory.appendingPathComponent(".grok")
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = grok.appendingPathComponent("auth.json")
        try authData(entry: entry(token: "access-old", expiresAt: now)).write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)

        let network = GatedRefreshNetwork(response: tokenResponse(access: "access-new", expiresIn: 3_600))
        let firstProvider = GrokOAuthSessionProvider(
            network: network,
            clock: ManualClock(now: now),
            homeDirectory: directory
        )
        let secondProvider = GrokOAuthSessionProvider(
            network: network,
            clock: ManualClock(now: now),
            homeDirectory: directory
        )
        let first = Task { try await firstProvider.session(rejectedAccessToken: nil) }
        await network.waitForFirstRequest()
        let second = Task { try await secondProvider.session(rejectedAccessToken: nil) }
        for _ in 0..<10 { await Task.yield() }
        #expect(await network.requestCount == 1)
        await network.release()

        let firstSession = try await first.value
        let secondSession = try await second.value
        #expect(firstSession.accessToken == "access-new")
        #expect(secondSession.accessToken == "access-new")
        #expect(await network.requestCount == 1)
    }

    @Test("invalid_grant accepts a concurrently rotated credential instead of clobbering it")
    func rejectedGrantRecoversExternalRotation() async throws {
        let store = makeStore(entry(token: "access-old", expiresAt: now))
        let network = RotatingNetwork(
            store: store,
            replacementJSON: entryJSON(entry(token: "access-external", expiresAt: now.addingTimeInterval(3_600)))
        )
        let provider = GrokOAuthSessionProvider(network: network, clock: ManualClock(now: now), store: store)

        let session = try await provider.session(rejectedAccessToken: nil)

        #expect(session.accessToken == "access-external")
        #expect(await store.replaceCount == 0)
    }

    @Test("cancellation before a response never changes credentials")
    func cancellationDoesNotClobber() async throws {
        let store = makeStore(entry(token: "access-old", expiresAt: now))
        let provider = GrokOAuthSessionProvider(network: CancellingNetwork(), clock: ManualClock(now: now), store: store)
        do {
            _ = try await provider.session(rejectedAccessToken: nil)
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error type")
        }
        #expect(await store.stringValue(for: "key") == "access-old")
        #expect(await store.replaceCount == 0)
    }

    @Test("pre-cancelled work aborts before sending a refresh request")
    func cancellationBeforeRequest() async {
        let network = QueueNetworkClient(results: [])
        let provider = GrokOAuthSessionProvider(
            network: network,
            clock: ManualClock(now: now),
            store: makeStore(entry(token: "access-old", expiresAt: now))
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.session(rejectedAccessToken: nil)
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error type")
        }
        #expect(await network.requests.isEmpty)
    }

    @Test("cancellation after rotation response persists credentials before propagating")
    func cancellationAfterSuccessPersists() async {
        let store = makeStore(entry(token: "access-old", expiresAt: now))
        let network = GatedRefreshNetwork(response: tokenResponse(access: "access-new", expiresIn: 3_600))
        let provider = GrokOAuthSessionProvider(network: network, clock: ManualClock(now: now), store: store)
        let task = Task { try await provider.session(rejectedAccessToken: nil) }
        await network.waitForFirstRequest()
        task.cancel()
        await network.release()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation after durable save")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error type")
        }
        #expect(await store.stringValue(for: "key") == "access-new")
        #expect(await store.replaceCount == 1)
    }

    @Test("malformed token responses and unofficial refresh metadata are rejected")
    func malformedAndMetadataRejection() async throws {
        let malformedBodies: [[String: Any]] = [
            [:],
            ["access_token": "access-new", "token_type": "MAC", "expires_in": 100],
            ["access_token": "xai-management", "token_type": "Bearer", "expires_in": 100],
            ["access_token": "access-new", "token_type": "Bearer", "expires_in": true],
            ["access_token": "access-new", "token_type": "Bearer", "expires_in": 0],
        ]
        let hugeExpiryBody = try JSONSerialization.data(withJSONObject: [
            "access_token": "access-new",
            "token_type": "Bearer",
            "expires_in": Double.greatestFiniteMagnitude,
        ])
        let hugeExpiryProvider = GrokOAuthSessionProvider(
            network: QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: 200, headers: [:], body: hugeExpiryBody)),
            ]),
            clock: ManualClock(now: now),
            store: makeStore(entry(token: "access-old", expiresAt: now))
        )
        await expectError(.malformedResponse) {
            try await hugeExpiryProvider.session(rejectedAccessToken: nil)
        }
        for body in malformedBodies {
            let store = makeStore(entry(token: "access-old", expiresAt: now))
            let data = try JSONSerialization.data(withJSONObject: body)
            let network = QueueNetworkClient(results: [.success(NetworkResponse(statusCode: 200, headers: [:], body: data))])
            let provider = GrokOAuthSessionProvider(network: network, clock: ManualClock(now: now), store: store)
            await expectError(.malformedResponse) { try await provider.session(rejectedAccessToken: nil) }
        }

        for change in [["oidc_issuer": "https://evil.invalid"], ["oidc_client_id": "other-client"]] {
            let bad = entry(token: "access-old", expiresAt: now).merging(change) { _, new in new }
            let provider = GrokOAuthSessionProvider(
                network: QueueNetworkClient(results: []),
                clock: ManualClock(now: now),
                store: makeStore(bad)
            )
            await expectError(.authenticationRejected) { try await provider.session(rejectedAccessToken: nil) }
        }
    }

    @Test("rate limits preserve Retry-After while server and network failures remain transient")
    func transientAndRateLimitErrors() async throws {
        let rateStore = makeStore(entry(token: "access-old", expiresAt: now))
        let rateNetwork = QueueNetworkClient(results: [.success(NetworkResponse(statusCode: 429, headers: ["Retry-After": "120"], body: Data()))])
        let rateProvider = GrokOAuthSessionProvider(network: rateNetwork, clock: ManualClock(now: now), store: rateStore)
        do {
            _ = try await rateProvider.session(rejectedAccessToken: nil)
            Issue.record("Expected rate limit")
        } catch let error as CollectionError {
            #expect(error.kind == .rateLimited)
            #expect(error.retryAfter == now.addingTimeInterval(120))
        }

        let serverProvider = GrokOAuthSessionProvider(
            network: QueueNetworkClient(results: [
                .success(NetworkResponse(statusCode: 503, headers: [:], body: Data())),
            ]),
            clock: ManualClock(now: now),
            store: makeStore(entry(token: "access-old", expiresAt: now))
        )
        await expectError(.transientNetwork) {
            try await serverProvider.session(rejectedAccessToken: nil)
        }

        let offlineProvider = GrokOAuthSessionProvider(
            network: QueueNetworkClient(results: [
                .failure(CollectionError(kind: .offline, diagnosticCode: "synthetic.offline")),
            ]),
            clock: ManualClock(now: now),
            store: makeStore(entry(token: "access-old", expiresAt: now))
        )
        await expectError(.offline) {
            try await offlineProvider.session(rejectedAccessToken: nil)
        }

        let typedRetryAfter = now.addingTimeInterval(300)
        let typedRateProvider = GrokOAuthSessionProvider(
            network: QueueNetworkClient(results: [
                .failure(CollectionError(
                    kind: .rateLimited,
                    diagnosticCode: "synthetic.rate-limited",
                    retryAfter: typedRetryAfter
                )),
            ]),
            clock: ManualClock(now: now),
            store: makeStore(entry(token: "access-old", expiresAt: now))
        )
        do {
            _ = try await typedRateProvider.session(rejectedAccessToken: nil)
            Issue.record("Expected typed rate limit")
        } catch let error as CollectionError {
            #expect(error.kind == .rateLimited)
            #expect(error.retryAfter == typedRetryAfter)
        }
    }

    @Test("filesystem store enforces permissions, links, size, and atomic replacement")
    func filesystemSafety() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let grok = directory.appendingPathComponent(".grok")
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = grok.appendingPathComponent("auth.json")
        try authData(entry: entry(token: "access-old", expiresAt: now)).write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)

        let store = GrokAuthFileStore(homeDirectory: directory)
        let original = try await store.load()
        var replacement = original.selectedEntry
        replacement["key"] = "access-new"
        let saved = try await store.replacingEntry(
            in: original,
            mutation: GrokAuthFileMutation(expectedEntry: original.selectedEntry, replacement: replacement)
        )
        #expect(saved.selectedEntry["key"] as? String == "access-new")
        let attributes = try FileManager.default.attributesOfItem(atPath: auth.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: auth.path)
        await expectError(.unsafePath) { try await store.load() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)

        let conflicting = try await store.load()
        var externallyChanged = try JSONSerialization.jsonObject(with: conflicting.data) as! [String: Any]
        var changedEntry = conflicting.selectedEntry
        changedEntry["key"] = "access-external"
        externallyChanged[conflicting.selectedKey] = changedEntry
        try JSONSerialization.data(withJSONObject: externallyChanged).write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        await expectError(.sourceUnavailable) {
            try await store.replacingEntry(
                in: conflicting,
                mutation: GrokAuthFileMutation(
                    expectedEntry: conflicting.selectedEntry,
                    replacement: replacement
                )
            )
        }
        #expect(String(data: try Data(contentsOf: auth), encoding: .utf8)?.contains("access-external") == true)

        let hardLink = grok.appendingPathComponent("hard-link")
        try FileManager.default.linkItem(at: auth, to: hardLink)
        await expectError(.unsafePath) { try await store.load() }
        try FileManager.default.removeItem(at: hardLink)

        try Data(repeating: 1, count: 64 * 1024 + 1).write(to: auth)
        await expectError(.unsafePath) { try await store.load() }

        try FileManager.default.removeItem(at: auth)
        try FileManager.default.createSymbolicLink(at: auth, withDestinationURL: grok)
        await expectError(.unsafePath) { try await store.load() }
    }

    private func entry(token: String, expiresAt: Date?) -> [String: Any] {
        var value: [String: Any] = [
            "key": token,
            "email": "synthetic@example.invalid",
            "auth_mode": "oidc",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-id",
            "refresh_token": "refresh-old",
        ]
        if let expiresAt { value["expires_at"] = expiresAt.timeIntervalSince1970 }
        return value
    }

    private func tokenResponse(access: String, refresh: String? = nil, expiresIn: Double) -> NetworkResponse {
        var body: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": expiresIn]
        if let refresh { body["refresh_token"] = refresh }
        return NetworkResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))
    }

    private func authData(entry: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["https://auth.x.ai::client-id": entry])
    }

    /// Serializes a synthetic auth entry so only immutable `Data` crosses into test actors.
    private func entryJSON(_ entry: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: entry)
    }

    private func makeStore(_ entry: [String: Any]) -> MemoryGrokAuthStore {
        MemoryGrokAuthStore(entryJSON: entryJSON(entry))
    }

    private func expectError<T>(
        _ kind: CollectionErrorKind,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected CollectionError")
        } catch let error as CollectionError {
            #expect(error.kind == kind)
            let expectedRecovery: RecoveryAction
            switch kind {
            case .authenticationRejected, .authenticationRevoked, .externalSessionMissing:
                expectedRecovery = .signInSourceApp
            case .unsafePath:
                expectedRecovery = .none
            default:
                expectedRecovery = .waitForNextRefresh
            }
            #expect(error.recoveryAction == expectedRecovery)
        } catch {
            Issue.record("Unexpected error type")
        }
    }
}

private struct NoOpGrokRenewalLock: GrokAuthFileRenewalLock {
    func unlock() {}
}

private func decodeEntry(_ json: Data) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: json) as! [String: Any]
}

private actor MemoryGrokAuthStore: GrokAuthFileStoring {
    private var entry: [String: Any]
    private(set) var replaceCount = 0
    private(set) var readCount = 0

    init(entryJSON: Data) {
        entry = decodeEntry(entryJSON)
    }

    func acquireRenewalLock() async throws -> any GrokAuthFileRenewalLock {
        NoOpGrokRenewalLock()
    }

    func snapshot() -> GrokAuthFileDocument {
        document(entry)
    }

    func stringValue(for key: String) -> String? {
        entry[key] as? String
    }

    func load() -> GrokAuthFileDocument {
        readCount += 1
        return document(entry)
    }

    func replacingEntry(
        in original: GrokAuthFileDocument,
        mutation: GrokAuthFileMutation
    ) throws -> GrokAuthFileDocument {
        guard NSDictionary(dictionary: entry).isEqual(to: mutation.expectedEntry) else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.session.auth-file.conflict")
        }
        entry = mutation.replacement
        replaceCount += 1
        return document(entry)
    }

    func externallyReplace(with mutation: GrokAuthFileMutation) {
        entry = mutation.replacement
    }

    private func document(_ entry: [String: Any]) -> GrokAuthFileDocument {
        let root = ["https://auth.x.ai::client-id": entry]
        return GrokAuthFileDocument(
            data: try! JSONSerialization.data(withJSONObject: root),
            root: root,
            selectedKey: "https://auth.x.ai::client-id",
            selectedEntry: entry,
            device: 1,
            inode: 1,
            directoryDevice: 1,
            directoryInode: 1
        )
    }
}

private actor GatedRefreshNetwork: NetworkClient {
    private let response: NetworkResponse
    private let checksCancellation: Bool
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<NetworkResponse, Never>] = []
    private var isReleased = false
    private(set) var requestCount = 0

    init(response: NetworkResponse, checksCancellation: Bool = false) {
        self.response = response
        self.checksCancellation = checksCancellation
    }

    func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        _ = request
        requestCount += 1
        let waiters = firstRequestWaiters
        firstRequestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        let value: NetworkResponse
        if isReleased {
            value = response
        } else {
            value = await withCheckedContinuation { continuation in
                responseWaiters.append(continuation)
            }
        }
        if checksCancellation { try Task.checkCancellation() }
        return value
    }

    func waitForFirstRequest() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = responseWaiters
        responseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: response)
        }
    }
}
private actor RotatingNetwork: NetworkClient {
    let store: MemoryGrokAuthStore
    let replacement: GrokAuthFileMutation

    init(store: MemoryGrokAuthStore, replacementJSON: Data) {
        self.store = store
        self.replacement = GrokAuthFileMutation(expectedEntry: [:], replacement: decodeEntry(replacementJSON))
    }
    func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        _ = request
        await store.externallyReplace(with: replacement)
        return NetworkResponse(
            statusCode: 400,
            headers: [:],
            body: Data(#"{"error":"invalid_grant"}"#.utf8)
        )
    }
}

private struct CancellingNetwork: NetworkClient {
    func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        _ = request
        throw CancellationError()
    }
}
