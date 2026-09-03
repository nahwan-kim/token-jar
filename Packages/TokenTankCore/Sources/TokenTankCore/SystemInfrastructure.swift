import Darwin
import Foundation
import OSLog
@preconcurrency import Security
import SQLite3
import TokenTankDomain

public actor URLSessionNetworkClient: NetworkClient {
    private static let maximumRequestBytes = 1 * 1024 * 1024
    private static let maximumHeaderCount = 16
    private static let maximumHeaderNameBytes = 128
    private static let maximumHeaderValueBytes = 32 * 1024
    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumResponseHeaderCount = 128

    private let session: URLSession
    private let maximumResponseBytes: Int

    public init(maximumResponseBytes: Int = 4 * 1024 * 1024) {
        precondition(maximumResponseBytes > 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        self.maximumResponseBytes = maximumResponseBytes
    }

    init(session: URLSession, maximumResponseBytes: Int) {
        precondition(maximumResponseBytes > 0)
        self.session = session
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        guard Self.isAllowed(request) else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "network.destination-not-allowlisted"
            )
        }
        guard request.timeout > 0, request.timeout <= 60 else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "network.timeout-out-of-policy"
            )
        }
        guard (request.body?.count ?? 0) <= Self.maximumRequestBytes else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "network.request-size-limit"
            )
        }
        guard Self.headersAreAllowed(for: request) else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "network.header-invalid"
            )
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (bytes, response) = try await session.bytes(
                for: urlRequest,
                delegate: NoRedirectURLSessionDelegate()
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CollectionError(
                    kind: .malformedResponse,
                    diagnosticCode: "network.non-http-response"
                )
            }
            let headers = try Self.boundedHeaders(from: httpResponse)
            if response.expectedContentLength > Int64(maximumResponseBytes) {
                throw CollectionError(
                    kind: .malformedResponse,
                    diagnosticCode: "network.response-size-limit"
                )
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(
                    min(Int(response.expectedContentLength), maximumResponseBytes)
                )
            }
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw CollectionError(
                        kind: .malformedResponse,
                        diagnosticCode: "network.response-size-limit"
                    )
                }
                data.append(byte)
            }
            return NetworkResponse(
                statusCode: httpResponse.statusCode,
                headers: headers,
                body: data
            )
        } catch let error as CollectionError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff:
                throw CollectionError(kind: .offline, diagnosticCode: "network.offline")
            case .cancelled:
                throw CollectionError(kind: .cancelled, diagnosticCode: "network.cancelled")
            default:
                throw CollectionError(kind: .transientNetwork, diagnosticCode: "network.transport")
            }
        } catch {
            throw CollectionError(kind: .transientNetwork, diagnosticCode: "network.unknown")
        }
    }

    private static func headersAreAllowed(for request: NetworkRequest) -> Bool {
        guard request.headers.count <= maximumHeaderCount else { return false }
        let normalizedNames = request.headers.keys.map { $0.lowercased() }
        guard Set(normalizedNames).count == normalizedNames.count else { return false }

        var totalBytes = 0
        for (name, value) in request.headers {
            let nameBytes = Array(name.utf8)
            let valueBytes = Array(value.utf8)
            guard
                !nameBytes.isEmpty,
                nameBytes.count <= maximumHeaderNameBytes,
                valueBytes.count <= maximumHeaderValueBytes,
                nameBytes.allSatisfy(isHTTPTokenByte),
                valueBytes.allSatisfy({ $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) })
            else { return false }
            totalBytes += nameBytes.count + valueBytes.count
            guard totalBytes <= maximumHeaderBytes else { return false }
        }

        let expectedNames: Set<String>
        switch request.providerID {
        case .codex, .claude, .doubao:
            expectedNames = []
        case .grok:
            expectedNames = ["accept", "authorization", "x-xai-token-auth"]
        case .cursor:
            expectedNames = ["accept", "cookie"]
        }
        return Set(normalizedNames) == expectedNames
    }

    private static func isHTTPTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
            true
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
            true
        default:
            false
        }
    }

    private static func boundedHeaders(from response: HTTPURLResponse) throws -> [String: String] {
        guard response.allHeaderFields.count <= maximumResponseHeaderCount else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "network.response-header-limit")
        }
        var headers: [String: String] = [:]
        var totalBytes = 0
        for entry in response.allHeaderFields {
            guard let name = entry.key as? String else {
                throw CollectionError(kind: .malformedResponse, diagnosticCode: "network.response-header-invalid")
            }
            let value = String(describing: entry.value)
            totalBytes += name.utf8.count + value.utf8.count
            guard
                name.utf8.count <= maximumHeaderNameBytes,
                value.utf8.count <= maximumHeaderValueBytes,
                totalBytes <= maximumHeaderBytes
            else {
                throw CollectionError(kind: .malformedResponse, diagnosticCode: "network.response-header-limit")
            }
            headers[name] = value
        }
        return headers
    }

    static func isAllowed(_ request: NetworkRequest) -> Bool {
        guard
            request.url.scheme?.lowercased() == "https",
            request.url.absoluteString.utf8.count <= 16 * 1024,
            let host = request.url.host?.lowercased(),
            request.url.user == nil,
            request.url.password == nil,
            request.url.fragment == nil,
            request.url.port == nil || request.url.port == 443,
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        else { return false }

        switch request.providerID {
        case .codex, .claude, .doubao:
            return false
        case .grok:
            let items = components.queryItems ?? []
            return request.method == .get
                && host == "cli-chat-proxy.grok.com"
                && components.percentEncodedPath == "/v1/billing"
                && items.count == 1
                && items.first?.name == "format"
                && items.first?.value == "credits"
                && request.body == nil
        case .cursor:
            return request.method == .get
                && host == "cursor.com"
                && components.percentEncodedPath == "/api/usage-summary"
                && components.query == nil
                && request.body == nil
        }
    }
}

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

public actor KeychainCredentialStore: AppCredentialStore {
    private static let maximumCredentialBytes = 16 * 1024
    private let service: String
    public static let accessibilityClass = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    public init(service: String = "com.tokentank.credentials") {
        self.service = service
    }

    public func read(_ id: CredentialID) throws -> String? {
        try Self.validate(id)
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            var ownershipQuery = Self.ownedItemQuery(service: service, id: id)
            ownershipQuery[kSecReturnAttributes as String] = true
            ownershipQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var mismatchedItem: CFTypeRef?
            let mismatchStatus = SecItemCopyMatching(
                ownershipQuery as CFDictionary,
                &mismatchedItem
            )
            if mismatchStatus == errSecSuccess {
                throw CollectionError(
                    kind: .keychainUnavailable,
                    diagnosticCode: "keychain.read.attributes-mismatch"
                )
            }
            if mismatchStatus == errSecItemNotFound { return nil }
            try check(mismatchStatus, operation: "read")
            return nil
        }
        try check(status, operation: "read")
        guard
            let data = result as? Data,
            !data.isEmpty,
            data.count <= Self.maximumCredentialBytes,
            let value = String(data: data, encoding: .utf8)
        else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "keychain.value-invalid")
        }
        return value
    }

    public func write(_ value: String, for id: CredentialID) throws {
        try Self.validate(id)
        let data = Data(value.utf8)
        guard !data.isEmpty, data.count <= Self.maximumCredentialBytes else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "keychain.value-invalid")
        }
        let query = baseQuery(for: id)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibilityClass,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            try check(updateStatus, operation: "update")
        }

        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = Self.accessibilityClass
        try check(SecItemAdd(insertion as CFDictionary, nil), operation: "add")
    }

    public func delete(_ id: CredentialID) throws {
        try Self.validate(id)
        let status = SecItemDelete(
            Self.ownedItemQuery(service: service, id: id) as CFDictionary
        )
        if status == errSecItemNotFound { return }
        try check(status, operation: "delete")
    }

    private static func validate(_ id: CredentialID) throws {
        let allowedNames: Set<String>
        switch id.providerID {
        case .codex, .claude, .grok, .cursor, .doubao:
            allowedNames = []
        }
        guard allowedNames.contains(id.name) else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "keychain.credential-id-denied"
            )
        }
    }
    static func ownedItemQuery(
        service: String,
        id: CredentialID
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(id.providerID.rawValue).\(id.name)",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    static func dataProtectionQuery(
        service: String,
        id: CredentialID
    ) -> [String: Any] {
        var query = ownedItemQuery(service: service, id: id)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        return query
    }

    private func baseQuery(for id: CredentialID) -> [String: Any] {
        Self.dataProtectionQuery(service: service, id: id)
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            switch status {
            case errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed:
                throw CollectionError(
                    kind: .keychainUnavailable,
                    diagnosticCode: "keychain.\(operation).unavailable"
                )
            default:
                throw CollectionError(
                    kind: .keychainUnavailable,
                    diagnosticCode: "keychain.\(operation).status-\(status)"
                )
            }
        }
    }
}

public actor FilesystemAccessPolicy: ExternalSessionReader {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = Self.canonicalExistingURL(homeDirectory)
    }

    public func exists(_ request: ExternalFileRequest) -> Bool {
        guard let url = try? validatedURL(for: request) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func read(_ request: ExternalFileRequest) throws -> Data {
        let opened = try openReadOnlyRegularFile(for: request)
        defer { Darwin.close(opened.descriptor) }

        var data = Data()
        data.reserveCapacity(opened.length)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(request.maximumBytes, 1)))
        while true {
            let count = Darwin.read(opened.descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw mapErrno(errno, code: "filesystem.read")
            }
            guard data.count + count <= request.maximumBytes else {
                throw CollectionError(kind: .unsafePath, diagnosticCode: "filesystem.size-limit")
            }
            data.append(buffer, count: count)
        }
        return data
    }

    public func validatedURL(for request: ExternalFileRequest) throws -> URL {
        let path = request.relativePath
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
            throw CollectionError(kind: .unsafePath, diagnosticCode: "filesystem.invalid-relative-path")
        }
        let components = NSString(string: path).pathComponents
        guard !components.contains(".."), !components.contains(".") else {
            throw CollectionError(kind: .unsafePath, diagnosticCode: "filesystem.path-traversal")
        }

        let candidate = homeDirectory.appendingPathComponent(path, isDirectory: false)
        let resolved = Self.canonicalExistingURL(candidate)
        let rootPath = homeDirectory.path.hasSuffix("/") ? homeDirectory.path : homeDirectory.path + "/"
        guard candidate.path.hasPrefix(rootPath), resolved.path.hasPrefix(rootPath) else {
            throw CollectionError(kind: .unsafePath, diagnosticCode: "filesystem.path-escape")
        }
        guard candidate.path == resolved.path else {
            throw CollectionError(kind: .unsafePath, diagnosticCode: "filesystem.symlink-rejected")
        }
        return candidate
    }

    private static func canonicalExistingURL(_ url: URL) -> URL {
        if
            let referenceURL = (url as NSURL).fileReferenceURL(),
            let pathURL = (referenceURL as NSURL).filePathURL
        {
            return URL(fileURLWithPath: pathURL.path, isDirectory: url.hasDirectoryPath)
        }
        guard let pointer = Darwin.realpath(url.path, nil) else {
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }
        defer { Darwin.free(pointer) }
        let utf8Pointer = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        return URL(
            fileURLWithPath: String(decodingCString: utf8Pointer, as: UTF8.self),
            isDirectory: url.hasDirectoryPath
        )
    }

    func openReadOnlyRegularFile(
        for request: ExternalFileRequest
    ) throws -> (descriptor: Int32, length: Int) {
        let expectedURL = try validatedURL(for: request)
        let descriptor = Darwin.open(
            expectedURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw mapErrno(errno, code: "filesystem.open") }

        do {
            let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
            let openedURL = Self.canonicalExistingURL(descriptorURL)
            guard openedURL.path == expectedURL.path else {
                throw CollectionError(
                    kind: .unsafePath,
                    diagnosticCode: "filesystem.opened-path-changed"
                )
            }
            let length = Darwin.lseek(descriptor, 0, SEEK_END)
            guard length >= 0 else {
                throw CollectionError(
                    kind: .unsafePath,
                    diagnosticCode: "filesystem.not-regular"
                )
            }
            guard request.maximumBytes >= 0, length <= off_t(request.maximumBytes) else {
                throw CollectionError(kind: .unsafePath, diagnosticCode: "filesystem.size-limit")
            }
            guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw mapErrno(errno, code: "filesystem.seek")
            }
            return (descriptor, Int(length))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func mapErrno(_ value: Int32, code: String) -> CollectionError {
        switch value {
        case ENOENT:
            CollectionError(kind: .externalSessionMissing, diagnosticCode: "\(code).missing")
        case EACCES, EPERM:
            CollectionError(kind: .permissionDenied, diagnosticCode: "\(code).permission")
        case ELOOP:
            CollectionError(kind: .unsafePath, diagnosticCode: "\(code).symlink")
        default:
            CollectionError(kind: .sourceUnavailable, diagnosticCode: "\(code).errno-\(value)")
        }
    }
}

public actor SQLiteExternalSessionReader: ReadOnlySQLiteReader {
    private static let maximumValueBytes = 4 * 1024 * 1024

    private let policy: FilesystemAccessPolicy

    public init(policy: FilesystemAccessPolicy) {
        self.policy = policy
    }

    public func values(
        in request: ExternalFileRequest,
        table: String,
        keyColumn: String,
        valueColumn: String,
        keys: [String]
    ) async throws -> [String: String] {
        guard request.providerID == .cursor else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "capability.sqlite.denied"
            )
        }
        guard !keys.isEmpty else { return [:] }
        guard keys.count <= 64, keys.reduce(0, { $0 + $1.utf8.count }) <= 16 * 1024 else {
            throw CollectionError(kind: .unsafePath, diagnosticCode: "sqlite.key-limit")
        }
        guard request.maximumBytes > 0 else {
            throw CollectionError(
                kind: .unsafePath,
                diagnosticCode: "sqlite.request-size-limit"
            )
        }
        guard [table, keyColumn, valueColumn].allSatisfy(Self.isSafeIdentifier) else {
            throw CollectionError(kind: .unsafePath, diagnosticCode: "sqlite.invalid-identifier")
        }
        guard keys.allSatisfy({ !$0.contains("\0") }) else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.invalid-key")
        }

        let opened = try await policy.openReadOnlyRegularFile(for: request)
        defer { Darwin.close(opened.descriptor) }
        guard let databaseURI = Self.immutableDatabaseURI(for: opened.descriptor) else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "sqlite.uri-invalid"
            )
        }
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURI,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "sqlite.open-failed")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        try Self.requireOrdinaryTable(named: table, in: database)

        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let sql = "SELECT \(keyColumn), \(valueColumn) FROM \(table) WHERE \(keyColumn) IN (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CollectionError(kind: .schemaChanged, diagnosticCode: "sqlite.prepare-failed")
        }
        defer { sqlite3_finalize(statement) }

        for (index, key) in keys.enumerated() {
            let result = key.withCString { pointer in
                sqlite3_bind_text(
                    statement,
                    Int32(index + 1),
                    pointer,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            guard result == SQLITE_OK else {
                throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "sqlite.bind-failed")
            }
        }

        var result: [String: String] = [:]
        var resultBytes = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard sqlite3_column_type(statement, 0) == SQLITE_TEXT else {
                    throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.key-invalid")
                }
                let keyData = try Self.columnData(
                    statement,
                    index: 0,
                    maximumBytes: 16 * 1024
                )
                guard
                    let key = String(data: keyData, encoding: .utf8),
                    !key.isEmpty,
                    !key.contains("\0")
                else {
                    throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.key-invalid")
                }
                guard sqlite3_column_type(statement, 1) != SQLITE_NULL else {
                    throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.value-null")
                }
                let valueType = sqlite3_column_type(statement, 1)
                guard valueType == SQLITE_TEXT || valueType == SQLITE_BLOB else {
                    throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.value-type-invalid")
                }
                let valueData = try Self.columnData(
                    statement,
                    index: 1,
                    maximumBytes: min(request.maximumBytes, Self.maximumValueBytes)
                )
                guard result[key] == nil else {
                    throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.duplicate-key")
                }
                guard result.count < keys.count else {
                    throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.row-limit")
                }
                resultBytes += keyData.count + valueData.count
                guard resultBytes <= Self.maximumValueBytes else {
                    throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.result-size-limit")
                }
                result[key] = try Self.decodeValue(valueData)
            case SQLITE_DONE:
                return result
            case SQLITE_BUSY, SQLITE_LOCKED:
                throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "sqlite.busy")
            default:
                throw CollectionError(kind: .schemaChanged, diagnosticCode: "sqlite.step-failed")
            }
        }
    }

    private static func requireOrdinaryTable(named table: String, in database: OpaquePointer) throws {
        let sql = "SELECT type, sql FROM sqlite_master WHERE name = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CollectionError(kind: .schemaChanged, diagnosticCode: "sqlite.schema-prepare-failed")
        }
        defer { sqlite3_finalize(statement) }

        let bindStatus = table.withCString { pointer in
            sqlite3_bind_text(
                statement,
                1,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard bindStatus == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionError(kind: .schemaChanged, diagnosticCode: "sqlite.table-missing")
        }
        let typeData = try columnData(statement, index: 0, maximumBytes: 32)
        let definitionData = try columnData(statement, index: 1, maximumBytes: 64 * 1024)
        guard
            String(data: typeData, encoding: .utf8) == "table",
            let definition = String(data: definitionData, encoding: .utf8),
            definition.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .hasPrefix("CREATE TABLE")
        else {
            throw CollectionError(kind: .schemaChanged, diagnosticCode: "sqlite.table-invalid")
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CollectionError(kind: .schemaChanged, diagnosticCode: "sqlite.schema-duplicate")
        }
    }

    private static func columnData(
        _ statement: OpaquePointer?,
        index: Int32,
        maximumBytes: Int
    ) throws -> Data {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount >= 0, byteCount <= maximumBytes else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.value-size-limit")
        }
        guard byteCount > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(statement, index) else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.value-invalid")
        }
        return Data(bytes: pointer, count: byteCount)
    }

    private static func decodeValue(_ data: Data) throws -> String {
        guard !data.isEmpty else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.value-invalid")
        }

        if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xFE {
            let payload = Data(data.dropFirst(2))
            guard
                let value = String(data: payload, encoding: .utf16LittleEndian),
                !value.isEmpty,
                !value.contains("\0")
            else {
                throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.value-invalid")
            }
            return value
        }

        if
            isLikelyUTF16LE(data),
            let value = String(data: data, encoding: .utf16LittleEndian),
            !value.isEmpty,
            !value.contains("\0")
        {
            return value
        }

        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.value-invalid")
        }
        guard !value.contains("\0") else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "sqlite.value-invalid")
        }
        return value
    }

    private static func isLikelyUTF16LE(_ data: Data) -> Bool {
        guard data.count >= 2, data.count.isMultiple(of: 2) else { return false }
        var oddZeroes = 0
        var evenZeroes = 0
        for (index, byte) in data.enumerated() {
            if byte == 0 {
                if index.isMultiple(of: 2) {
                    evenZeroes += 1
                } else {
                    oddZeroes += 1
                }
            }
        }
        return oddZeroes >= 1 && oddZeroes > evenZeroes && oddZeroes * 4 >= data.count
    }

    private static func immutableDatabaseURI(for descriptor: Int32) -> String? {
        var components = URLComponents()
        components.scheme = "file"
        components.path = "/dev/fd/\(descriptor)"
        components.percentEncodedQuery = "mode=ro&immutable=1"
        return components.string
    }
    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first)
        else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }
}

public actor CodexAppServerUsageReader: CodexAccountUsageReader {
    private let executableCandidates: [URL]
    private let timeout: Duration

    public init(
        executableCandidates: [URL] = CodexAppServerUsageReader.defaultExecutableCandidates,
        timeout: Duration = .seconds(20)
    ) {
        self.executableCandidates = executableCandidates
        self.timeout = timeout
    }

    public func readRateLimits() async throws -> Data {
        guard let executable = executableCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "codex.app-server.executable-missing"
            )
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "codex.app-server.launch-failed")
        }
        defer {
            input.fileHandleForWriting.closeFile()
            Self.stop(process)
            output.fileHandleForReading.closeFile()
        }

        try writeJSONLine(
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "token_tank",
                        "title": "Token Tank",
                        "version": "1.0.0",
                    ],
                ],
            ],
            to: input.fileHandleForWriting
        )
        _ = try await response(id: 0, from: output.fileHandleForReading)
        try writeJSONLine(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
        try writeJSONLine(["method": "account/rateLimits/read", "id": 1], to: input.fileHandleForWriting)
        return try await response(id: 1, from: output.fileHandleForReading)
    }

    public static var defaultExecutableCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".local/share/mise/shims/codex"),
            home.appendingPathComponent(".bun/bin/codex"),
        ]
    }

    private static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 {
                if !process.isRunning { break }
                Darwin.usleep(50_000)
            }
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func writeJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func response(id: Int, from handle: FileHandle) async throws -> Data {
        let fileDescriptor = handle.fileDescriptor
        let timeout = timeout
        let reader = Task.detached(priority: .utility) {
            try Self.readResponse(fileDescriptor: fileDescriptor, id: id, timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            try await reader.value
        } onCancel: {
            reader.cancel()
        }
    }

    private nonisolated static func readResponse(
        fileDescriptor: Int32,
        id: Int,
        timeout: Duration
    ) throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var line = Data()
        var descriptor = pollfd(
            fd: fileDescriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )

        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw CollectionError(
                    kind: .sourceUnavailable,
                    diagnosticCode: "codex.app-server.timeout"
                )
            }
            let components = remaining.components
            let remainingSeconds =
                Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
            let pollMilliseconds = max(1, min(100, Int(ceil(remainingSeconds * 1_000))))

            descriptor.revents = 0
            let pollResult = Darwin.poll(&descriptor, 1, Int32(pollMilliseconds))
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CollectionError(
                    kind: .sourceUnavailable,
                    diagnosticCode: "codex.app-server.read-failed"
                )
            }

            var byte: UInt8 = 0
            let count = Darwin.read(fileDescriptor, &byte, 1)
            if count == 0 {
                throw CollectionError(
                    kind: .sourceUnavailable,
                    diagnosticCode: "codex.app-server.closed"
                )
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CollectionError(
                    kind: .sourceUnavailable,
                    diagnosticCode: "codex.app-server.read-failed"
                )
            }
            if byte == 0x0A {
                if let result = try responseResult(from: line, id: id) {
                    return result
                }
                line.removeAll(keepingCapacity: true)
                continue
            }
            if byte != 0x0D {
                line.append(byte)
            }
            guard line.count <= 4 * 1024 * 1024 else {
                throw CollectionError(
                    kind: .malformedResponse,
                    diagnosticCode: "codex.app-server.response-size-limit"
                )
            }
        }
    }

    private nonisolated static func responseResult(from line: Data, id: Int) throws -> Data? {
        guard
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["jsonrpc"] == nil || object["jsonrpc"] as? String == "2.0",
            let responseID = object["id"] as? NSNumber,
            !JSONScalar.isBoolean(responseID),
            responseID.decimalValue == Decimal(id)
        else { return nil }

        if object["error"] != nil {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "codex.app-server.rpc-error"
            )
        }
        guard let result = object["result"] else {
            throw CollectionError(
                kind: .malformedResponse,
                diagnosticCode: "codex.app-server.result-missing"
            )
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }
}
public actor ArkCLIPlanUsageReader: DoubaoPlanUsageReader {
    private let executableCandidates: [URL]
    private let timeout: Duration

    public init(
        executableCandidates: [URL] = ArkCLIPlanUsageReader.defaultExecutableCandidates,
        timeout: Duration = .seconds(20)
    ) {
        self.executableCandidates = executableCandidates
        self.timeout = timeout
    }

    public func readPlanUsage() async throws -> Data {
        guard let executable = executableCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "doubao.arkcli.executable-missing"
            )
        }

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = ["usage", "plan", "--format", "json"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "doubao.arkcli.launch-failed")
        }
        defer { Self.stop(process) }

        let stdoutHandle = output.fileHandleForReading
        let fileDescriptor = stdoutHandle.fileDescriptor
        let timeout = timeout
        let reader = Task.detached(priority: .utility) {
            try Self.readBoundedOutput(fileDescriptor: fileDescriptor, timeout: timeout)
        }
        let data: Data
        do {
            data = try await withTaskCancellationHandler {
                try await reader.value
            } onCancel: {
                reader.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError {
            throw error
        } catch {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "doubao.arkcli.read-failed")
        }

        process.waitUntilExit()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            if Self.looksLikeMissingSession(data) || Self.looksLikeMissingSession(stderr) {
                throw CollectionError(
                    kind: .externalSessionMissing,
                    diagnosticCode: "doubao.arkcli.session-missing"
                )
            }
            throw CollectionError(
                kind: .sourceUnavailable,
                diagnosticCode: "doubao.arkcli.exit-\(process.terminationStatus)"
            )
        }
        guard !data.isEmpty else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "doubao.arkcli.empty-output")
        }
        return data
    }

    public static var defaultExecutableCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin/arkcli"),
            URL(fileURLWithPath: "/usr/local/bin/arkcli"),
            home.appendingPathComponent(".local/bin/arkcli"),
            home.appendingPathComponent(".local/share/mise/shims/arkcli"),
            home.appendingPathComponent(".bun/bin/arkcli"),
        ]
    }

    private static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 {
                if !process.isRunning { break }
                Darwin.usleep(50_000)
            }
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private nonisolated static func readBoundedOutput(
        fileDescriptor: Int32,
        timeout: Duration
    ) throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var data = Data()
        var descriptor = pollfd(
            fd: fileDescriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        while true {
            if Task.isCancelled { throw CancellationError() }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw CollectionError(
                    kind: .sourceUnavailable,
                    diagnosticCode: "doubao.arkcli.timeout"
                )
            }
            let components = remaining.components
            let remainingSeconds =
                Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
            let pollMilliseconds = max(1, min(100, Int(ceil(remainingSeconds * 1_000))))
            descriptor.revents = 0
            let pollResult = Darwin.poll(&descriptor, 1, Int32(pollMilliseconds))
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "doubao.arkcli.read-failed")
            }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "doubao.arkcli.read-failed")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 4 * 1024 * 1024 else {
                throw CollectionError(
                    kind: .malformedResponse,
                    diagnosticCode: "doubao.arkcli.response-size-limit"
                )
            }
        }
    }

    private static func looksLikeMissingSession(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("auth login")
            || text.contains("refresh_token")
            || text.contains("sts")
            || text.contains("not logged")
            || text.contains("session")
    }
}

public struct UnifiedDiagnostics: DiagnosticsSink {
    private let subsystem: String

    public init(subsystem: String = "com.tokentank") {
        self.subsystem = subsystem
    }

    public func record(_ event: DiagnosticEvent) async {
        let category = Self.sanitizedComponent(event.category, fallback: "diagnostics")
        let code = Self.sanitizedComponent(event.code, fallback: "diagnostic.invalid-code")
        let logger = Logger(subsystem: subsystem, category: category)
        let signposter = OSSignposter(logger: logger)
        let provider = event.providerID?.rawValue ?? "none"
        let correlation = event.correlationID?.uuidString ?? "none"
        let durationMilliseconds: String
        if let duration = event.duration {
            let components = duration.components
            let milliseconds =
                Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
            durationMilliseconds = String(format: "%.3f", milliseconds)
        } else {
            durationMilliseconds = "none"
        }

        signposter.emitEvent(
            "TokenTankEvent",
            "code=\(code, privacy: .public) provider=\(provider, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
        )
        switch event.level {
        case .debug:
            logger.debug(
                "code=\(code, privacy: .public) provider=\(provider, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) correlation=\(correlation, privacy: .private(mask: .hash))"
            )
        case .info:
            logger.info(
                "code=\(code, privacy: .public) provider=\(provider, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) correlation=\(correlation, privacy: .private(mask: .hash))"
            )
        case .notice:
            logger.notice(
                "code=\(code, privacy: .public) provider=\(provider, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) correlation=\(correlation, privacy: .private(mask: .hash))"
            )
        case .error:
            logger.error(
                "code=\(code, privacy: .public) provider=\(provider, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) correlation=\(correlation, privacy: .private(mask: .hash))"
            )
        }
    }

    static func sanitizedComponent(_ value: String, fallback: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 128 else { return fallback }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : fallback
    }
}
