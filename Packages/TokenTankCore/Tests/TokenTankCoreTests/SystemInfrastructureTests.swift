import Darwin
import Foundation
@preconcurrency import Security
import SQLite3
import Testing
@testable import TokenTankCore
import TokenTankDomain

@Suite("System capability boundaries", .serialized)
struct SystemInfrastructureTests {
    @Test("external file reads are exact, read-only, size-bounded, and non-mutating")
    func readOnlyFileAccess() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent(".provider", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("auth.json")
        let expected = Data("{\"token\":\"redacted\"}".utf8)
        try expected.write(to: file, options: .atomic)

        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let policy = FilesystemAccessPolicy(homeDirectory: root)
        let request = ExternalFileRequest(
            providerID: .claude,
            relativePath: ".provider/auth.json",
            maximumBytes: 1_024
        )

        let actual = try await policy.read(request)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)

        #expect(actual == expected)
        #expect(before[.size] as? NSNumber == after[.size] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }

    @Test("path traversal and symbolic links fail closed")
    func unsafePathsFailClosed() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let policy = FilesystemAccessPolicy(homeDirectory: root)

        await expectCollectionError(kind: .unsafePath) {
            _ = try await policy.read(
                ExternalFileRequest(providerID: .cursor, relativePath: "../escape")
            )
        }
        await expectCollectionError(kind: .unsafePath) {
            _ = try await policy.read(
                ExternalFileRequest(providerID: .cursor, relativePath: "linked")
            )
        }
    }

    @Test("non-regular external paths fail without blocking")
    func nonRegularPathFailsClosed() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("owner-session")
        #expect(Darwin.mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
        let policy = FilesystemAccessPolicy(homeDirectory: root)

        await expectCollectionError(kind: .unsafePath, code: "filesystem.not-regular") {
            _ = try await policy.read(
                ExternalFileRequest(providerID: .cursor, relativePath: "owner-session")
            )
        }
    }

    @Test("SQLite capability opens Cursor WAL state with immutable read-only access")
    func sqliteReadOnly() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("state.vscdb")

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        guard let database else { return }
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA wal_autocheckpoint=0", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'owner-token')", nil, nil, nil) == SQLITE_OK)
        let utf16Token = "utf16-token".utf16.reduce(into: Data()) { data, codeUnit in
            data.append(UInt8(codeUnit & 0xFF))
            data.append(UInt8(codeUnit >> 8))
        }
        let utf16Hex = utf16Token.map { String(format: "%02X", $0) }.joined()
        let utf16BOMHex = "FFFE\(utf16Hex)"
        #expect(
            sqlite3_exec(
                database,
                "INSERT INTO ItemTable VALUES ('cursorAuth/utf16Token', X'\(utf16Hex)')",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        #expect(
            sqlite3_exec(
                database,
                "INSERT INTO ItemTable VALUES ('cursorAuth/utf16BOMToken', X'\(utf16BOMHex)')",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        #expect(sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "INSERT INTO ItemTable VALUES ('wal-noise', 'wal')", nil, nil, nil) == SQLITE_OK)

        let before = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        #expect(FileManager.default.fileExists(atPath: walURL.path))
        #expect(FileManager.default.fileExists(atPath: shmURL.path))
        let beforeWAL = try FileManager.default.attributesOfItem(atPath: walURL.path)
        let beforeSHM = try FileManager.default.attributesOfItem(atPath: shmURL.path)
        let beforeDatabaseData = try Data(contentsOf: databaseURL)
        let beforeWALData = try Data(contentsOf: walURL)
        let beforeSHMData = try Data(contentsOf: shmURL)
        let policy = FilesystemAccessPolicy(homeDirectory: root)
        let reader = SQLiteExternalSessionReader(policy: policy)
        let values = try await reader.values(
            in: ExternalFileRequest(
                providerID: .cursor,
                relativePath: "Library/Application Support/Cursor/state.vscdb"
            ),
            table: "ItemTable",
            keyColumn: "key",
            valueColumn: "value",
            keys: [
                "cursorAuth/accessToken",
                "cursorAuth/utf16Token",
                "cursorAuth/utf16BOMToken",
                "missing",
            ]
        )
        let after = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let afterWAL = try FileManager.default.attributesOfItem(atPath: walURL.path)
        let afterSHM = try FileManager.default.attributesOfItem(atPath: shmURL.path)
        let afterDatabaseData = try Data(contentsOf: databaseURL)
        let afterWALData = try Data(contentsOf: walURL)
        let afterSHMData = try Data(contentsOf: shmURL)

        #expect(values == [
            "cursorAuth/accessToken": "owner-token",
            "cursorAuth/utf16Token": "utf16-token",
            "cursorAuth/utf16BOMToken": "utf16-token",
        ])
        #expect(before[.size] as? NSNumber == after[.size] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.posixPermissions] as? NSNumber == after[.posixPermissions] as? NSNumber)
        #expect(before[.ownerAccountID] as? NSNumber == after[.ownerAccountID] as? NSNumber)
        #expect(before[.groupOwnerAccountID] as? NSNumber == after[.groupOwnerAccountID] as? NSNumber)
        #expect(beforeWAL[.size] as? NSNumber == afterWAL[.size] as? NSNumber)
        #expect(beforeWAL[.modificationDate] as? Date == afterWAL[.modificationDate] as? Date)
        #expect(beforeWAL[.systemFileNumber] as? NSNumber == afterWAL[.systemFileNumber] as? NSNumber)
        #expect(beforeWAL[.posixPermissions] as? NSNumber == afterWAL[.posixPermissions] as? NSNumber)
        #expect(beforeWAL[.ownerAccountID] as? NSNumber == afterWAL[.ownerAccountID] as? NSNumber)
        #expect(beforeWAL[.groupOwnerAccountID] as? NSNumber == afterWAL[.groupOwnerAccountID] as? NSNumber)
        #expect(beforeSHM[.size] as? NSNumber == afterSHM[.size] as? NSNumber)
        #expect(beforeSHM[.modificationDate] as? Date == afterSHM[.modificationDate] as? Date)
        #expect(beforeSHM[.systemFileNumber] as? NSNumber == afterSHM[.systemFileNumber] as? NSNumber)
        #expect(beforeSHM[.posixPermissions] as? NSNumber == afterSHM[.posixPermissions] as? NSNumber)
        #expect(beforeSHM[.ownerAccountID] as? NSNumber == afterSHM[.ownerAccountID] as? NSNumber)
        #expect(beforeSHM[.groupOwnerAccountID] as? NSNumber == afterSHM[.groupOwnerAccountID] as? NSNumber)
        #expect(beforeDatabaseData == afterDatabaseData)
        #expect(beforeWALData == afterWALData)
        #expect(beforeSHMData == afterSHMData)
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path + "-journal"))
    }
    @Test("SQLite reader rejects non-Cursor capability requests")
    func sqliteProviderScope() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.vscdb")
        let policy = FilesystemAccessPolicy(homeDirectory: root)
        let reader = SQLiteExternalSessionReader(policy: policy)

        await expectCollectionError(
            kind: .sourceUnavailable,
            code: "capability.sqlite.denied"
        ) {
            _ = try await reader.values(
                in: ExternalFileRequest(providerID: .grok, relativePath: "state.vscdb"),
                table: "ItemTable",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["cursorAuth/accessToken"]
            )
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test("SQLite reader rejects malformed and oversized token values")
    func sqliteValueBounds() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("state.vscdb")

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        guard let database else { return }
        #expect(
            sqlite3_exec(
                database,
                "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB NOT NULL)",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        #expect(
            sqlite3_exec(
                database,
                "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', zeroblob(4194305))",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(database)

        let reader = SQLiteExternalSessionReader(
            policy: FilesystemAccessPolicy(homeDirectory: root)
        )
        await expectCollectionError(
            kind: .malformedResponse,
            code: "sqlite.value-size-limit"
        ) {
            _ = try await reader.values(
                in: ExternalFileRequest(
                    providerID: .cursor,
                    relativePath: "state.vscdb",
                    maximumBytes: 64 * 1024 * 1024
                ),
                table: "ItemTable",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["cursorAuth/accessToken"]
            )
        }

        await expectCollectionError(kind: .unsafePath, code: "filesystem.size-limit") {
            _ = try await reader.values(
                in: ExternalFileRequest(
                    providerID: .cursor,
                    relativePath: "state.vscdb",
                    maximumBytes: 1
                ),
                table: "ItemTable",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["cursorAuth/accessToken"]
            )
        }

        await expectCollectionError(kind: .unsafePath, code: "sqlite.key-limit") {
            _ = try await reader.values(
                in: ExternalFileRequest(
                    providerID: .cursor,
                    relativePath: "state.vscdb",
                    maximumBytes: 64 * 1024 * 1024
                ),
                table: "ItemTable",
                keyColumn: "key",
                valueColumn: "value",
                keys: (0..<65).map { "key-\($0)" }
            )
        }

        var reopened: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &reopened) == SQLITE_OK)
        guard let reopened else { return }
        #expect(
            sqlite3_exec(
                reopened,
                "UPDATE ItemTable SET value = 123 WHERE key = 'cursorAuth/accessToken'",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(reopened)

        await expectCollectionError(kind: .malformedResponse, code: "sqlite.value-type-invalid") {
            _ = try await reader.values(
                in: ExternalFileRequest(
                    providerID: .cursor,
                    relativePath: "state.vscdb",
                    maximumBytes: 64 * 1024 * 1024
                ),
                table: "ItemTable",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["cursorAuth/accessToken"]
            )
        }
    }
    @Test("SQLite reader rejects duplicate keys and view-backed queries")
    func sqliteSchemaAndRowBounds() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("state.vscdb")

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        guard let database else { return }
        #expect(
            sqlite3_exec(
                database,
                "CREATE TABLE DuplicateItems (key TEXT NOT NULL, value TEXT NOT NULL)",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        #expect(
            sqlite3_exec(
                database,
                "INSERT INTO DuplicateItems VALUES ('cursorAuth/accessToken', 'first'), ('cursorAuth/accessToken', 'second')",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        #expect(
            sqlite3_exec(
                database,
                "CREATE VIEW ItemView AS SELECT key, value FROM DuplicateItems",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(database)

        let reader = SQLiteExternalSessionReader(
            policy: FilesystemAccessPolicy(homeDirectory: root)
        )
        let request = ExternalFileRequest(
            providerID: .cursor,
            relativePath: "state.vscdb",
            maximumBytes: 64 * 1024 * 1024
        )
        await expectCollectionError(kind: .malformedResponse, code: "sqlite.duplicate-key") {
            _ = try await reader.values(
                in: request,
                table: "DuplicateItems",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["cursorAuth/accessToken"]
            )
        }
        await expectCollectionError(kind: .schemaChanged, code: "sqlite.table-invalid") {
            _ = try await reader.values(
                in: request,
                table: "ItemView",
                keyColumn: "key",
                valueColumn: "value",
                keys: ["cursorAuth/accessToken"]
            )
        }
    }

    @Test("network capability rejects unreviewed destinations and unsafe request shapes")
    func networkAllowlist() async {
        let client = URLSessionNetworkClient()
        let cursorURL = URL(string: "https://cursor.com/api/usage-summary")!
        let approvedRequests = [
            NetworkRequest(
                providerID: .claude,
                url: URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-08-01T00%3A00%3A00Z&ending_at=2026-09-01T00%3A00%3A00Z&bucket_width=1d")!
            ),
            NetworkRequest(
                providerID: .claude,
                url: URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-08-01T00%3A00%3A00Z&ending_at=2026-09-01T00%3A00%3A00Z&bucket_width=1d&page=next-page")!
            ),
            NetworkRequest(
                providerID: .grok,
                url: URL(string: "https://management-api.x.ai/v1/billing/teams/team-123/prepaid/balance")!
            ),
            NetworkRequest(providerID: .cursor, url: cursorURL),
            NetworkRequest(
                providerID: .doubao,
                url: URL(string: "https://open.volcengineapi.com?Action=GetCodingPlanUsage&Version=2024-01-01")!,
                method: .post
            ),
            NetworkRequest(
                providerID: .doubao,
                url: URL(string: "https://ark.cn-beijing.volces.com/?Action=GetAFPUsage&Version=2024-01-01")!,
                method: .post
            ),
        ]
        #expect(approvedRequests.allSatisfy(URLSessionNetworkClient.isAllowed))
        var oversizedClaudeComponents = URLComponents(
            string: "https://api.anthropic.com/v1/organizations/usage_report/messages"
        )!
        oversizedClaudeComponents.queryItems = [
            URLQueryItem(name: "starting_at", value: String(repeating: "2", count: 16 * 1024)),
            URLQueryItem(name: "ending_at", value: "2026-09-01T00:00:00Z"),
            URLQueryItem(name: "bucket_width", value: "1d"),
        ]
        let oversizedClaudeURL = oversizedClaudeComponents.url!
        let requests: [(NetworkRequest, String)] = [
            (
                NetworkRequest(
                    providerID: .claude,
                    url: URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-08-02T00%3A00%3A00Z&ending_at=2026-09-01T00%3A00%3A00Z&bucket_width=1d")!
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .claude,
                    url: URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-08-01T00%3A00%3A00Z&ending_at=2026-09-02T00%3A00%3A00Z&bucket_width=1d")!
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(providerID: .claude, url: oversizedClaudeURL),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .claude,
                    url: URL(string: "https://example.com/v1/organizations/usage_report/messages?starting_at=a&ending_at=b&bucket_width=1d")!
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .cursor,
                    url: URL(string: "https://api.cursor.com/teams/spend")!,
                    method: .post
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .cursor,
                    url: URL(string: "https://cursor.com/api/usage-summary?extra=1")!
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .cursor,
                    url: cursorURL,
                    body: Data("unexpected".utf8)
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .claude,
                    url: URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-08-01T00%3A00%3A00Z&ending_at=2026-09-01T00%3A00%3A00Z&bucket_width=1d")!,
                    body: Data("unexpected".utf8)
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .grok,
                    url: URL(string: "https://management-api.x.ai/v1/billing/teams/team-123/prepaid/balance")!,
                    body: Data("unexpected".utf8)
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .grok,
                    url: URL(string: "https://management-api.x.ai/v1/billing/teams/team%2Falpha/prepaid/balance")!
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .cursor,
                    url: cursorURL,
                    headers: ["Authorization": "Basic safe\r\nInjected: true"]
                ),
                "network.header-invalid"
            ),
            (
                NetworkRequest(
                    providerID: .cursor,
                    url: cursorURL,
                    headers: [
                        "Accept": "application/json",
                        "Cookie": String(repeating: "a", count: 32 * 1024 + 1),
                    ]
                ),
                "network.header-invalid"
            ),
            (
                NetworkRequest(
                    providerID: .doubao,
                    url: URL(string: "https://open.volcengineapi.com/?Action=DeleteEverything&Version=2024-01-01")!,
                    method: .post
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .codex,
                    url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!
                ),
                "network.destination-not-allowlisted"
            ),
            (
                NetworkRequest(
                    providerID: .doubao,
                    url: URL(string: "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01")!,
                    method: .post,
                    body: Data(count: 1_048_577)
                ),
                "network.request-size-limit"
            ),
            (
                NetworkRequest(
                    providerID: .cursor,
                    url: cursorURL,
                    timeout: 61
                ),
                "network.timeout-out-of-policy"
            ),
        ]

        for (request, diagnosticCode) in requests {
            do {
                _ = try await client.send(request)
                Issue.record("Expected network policy rejection for \(diagnosticCode)")
            } catch let error as CollectionError {
                #expect(error.kind == .sourceUnavailable)
                #expect(error.diagnosticCode == diagnosticCode)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("network responses are rejected as soon as the byte limit is crossed")
    func boundedNetworkResponse() async {
        BoundedResponseURLProtocol.setPayload(Data(repeating: 0x41, count: 4))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = URLSessionNetworkClient(
            session: session,
            maximumResponseBytes: 3
        )
        let request = NetworkRequest(
            providerID: .claude,
            url: URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-08-01T00%3A00%3A00Z&ending_at=2026-09-01T00%3A00%3A00Z&bucket_width=1d")!,
            headers: [
                "Accept": "application/json",
                "anthropic-version": "2023-06-01",
                "x-api-key": "test-key",
            ]
        )

        do {
            _ = try await client.send(request)
            Issue.record("Expected bounded response failure")
        } catch let error as CollectionError {
            #expect(error.kind == .malformedResponse)
            #expect(error.diagnosticCode == "network.response-size-limit")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
    @Test("Codex app-server reader performs the bounded read-only RPC and times out")
    func codexAppServerBoundary() async throws {
        let miseShim = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/mise/shims/codex")
        #expect(CodexAppServerUsageReader.defaultExecutableCandidates.contains(miseShim))
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let successExecutable = directory.appendingPathComponent("codex-success")
        let successScript = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\\n' '{"jsonrpc":"2.0","id":0,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"rate_limits":{"primary":{"used_percent":25,"limit_window_seconds":3600,"reset_at":1800000000}}}}'
        """
        try Data(successScript.utf8).write(to: successExecutable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: successExecutable.path)

        let reader = CodexAppServerUsageReader(
            executableCandidates: [successExecutable],
            timeout: .seconds(1)
        )
        let result = try await reader.readRateLimits()
        let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        #expect(object["rate_limits"] != nil)

        let currentExecutable = directory.appendingPathComponent("codex-current")
        let currentScript = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\\n' '{"id":0,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\\n' '{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":91}}}}'
        """
        try Data(currentScript.utf8).write(to: currentExecutable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: currentExecutable.path)

        let currentReader = CodexAppServerUsageReader(
            executableCandidates: [currentExecutable],
            timeout: .seconds(1)
        )
        let currentResult = try await currentReader.readRateLimits()
        let currentObject = try #require(
            JSONSerialization.jsonObject(with: currentResult) as? [String: Any]
        )
        #expect(currentObject["rateLimits"] != nil)

        let fractionalExecutable = directory.appendingPathComponent("codex-fractional-id")
        let fractionalScript = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\\n' '{"jsonrpc":"2.0","id":0,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\\n' '{"jsonrpc":"2.0","id":1.9,"result":{"rate_limits":{}}}'
        """
        try Data(fractionalScript.utf8).write(to: fractionalExecutable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fractionalExecutable.path
        )
        let fractionalReader = CodexAppServerUsageReader(
            executableCandidates: [fractionalExecutable],
            timeout: .seconds(1)
        )
        do {
            _ = try await fractionalReader.readRateLimits()
            Issue.record("Expected fractional JSON-RPC ID rejection")
        } catch let error as CollectionError {
            #expect(error.diagnosticCode == "codex.app-server.closed")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let timeoutExecutable = directory.appendingPathComponent("codex-timeout")
        let timeoutScript = """
        #!/bin/sh
        exec /bin/sleep 5
        """
        try Data(timeoutScript.utf8).write(to: timeoutExecutable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: timeoutExecutable.path)

        let timeoutReader = CodexAppServerUsageReader(
            executableCandidates: [timeoutExecutable],
            timeout: .milliseconds(25)
        )
        do {
            _ = try await timeoutReader.readRateLimits()
            Issue.record("Expected bounded app-server timeout")
        } catch let error as CollectionError {
            #expect(error.kind == .sourceUnavailable)
            #expect(error.diagnosticCode == "codex.app-server.timeout")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
    @Test("stable source IDs are deterministic and do not persist raw account identifiers")
    func stableSourceIDs() {
        let first = StableSourceID.make(
            prefix: "provider",
            components: ["member@example.com", "overallSpendCents"]
        )
        let repeated = StableSourceID.make(
            prefix: "provider",
            components: ["member@example.com", "overallSpendCents"]
        )
        let different = StableSourceID.make(
            prefix: "provider",
            components: ["other@example.com", "overallSpendCents"]
        )

        #expect(first == repeated)
        #expect(first != different)
        #expect(first.rawValue.hasPrefix("provider."))
        #expect(!first.rawValue.contains("member@example.com"))
    }
    @Test("diagnostic components reject payload-shaped or oversized values")
    func diagnosticSanitization() {
        #expect(
            UnifiedDiagnostics.sanitizedComponent(
                "collection.succeeded",
                fallback: "diagnostic.invalid-code"
            ) == "collection.succeeded"
        )
        #expect(
            UnifiedDiagnostics.sanitizedComponent(
                "secret=do-not-log",
                fallback: "diagnostic.invalid-code"
            ) == "diagnostic.invalid-code"
        )
        #expect(
            UnifiedDiagnostics.sanitizedComponent(
                String(repeating: "a", count: 129),
                fallback: "diagnostic.invalid-code"
            ) == "diagnostic.invalid-code"
        )
    }
    @Test("Keychain credentials use the data-protection Keychain and frozen accessibility class")
    func keychainAccessibility() async {
        let service = "com.tokentank.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        let id = CredentialID(providerID: .grok, name: "management-api-key")

        await expectCollectionError(
            kind: .sourceUnavailable,
            code: "keychain.credential-id-denied"
        ) {
            try await store.write(
                "blocked",
                for: CredentialID(providerID: .cursor, name: "access-token")
            )
        }
        await expectCollectionError(
            kind: .malformedResponse,
            code: "keychain.value-invalid"
        ) {
            try await store.write(String(repeating: "a", count: 16 * 1024 + 1), for: id)
        }

        let query = KeychainCredentialStore.dataProtectionQuery(service: service, id: id)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == service)
        #expect(query[kSecAttrAccount as String] as? String == "grok.management-api-key")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(
            query[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        #expect(
            KeychainCredentialStore.accessibilityClass
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }


    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenTankTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func expectCollectionError(
        kind: CollectionErrorKind,
        code: String? = nil,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected CollectionError.\(kind.rawValue)")
        } catch let error as CollectionError {
            #expect(error.kind == kind)
            if let code {
                #expect(error.diagnosticCode == code)
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private final class BoundedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payload = Data()

    static func setPayload(_ value: Data) {
        lock.lock()
        payload = value
        lock.unlock()
    }

    private static func currentPayload() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.currentPayload())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
