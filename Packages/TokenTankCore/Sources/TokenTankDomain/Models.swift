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
public enum CodexAccountSource: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case primary = "codex.primary"
    case secondary = "codex.secondary"

    public var id: String { rawValue }

    public var directoryName: String {
        switch self {
        case .primary:
            ".codex"
        case .secondary:
            ".codex-secondary"
        }
    }

    public var displayName: String {
        switch self {
        case .primary:
            "Default"
        case .secondary:
            "Secondary"
        }
    }

    public var isOptional: Bool {
        self == .secondary
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

public struct ProviderAccountSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let sourceID: String
    public let quotas: [RawQuotaItem]
    public let refreshedAt: Date?
    public let accountEmail: String?
    public let plan: String?
    public let failure: CollectionError?
    public let failedAt: Date?

    public var id: String { sourceID }
    public var isStale: Bool { failure != nil }
    public var hasData: Bool {
        !quotas.isEmpty || accountEmail != nil || plan != nil || refreshedAt != nil
    }

    public init(
        sourceID: String,
        quotas: [RawQuotaItem],
        refreshedAt: Date? = nil,
        accountEmail: String? = nil,
        plan: String? = nil,
        failure: CollectionError? = nil,
        failedAt: Date? = nil
    ) {
        self.sourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.quotas = quotas
        self.refreshedAt = refreshedAt
        self.accountEmail = ProviderSnapshot.validatedAccountEmail(accountEmail)
        self.plan = Self.validatedPlan(plan)
        self.failure = failure
        self.failedAt = failedAt
    }

    public static func validatedPlan(_ value: String?) -> String? {
        guard let value else { return nil }
        let plan = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plan.isEmpty, plan.utf8.count <= 128,
              !plan.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.illegalCharacters.contains($0)
                      || $0.properties.generalCategory == .format
              }) else { return nil }
        return plan
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID
        case quotas
        case refreshedAt
        case accountEmail
        case plan
        case failure
        case failedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceID = try container.decode(String.self, forKey: .sourceID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.quotas = try container.decodeIfPresent([RawQuotaItem].self, forKey: .quotas) ?? []
        self.refreshedAt = try container.decodeIfPresent(Date.self, forKey: .refreshedAt)
        self.accountEmail = ProviderSnapshot.validatedAccountEmail(
            try container.decodeIfPresent(String.self, forKey: .accountEmail)
        )
        self.plan = Self.validatedPlan(
            try container.decodeIfPresent(String.self, forKey: .plan)
        )
        self.failure = try container.decodeIfPresent(CollectionError.self, forKey: .failure)
        self.failedAt = try container.decodeIfPresent(Date.self, forKey: .failedAt)
    }
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let providerID: ProviderID
    public let source: ProviderSourceDescriptor
    public let quotas: [RawQuotaItem]
    public let refreshedAt: Date
    public let accountEmail: String?
    public let accounts: [ProviderAccountSnapshot]

    public init(
        providerID: ProviderID,
        source: ProviderSourceDescriptor,
        quotas: [RawQuotaItem],
        refreshedAt: Date,
        accountEmail: String? = nil,
        accounts: [ProviderAccountSnapshot] = []
    ) {
        self.providerID = providerID
        self.source = source
        self.quotas = quotas
        self.refreshedAt = refreshedAt
        self.accountEmail = Self.validatedAccountEmail(accountEmail)
        self.accounts = accounts.sorted { lhs, rhs in
            if lhs.sourceID == rhs.sourceID {
                return lhs.id < rhs.id
            }
            return lhs.sourceID < rhs.sourceID
        }
    }

    public init(
        providerID: ProviderID,
        source: ProviderSourceDescriptor,
        accounts: [ProviderAccountSnapshot],
        refreshedAt: Date
    ) {
        let primaryEmail = accounts.first {
            $0.sourceID == CodexAccountSource.primary.id
        }?.accountEmail ?? accounts.first?.accountEmail
        self.init(
            providerID: providerID,
            source: source,
            quotas: accounts.count == 1 ? accounts[0].quotas : [],
            refreshedAt: refreshedAt,
            accountEmail: primaryEmail,
            accounts: accounts
        )
    }

    public func account(for sourceID: String) -> ProviderAccountSnapshot? {
        accounts.first { $0.sourceID == sourceID }
    }

    public var hasStaleAccounts: Bool {
        accounts.contains(where: \.isStale)
    }

    public func retainingAccountData(from previous: ProviderSnapshot?) -> ProviderSnapshot {
        guard providerID == .codex, !accounts.isEmpty else { return self }
        var previousBySourceID: [String: ProviderAccountSnapshot] = [:]
        for account in previous?.accounts ?? [] {
            previousBySourceID[account.sourceID] = account
        }
        let mergedAccounts = accounts.map { current in
            guard let failure = current.failure,
                  let previous = previousBySourceID[current.sourceID]
            else {
                return current
            }
            return ProviderAccountSnapshot(
                sourceID: current.sourceID,
                quotas: previous.quotas,
                refreshedAt: previous.refreshedAt,
                accountEmail: previous.accountEmail,
                plan: previous.plan,
                failure: failure,
                failedAt: current.failedAt
            )
        }
        return ProviderSnapshot(
            providerID: providerID,
            source: source,
            quotas: mergedAccounts.count == 1 ? mergedAccounts[0].quotas : [],
            refreshedAt: refreshedAt,
            accountEmail: mergedAccounts.first {
                $0.sourceID == CodexAccountSource.primary.id
            }?.accountEmail ?? accountEmail,
            accounts: mergedAccounts
        )
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

    private enum CodingKeys: String, CodingKey {
        case providerID
        case source
        case quotas
        case refreshedAt
        case accountEmail
        case accounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providerID = try container.decode(ProviderID.self, forKey: .providerID)
        self.source = try container.decode(ProviderSourceDescriptor.self, forKey: .source)
        self.quotas = try container.decodeIfPresent([RawQuotaItem].self, forKey: .quotas) ?? []
        self.refreshedAt = try container.decode(Date.self, forKey: .refreshedAt)
        self.accountEmail = Self.validatedAccountEmail(
            try container.decodeIfPresent(String.self, forKey: .accountEmail)
        )
        self.accounts = (try container.decodeIfPresent(
            [ProviderAccountSnapshot].self,
            forKey: .accounts
        ) ?? []).sorted { lhs, rhs in
            if lhs.sourceID == rhs.sourceID {
                return lhs.id < rhs.id
            }
            return lhs.sourceID < rhs.sourceID
        }
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
    public var representativeQuotaID: RawQuotaID?

    public var id: ProviderID { providerID }

    public init(
        providerID: ProviderID,
        isVisible: Bool = true,
        order: Int,
        representativeQuotaID: RawQuotaID? = nil
    ) {
        self.providerID = providerID
        self.isVisible = isVisible
        self.order = order
        self.representativeQuotaID = representativeQuotaID
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case isVisible
        case order
        case representativeQuotaID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerID: try container.decode(ProviderID.self, forKey: .providerID),
            isVisible: try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true,
            order: try container.decodeIfPresent(Int.self, forKey: .order) ?? 0,
            representativeQuotaID: try container.decodeIfPresent(
                RawQuotaID.self,
                forKey: .representativeQuotaID
            )
        )
    }
}

public struct UserPreferences: Codable, Equatable, Sendable {
    public var providers: [ProviderPreference]
    public var showsMenuBarPercentSign: Bool

    public init(
        providers: [ProviderPreference] = UserPreferences.defaults,
        showsMenuBarPercentSign: Bool = true
    ) {
        self.providers = providers
        self.showsMenuBarPercentSign = showsMenuBarPercentSign
    }

    private enum CodingKeys: String, CodingKey {
        case providers
        case showsMenuBarPercentSign
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providers: try container.decode([ProviderPreference].self, forKey: .providers),
            showsMenuBarPercentSign: try container.decodeIfPresent(
                Bool.self,
                forKey: .showsMenuBarPercentSign
            ) ?? true
        )
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
        for providerID in ProviderID.allCases where !seen.contains(providerID) {
            normalizedProviders.append(
                ProviderPreference(
                    providerID: providerID,
                    order: normalizedProviders.count
                )
            )
        }
        return UserPreferences(
            providers: normalizedProviders,
            showsMenuBarPercentSign: showsMenuBarPercentSign
        )
    }

    public var visibleProviders: [ProviderPreference] {
        providers.filter(\.isVisible).sorted { lhs, rhs in
            if lhs.order == rhs.order { return lhs.providerID.rawValue < rhs.providerID.rawValue }
            return lhs.order < rhs.order
        }
    }
}
