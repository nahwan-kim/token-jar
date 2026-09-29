import CryptoKit
import Foundation
import TokenTankDomain

/// Process-lifetime memory for supplemental Claude requests. Nothing here is written to disk
/// or the Keychain, and access tokens are held only as SHA-256 digests.
actor ClaudeAccountMemory {
    private struct ProfileEntry {
        let tokenDigest: String
        let profile: ClaudeProfile
    }

    private struct ResetEntry {
        let identity: String?
        let fetchedAt: Date
        let items: [RawQuotaItem]
    }

    private var profiles: [String: ProfileEntry] = [:]
    private var resets: [String: ResetEntry] = [:]

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func retain(sourceIDs: Set<String>) {
        profiles = profiles.filter { sourceIDs.contains($0.key) }
        resets = resets.filter { sourceIDs.contains($0.key) }
    }

    func profile(for sourceID: String, tokenDigest: String) -> ClaudeProfile? {
        guard let entry = profiles[sourceID], entry.tokenDigest == tokenDigest else { return nil }
        return entry.profile
    }

    func storeProfile(_ profile: ClaudeProfile, for sourceID: String, tokenDigest: String) {
        profiles[sourceID] = ProfileEntry(tokenDigest: tokenDigest, profile: profile)
    }

    func resetCredits(for sourceID: String, identity: String?, now: Date, maximumAge: TimeInterval) -> [RawQuotaItem]? {
        guard let entry = resets[sourceID], entry.identity == identity else { return nil }
        let age = now.timeIntervalSince(entry.fetchedAt)
        guard age >= 0, age < maximumAge else { return nil }
        return entry.items
    }

    func lastResetCredits(for sourceID: String, identity: String?) -> [RawQuotaItem]? {
        guard let entry = resets[sourceID], entry.identity == identity else { return nil }
        return entry.items
    }

    func storeResetCredits(_ items: [RawQuotaItem], for sourceID: String, identity: String?, fetchedAt: Date) {
        resets[sourceID] = ResetEntry(identity: identity, fetchedAt: fetchedAt, items: items)
    }
}
