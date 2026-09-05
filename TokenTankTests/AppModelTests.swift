import XCTest
@testable import TokenTank
import TokenTankCore
import TokenTankDomain

@MainActor
final class AppModelTests: XCTestCase {
    func testWholeProviderFailuresMarkEveryRetainedAccountStale() {
        let previous = makeSnapshot(providerID: .codex, percentage: 26)
        let accounts = [CodexAccountSource.primary, .secondary].map {
            ProviderAccountSnapshot(sourceID: $0.id, quotas: previous.quotas, refreshedAt: previous.refreshedAt)
        }
        let snapshot = ProviderSnapshot(providerID: .codex, source: previous.source, accounts: accounts, refreshedAt: previous.refreshedAt)
        for failure in [
            CollectionError(kind: .sourceUnavailable, diagnosticCode: "test.executable.missing"),
            CollectionError(kind: .authenticationRejected, diagnosticCode: "test.auth")
        ] {
            let state: CollectionState = failure.kind.requiresAuthenticationAction
                ? .authenticationActionRequired(snapshot: snapshot, failure: failure)
                : .stale(snapshot: snapshot, failure: failure, failedAt: previous.refreshedAt)
            let projected = CodexAccountPresentation.accounts(for: state)
            XCTAssertEqual(projected.map(\.failure), [failure, failure])
            XCTAssertEqual(projected.map(\.quotas), accounts.map(\.quotas))
            XCTAssertTrue(projected.allSatisfy(\.isStale))
        }
        XCTAssertTrue(CodexAccountPresentation.accounts(for: .fresh(snapshot)).allSatisfy { !$0.isStale })
    }

    func testCodexWeeklySelectionUsesDurationNotPrimaryPosition() {
        func quota(_ id: String, window: String, minutes: String?) -> RawQuotaItem {
            var fields = ["limitId": "codex", "window": window]
            fields["windowDurationMins"] = minutes
            return RawQuotaItem(id: RawQuotaID(rawValue: id), originalName: "Codex", used: nil, remaining: nil,
                                percentage: .missing(meaning: .used), resetsAt: nil, sourceFields: fields)
        }
        let short = quota("codex.primary", window: "primary", minutes: "300")
        let weekly = quota("codex.secondary", window: "secondary", minutes: "10080")
        XCTAssertEqual(QuotaDisplayFormatter.defaultCodexQuota([short, weekly])?.id, weekly.id)
        XCTAssertEqual(QuotaDisplayFormatter.name(for: short, locale: Locale(identifier: "en")), "5-hour")
        XCTAssertEqual(QuotaDisplayFormatter.name(for: weekly, locale: Locale(identifier: "ko")), "주간")
        let unknown = quota("unknown", window: "primary", minutes: nil)
        XCTAssertEqual(QuotaDisplayFormatter.name(for: unknown, locale: Locale(identifier: "en")), "Usage")
    }
    func testLanguageSelectionPersistsAndResolvesUnsupportedLanguages() throws {
        let suite = "TokenTankTests.language.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(adapters: [], languageDefaults: defaults)
        model.language = .korean
        XCTAssertEqual(model.locale.language.languageCode?.identifier, "ko")
        XCTAssertEqual(AppModel(adapters: [], languageDefaults: defaults).language, .korean)
        model.language = .english
        XCTAssertEqual(AppModel(adapters: [], languageDefaults: defaults).language, .english)
        XCTAssertEqual(AppLanguage.preferred(["ko-KR"]), .korean)
        XCTAssertEqual(AppLanguage.preferred(["en_US"]), .english)
        XCTAssertEqual(AppLanguage.preferred(["ja-JP"]), .english)
        XCTAssertEqual(AppLanguage.preferred([]), .english)
    }

    func testResetCountdownUsesElapsedDaysAndHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(TimeInterval, String, String)] = [
            (-1, "Reset pending", "리셋 대기 중"),
            (0, "Reset pending", "리셋 대기 중"),
            (1, "<1h", "1시간 미만"),
            (3_599, "<1h", "1시간 미만"),
            (3_600, "1h", "1시간"),
            (86_399, "23h", "23시간"),
            (86_400, "1d 0h", "1일 0시간"),
            (183_600, "2d 3h", "2일 3시간"),
            (691_200, "8d 0h", "8일 0시간"),
        ]
        for (seconds, english, korean) in cases {
            for (language, expected) in [("en", english), ("ko", korean)] {
                XCTAssertEqual(QuotaDisplayFormatter.resetCountdown(
                    now.addingTimeInterval(seconds), relativeTo: now, locale: Locale(identifier: language)
                ), expected)
            }
        }
    }

    func testResetTicketsShowOnlyNearestUnexpiredDate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func summary(_ count: Decimal?) -> RawQuotaItem {
            RawQuotaItem(id: "rateLimitResetCredits", originalName: "tickets", used: nil,
                         remaining: count.map { SourceValue(value: $0, rawText: "\($0)", unit: "credits") },
                         percentage: .missing(meaning: .remaining), resetsAt: nil)
        }
        let tickets = [-1.0, 7200, 3600].enumerated().map { index, seconds in
            RawQuotaItem(id: RawQuotaID(rawValue: "rateLimitResetCredit.\(index)"), originalName: "ticket",
                         used: nil, remaining: nil, percentage: .missing(meaning: .remaining),
                         resetsAt: now.addingTimeInterval(seconds))
        }
        let result = QuotaDisplayFormatter.codexResetCredits([summary(2)] + tickets, now: now)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.expiresAt, now.addingTimeInterval(3600))
        XCTAssertFalse(QuotaDisplayFormatter.ticketExpiry(result.expiresAt).contains("\n"))
        XCTAssertNil(QuotaDisplayFormatter.codexResetCredits([summary(0)] + tickets, now: now).expiresAt)
        XCTAssertNil(QuotaDisplayFormatter.codexResetCredits([summary(2)], now: now).expiresAt)
        XCTAssertNil(QuotaDisplayFormatter.codexResetCredits([summary(2)] + tickets, now: now.addingTimeInterval(7200)).expiresAt)
        XCTAssertNil(QuotaDisplayFormatter.codexResetCredits([], now: now).count)
        XCTAssertEqual(QuotaDisplayFormatter.ticketExpiry(nil), "—")
    }

    func testFreshnessUsesLastSuccessAndMinuteBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (seconds, en, ko) in [(0.0, "now", "방금"), (59, "now", "방금"), (60, "1m ago", "1분 전"),
                                  (179, "2m ago", "2분 전"), (3600, "60m ago", "60분 전"), (-1, "now", "방금")] {
            let date = now.addingTimeInterval(-seconds)
            XCTAssertEqual(QuotaDisplayFormatter.refreshAge(date, now: now, locale: Locale(identifier: "en")), en)
            XCTAssertEqual(QuotaDisplayFormatter.refreshAge(date, now: now, locale: Locale(identifier: "ko")), ko)
        }
        XCTAssertEqual(QuotaDisplayFormatter.refreshAge(nil, now: now), "—")
    }

    func testAccountIdentityUsesEmailAndPlanWithoutAlias() {
        let account = ProviderAccountSnapshot(sourceID: "codex.primary", quotas: [], accountEmail: "work@example.com", plan: "pro")
        XCTAssertEqual(CodexAccountPresentation.identity(for: account, locale: Locale(identifier: "en")), "work@example.com · pro")
    }
    func testRepresentativeQuotaRequiresExplicitSelection() async throws {
        let snapshot = makeSnapshot(providerID: .claude, percentage: 37.5)
        let adapter = TestAppAdapter(id: .claude, results: [.success(snapshot)])
        let preferences = MemoryPreferencesStore()
        let credentials = InMemoryCredentialStore()
        let model = AppModel(
            adapters: [adapter],
            credentialStore: credentials,
            preferencesStore: preferences,
            context: makeContext(credentials: credentials)
        )

        model.ensureStarted()
        let becameFresh = await eventually {
            if case .fresh = model.states[.claude] { return true }
            return false
        }
        XCTAssertTrue(becameFresh)
        var preference = model.preference(for: .claude)
        XCTAssertEqual(model.menuValue(for: preference), "63%")

        preference.representativeQuotaID = "primary"
        model.updatePreference(preference)
        XCTAssertEqual(model.menuValue(for: preference), "63%")

        preference.representativeQuotaID = "vanished"
        model.updatePreference(preference)
        XCTAssertEqual(model.menuValue(for: preference), "—")
        await model.stop()
    }

    func testMenuValueFallsBackToPopupQuotaWhenUnselected() async throws {
        let snapshot = ProviderSnapshot(
            providerID: .codex,
            source: ProviderSourceDescriptor(
                id: "test.codex",
                name: "Test source",
                kind: .officialAPI,
                credentialOwnership: .tokenTank,
                documentationURL: nil,
                detail: "Test source"
            ),
            quotas: [
                RawQuotaItem(
                    id: "codex.primary",
                    originalName: "Codex",
                    used: SourceValue(value: 37.5, rawText: "37.5", unit: "%"),
                    remaining: nil,
                    percentage: SourcePercentage(value: 37.5, rawText: "37.5", meaning: .used),
                    resetsAt: nil,
                    sourceFields: ["limitId": "codex", "window": "primary", "windowDurationMins": "10080"]
                ),
            ],
            refreshedAt: Date()
        )
        let credentials = InMemoryCredentialStore()
        let model = AppModel(
            adapters: [TestAppAdapter(id: .codex, results: [.success(snapshot)])],
            credentialStore: credentials,
            preferencesStore: MemoryPreferencesStore(),
            context: makeContext(credentials: credentials)
        )
        model.ensureStarted()
        let becameFresh = await eventually {
            if case .fresh = model.states[.codex] { return true }
            return false
        }
        XCTAssertTrue(becameFresh)
        XCTAssertEqual(model.menuValue(for: model.preference(for: .codex)), "63%")
        await model.stop()
    }

    func testMenuValueShowsIntegerRemainingPercentageOnly() async throws {
        let usedPercent = makeSnapshot(providerID: .codex, percentage: 37.5)
        let remainingPercent = makeSnapshot(
            providerID: .claude,
            percentage: 18,
            percentageMeaning: .remaining
        )
        let missingPercent = makeSnapshot(
            providerID: .grok,
            used: SourceValue(value: 10, rawText: "10", unit: "tokens")
        )
        let credentials = InMemoryCredentialStore()
        let model = AppModel(
            adapters: [
                TestAppAdapter(id: .codex, results: [.success(usedPercent)]),
                TestAppAdapter(id: .claude, results: [.success(remainingPercent)]),
                TestAppAdapter(id: .grok, results: [.success(missingPercent)]),
            ],
            credentialStore: credentials,
            preferencesStore: MemoryPreferencesStore(),
            context: makeContext(credentials: credentials)
        )

        model.ensureStarted()
        let allFresh = await eventually {
            if case .fresh = model.states[.codex],
               case .fresh = model.states[.claude],
               case .fresh = model.states[.grok] {
                return true
            }
            return false
        }
        XCTAssertTrue(allFresh)

        var codexPreference = model.preference(for: .codex)
        codexPreference.representativeQuotaID = "primary"
        model.updatePreference(codexPreference)
        XCTAssertEqual(model.menuValue(for: codexPreference), "63%")

        var claudePreference = model.preference(for: .claude)
        claudePreference.representativeQuotaID = "primary"
        model.updatePreference(claudePreference)
        XCTAssertEqual(model.menuValue(for: claudePreference), "18%")

        var grokPreference = model.preference(for: .grok)
        grokPreference.representativeQuotaID = "primary"
        model.updatePreference(grokPreference)
        XCTAssertEqual(model.menuValue(for: grokPreference), "—")

        await model.stop()
    }

    func testMenuBarLabelJoinsEveryVisibleProvider() async throws {
        let credentials = InMemoryCredentialStore()
        let model = AppModel(
            adapters: [],
            credentialStore: credentials,
            preferencesStore: MemoryPreferencesStore(),
            context: makeContext(credentials: credentials)
        )

        XCTAssertEqual(model.menuBarLabelText(), "CDX —  CLD —  GRK —  CUR —  DB —")

        var cursor = model.preference(for: .cursor)
        cursor.isVisible = false
        model.updatePreference(cursor)
        var claude = model.preference(for: .claude)
        claude.representativeQuotaID = "primary"
        model.updatePreference(claude)
        XCTAssertEqual(model.menuBarLabelText(), "CDX —  CLD —  GRK —  DB —")

        await model.stop()
    }
    func testCodexMenuUsesIndependentAccountValuesInStableSourceOrder() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = makeSnapshot(providerID: .codex, percentage: 26)
        let secondary = makeSnapshot(providerID: .codex, percentage: 2)
        let snapshot = ProviderSnapshot(
            providerID: .codex,
            source: primary.source,
            accounts: [
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.secondary.id,
                    quotas: secondary.quotas,
                    refreshedAt: now,
                    accountEmail: "personal@example.com",
                    plan: "Plus"
                ),
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.primary.id,
                    quotas: primary.quotas,
                    refreshedAt: now,
                    accountEmail: "work@example.com",
                    plan: "Plus"
                ),
            ],
            refreshedAt: now
        )
        let credentials = InMemoryCredentialStore()
        let model = AppModel(
            adapters: [TestAppAdapter(id: .codex, results: [.success(snapshot)])],
            credentialStore: credentials,
            preferencesStore: MemoryPreferencesStore(),
            context: makeContext(credentials: credentials)
        )

        model.ensureStarted()
        let becameFresh = await eventually {
            if case .fresh = model.states[.codex] { return true }
            return false
        }
        XCTAssertTrue(becameFresh)

        var preference = model.preference(for: .codex)
        preference.representativeQuotaID = "primary"
        model.updatePreference(preference)

        let values = model.codexMenuValues(for: preference)
        XCTAssertEqual(values.map(\.sourceID), [
            CodexAccountSource.primary.id,
            CodexAccountSource.secondary.id,
        ])
        XCTAssertEqual(values.map(\.value), ["74%", "98%"])
        XCTAssertEqual(model.menuValue(for: preference), "74%")
        XCTAssertTrue(model.menuBarLabelText().hasPrefix("CDX 74% · 98%"))
        XCTAssertEqual(model.menuBarSummaryItems().first?.text, "74% · 98%")
        XCTAssertFalse(model.menuBarLabelText().contains("172%"))

        await model.stop()
    }

    func testCodexMenuDistinguishesMissingAndStaleAccountValues() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let primarySnapshot = makeSnapshot(providerID: .codex, percentage: 10)
        let missingSnapshot = ProviderSnapshot(
            providerID: .codex,
            source: primarySnapshot.source,
            accounts: [
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.primary.id,
                    quotas: primarySnapshot.quotas,
                    refreshedAt: now,
                    accountEmail: "work@example.com"
                ),
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.secondary.id,
                    quotas: [],
                    refreshedAt: nil,
                    accountEmail: nil
                ),
            ],
            refreshedAt: now
        )
        let missingCredentials = InMemoryCredentialStore()
        let missingModel = AppModel(
            adapters: [TestAppAdapter(id: .codex, results: [.success(missingSnapshot)])],
            credentialStore: missingCredentials,
            preferencesStore: MemoryPreferencesStore(),
            context: makeContext(credentials: missingCredentials)
        )
        missingModel.ensureStarted()
        let missingBecameFresh = await eventually {
            if case .fresh = missingModel.states[.codex] { return true }
            return false
        }
        XCTAssertTrue(missingBecameFresh)
        let missingValues = missingModel.codexMenuValues(for: missingModel.preference(for: .codex))
        XCTAssertEqual(missingValues.map(\.value), ["90%", "—"])
        XCTAssertFalse(missingValues[1].isStale)
        await missingModel.stop()

        let staleSnapshot = ProviderSnapshot(
            providerID: .codex,
            source: primarySnapshot.source,
            accounts: [
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.primary.id,
                    quotas: primarySnapshot.quotas,
                    refreshedAt: now,
                    accountEmail: "work@example.com"
                ),
                ProviderAccountSnapshot(
                    sourceID: CodexAccountSource.secondary.id,
                    quotas: primarySnapshot.quotas,
                    refreshedAt: now.addingTimeInterval(-600),
                    accountEmail: "personal@example.com",
                    failure: CollectionError(
                        kind: .offline,
                        diagnosticCode: "test.codex.secondary.offline"
                    ),
                    failedAt: now
                ),
            ],
            refreshedAt: now
        )
        let staleCredentials = InMemoryCredentialStore()
        let staleModel = AppModel(
            adapters: [TestAppAdapter(id: .codex, results: [.success(staleSnapshot)])],
            credentialStore: staleCredentials,
            preferencesStore: MemoryPreferencesStore(),
            context: makeContext(credentials: staleCredentials)
        )
        staleModel.ensureStarted()
        let staleBecameFresh = await eventually {
            if case .fresh = staleModel.states[.codex] { return true }
            return false
        }
        XCTAssertTrue(staleBecameFresh)
        let stalePreference = staleModel.preference(for: .codex)
        let staleValues = staleModel.codexMenuValues(for: stalePreference)
        XCTAssertEqual(staleValues.map(\.value), ["90%", "90%"])
        XCTAssertFalse(staleValues[0].isStale)
        XCTAssertTrue(staleValues[1].isStale)
        XCTAssertTrue(staleModel.menuBarLabelText().contains("Stale"))

        await staleModel.stop()
    }
    func testCodexPopupExcludesSparkAndNonWeeklyQuotas() {
        func quota(
            id: String,
            limitID: String,
            limitName: String,
            percentage: Decimal
        ) -> RawQuotaItem {
            RawQuotaItem(
                id: RawQuotaID(rawValue: id),
                originalName: limitName,
                used: nil,
                remaining: nil,
                percentage: SourcePercentage(
                    value: percentage,
                    rawText: NSDecimalNumber(decimal: percentage).stringValue,
                    meaning: .used
                ),
                resetsAt: nil,
                sourceFields: [
                    "limitId": limitID,
                    "limitName": limitName,
                    "window": "primary",
                    "windowDurationMins": limitID == "codex" ? "10080" : "300",
                ]
            )
        }

        let spark = quota(
            id: "codex_spark.primary",
            limitID: "codex_spark",
            limitName: "Spark",
            percentage: 12
        )
        let general = quota(
            id: "codex.primary",
            limitID: "codex",
            limitName: "Codex",
            percentage: 8
        )
        let displayed = QuotaDisplayFormatter.displayedQuotas(
            [spark, general],
            providerID: .codex
        )

        XCTAssertEqual(displayed.map(\.id.rawValue), ["codex.primary"])
        XCTAssertNil(QuotaDisplayFormatter.defaultCodexQuota([spark]))
        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: displayed[0], locale: Locale(identifier: "en_US")),
            "Weekly"
        )
        XCTAssertTrue(QuotaDisplayFormatter.displayedQuotas([spark], providerID: .codex).isEmpty)
    }
    func testBrandIconsAreBundledAndMenuBarSummaryRenders() {
        for providerID in ProviderID.allCases {
            XCTAssertNotNil(
                BrandIcon.image(for: providerID, pointSize: 16, color: false),
                "Missing template mark for \(providerID.rawValue)"
            )
            if BrandIcon.hasColorVariant(providerID) {
                XCTAssertNotNil(
                    BrandIcon.image(for: providerID, pointSize: 16, color: true),
                    "Missing color mark for \(providerID.rawValue)"
                )
            } else {
                XCTAssertEqual(
                    BrandIcon.resourceName(for: providerID, color: true),
                    BrandIcon.resourceName(for: providerID, color: false)
                )
            }
        }

        let tints = ProviderID.allCases.map(BrandIcon.tint(for:))
        XCTAssertEqual(Set(tints.map(\.description)).count, ProviderID.allCases.count)

        let image = MenuBarSummaryRenderer.compose(
            items: [
                (.codex, "63%"),
                (.claude, "90%"),
                (.grok, "—"),
            ]
        )
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, true)
        XCTAssertGreaterThan(image?.size.width ?? 0, 40)
        XCTAssertEqual(image?.size.height, 16)
        let dualImage = MenuBarSummaryRenderer.compose(
            summaryItems: [
                MenuBarSummaryItem(providerID: .codex, text: "CDX Work 74% · Personal 98%"),
            ]
        )
        XCTAssertNotNil(dualImage)
        XCTAssertEqual(dualImage?.isTemplate, true)
        XCTAssertGreaterThan(dualImage?.size.width ?? 0, image?.size.width ?? 0)
    }

    func testVisibilityOrderingAndAbbreviationPersist() async throws {
        let preferences = MemoryPreferencesStore()
        let model = AppModel(
            adapters: [],
            credentialStore: InMemoryCredentialStore(),
            preferencesStore: preferences,
            context: makeContext(credentials: InMemoryCredentialStore())
        )
        model.ensureStarted()
        let loadedPreferences = await eventually { await preferences.loadCount > 0 }
        XCTAssertTrue(loadedPreferences)

        var codex = model.preference(for: .codex)
        codex.isVisible = false
        codex.abbreviation = "  C\nO\tDEX-LONG  "
        model.updatePreference(codex)
        XCTAssertEqual(model.preference(for: .codex).abbreviation, "CODEX-LO")
        model.move(.doubao, offset: -1)
        try await Task.sleep(for: .milliseconds(100))
        let backgroundSaveCount = await preferences.saveCount
        XCTAssertEqual(backgroundSaveCount, 1)

        await model.stop()
        let saved = await preferences.load()
        XCTAssertEqual(saved.preference(for: .codex).isVisible, false)
        XCTAssertEqual(saved.preference(for: .codex).abbreviation, "CODEX-LO")
        XCTAssertEqual(model.orderedPreferences.count, ProviderID.allCases.count)
    }


    func testStopRejectsLaterManualRefresh() async throws {
        let adapter = TestAppAdapter(
            id: .codex,
            results: [.success(makeSnapshot(providerID: .codex, percentage: 10))]
        )
        let model = AppModel(
            adapters: [adapter],
            credentialStore: InMemoryCredentialStore(),
            preferencesStore: MemoryPreferencesStore(),
            context: makeContext(credentials: InMemoryCredentialStore())
        )

        await model.stop()
        model.refresh(.codex)
        model.refreshAll()
        var postStopPreference = model.preference(for: .codex)
        postStopPreference.abbreviation = "POSTSTOP"
        model.updatePreference(postStopPreference)
        model.updateCredentialDraft("blocked", id: "doubao.secret-access-key")
        try await Task.sleep(for: .milliseconds(25))

        let fetchCount = await adapter.fetchCount
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(model.states[.codex], .neverLoaded)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.preference(for: .codex).abbreviation, "CDX")
        XCTAssertFalse(model.hasCredentialDrafts(for: .doubao))
    }

    func testReviewedSourcesAndOwnedCredentialsAreExposed() {
        let model = AppModel(
            adapters: [],
            credentialStore: InMemoryCredentialStore(),
            preferencesStore: MemoryPreferencesStore(),
            context: makeContext(credentials: InMemoryCredentialStore())
        )

        XCTAssertEqual(model.credentialGroups.map(\.providerID), [])
        for providerID in ProviderID.allCases {
            XCTAssertNotNil(model.sourceDescriptor(for: providerID))
        }
    }
    func testEnglishKoreanCatalogCoversEveryPresentationKey() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("TokenTankApp/Resources/Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        func localizedValue(_ key: String, locale: String) throws -> String {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing catalog key \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertEqual(Set(localizations.keys), ["en", "ko"], "Unexpected locales for \(key)")
            let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
            XCTAssertEqual(unit["state"] as? String, "translated")
            return try XCTUnwrap(unit["value"] as? String)
        }

        for key in strings.keys {
            XCTAssertFalse(try localizedValue(key, locale: "en").isEmpty)
            XCTAssertFalse(try localizedValue(key, locale: "ko").isEmpty)
        }

        let keyPattern = try NSRegularExpression(
            pattern: "\"((?:action|credential|detail|error|field|menu|quota|settings|source|state)\\\\.[A-Za-z0-9_.]+)\""
        )
        var presentationKeys = Set<String>()
        for relativePath in [
            "TokenTankApp/App/AppModel.swift",
            "TokenTankApp/UI/Views.swift",
            "TokenTankApp/UI/BrandIcons.swift",
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in keyPattern.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                presentationKeys.insert(String(source[keyRange]))
            }
        }
        XCTAssertTrue(
            presentationKeys.isSubset(of: Set(strings.keys)),
            "Missing catalog keys: \(presentationKeys.subtracting(strings.keys))"
        )

        let frozen: [String: (en: String, ko: String)] = [
            "field.not_provided": ("Not provided", "제공 안 됨"),
            "state.stale": ("Stale", "오래됨"),
            "error.network": ("Network error", "네트워크 오류"),
            "error.offline": ("Offline", "오프라인"),
            "error.rate_limited": ("Rate limited", "요청 한도 초과"),
            "error.schema": ("Data format changed", "데이터 형식 변경됨"),
            "error.permission": ("Permission required", "권한 필요"),
            "error.keychain": ("Keychain unavailable", "키체인을 사용할 수 없음"),
            "action.retry": ("Retry", "다시 시도"),
            "action.wait": ("Wait for next refresh", "다음 갱신까지 대기"),
            "action.sign_in_source": ("Sign in again in the source app", "원본 앱에서 다시 로그인"),
            "action.sign_in_token_tank": ("Sign in to Token Tank", "Token Tank에서 로그인"),
            "action.allow_system_settings": ("Allow access in System Settings", "시스템 설정에서 접근 허용"),
            "state.selected_unavailable": ("Selected quota unavailable", "선택한 할당량을 사용할 수 없음"),
            "settings.representative.none": ("Choose another", "다시 선택"),
        ]
        for (key, expected) in frozen {
            XCTAssertEqual(try localizedValue(key, locale: "en"), expected.en)
            XCTAssertEqual(try localizedValue(key, locale: "ko"), expected.ko)
        }

        let infoData = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("TokenTankApp/Supporting/Info.plist")
        )
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertEqual(info["CFBundleLocalizations"] as? [String], ["en", "ko"])
    }

    func testQuotaDisplayNamesHideRawSourceKeys() {
        let quota = RawQuotaItem(
            id: "cursor-plan-auto",
            originalName: "individualUsage.plan.autoPercentUsed",
            used: nil,
            remaining: nil,
            percentage: .missing(meaning: .used),
            resetsAt: nil
        )
        let codexWindow = RawQuotaItem(
            id: "codex-primary",
            originalName: "Codex",
            used: nil,
            remaining: nil,
            percentage: .missing(meaning: .used),
            resetsAt: nil,
            sourceFields: ["limitId": "codex", "window": "primary", "windowDurationMins": "10080"]
        )

        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: quota, locale: Locale(identifier: "en_US")),
            "Cursor Models"
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: quota, locale: Locale(identifier: "ko_KR")),
            "Cursor 모델"
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: codexWindow, locale: Locale(identifier: "en_US")),
            "Weekly"
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: codexWindow, locale: Locale(identifier: "ko_KR")),
            "주간"
        )
        let extraCodex = RawQuotaItem(
            id: "codex_other.primary",
            originalName: "codex_other",
            used: nil,
            remaining: nil,
            percentage: .missing(meaning: .used),
            resetsAt: nil,
            sourceFields: ["limitId": "codex_other", "window": "primary"]
        )
        let secondary = RawQuotaItem(
            id: "codex.secondary",
            originalName: "Codex",
            used: nil,
            remaining: nil,
            percentage: .missing(meaning: .used),
            resetsAt: nil,
            sourceFields: ["limitId": "codex", "window": "secondary"]
        )
        let resetCredits = RawQuotaItem(
            id: "rateLimitResetCredits",
            originalName: "rateLimitResetCredits",
            used: nil,
            remaining: SourceValue(value: 2, rawText: "2", unit: "credits"),
            percentage: .missing(meaning: .remaining),
            resetsAt: nil
        )
        let resetCredit = RawQuotaItem(
            id: "rateLimitResetCredit.credit-1",
            originalName: "Rate-limit reset",
            used: nil,
            remaining: nil,
            percentage: .missing(meaning: .remaining),
            resetsAt: nil,
            sourceFields: ["expiresAt": "1800000400"]
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.displayedQuotas(
                [codexWindow, extraCodex, secondary, resetCredits],
                providerID: .codex
            ).map(\.id.rawValue),
            ["codex-primary"]
        )
        XCTAssertEqual(QuotaDisplayFormatter.codexResetCredits(
            [resetCredits, resetCredit], now: Date(timeIntervalSince1970: 1_800_000_000)
        ).count, 2)
        XCTAssertEqual(
            QuotaDisplayFormatter.displayedQuotas(
                [
                    RawQuotaItem(
                        id: "session",
                        originalName: "session",
                        used: nil,
                        remaining: nil,
                        percentage: .missing(meaning: .used),
                        resetsAt: nil
                    ),
                    RawQuotaItem(
                        id: "weekly_scoped",
                        originalName: "weekly_scoped.Fable",
                        used: nil,
                        remaining: nil,
                        percentage: .missing(meaning: .used),
                        resetsAt: nil
                    ),
                    RawQuotaItem(
                        id: "weekly_all",
                        originalName: "weekly_all",
                        used: nil,
                        remaining: nil,
                        percentage: .missing(meaning: .used),
                        resetsAt: nil
                    ),
                ],
                providerID: .claude
            ).map(\.originalName),
            ["session", "weekly_all"]
        )
        let weeklyAll = RawQuotaItem(
            id: "weekly_all",
            originalName: "weekly_all",
            used: nil,
            remaining: nil,
            percentage: SourcePercentage(value: 22, rawText: "22", meaning: .used),
            resetsAt: nil
        )
        let fable = RawQuotaItem(
            id: "weekly_scoped",
            originalName: "weekly_scoped.Fable",
            used: nil,
            remaining: nil,
            percentage: SourcePercentage(value: 44, rawText: "44", meaning: .used),
            resetsAt: nil
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.claudeFableLimit(for: weeklyAll, in: [weeklyAll, fable])?.title,
            "Fable"
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.claudeFableLimit(for: weeklyAll, in: [weeklyAll, fable])?.remaining,
            56
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.name(
                for: RawQuotaItem(
                    id: "auto",
                    originalName: "individualUsage.plan.autoPercentUsed",
                    used: nil,
                    remaining: nil,
                    percentage: .missing(meaning: .used),
                    resetsAt: nil
                ),
                locale: Locale(identifier: "en_US")
            ),
            "Cursor Models"
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.displayedQuotas(
                [
                    RawQuotaItem(
                        id: "plan",
                        originalName: "individualUsage.plan",
                        used: nil,
                        remaining: nil,
                        percentage: .missing(meaning: .used),
                        resetsAt: nil
                    ),
                    RawQuotaItem(
                        id: "auto",
                        originalName: "individualUsage.plan.autoPercentUsed",
                        used: nil,
                        remaining: nil,
                        percentage: SourcePercentage(value: 8, rawText: "8", meaning: .used),
                        resetsAt: nil
                    ),
                    RawQuotaItem(
                        id: "api",
                        originalName: "individualUsage.plan.apiPercentUsed",
                        used: nil,
                        remaining: nil,
                        percentage: SourcePercentage(value: 43, rawText: "43", meaning: .used),
                        resetsAt: nil
                    ),
                ],
                providerID: .cursor
            ).map(\.originalName),
            ["individualUsage.plan.autoPercentUsed", "individualUsage.plan.apiPercentUsed"]
        )
        let doubao = RawQuotaItem(
            id: "arkcli-agent-weekly",
            originalName: "agent-plan.personal.weekly",
            used: nil,
            remaining: nil,
            percentage: .missing(meaning: .used),
            resetsAt: nil,
            sourceFields: ["path": "agent-plan.personal", "level": "weekly", "tier": "medium"]
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: doubao, locale: Locale(identifier: "en_US")),
            "Weekly"
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.planName(
                for: .cursor,
                quotas: [
                    RawQuotaItem(
                        id: "auto",
                        originalName: "individualUsage.plan.autoPercentUsed",
                        used: nil,
                        remaining: nil,
                        percentage: .missing(meaning: .used),
                        resetsAt: nil,
                        sourceFields: ["membershipType": "pro"]
                    ),
                ],
                locale: Locale(identifier: "en_US")
            ),
            "Pro"
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.planName(
                for: .doubao,
                quotas: [doubao],
                locale: Locale(identifier: "en_US")
            ),
            "Agent plan · Personal · Medium"
        )
        XCTAssertNil(
            QuotaDisplayFormatter.planName(
                for: .claude,
                quotas: [
                    RawQuotaItem(
                        id: "weekly_all",
                        originalName: "weekly_all",
                        used: nil,
                        remaining: nil,
                        percentage: .missing(meaning: .used),
                        resetsAt: nil
                    ),
                ]
            )
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.displayedQuotas(
                [
                    doubao,
                    RawQuotaItem(
                        id: "monthly",
                        originalName: "agent-plan.personal.monthly",
                        used: nil,
                        remaining: nil,
                        percentage: .missing(meaning: .used),
                        resetsAt: nil
                    ),
                ],
                providerID: .doubao
            ).map(\.originalName),
            ["agent-plan.personal.weekly"]
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: doubao, locale: Locale(identifier: "ko_KR")),
            "주간"
        )
        let doubaoFiveHour = RawQuotaItem(
            id: "arkcli-agent-5h",
            originalName: "agent-plan.personal.5h",
            used: nil,
            remaining: nil,
            percentage: .missing(meaning: .used),
            resetsAt: nil
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: doubaoFiveHour, locale: Locale(identifier: "en_US")),
            "5-hour"
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: doubaoFiveHour, locale: Locale(identifier: "ko_KR")),
            "5시간"
        )
    }

    func testQuotaDisplayValuesUseReadableNumbersAndUnits() {
        let locale = Locale(identifier: "en_US")
        let tokens = SourceValue(value: 1_234_567.5, rawText: "1234567.5000", unit: "tokens")
        let cents = SourceValue(value: 125, rawText: "125", unit: "cents")
        let percentage = SourcePercentage(value: 42.50, rawText: "42.50", meaning: .used)

        XCTAssertEqual(QuotaDisplayFormatter.value(tokens, locale: locale), "1,234,567.5 tokens")
        XCTAssertEqual(QuotaDisplayFormatter.value(cents, locale: locale), "$1.25")
        XCTAssertEqual(QuotaDisplayFormatter.percentage(percentage, locale: locale), "42.5%")
        XCTAssertEqual(QuotaDisplayFormatter.remainingPercentage(percentage), 57.5)
        XCTAssertEqual(
            QuotaDisplayFormatter.remainingPercentage(
                SourcePercentage(value: 18, rawText: "18", meaning: .remaining)
            ),
            18
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.remainingPercentage(
                SourcePercentage(value: 120, rawText: "120", meaning: .used)
            ),
            0
        )
        XCTAssertNil(
            QuotaDisplayFormatter.remainingPercentage(.missing(meaning: .remaining))
        )
        XCTAssertNil(QuotaDisplayFormatter.value(nil, locale: locale))
    }
    private func makeContext(credentials: any AppCredentialStore) -> CollectionContext {
        CollectionContext(
            network: UnavailableNetworkClient(),
            credentials: credentials,
            externalSessions: NoExternalSessionReader(),
            sqlite: NoSQLiteReader(),
            codexAccount: NoCodexAccountUsageReader(),
            doubaoPlan: NoDoubaoPlanUsageReader(),
            clock: SystemClock(),
            diagnostics: NoDiagnostics()
        )
    }

    private func makeSnapshot(
        providerID: ProviderID,
        percentage: Decimal? = nil,
        percentageMeaning: PercentageMeaning = .used,
        used: SourceValue? = nil,
        remaining: SourceValue? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
            source: ProviderSourceDescriptor(
                id: "test.\(providerID.rawValue)",
                name: "Test source",
                kind: .officialAPI,
                credentialOwnership: .tokenTank,
                documentationURL: nil,
                detail: "Test source"
            ),
            quotas: [
                RawQuotaItem(
                    id: "primary",
                    originalName: "Primary",
                    used: used,
                    remaining: remaining,
                    percentage: percentage.map {
                        SourcePercentage(
                            value: $0,
                            rawText: NSDecimalNumber(decimal: $0).stringValue,
                            meaning: percentageMeaning
                        )
                    } ?? .missing(meaning: .used),
                    resetsAt: nil,
                    sourceFields: providerID == .codex ? ["limitId": "codex", "window": "primary", "windowDurationMins": "10080"] : [:]
                ),
            ],
            refreshedAt: Date()
        )
    }

    private func eventually(
        attempts: Int = 300,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }
}

private actor MemoryPreferencesStore: PreferencesStore {
    private var value = UserPreferences()
    private(set) var loadCount = 0
    private(set) var saveCount = 0

    func load() -> UserPreferences {
        loadCount += 1
        return value
    }

    func save(_ preferences: UserPreferences) {
        saveCount += 1
        value = preferences
    }
}

private actor BlockingCredentialStore: AppCredentialStore {
    private(set) var writeStarted = false
    private(set) var cancellationCount = 0
    private var values: [CredentialID: String] = [:]

    func read(_ id: CredentialID) -> String? {
        values[id]
    }

    func write(_ value: String, for id: CredentialID) async throws {
        writeStarted = true
        do {
            try await Task.sleep(for: .seconds(60))
            values[id] = value
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func delete(_ id: CredentialID) {
        values.removeValue(forKey: id)
    }
}
private actor TestAppAdapter: ProviderAdapter {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let defaultAbbreviation: String
    nonisolated let sourceDescriptor: ProviderSourceDescriptor
    private var results: [Result<ProviderSnapshot, CollectionError>]
    private(set) var fetchCount = 0

    init(id: ProviderID, results: [Result<ProviderSnapshot, CollectionError>]) {
        let descriptor = ProviderSourceDescriptor(
            id: "test.\(id.rawValue)",
            name: "Test source",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: nil,
            detail: "Test source"
        )
        self.id = id
        self.displayName = id.displayName
        self.defaultAbbreviation = id.defaultAbbreviation
        self.sourceDescriptor = descriptor
        self.results = results
    }

    func probeAvailability(context: CollectionContext) -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    func fetchSnapshot(context: CollectionContext) throws -> ProviderSnapshot {
        fetchCount += 1
        guard !results.isEmpty else {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "test.no-result")
        }
        return try results.removeFirst().get()
    }
}
