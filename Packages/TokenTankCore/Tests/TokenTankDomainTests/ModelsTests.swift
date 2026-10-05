import Foundation
import Testing
@testable import TokenTankDomain

@Suite("Token Jar domain semantics")
struct ModelsTests {
    @Test("account metadata is normalized without exposing invalid display values")
    func accountEmailValidation() {
        #expect(ProviderSnapshot.validatedAccountEmail("  owner+work@example.com \n") == "owner+work@example.com")
        for invalid: String? in [nil, "", "not-an-email", "@example.com", "owner@", "a@b@c",
                                "owner name@example.com", "owner\n@example.com",
                                "owner\t@example.com", String(UnicodeScalar(0x202E)!) + "owner@example.com",
                                String(repeating: "a", count: 243) + "@example.com"] {
            #expect(ProviderSnapshot.validatedAccountEmail(invalid) == nil)
        }
        let longest = String(repeating: "a", count: 242) + "@example.com"
        #expect(ProviderSnapshot.validatedAccountEmail(longest) == longest)
    }

    @Test("zero remains distinct from a missing source value")
    func zeroIsNotMissing() {
        let zero = SourceValue(value: 0, rawText: "0", unit: "requests")
        let item = RawQuotaItem(
            id: "requests",
            originalName: "Requests",
            used: zero,
            remaining: nil,
            percentage: .missing(meaning: .used),
            resetsAt: nil
        )

        #expect(item.used == zero)
        #expect(item.remaining == nil)
        #expect(item.percentage.value == nil)
    }

    @Test("percentage direction is source-explicit")
    func percentageDirection() {
        let used = SourcePercentage(value: 37.5, rawText: "37.5", meaning: .used)
        let remaining = SourcePercentage(value: 62.5, rawText: "62.5", meaning: .remaining)

        #expect(used.meaning == .used)
        #expect(remaining.meaning == .remaining)
        #expect(used != remaining)
    }

    @Test("only terminal authentication failures request authentication")
    func authenticationBoundary() {
        let terminal: Set<CollectionErrorKind> = [
            .authenticationRejected,
            .authenticationRevoked,
            .externalSessionMissing,
            .appCredentialMissing,
        ]

        for kind in CollectionErrorKind.allCases {
            #expect(kind.requiresAuthenticationAction == terminal.contains(kind))
        }
        #expect(CollectionErrorKind.keychainUnavailable.defaultRecoveryAction == .waitForNextRefresh)
        #expect(CollectionErrorKind.permissionDenied.defaultRecoveryAction == .allowAccessInSystemSettings)
        #expect(CollectionErrorKind.externalSessionMissing.defaultRecoveryAction == .signInSourceApp)
    }

    @Test("default preferences contain each required provider once")
    func defaultPreferences() {
        let preferences = UserPreferences()

        #expect(preferences.providers.map(\.providerID) == ProviderID.allCases)
        #expect(preferences.visibleProviders.map(\.providerID) == ProviderID.allCases)
        #expect(preferences.showsMenuBarPercentSign)
    }

    @Test("menu bar percent sign preference JSON round trips")
    func menuBarPercentSignJSONRoundTrip() throws {
        for value in [false, true] {
            let preferences = UserPreferences(showsMenuBarPercentSign: value)
            let data = try JSONEncoder().encode(preferences)
            let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)
            #expect(decoded == preferences)
        }
    }

    @Test("disabled accounts default empty, round trip, and normalize without duplicates")
    func disabledAccountsPreference() throws {
        let legacy = try JSONDecoder().decode(
            UserPreferences.self,
            from: Data(#"{"providers":[{"providerID":"codex","isVisible":true,"order":0}]}"#.utf8)
        )
        #expect(legacy.disabledAccounts.isEmpty)

        let secondary = DisabledAccount(
            providerID: .codex,
            sourceID: CodexAccountSource.secondary.id,
            accountEmail: "secondary@example.com"
        )
        let preferences = UserPreferences(disabledAccounts: [secondary, secondary])
        let decoded = try JSONDecoder().decode(
            UserPreferences.self,
            from: JSONEncoder().encode(preferences)
        )
        #expect(decoded == preferences)
        #expect(decoded.normalized().disabledAccounts == [secondary])
        #expect(decoded.disabledAccountSourceIDs == [CodexAccountSource.secondary.id])
    }

    @Test("excluding accounts leaves a single account as the provider quotas")
    func excludingAccounts() {
        let source = ProviderSourceDescriptor(
            id: "test.codex",
            name: "Test",
            kind: .officialCLI,
            credentialOwnership: .externalProvider,
            documentationURL: nil,
            detail: "Test"
        )
        let quota = RawQuotaItem(
            id: "codex.primary",
            originalName: "Primary",
            used: nil,
            remaining: nil,
            percentage: SourcePercentage(value: 10, rawText: "10", meaning: .used),
            resetsAt: nil
        )
        let snapshot = ProviderSnapshot(
            providerID: .codex,
            source: source,
            accounts: [
                ProviderAccountSnapshot(sourceID: CodexAccountSource.primary.id, quotas: [quota]),
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.secondary.id,
                    quotas: [quota],
                    accountEmail: "secondary@example.com"
                ),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(snapshot.quotas.isEmpty)
        #expect(snapshot.excludingAccounts([]) == snapshot)

        let remaining = snapshot.excludingAccounts([CodexAccountSource.secondary.id])
        #expect(remaining.accounts.map(\.sourceID) == [CodexAccountSource.primary.id])
        #expect(remaining.quotas == [quota])
        #expect(remaining.accountEmail == nil)
        #expect(
            CollectionState.fresh(snapshot).excludingAccounts([CodexAccountSource.secondary.id])
                == .fresh(remaining)
        )
    }

    @Test("missing menu bar percent sign defaults true without changing provider preferences")
    func missingMenuBarPercentSignDefaults() throws {
        let data = Data(
            #"{"providers":[{"providerID":"grok","isVisible":false,"order":3},{"providerID":"codex","isVisible":true,"order":1}]}"#.utf8
        )
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)

        #expect(decoded.showsMenuBarPercentSign)
        #expect(decoded.providers.map(\.providerID) == [.grok, .codex])
        #expect(decoded.providers.map(\.isVisible) == [false, true])
        #expect(decoded.providers.map(\.order) == [3, 1])
    }

    @Test("normalization preserves menu bar percent sign preference")
    func normalizedMenuBarPercentSign() {
        for value in [false, true] {
            let preferences = UserPreferences(showsMenuBarPercentSign: value)
            #expect(preferences.normalized().showsMenuBarPercentSign == value)
        }
    }

    @Test("snapshot round trips without changing raw source precision")
    func snapshotRoundTrip() throws {
        let source = ProviderSourceDescriptor(
            id: "fixture",
            name: "Fixture",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: URL(string: "https://example.invalid/docs"),
            detail: "Fixture source"
        )
        let snapshot = ProviderSnapshot(
            providerID: .grok,
            source: source,
            quotas: [
                RawQuotaItem(
                    id: "credit",
                    originalName: "Prepaid credit",
                    used: SourceValue(value: 0.10, rawText: "0.10", unit: "USD"),
                    remaining: SourceValue(value: 9.90, rawText: "9.90", unit: "USD"),
                    percentage: SourcePercentage(value: 1.00, rawText: "1.00", meaning: .used),
                    resetsAt: nil,
                    sourceFields: ["currency": "USD"]
                ),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000),
            accountEmail: "owner@example.com"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.quotas[0].used?.rawText == "0.10")
    }
    @Test("Codex account snapshots preserve source boundaries for shared quota IDs")
    func accountSnapshotsPreserveSourceBoundaries() throws {
        let source = ProviderSourceDescriptor(
            id: "codex.fixture",
            name: "Codex fixture",
            kind: .officialCLI,
            credentialOwnership: .externalProvider,
            documentationURL: nil,
            detail: "Fixture source"
        )
        let quota = RawQuotaItem(
            id: "codex.primary",
            originalName: "Primary",
            used: SourceValue(value: 25, rawText: "25", unit: "%"),
            remaining: SourceValue(value: 75, rawText: "75", unit: "%"),
            percentage: SourcePercentage(value: 25, rawText: "25", meaning: .used),
            resetsAt: nil
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderSnapshot(
            providerID: .codex,
            source: source,
            accounts: [
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.secondary.id,
                    quotas: [quota],
                    refreshedAt: date,
                    accountEmail: "secondary@example.com"
                ),
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.primary.id,
                    quotas: [quota],
                    refreshedAt: date,
                    accountEmail: "primary@example.com"
                ),
            ],
            refreshedAt: date
        )

        #expect(snapshot.accounts.map(\.sourceID) == [
            CodexAccountSource.primary.id,
            CodexAccountSource.secondary.id,
        ])
        #expect(snapshot.account(for: CodexAccountSource.primary.id)?.quotas == [quota])
        #expect(snapshot.account(for: CodexAccountSource.secondary.id)?.quotas == [quota])
        #expect(snapshot.quotas.isEmpty)

        let decoded = try JSONDecoder().decode(
            ProviderSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded.accounts == snapshot.accounts)
        #expect(decoded.account(for: CodexAccountSource.secondary.id)?.accountEmail == "secondary@example.com")
    }
}
