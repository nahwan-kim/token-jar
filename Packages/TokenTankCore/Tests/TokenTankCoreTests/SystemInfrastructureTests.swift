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
        let grokURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        let approvedRequests = [
            NetworkRequest(providerID: .grok, url: grokURL),
            NetworkRequest(providerID: .cursor, url: cursorURL),
        ]
        #expect(approvedRequests.allSatisfy(URLSessionNetworkClient.isAllowed))
        let requests: [(NetworkRequest, String)] = [
            (
                NetworkRequest(
                    providerID: .claude,
                    url: URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-08-01T00%3A00%3A00Z&ending_at=2026-09-01T00%3A00%3A00Z&bucket_width=1d")!
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
                    providerID: .grok,
                    url: URL(string: "https://management-api.x.ai/v1/billing/teams/team-123/prepaid/balance")!
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
                "network.destination-not-allowlisted"
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
            providerID: .cursor,
            url: URL(string: "https://cursor.com/api/usage-summary")!,
            headers: [
                "Accept": "application/json",
                "Cookie": "WorkosCursorSessionToken=user%3A%3Atoken",
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
        IFS= read -r rateLimitsRequest
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"rate_limits":{"primary":{"used_percent":25,"limit_window_seconds":3600,"reset_at":1800000000}}}}'
        IFS= read -r accountRequest
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"owner@example.com"}}}'
        """
        try Data(successScript.utf8).write(to: successExecutable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: successExecutable.path)

        let reader = CodexAppServerUsageReader(
            executableCandidates: [successExecutable],
            accountSources: [.primary],
            timeout: .seconds(1)
        )
        let reads = try await reader.readAccounts()
        let result = try #require(reads.first?.data)
        let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        #expect(object["rate_limits"] != nil)
        let account = try #require(object["account"] as? [String: Any])
        #expect(account["email"] as? String == "owner@example.com")

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
            accountSources: [.primary],
            timeout: .seconds(1)
        )
        let currentReads = try await currentReader.readAccounts()
        let currentResult = try #require(currentReads.first?.data)
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
            accountSources: [.primary],
            timeout: .seconds(1)
        )
        let fractionalReads = try await fractionalReader.readAccounts()
        let fractionalFailure = try #require(fractionalReads.first?.failure)
        #expect(fractionalFailure.diagnosticCode == "codex.app-server.closed")

        let timeoutExecutable = directory.appendingPathComponent("codex-timeout")
        let timeoutScript = """
        #!/bin/sh
        exec /bin/sleep 5
        """
        try Data(timeoutScript.utf8).write(to: timeoutExecutable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: timeoutExecutable.path)

        let timeoutReader = CodexAppServerUsageReader(
            executableCandidates: [timeoutExecutable],
            accountSources: [.primary],
            timeout: .milliseconds(25)
        )
        let timeoutReads = try await timeoutReader.readAccounts()
        let timeoutFailure = try #require(timeoutReads.first?.failure)
        #expect(timeoutFailure.kind == .sourceUnavailable)
        #expect(timeoutFailure.diagnosticCode == "codex.app-server.timeout")
    }
    @Test("Codex app-server handles an early child exit without terminating the host")
    func codexEarlyChildExitDoesNotRaiseSIGPIPE() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex-early-exit")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        exec 0<&-
        ( /bin/sleep 0.1; printf '%s\\n' '{"jsonrpc":"2.0","id":0,"result":{}}' ) &
        exit 13
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let reader = CodexAppServerUsageReader(
            executableCandidates: [executable],
            accountSources: [.primary],
            timeout: .seconds(1)
        )
        let reads = try await reader.readAccounts()
        let failure = try #require(reads.first?.failure)
        #expect(failure.kind == .sourceUnavailable)
        #expect(failure.diagnosticCode == "codex.app-server.write-failed")
    }

    @Test("fast CLI exits complete cleanup repeatedly without run-loop waits", .timeLimit(.minutes(1)))
    func repeatedFastProcessExit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codex = directory.appendingPathComponent("codex-fast-exit")
        let arkcli = directory.appendingPathComponent("arkcli-fast-exit")
        let pidFile = directory.appendingPathComponent("children")
        let codexScript = """
        #!/bin/sh
        printf '%s\\n' "$$" >> "\(pidFile.path)"
        IFS= read -r initialize
        printf '%s\\n' '{"id":0,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\\n' '{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":25}}}}'
        """
        let arkScript = """
        #!/bin/sh
        printf '%s\\n' "$$" >> "\(pidFile.path)"
        printf '%s\\n' '{"items":[]}'
        """
        try Data(codexScript.utf8).write(to: codex, options: .atomic)
        try Data(arkScript.utf8).write(to: arkcli, options: .atomic)
        for executable in [codex, arkcli] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let codexReader = CodexAppServerUsageReader(
            executableCandidates: [codex], accountSources: [.primary], timeout: .seconds(1)
        )
        let arkReader = ArkCLIPlanUsageReader(executableCandidates: [arkcli], timeout: .seconds(1))
        for _ in 0..<24 {
            async let codexReads = codexReader.readAccounts()
            async let arkData = arkReader.readPlanUsage()
            let reads = try await codexReads
            #expect(reads.first?.data != nil)
            #expect(reads.first?.failure == nil)
            let data = try await arkData
            #expect(data == Data("{\"items\":[]}\n".utf8))
        }
        let pids = try String(contentsOf: pidFile, encoding: .utf8)
            .split(separator: "\n").compactMap { Int32($0) }
        #expect(pids.count == 48)
        for pid in pids {
            #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "CLI child must be reaped before returning")
        }
    }
    @Test("Codex app-server identity RPC failures preserve successful rate limits")
    func codexIdentityFailurePreservesUsage() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex-account-failure")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\\n' '{"id":0,"result":{}}'
        IFS= read -r initialized
        IFS= read -r rateLimitsRequest
        printf '%s\\n' '{"id":1,"result":{"rate_limits":{"primary":{"used_percent":12}}}}'
        IFS= read -r accountRequest
        printf '%s\\n' '{"id":2,"error":{"code":401,"message":"account unavailable"}}'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let reader = CodexAppServerUsageReader(
            executableCandidates: [executable],
            accountSources: [.primary],
            timeout: .seconds(1)
        )
        let reads = try await reader.readAccounts()
        let result = try #require(reads.first?.data)
        let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        #expect(object["rate_limits"] != nil)
        #expect(object["account"] == nil)
    }
    @Test("omits an absent optional secondary source without failing the primary")
    func absentOptionalSecondaryIsNotAnError() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primaryHome = directory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryHome, withIntermediateDirectories: true)

        let executable = directory.appendingPathComponent("codex-primary-only")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\\n' '{"id":0,"result":{}}'
        IFS= read -r initialized
        IFS= read -r rateLimitsRequest
        printf '%s\\n' '{"id":1,"result":{"rate_limits":{"primary":{"used_percent":25}}}}'
        IFS= read -r accountRequest
        printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"primary@example.com"}}}'
        sleep 1
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let reader = CodexAppServerUsageReader(
            executableCandidates: [executable],
            homeDirectory: directory,
            accountSources: CodexAccountSource.allCases,
            timeout: .seconds(1)
        )
        let reads = try await reader.readAccounts()

        #expect(reads.map(\.sourceID) == [.primary])
        #expect(reads.first?.failure == nil)
        #expect(reads.first?.data != nil)
    }

    @Test("separates Codex source homes and secondary fixed credential configuration")
    func codexSourceEnvironmentIsIsolated() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for source in CodexAccountSource.allCases {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(source.directoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let executable = directory.appendingPathComponent("codex-isolated-sources")
        let script = """
        #!/bin/sh
        set -eu
        if [ -n "${OPENAI_API_KEY:-}" ] ||
           [ -n "${OPENAI_ACCESS_TOKEN:-}" ] ||
           [ -n "${CODEX_API_KEY:-}" ] ||
           [ -n "${CODEX_ACCESS_TOKEN:-}" ] ||
           [ -n "${CODEX_AUTH:-}" ] ||
           [ -n "${CODEX_REFRESH_TOKEN_URL_OVERRIDE:-}" ]; then
            exit 90
        fi
        case "$CODEX_HOME" in
          */.codex-secondary)
            [ "$1" = "-c" ] || exit 91
            [ "$2" = 'cli_auth_credentials_store="file"' ] || exit 92
            [ "$3" = "app-server" ] || exit 93
            used=75
            email=secondary@example.com
            ;;
          */.codex)
            [ "$1" = "app-server" ] || exit 94
            [ "$#" -eq 1 ] || exit 95
            used=25
            email=primary@example.com
            ;;
          *)
            exit 96
            ;;
        esac
        printf 'arg1=%s\\narg2=%s\\narg3=%s\\n' "$1" "${2-}" "${3-}" > "$CODEX_HOME/observed-environment"
        IFS= read -r initialize
        printf '%s\\n' '{"id":0,"result":{}}'
        IFS= read -r initialized
        IFS= read -r rateLimitsRequest
        printf '{"id":1,"result":{"rate_limits":{"primary":{"used_percent":%s}}}}\\n' "$used"
        IFS= read -r accountRequest
        printf '{"id":2,"result":{"account":{"type":"chatgpt","email":"%s"}}}\\n' "$email"
        sleep 1
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let authKeys = [
            "OPENAI_API_KEY",
            "OPENAI_ACCESS_TOKEN",
            "CODEX_API_KEY",
            "CODEX_ACCESS_TOKEN",
            "CODEX_AUTH",
            "CODEX_REFRESH_TOKEN_URL_OVERRIDE",
        ]
        let originalValues = authKeys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        for key in authKeys {
            #expect(setenv(key, "cross-account-secret", 1) == 0)
        }
        defer {
            for (key, value) in originalValues {
                if let value {
                    _ = setenv(key, value, 1)
                } else {
                    _ = unsetenv(key)
                }
            }
        }

        let reader = CodexAppServerUsageReader(
            executableCandidates: [executable],
            homeDirectory: directory,
            accountSources: CodexAccountSource.allCases,
            timeout: .seconds(2)
        )
        let reads = try await reader.readAccounts()
        #expect(Set(reads.map(\.sourceID)) == Set(CodexAccountSource.allCases))
        #expect(reads.allSatisfy { $0.failure == nil })

        let primaryObservation = try #require(
            String(
                data: try Data(
                    contentsOf: directory
                        .appendingPathComponent(CodexAccountSource.primary.directoryName)
                        .appendingPathComponent("observed-environment")
                ),
                encoding: .utf8
            )
        )
        let secondaryObservation = try #require(
            String(
                data: try Data(
                    contentsOf: directory
                        .appendingPathComponent(CodexAccountSource.secondary.directoryName)
                        .appendingPathComponent("observed-environment")
                ),
                encoding: .utf8
            )
        )
        #expect(primaryObservation.contains("arg1=app-server"))
        #expect(primaryObservation.contains("arg2=\n"))
        #expect(primaryObservation.contains("arg3=\n"))
        #expect(secondaryObservation.contains("arg1=-c"))
        #expect(secondaryObservation.contains("arg2=cli_auth_credentials_store=\"file\""))
        #expect(secondaryObservation.contains("arg3=app-server"))
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
        let id = CredentialID(providerID: .doubao, name: "access-key-id")
        await expectCollectionError(
            kind: .sourceUnavailable,
            code: "keychain.credential-id-denied"
        ) {
            try await KeychainCredentialStore(service: service).write("blocked", for: id)
        }

        let query = KeychainCredentialStore.dataProtectionQuery(service: service, id: id)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == service)
        #expect(query[kSecAttrAccount as String] as? String == "doubao.access-key-id")
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
