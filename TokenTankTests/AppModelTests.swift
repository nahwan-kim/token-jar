import XCTest
@testable import TokenTank
import TokenTankCore
import TokenTankDomain

@MainActor
final class AppModelTests: XCTestCase {
    func testRepresentativeQuotaRequiresExplicitSelection() async throws {
        let snapshot = makeSnapshot(providerID: .codex, percentage: 37.5)
        let adapter = TestAppAdapter(id: .codex, results: [.success(snapshot)])
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
            if case .fresh = model.states[.codex] { return true }
            return false
        }
        XCTAssertTrue(becameFresh)
        var preference = model.preference(for: .codex)
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
                    sourceFields: ["limitId": "codex", "window": "primary"]
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
            sourceFields: ["limitId": "codex", "window": "primary"]
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
            "Weekly limit"
        )
        XCTAssertEqual(
            QuotaDisplayFormatter.name(for: codexWindow, locale: Locale(identifier: "ko_KR")),
            "주간 한도"
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
        XCTAssertEqual(
            QuotaDisplayFormatter.codexResetCreditsLine(
                [resetCredits, resetCredit],
                now: Date(timeIntervalSince1970: 1_800_000_000),
                locale: Locale(identifier: "en_US")
            )?.hasPrefix("2 reset credits"),
            true
        )
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
            "Agent plan · Personal · Weekly"
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
            "Agent 플랜 · 개인 · 주간"
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
                    resetsAt: nil
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
