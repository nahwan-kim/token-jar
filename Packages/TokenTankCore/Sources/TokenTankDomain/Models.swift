import Foundation

public enum ProviderID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case claude
    case grok
    case cursor
    case doubao

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .cursor: "Cursor"
        case .doubao: "Doubao"
        }
    }

    public var defaultAbbreviation: String {
        switch self {
        case .codex: "CDX"
        case .claude: "CLD"
        case .grok: "GRK"
        case .cursor: "CUR"
        case .doubao: "DB"
        }
    }
}

public struct RawQuotaID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

public struct SourceValue: Codable, Equatable, Hashable, Sendable {
    public let value: Decimal
    public let rawText: String
    public let unit: String?

    public init(value: Decimal, rawText: String, unit: String? = nil) {
        self.value = value
        self.rawText = rawText
        self.unit = unit
    }
}

public enum PercentageMeaning: String, Codable, Equatable, Hashable, Sendable {
    case used
    case remaining
}

public struct SourcePercentage: Codable, Equatable, Hashable, Sendable {
    public let value: Decimal?
    public let rawText: String?
    public let meaning: PercentageMeaning

    public init(value: Decimal?, rawText: String?, meaning: PercentageMeaning) {
        self.value = value
        self.rawText = rawText
        self.meaning = meaning
    }

    public static func missing(meaning: PercentageMeaning) -> SourcePercentage {
        SourcePercentage(value: nil, rawText: nil, meaning: meaning)
    }
}

public enum ProviderSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case officialAPI
    case officialCLI
    case localSession
}

public enum CredentialOwnership: String, Codable, Equatable, Hashable, Sendable {
    case tokenTank
    case externalProvider
}

public struct ProviderSourceDescriptor: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: ProviderSourceKind
    public let credentialOwnership: CredentialOwnership
    public let documentationURL: URL?
    public let detail: String

    public init(
        id: String,
        name: String,
        kind: ProviderSourceKind,
        credentialOwnership: CredentialOwnership,
        documentationURL: URL?,
        detail: String
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.credentialOwnership = credentialOwnership
        self.documentationURL = documentationURL
        self.detail = detail
    }
}

public struct RawQuotaItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: RawQuotaID
    public let originalName: String
    public let used: SourceValue?
    public let remaining: SourceValue?
    public let percentage: SourcePercentage
    public let resetsAt: Date?
    public let sourceFields: [String: String]

    public init(
        id: RawQuotaID,
        originalName: String,
        used: SourceValue?,
        remaining: SourceValue?,
        percentage: SourcePercentage,
        resetsAt: Date?,
        sourceFields: [String: String] = [:]
    ) {
        self.id = id
        self.originalName = originalName
        self.used = used
        self.remaining = remaining
        self.percentage = percentage
        self.resetsAt = resetsAt
        self.sourceFields = sourceFields
    }
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let providerID: ProviderID
    public let source: ProviderSourceDescriptor
    public let quotas: [RawQuotaItem]
    public let refreshedAt: Date
    public let accountEmail: String?

    public init(
        providerID: ProviderID,
        source: ProviderSourceDescriptor,
        quotas: [RawQuotaItem],
        refreshedAt: Date,
        accountEmail: String? = nil
    ) {
        self.providerID = providerID
        self.source = source
        self.quotas = quotas
        self.refreshedAt = refreshedAt
        self.accountEmail = Self.validatedAccountEmail(accountEmail)
    }

    public static func validatedAccountEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.utf8.count <= 254, parts.count == 2,
              !parts[0].isEmpty, !parts[1].isEmpty,
              !email.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.illegalCharacters.contains($0)
                      || $0.properties.generalCategory == .format
              }) else { return nil }
        return email
    }
}

public enum CollectionErrorKind: String, Codable, CaseIterable, Sendable {
    case transientNetwork
    case offline
    case rateLimited
    case sourceUnavailable
    case schemaChanged
    case malformedResponse
    case authenticationRejected
    case authenticationRevoked
    case externalSessionMissing
    case appCredentialMissing
    case keychainUnavailable
    case permissionDenied
    case unsafePath
    case cancelled
}

public enum RecoveryAction: String, Codable, Equatable, Sendable {
    case retry
    case waitForNextRefresh
    case signInSourceApp
    case signInTokenTank
    case allowAccessInSystemSettings
    case none
}

public struct CollectionError: Error, Codable, Equatable, Sendable {
    public let kind: CollectionErrorKind
    public let diagnosticCode: String
    public let recoveryAction: RecoveryAction
    public let retryAfter: Date?

    public init(
        kind: CollectionErrorKind,
        diagnosticCode: String,
        recoveryAction: RecoveryAction? = nil,
        retryAfter: Date? = nil
    ) {
        self.kind = kind
        self.diagnosticCode = diagnosticCode
        self.recoveryAction = recoveryAction ?? kind.defaultRecoveryAction
        self.retryAfter = retryAfter
    }
}

public extension CollectionErrorKind {
    var defaultRecoveryAction: RecoveryAction {
        switch self {
        case .transientNetwork, .offline, .sourceUnavailable, .schemaChanged,
             .malformedResponse, .keychainUnavailable, .cancelled:
            .waitForNextRefresh
        case .rateLimited:
            .waitForNextRefresh
        case .authenticationRejected, .authenticationRevoked, .appCredentialMissing:
            .signInTokenTank
        case .externalSessionMissing:
            .signInSourceApp
        case .permissionDenied:
            .allowAccessInSystemSettings
        case .unsafePath:
            .none
        }
    }

    var requiresAuthenticationAction: Bool {
        switch self {
        case .authenticationRejected, .authenticationRevoked, .externalSessionMissing, .appCredentialMissing:
            true
        default:
            false
        }
    }
}

public enum CollectionState: Equatable, Sendable {
    case neverLoaded
    case refreshing(previous: ProviderSnapshot?)
    case fresh(ProviderSnapshot)
    case stale(snapshot: ProviderSnapshot?, failure: CollectionError, failedAt: Date)
    case authenticationActionRequired(snapshot: ProviderSnapshot?, failure: CollectionError)

    public var snapshot: ProviderSnapshot? {
        switch self {
        case .neverLoaded:
            nil
        case let .refreshing(previous):
            previous
        case let .fresh(snapshot):
            snapshot
        case let .stale(snapshot, _, _):
            snapshot
        case let .authenticationActionRequired(snapshot, _):
            snapshot
        }
    }

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

public enum ProviderAvailability: Equatable, Sendable {
    case available(ProviderSourceDescriptor)
    case needsConfiguration(code: String)
    case unavailable(CollectionError)
}

public struct ProviderPreference: Codable, Equatable, Sendable, Identifiable {
    public let providerID: ProviderID
    public var isVisible: Bool
    public var order: Int
    public var abbreviation: String
    public var representativeQuotaID: RawQuotaID?

    public var id: ProviderID { providerID }

    public init(
        providerID: ProviderID,
        isVisible: Bool = true,
        order: Int,
        abbreviation: String? = nil,
        representativeQuotaID: RawQuotaID? = nil
    ) {
        self.providerID = providerID
        self.isVisible = isVisible
        self.order = order
        self.abbreviation = abbreviation ?? providerID.defaultAbbreviation
        self.representativeQuotaID = representativeQuotaID
    }

    public func normalized() -> ProviderPreference {
        var normalized = self
        let sanitized = abbreviation.unicodeScalars.reduce(into: "") { result, scalar in
            guard
                !CharacterSet.controlCharacters.contains(scalar),
                !CharacterSet.newlines.contains(scalar)
            else { return }
            result.unicodeScalars.append(scalar)
        }
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.abbreviation = trimmed.isEmpty
            ? providerID.defaultAbbreviation
            : String(trimmed.prefix(8))
        return normalized
    }
}

public struct UserPreferences: Codable, Equatable, Sendable {
    public var providers: [ProviderPreference]

    public init(providers: [ProviderPreference] = UserPreferences.defaults) {
        self.providers = providers
    }

    public static let defaults = ProviderID.allCases.enumerated().map { index, providerID in
        ProviderPreference(providerID: providerID, order: index)
    }

    public func preference(for providerID: ProviderID) -> ProviderPreference {
        providers.first(where: { $0.providerID == providerID })
            ?? ProviderPreference(providerID: providerID, order: ProviderID.allCases.firstIndex(of: providerID) ?? 0)
    }

    public func normalized() -> UserPreferences {
        var seen = Set<ProviderID>()
        var normalizedProviders = providers
            .filter { seen.insert($0.providerID).inserted }
            .map { $0.normalized() }
        for providerID in ProviderID.allCases where !seen.contains(providerID) {
            normalizedProviders.append(
                ProviderPreference(
                    providerID: providerID,
                    order: normalizedProviders.count
                )
            )
        }
        return UserPreferences(providers: normalizedProviders)
    }

    public var visibleProviders: [ProviderPreference] {
        providers.filter(\.isVisible).sorted { lhs, rhs in
            if lhs.order == rhs.order { return lhs.providerID.rawValue < rhs.providerID.rawValue }
            return lhs.order < rhs.order
        }
    }
}
