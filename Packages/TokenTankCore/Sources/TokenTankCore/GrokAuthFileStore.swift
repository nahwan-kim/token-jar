import Darwin
import Foundation
import TokenTankDomain

struct GrokAuthFileDocument: @unchecked Sendable {
    let data: Data
    let root: [String: Any]
    /// Session entries with a safe access token: official OIDC scopes by key, then the legacy sign-in.
    let entries: [(key: String, value: [String: Any])]
}

protocol GrokAuthFileStoring: Sendable {
    func load() async throws -> GrokAuthFileDocument
}

/// Read-only access to `~/.grok/auth.json`. The Grok CLI owns and rewrites this file.
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
        let entries = sessionEntries(in: root)
        guard !entries.isEmpty else {
            throw auth("grok.session.token-missing")
        }
        return GrokAuthFileDocument(data: data, root: root, entries: entries)
    }

    private func sessionEntries(in root: [String: Any]) -> [(key: String, value: [String: Any])] {
        var entries: [(key: String, value: [String: Any])] = []
        for key in root.keys.sorted() where key.hasPrefix("https://auth.x.ai::") {
            if let entry = root[key] as? [String: Any],
               let token = entry["key"] as? String,
               grokAccessTokenIsSafe(token) {
                entries.append((key, entry))
            }
        }
        if let entry = root["https://accounts.x.ai/sign-in"] as? [String: Any],
           let token = entry["key"] as? String,
           grokAccessTokenIsSafe(token) {
            entries.append(("https://accounts.x.ai/sign-in", entry))
        }
        return entries
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
