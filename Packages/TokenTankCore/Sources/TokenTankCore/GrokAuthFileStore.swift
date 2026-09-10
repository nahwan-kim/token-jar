import Darwin
import Foundation
import TokenTankDomain

struct GrokAuthFileDocument: @unchecked Sendable {
    let data: Data
    let root: [String: Any]
    let selectedKey: String
    let selectedEntry: [String: Any]
    let device: UInt64
    let inode: UInt64
    let directoryDevice: UInt64
    let directoryInode: UInt64
}
struct GrokAuthFileMutation: @unchecked Sendable {
    let expectedEntry: [String: Any]
    let replacement: [String: Any]
}

protocol GrokAuthFileRenewalLock: Sendable {
    func unlock()
}

protocol GrokAuthFileStoring: Sendable {
    func load() async throws -> GrokAuthFileDocument
    func acquireRenewalLock() async throws -> any GrokAuthFileRenewalLock
    func replacingEntry(
        in original: GrokAuthFileDocument,
        mutation: GrokAuthFileMutation
    ) async throws -> GrokAuthFileDocument
}

final class GrokAuthFileStore: GrokAuthFileStoring, @unchecked Sendable {
    private static let maximumBytes = 64 * 1024
    private let homeDirectory: URL

    init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    func load() async throws -> GrokAuthFileDocument {
        let descriptors = try openDirectories()
        defer {
            close(descriptors.grok)
            close(descriptors.home)
        }
        return try load(from: descriptors.grok)
    }

    func acquireRenewalLock() async throws -> any GrokAuthFileRenewalLock {
        let descriptors = try openDirectories()
        defer {
            close(descriptors.grok)
            close(descriptors.home)
        }
        let descriptor = try await acquireLock(in: descriptors.grok)
        return GrokFileLock(descriptor: descriptor)
    }

    func replacingEntry(
        in original: GrokAuthFileDocument,
        mutation: GrokAuthFileMutation
    ) async throws -> GrokAuthFileDocument {
        let descriptors = try openDirectories()
        defer {
            close(descriptors.grok)
            close(descriptors.home)
        }

        var current = try load(from: descriptors.grok)
        for attempt in 0...1 {
            guard current.directoryDevice == original.directoryDevice,
                  current.directoryInode == original.directoryInode,
                  current.selectedKey == original.selectedKey else {
                throw conflict()
            }
            guard dictionariesEqual(current.selectedEntry, mutation.expectedEntry) else {
                throw conflict()
            }
            var root = current.root
            root[current.selectedKey] = mutation.replacement
            let encoded: Data
            do {
                encoded = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            } catch {
                throw malformed("grok.session.auth-file.encode-failed")
            }
            guard encoded.count <= Self.maximumBytes else {
                throw unsafe("grok.session.auth-file.oversize")
            }
            do {
                try commit(
                    encoded,
                    replacing: current,
                    homeDirectory: descriptors.home,
                    grokDirectory: descriptors.grok
                )
                return try load(from: descriptors.grok)
            } catch is GrokStoreConflict where attempt == 0 {
                current = try load(from: descriptors.grok)
            } catch is GrokStoreConflict {
                throw conflict()
            }
        }
        throw conflict()
    }

    private func openDirectories() throws -> (home: Int32, grok: Int32) {
        let home = open(homeDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard home >= 0 else { throw unsafe("grok.session.home-unsafe") }
        do {
            try validateDirectory(home, code: "grok.session.home-unsafe")
            let grok = openat(home, ".grok", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard grok >= 0 else {
                if errno == ENOENT { throw missing() }
                throw unsafe("grok.session.directory-unsafe")
            }
            do {
                try validateDirectory(grok, code: "grok.session.directory-unsafe")
                return (home, grok)
            } catch {
                close(grok)
                throw error
            }
        } catch {
            close(home)
            throw error
        }
    }

    private func validateDirectory(_ descriptor: Int32, code: String) throws {
        let info = try metadata(descriptor)
        guard info.type == .typeDirectory, info.owner == UInt64(geteuid()),
              info.permissions & 0o022 == 0 else { throw unsafe(code) }
    }

    private func load(from directory: Int32) throws -> GrokAuthFileDocument {
        let descriptor = openat(directory, "auth.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw missing() }
            throw unsafe("grok.session.auth-file.open-denied")
        }
        defer { close(descriptor) }
        let info = try metadata(descriptor)
        guard info.type == .typeRegular,
              info.owner == UInt64(geteuid()),
              info.links == 1,
              info.permissions & 0o077 == 0,
              info.size <= Self.maximumBytes
        else { throw unsafe("grok.session.auth-file.unsafe") }

        var data = Data()
        data.reserveCapacity(Int(info.size))
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw unavailable("grok.session.auth-file.read-failed")
            }
            guard data.count + count <= Self.maximumBytes else {
                throw unsafe("grok.session.auth-file.oversize")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        let root: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw malformed("grok.session.auth-file.invalid-json")
            }
            root = value
        } catch let error as CollectionError {
            throw error
        } catch {
            throw malformed("grok.session.auth-file.invalid-json")
        }
        guard let selection = selectEntry(in: root) else {
            throw auth("grok.session.token-missing")
        }
        let directoryInfo = try metadata(directory)
        return GrokAuthFileDocument(
            data: data,
            root: root,
            selectedKey: selection.key,
            selectedEntry: selection.entry,
            device: info.device,
            inode: info.inode,
            directoryDevice: directoryInfo.device,
            directoryInode: directoryInfo.inode
        )
    }

    private func selectEntry(in root: [String: Any]) -> (key: String, entry: [String: Any])? {
        for key in root.keys.sorted() where key.hasPrefix("https://auth.x.ai::") {
            if let entry = root[key] as? [String: Any],
               let token = entry["key"] as? String,
               grokAccessTokenIsSafe(token) {
                return (key, entry)
            }
        }
        if let entry = root["https://accounts.x.ai/sign-in"] as? [String: Any],
           let token = entry["key"] as? String,
           grokAccessTokenIsSafe(token) {
            return ("https://accounts.x.ai/sign-in", entry)
        }
        return nil
    }

    private func acquireLock(in directory: Int32) async throws -> Int32 {
        let descriptor = openat(
            directory,
            ".token-tank-auth.lock",
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw unavailable("grok.session.lock-unavailable") }
        do {
            let info = try metadata(descriptor)
            guard info.type == .typeRegular, info.owner == UInt64(geteuid()),
                  info.links == 1, info.permissions & 0o077 == 0 else {
                throw unsafe("grok.session.lock-unsafe")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while true {
                try Task.checkCancellation()
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
                guard errno == EWOULDBLOCK || errno == EINTR else {
                    throw unavailable("grok.session.lock-unavailable")
                }
                guard ContinuousClock.now < deadline else {
                    throw unavailable("grok.session.lock-busy")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func commit(
        _ data: Data,
        replacing snapshot: GrokAuthFileDocument,
        homeDirectory: Int32,
        grokDirectory: Int32
    ) throws {
        let name = ".token-tank-auth.\(UUID().uuidString).tmp"
        let descriptor = openat(
            grokDirectory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw unavailable("grok.session.auth-file.temp-failed") }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            unlinkat(grokDirectory, name, 0)
            throw unavailable("grok.session.auth-file.temp-permissions-failed")
        }
        var keepTemp = true
        defer {
            close(descriptor)
            if keepTemp { unlinkat(grokDirectory, name, 0) }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else {
                    if count < 0, errno == EINTR { continue }
                    throw unavailable("grok.session.auth-file.write-failed")
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw unavailable("grok.session.auth-file.sync-failed") }

        try validateDirectory(grokDirectory, code: "grok.session.directory-changed")
        let namedHome = open(self.homeDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard namedHome >= 0 else { throw GrokStoreConflict() }
        defer { close(namedHome) }
        let namedGrok = openat(namedHome, ".grok", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard namedGrok >= 0 else { throw GrokStoreConflict() }
        defer { close(namedGrok) }
        try validateDirectory(namedHome, code: "grok.session.home-unsafe")
        try validateDirectory(namedGrok, code: "grok.session.directory-unsafe")
        let heldHome = try metadata(homeDirectory)
        let currentHome = try metadata(namedHome)
        let heldGrok = try metadata(grokDirectory)
        let currentGrok = try metadata(namedGrok)
        guard heldHome.device == currentHome.device, heldHome.inode == currentHome.inode,
              heldGrok.device == currentGrok.device, heldGrok.inode == currentGrok.inode
        else { throw GrokStoreConflict() }
        let current = try load(from: grokDirectory)
        guard current.device == snapshot.device,
              current.inode == snapshot.inode,
              current.data == snapshot.data
        else { throw GrokStoreConflict() }
        guard renameat(grokDirectory, name, grokDirectory, "auth.json") == 0 else {
            throw unavailable("grok.session.auth-file.rename-failed")
        }
        keepTemp = false
        guard fsync(grokDirectory) == 0 else { throw unavailable("grok.session.auth-file.directory-sync-failed") }
    }

    private struct FileMetadata {
        let type: FileAttributeType
        let owner: UInt64
        let links: UInt64
        let permissions: UInt64
        let size: UInt64
        let device: UInt64
        let inode: UInt64
    }

    private func metadata(_ descriptor: Int32) throws -> FileMetadata {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: "/dev/fd/\(descriptor)")
        } catch {
            throw unavailable("grok.session.auth-file.metadata-failed")
        }
        guard let type = attributes[.type] as? FileAttributeType,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let links = attributes[.referenceCount] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw unsafe("grok.session.auth-file.metadata-invalid")
        }
        return FileMetadata(
            type: type, owner: owner.uint64Value, links: links.uint64Value,
            permissions: permissions.uint64Value, size: size.uint64Value,
            device: device.uint64Value, inode: inode.uint64Value
        )
    }
}

private final class GrokFileLock: GrokAuthFileRenewalLock, @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func unlock() {
        mutex.lock()
        defer { mutex.unlock() }
        guard let descriptor else { return }
        self.descriptor = nil
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { unlock() }
}

private struct GrokStoreConflict: Error {}

func grokAccessTokenIsSafe(_ token: String) -> Bool {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == token, !token.isEmpty, token.utf8.count <= 8_192 else { return false }
    let lowered = token.lowercased()
    guard !lowered.hasPrefix("xai-"),
          !lowered.contains("cookie:"),
          !lowered.contains("authorization:"),
          !token.contains("\r"),
          !token.contains("\n"),
          !(token.contains("=") && token.contains(";"))
    else { return false }
    return token.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value != 0x7f }
}

private func dictionariesEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    NSDictionary(dictionary: lhs).isEqual(to: rhs)
}

private func conflict() -> CollectionError {
    CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.session.auth-file.conflict")
}

private func missing() -> CollectionError {
    CollectionError(
        kind: .externalSessionMissing,
        diagnosticCode: "grok.session.auth-file.missing",
        recoveryAction: .signInSourceApp
    )
}

private func auth(_ code: String) -> CollectionError {
    CollectionError(kind: .authenticationRejected, diagnosticCode: code, recoveryAction: .signInSourceApp)
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
