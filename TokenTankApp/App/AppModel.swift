import Combine
import Foundation
import TokenTankCore
import TokenTankDomain
import TokenTankProviders
import AppKit
import ServiceManagement

struct CredentialField: Identifiable, Sendable {
    let providerID: ProviderID
    let name: String
    let labelKey: String

    var id: String { "\(providerID.rawValue).\(name)" }
    var credentialID: CredentialID { CredentialID(providerID: providerID, name: name) }
}

struct CredentialGroup: Identifiable, Sendable {
    let providerID: ProviderID
    let fields: [CredentialField]

    var id: ProviderID { providerID }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case korean = "ko"

    var id: String { rawValue }
    var title: String { self == .english ? "English" : "한국어" }
    var locale: Locale { Locale(identifier: rawValue) }

    var appName: String {
        let bundle = Bundle.main.url(forResource: rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? Bundle.main
        return bundle.localizedString(forKey: "detail.title", value: nil, table: nil)
    }

    static func preferred(_ languages: [String]) -> AppLanguage {
        languages.first?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first == "ko"
            ? .korean : .english
    }
}
struct CodexAccountMenuValue: Equatable, Identifiable, Sendable {
    let sourceID: String
    let value: String
    let isStale: Bool

    var id: String { sourceID }
}
enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound

    var isRegistered: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }

    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SMAppLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
private final class DisabledLaunchAtLoginService: LaunchAtLoginServicing {
    private(set) var status: LaunchAtLoginStatus = .notRegistered

    func register() throws {
        status = .enabled
    }

    func unregister() throws {
        status = .notRegistered
    }

    func openSystemSettings() {}
}

@MainActor
enum CodexAccountPresentation {
    static func accounts(for state: CollectionState) -> [ProviderAccountSnapshot] {
        let accounts = ordered(state.snapshot?.accounts ?? [])
        let failure: CollectionError
        let failedAt: Date?
        switch state {
        case let .stale(_, error, date):
            failure = error
            failedAt = date
        case let .authenticationActionRequired(_, error):
            failure = error
            failedAt = nil
        default:
            return accounts
        }
        return accounts.map { account in
            ProviderAccountSnapshot(
                sourceID: account.sourceID,
                quotas: account.quotas,
                refreshedAt: account.refreshedAt,
                accountEmail: account.accountEmail,
                plan: account.plan,
                failure: failure,
                failedAt: failedAt
            )
        }
    }

    static func ordered(_ accounts: [ProviderAccountSnapshot]) -> [ProviderAccountSnapshot] {
        accounts.sorted { lhs, rhs in
            let lhsRank = rank(for: lhs.sourceID)
            let rhsRank = rank(for: rhs.sourceID)
            if lhsRank == rhsRank {
                return lhs.sourceID < rhs.sourceID
            }
            return lhsRank < rhsRank
        }
    }

    static func identity(for account: ProviderAccountSnapshot, locale: Locale) -> String {
        let email = account.accountEmail ?? localized(
            account.sourceID == CodexAccountSource.primary.id ? "codex.account.default" : "codex.account.secondary",
            locale: locale
        )
        return [email, account.plan].compactMap { $0 }.joined(separator: " · ")
    }

    static func localized(_ key: String, locale: Locale) -> String {
        String(
            localized: String.LocalizationValue(stringLiteral: key),
            bundle: Bundle(for: AppModel.self),
            locale: locale
        )
    }

    private static func rank(for sourceID: String) -> Int {
        switch CodexAccountSource(rawValue: sourceID) {
        case .primary: 0
        case .secondary: 1
        case nil: 2
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var states: [ProviderID: CollectionState]
    @Published private(set) var preferences = UserPreferences()
    @Published var language: AppLanguage {
        didSet { languageDefaults.set(language.rawValue, forKey: "appLanguage") }
    }
    var locale: Locale { language.locale }
    private let languageDefaults: UserDefaults
    @Published private(set) var isRefreshing = false
    @Published private(set) var credentialErrorCodes: [ProviderID: String] = [:]
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var updaterError = false
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var launchAtLoginError: Error?
    @Published private var automaticUpdateChecksEnabled: Bool
    var automaticallyChecksForUpdates: Bool {
        get { automaticUpdateChecksEnabled }
        set {
            guard !isStopping, automaticUpdateChecksEnabled != newValue else { return }
            updater?.automaticallyChecksForUpdates = newValue
            automaticUpdateChecksEnabled = updater?.automaticallyChecksForUpdates ?? newValue
        }
    }
    @Published private var credentialDrafts: [String: String] = [:]

    let credentialGroups: [CredentialGroup] = []

    private let sourceDescriptors: [ProviderID: ProviderSourceDescriptor]
    private let credentialStore: any AppCredentialStore
    private let preferencesStore: any PreferencesStore
    private let coordinator: RefreshCoordinator
    private let diagnostics: any DiagnosticsSink
    private struct CredentialOperation {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var started = false
    private var streamTask: Task<Void, Never>?
    private var preferenceSaveTask: Task<Void, Never>?
    private var credentialOperations: [ProviderID: CredentialOperation] = [:]
    private var refreshOperations: [UUID: Task<Void, Never>] = [:]
    private var isStopping = false
    private var lastLoggedStateCodes: [ProviderID: String] = [:]
    private let updater: (any AppUpdating)?
    private var updaterStartAttempted = false
    private let launchAtLoginService: any LaunchAtLoginServicing
    private var applicationActivationObserver: AnyCancellable?

    init(
        adapters suppliedAdapters: [any ProviderAdapter]? = nil,
        credentialStore suppliedCredentialStore: (any AppCredentialStore)? = nil,
        preferencesStore suppliedPreferencesStore: (any PreferencesStore)? = nil,
        context suppliedContext: CollectionContext? = nil,
        languageDefaults: UserDefaults = .standard,
        updater suppliedUpdater: (any AppUpdating)? = nil,
        launchAtLoginService suppliedLaunchAtLoginService: (any LaunchAtLoginServicing)? = nil
    ) {
        self.languageDefaults = languageDefaults
        let resolvedLaunchAtLoginService: any LaunchAtLoginServicing = {
            if let suppliedLaunchAtLoginService { return suppliedLaunchAtLoginService }
            #if UITEST
            return DisabledLaunchAtLoginService()
            #else
            guard
                suppliedContext == nil,
                NSClassFromString("XCTestCase") == nil,
                ProcessInfo.processInfo.environment["TOKENTANK_DISABLE_AUTOSTART"] != "1"
            else {
                return DisabledLaunchAtLoginService()
            }
            return SMAppLaunchAtLoginService()
            #endif
        }()
        self.launchAtLoginService = resolvedLaunchAtLoginService
        self._launchAtLoginStatus = Published(initialValue: resolvedLaunchAtLoginService.status)
        self._launchAtLoginError = Published(initialValue: nil)
        let resolvedUpdater: (any AppUpdating)? = {
            if let suppliedUpdater { return suppliedUpdater }
            #if UITEST
            return nil
            #else
            guard
                suppliedContext == nil,
                NSClassFromString("XCTestCase") == nil,
                ProcessInfo.processInfo.environment["TOKENTANK_DISABLE_AUTOSTART"] != "1"
            else { return nil }
            return AppUpdater()
            #endif
        }()
        self.updater = resolvedUpdater
        self._canCheckForUpdates = Published(initialValue: resolvedUpdater?.canCheckForUpdates ?? false)
        self._updaterError = Published(initialValue: false)
        self._automaticUpdateChecksEnabled = Published(
            initialValue: resolvedUpdater?.automaticallyChecksForUpdates ?? true
        )
        self.language = languageDefaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.preferred(Locale.preferredLanguages)
        let defaultAdapters = TokenTankProviderRegistry.defaultAdapters()
        let adapterList = suppliedAdapters ?? defaultAdapters
        self.sourceDescriptors = Dictionary(
            uniqueKeysWithValues: defaultAdapters.map { ($0.id, $0.sourceDescriptor) }
        )
        self.states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, .neverLoaded) })

        if let suppliedContext {
            self.credentialStore = suppliedCredentialStore ?? suppliedContext.credentials
            self.preferencesStore = suppliedPreferencesStore ?? UserDefaultsPreferencesStore()
            self.diagnostics = suppliedContext.diagnostics
            self.coordinator = RefreshCoordinator(adapters: adapterList, context: suppliedContext)
        } else {
            let credentials = suppliedCredentialStore ?? KeychainCredentialStore()
            let diagnostics: any DiagnosticsSink = UnifiedDiagnostics()
            let filesystemPolicy = FilesystemAccessPolicy()
            let context = CollectionContext(
                network: URLSessionNetworkClient(),
                credentials: credentials,
                externalSessions: filesystemPolicy,
                sqlite: SQLiteExternalSessionReader(policy: filesystemPolicy),
                codexAccount: CodexAppServerUsageReader(),
                doubaoPlan: ArkCLIPlanUsageReader(),
                clock: SystemClock(),
                diagnostics: diagnostics
            )
            self.credentialStore = credentials
            self.preferencesStore = suppliedPreferencesStore ?? UserDefaultsPreferencesStore()
            self.coordinator = RefreshCoordinator(adapters: adapterList, context: context)
            self.diagnostics = diagnostics
        }
        resolvedUpdater?.onCanCheckForUpdatesChanged = { [weak self] canCheckForUpdates in
            guard let self, !self.isStopping, !self.updaterError else { return }
            self.canCheckForUpdates = canCheckForUpdates
        }
        applicationActivationObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLaunchAtLoginStatus()
                }
            }
    }

    deinit {
        streamTask?.cancel()
        preferenceSaveTask?.cancel()
        for operation in credentialOperations.values { operation.task.cancel() }
        for task in refreshOperations.values { task.cancel() }
    }

    func ensureStarted() {
        guard !started, !isStopping else { return }
        started = true
        if !updaterStartAttempted, let updater {
            updaterStartAttempted = true
            do {
                try updater.start()
                canCheckForUpdates = updater.canCheckForUpdates
            } catch {
                updaterError = true
                canCheckForUpdates = false
            }
        }
        let coordinator = coordinator
        let preferencesStore = preferencesStore
        let diagnostics = diagnostics
        streamTask = Task { [weak self, coordinator, preferencesStore, diagnostics] in
            await diagnostics.record(
                DiagnosticEvent(level: .info, category: "lifecycle", code: "lifecycle.started")
            )
            let preferredLanguage = Locale.preferredLanguages.first?
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first?
                .lowercased() ?? "en"
            let localizationCode = ["en", "ko"].contains(preferredLanguage)
                ? "localization.supported"
                : "localization.english-fallback"
            await diagnostics.record(
                DiagnosticEvent(level: .info, category: "localization", code: localizationCode)
            )
            let loadedPreferences = await preferencesStore.load()
            if Task.isCancelled { return }
            self?.preferences = loadedPreferences
            let stream = await coordinator.stateStream()
            await coordinator.start()
            for await nextStates in stream {
                if Task.isCancelled { break }
                await self?.apply(states: nextStates)
            }
            await coordinator.stop()
        }
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        let runningStreamTask = streamTask
        streamTask = nil
        runningStreamTask?.cancel()

        let pendingPreferenceTask = preferenceSaveTask
        preferenceSaveTask = nil
        pendingPreferenceTask?.cancel()
        let pendingRefreshOperations = Array(refreshOperations.values)
        refreshOperations.removeAll(keepingCapacity: false)
        for operation in pendingRefreshOperations {
            operation.cancel()
        }

        let pendingCredentialOperations = Array(credentialOperations.values)
        credentialOperations.removeAll(keepingCapacity: false)
        for operation in pendingCredentialOperations {
            operation.task.cancel()
        }

        await runningStreamTask?.value
        await pendingPreferenceTask?.value
        for operation in pendingRefreshOperations {
            await operation.value
        }
        for operation in pendingCredentialOperations {
            await operation.task.value
        }

        if started {
            do {
                try await preferencesStore.save(preferences)
            } catch {
                await recordPreferenceSaveFailure()
            }
        }
        credentialDrafts.removeAll(keepingCapacity: false)
        credentialErrorCodes.removeAll(keepingCapacity: false)
        await coordinator.clearProcessLifetimeSnapshots()
        states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, .neverLoaded) })
        isRefreshing = false
        lastLoggedStateCodes.removeAll(keepingCapacity: false)
        canCheckForUpdates = false
        if started {
            await diagnostics.record(
                DiagnosticEvent(level: .info, category: "lifecycle", code: "lifecycle.stopped")
            )
        }
        started = false
    }

    func refreshAll() {
        guard !isStopping else { return }
        ensureStarted()
        guard started else { return }
        startRefresh()
    }

    func refresh(_ providerID: ProviderID) {
        guard !isStopping else { return }
        ensureStarted()
        guard started else { return }
        startRefresh(providerID: providerID)
    }
    func checkForUpdates() {
        guard
            started,
            !isStopping,
            canCheckForUpdates,
            let updater,
            updater.canCheckForUpdates
        else { return }
        updater.checkForUpdates()
    }
    var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus.isRegistered
    }

    func refreshLaunchAtLoginStatus() {
        guard !isStopping else { return }
        launchAtLoginStatus = launchAtLoginService.status
        launchAtLoginError = nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isStopping else { return }
        refreshLaunchAtLoginStatus()
        guard launchAtLoginStatus.isRegistered != enabled else { return }

        do {
            if enabled {
                try launchAtLoginService.register()
            } else {
                try launchAtLoginService.unregister()
            }
        } catch {
            launchAtLoginError = error
            launchAtLoginStatus = launchAtLoginService.status
            return
        }
        refreshLaunchAtLoginStatus()
    }

    func openLaunchAtLoginSettings() {
        guard !isStopping else { return }
        launchAtLoginService.openSystemSettings()
    }

    func menuValue(for preference: ProviderPreference) -> String {
        if preference.providerID == .codex,
           let primary = codexAccounts().first,
           let quota = menuQuota(for: primary, preference: preference),
           let remaining = QuotaDisplayFormatter.remainingPercentage(quota.percentage) {
            return "\(Self.roundedPercent(remaining))%"
        }
        guard
            let quota = menuQuota(for: preference),
            let remaining = QuotaDisplayFormatter.remainingPercentage(quota.percentage)
        else { return "—" }
        return "\(Self.roundedPercent(remaining))%"
    }

    func menuQuota(for preference: ProviderPreference) -> RawQuotaItem? {
        if preference.providerID == .codex,
           let primary = codexAccounts().first {
            return menuQuota(for: primary, preference: preference)
        }
        let quotas = states[preference.providerID]?.snapshot?.quotas ?? []
        return menuQuota(in: quotas, preference: preference)
    }

    private func menuQuota(
        for account: ProviderAccountSnapshot,
        preference: ProviderPreference
    ) -> RawQuotaItem? {
        menuQuota(in: account.quotas, preference: preference)
    }

    private func menuQuota(
        in quotas: [RawQuotaItem],
        preference: ProviderPreference
    ) -> RawQuotaItem? {
        if preference.providerID == .codex {
            return QuotaDisplayFormatter.defaultCodexQuota(quotas)
        }
        if let selectedID = preference.representativeQuotaID {
            return quotas.first(where: { $0.id == selectedID })
        }
        return QuotaDisplayFormatter.displayedQuotas(
            quotas,
            providerID: preference.providerID
        ).first
    }

    func codexAccounts() -> [ProviderAccountSnapshot] {
        CodexAccountPresentation.accounts(for: states[.codex] ?? .neverLoaded)
    }


    func codexMenuValues(for preference: ProviderPreference) -> [CodexAccountMenuValue] {
        guard preference.providerID == .codex else { return [] }
        return codexAccounts().map { account in
            let quota = menuQuota(for: account, preference: preference)
            let value = quota.flatMap {
                QuotaDisplayFormatter.remainingPercentage($0.percentage).map {
                    "\(Self.roundedPercent($0))%"
                }
            } ?? "—"
            return CodexAccountMenuValue(
                sourceID: account.sourceID,
                value: value,
                isStale: account.isStale
            )
        }
    }

    func menuSummaryText(for preference: ProviderPreference) -> String {
        let staleLabel = CodexAccountPresentation.localized("state.stale", locale: locale)
        if preference.providerID == .codex {
            let values = codexMenuValues(for: preference)
            if !values.isEmpty {
                let accounts = values.map { value in
                    let suffix = value.isStale ? " (\(staleLabel))" : ""
                    return "\(value.value)\(suffix)"
                }.joined(separator: " · ")
                return "\(preference.providerID.displayName) \(accounts)"
            }
        }

        var value = "\(preference.providerID.displayName) \(menuValue(for: preference))"
        if states[preference.providerID]?.isStale == true {
            value += " (\(staleLabel))"
        }
        return value
    }

    func menuBarSummaryItems() -> [MenuBarSummaryItem] {
        preferences.visibleProviders.map { preference in
            let text: String
            if preference.providerID == .codex, !codexAccounts().isEmpty {
                text = codexMenuValues(for: preference).map {
                    "\($0.value)\($0.isStale ? "*" : "")"
                }.joined(separator: " · ")
            } else {
                text = menuValue(for: preference)
            }
            return MenuBarSummaryItem(
                providerID: preference.providerID,
                text: menuBarDisplayText(text)
            )
        }
    }

    private static func roundedPercent(_ value: Decimal) -> Int {
        var rounded = Decimal()
        var source = value
        NSDecimalRound(&rounded, &source, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    func menuBarLabelText(forDisplay: Bool = false) -> String {
        let text = preferences.visibleProviders.map { menuSummaryText(for: $0) }.joined(separator: "  ")
        return forDisplay ? menuBarDisplayText(text) : text
    }

    private func menuBarDisplayText(_ text: String) -> String {
        preferences.showsMenuBarPercentSign ? text : text.replacingOccurrences(of: "%", with: "")
    }

    var orderedPreferences: [ProviderPreference] {
        preferences.providers.sorted { lhs, rhs in
            if lhs.order == rhs.order { return lhs.providerID.rawValue < rhs.providerID.rawValue }
            return lhs.order < rhs.order
        }
    }

    private func apply(states nextStates: [ProviderID: CollectionState]) async {
        states = nextStates.merging(
            Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, .neverLoaded) })
        ) { current, _ in current }
        isRefreshing = states.values.contains {
            if case .refreshing = $0 { return true }
            return false
        }
        for (providerID, state) in states {
            let code = diagnosticStateCode(state)
            guard lastLoggedStateCodes[providerID] != code else { continue }
            lastLoggedStateCodes[providerID] = code
            await diagnostics.record(
                DiagnosticEvent(
                    level: .debug,
                    category: "ui-state",
                    code: code,
                    providerID: providerID
                )
            )
        }
    }

    private func diagnosticStateCode(_ state: CollectionState) -> String {
        switch state {
        case .neverLoaded: "ui-state.never-loaded"
        case .refreshing: "ui-state.refreshing"
        case .fresh: "ui-state.fresh"
        case .stale: "ui-state.stale"
        case .authenticationActionRequired: "ui-state.authentication-required"
        }
    }

    func preference(for providerID: ProviderID) -> ProviderPreference {
        preferences.preference(for: providerID)
    }

    func updatePreference(_ preference: ProviderPreference) {
        guard !isStopping else { return }
        var next = preferences
        if let index = next.providers.firstIndex(where: { $0.providerID == preference.providerID }) {
            next.providers[index] = preference
        } else {
            next.providers.append(preference)
        }
        preferences = next.normalized()
        persistPreferences()
    }

    func setShowsMenuBarPercentSign(_ value: Bool) {
        guard !isStopping, preferences.showsMenuBarPercentSign != value else { return }
        preferences.showsMenuBarPercentSign = value
        persistPreferences()
    }

    func move(_ providerID: ProviderID, offset: Int) {
        guard !isStopping else { return }
        var ordered = orderedPreferences
        guard
            let sourceIndex = ordered.firstIndex(where: { $0.providerID == providerID }),
            ordered.indices.contains(sourceIndex + offset)
        else { return }
        ordered.swapAt(sourceIndex, sourceIndex + offset)
        for index in ordered.indices { ordered[index].order = index }
        var next = preferences
        next.providers = ordered
        preferences = next.normalized()
        persistPreferences()
    }

    func isFirst(_ providerID: ProviderID) -> Bool {
        orderedPreferences.first?.providerID == providerID
    }

    func isLast(_ providerID: ProviderID) -> Bool {
        orderedPreferences.last?.providerID == providerID
    }

    func quotas(for providerID: ProviderID) -> [RawQuotaItem] {
        guard let snapshot = states[providerID]?.snapshot else { return [] }
        let quotas: [RawQuotaItem]
        if providerID == .codex, snapshot.quotas.isEmpty, !snapshot.accounts.isEmpty {
            quotas = CodexAccountPresentation.ordered(snapshot.accounts).flatMap(\.quotas)
        } else {
            quotas = snapshot.quotas
        }
        guard providerID == .codex else { return quotas }
        return QuotaDisplayFormatter.displayedQuotas(quotas, providerID: .codex)
    }

    func sourceDescriptor(for providerID: ProviderID) -> ProviderSourceDescriptor? {
        sourceDescriptors[providerID]
    }

    #if UITEST
    func installUITestStates() {
        let now = Date()
        func snapshot(
            _ providerID: ProviderID,
            originalName: String,
            used: Decimal?,
            remaining: Decimal?,
            percentage: Decimal?,
            meaning: PercentageMeaning,
            resetsAt: Date?,
            sourceFields: [String: String] = [:],
            accountEmail: String? = nil
        ) -> ProviderSnapshot {
            let quota = RawQuotaItem(
                id: RawQuotaID(rawValue: "ui-test.\(providerID.rawValue)"),
                originalName: originalName,
                used: used.map {
                    SourceValue(
                        value: $0,
                        rawText: NSDecimalNumber(decimal: $0).stringValue,
                        unit: "tokens"
                    )
                },
                remaining: remaining.map {
                    SourceValue(
                        value: $0,
                        rawText: NSDecimalNumber(decimal: $0).stringValue,
                        unit: "tokens"
                    )
                },
                percentage: percentage.map {
                    SourcePercentage(
                        value: $0,
                        rawText: NSDecimalNumber(decimal: $0).stringValue,
                        meaning: meaning
                    )
                } ?? .missing(meaning: meaning),
                resetsAt: resetsAt,
                sourceFields: sourceFields
            )
            var quotas = [quota]
            if providerID == .codex {
                quotas.append(RawQuotaItem(
                    id: "ui-test.codex.spark", originalName: "Spark", used: nil, remaining: nil,
                    percentage: SourcePercentage(value: 0, rawText: "0", meaning: .used), resetsAt: nil,
                    sourceFields: ["limitId": "codex_spark", "window": "primary", "windowDurationMins": "300"]
                ))
                quotas.append(RawQuotaItem(
                    id: "rateLimitResetCredits", originalName: "tickets", used: nil,
                    remaining: SourceValue(value: 2, rawText: "2", unit: "credits"),
                    percentage: .missing(meaning: .remaining), resetsAt: nil
                ))
                for index in 1...2 {
                    quotas.append(RawQuotaItem(
                        id: RawQuotaID(rawValue: "rateLimitResetCredit.\(index)"), originalName: "ticket",
                        used: nil, remaining: nil, percentage: .missing(meaning: .remaining),
                        resetsAt: now.addingTimeInterval(Double(index) * 3600)
                    ))
                }
            }
            if providerID == .claude {
                quotas.append(RawQuotaItem(
                    id: "ui-test.claude.fable",
                    originalName: "weekly_scoped.Fable",
                    used: nil,
                    remaining: nil,
                    percentage: SourcePercentage(value: 44, rawText: "44", meaning: .used),
                    resetsAt: nil
                ))
            }
            return ProviderSnapshot(
                providerID: providerID,
                source: sourceDescriptors[providerID]!,
                quotas: quotas,
                refreshedAt: now.addingTimeInterval(-30),
                accountEmail: accountEmail
            )
        }

        let baseCodex = snapshot(
            .codex,
            originalName: "Primary window",
            used: 0,
            remaining: 100,
            percentage: 0,
            meaning: .used,
            resetsAt: now.addingTimeInterval(3_600),
            sourceFields: ["limitId": "codex", "window": "primary", "windowDurationMins": "10080"],
            accountEmail: "codex@example.com"
        )
        let codex: ProviderSnapshot
        if ProcessInfo.processInfo.environment["TOKENTANK_UI_CODEX_ACCOUNTS"] == "1" {
            let primary = snapshot(
                .codex,
                originalName: "Codex",
                used: 26,
                remaining: nil,
                percentage: 26,
                meaning: .used,
                resetsAt: now.addingTimeInterval(3_600),
                sourceFields: [
                    "limitId": "codex",
                    "limitName": "Codex",
                    "window": "primary",
                    "windowDurationMins": "10080"
                ],
                accountEmail: "work@example.com"
            )
            let secondary = snapshot(
                .codex,
                originalName: "Codex",
                used: 2,
                remaining: nil,
                percentage: 2,
                meaning: .used,
                resetsAt: now.addingTimeInterval(7_200),
                sourceFields: [
                    "limitId": "codex",
                    "limitName": "Codex",
                    "window": "primary",
                    "windowDurationMins": "10080"
                ],
                accountEmail: "personal@example.com"
            )
            codex = ProviderSnapshot(
                providerID: .codex,
                source: sourceDescriptors[.codex]!,
                accounts: [
                    ProviderAccountSnapshot(
                        sourceID: CodexAccountSource.primary.id,
                        quotas: primary.quotas,
                        refreshedAt: primary.refreshedAt,
                        accountEmail: "work@example.com",
                        plan: "Plus"
                    ),
                    ProviderAccountSnapshot(
                        sourceID: CodexAccountSource.secondary.id,
                        quotas: secondary.quotas,
                        refreshedAt: secondary.refreshedAt,
                        accountEmail: "personal@example.com",
                        plan: "Plus",
                        failure: ProcessInfo.processInfo.environment["TOKENTANK_UI_CODEX_SECONDARY_FAILURE"] == "1"
                            ? CollectionError(kind: .authenticationRejected, diagnosticCode: "ui-test.codex.secondary.auth", recoveryAction: .signInSourceApp) : nil,
                        failedAt: ProcessInfo.processInfo.environment["TOKENTANK_UI_CODEX_SECONDARY_FAILURE"] == "1" ? now : nil
                    ),
                ],
                refreshedAt: now.addingTimeInterval(-30)
            )
        } else {
            codex = baseCodex
        }
        let claude = snapshot(
            .claude,
            originalName: "weekly_all",
            used: 10,
            remaining: nil,
            percentage: 10,
            meaning: .used,
            resetsAt: nil,
            accountEmail: "claude.long.account.name.for.compact.layout@example.com"
        )
        let doubao = snapshot(
            .doubao,
            originalName: "5h",
            used: nil,
            remaining: ProcessInfo.processInfo.environment["TOKENTANK_UI_MISSING_QUOTA"] == "1" ? nil : 0,
            percentage: nil,
            meaning: .remaining,
            resetsAt: nil
        )
        states = [
            .codex: .fresh(codex),
            .claude: .stale(
                snapshot: claude,
                failure: CollectionError(
                    kind: .offline,
                    diagnosticCode: "ui-test.claude.offline"
                ),
                failedAt: now
            ),
            .grok: .authenticationActionRequired(
                snapshot: nil,
                failure: CollectionError(
                    kind: .authenticationRejected,
                    diagnosticCode: "ui-test.grok.authentication",
                    recoveryAction: .signInSourceApp
                )
            ),
            .cursor: .stale(
                snapshot: nil,
                failure: CollectionError(
                    kind: .permissionDenied,
                    diagnosticCode: "ui-test.cursor.permission"
                ),
                failedAt: now
            ),
            .doubao: .fresh(doubao),
        ]
        preferences.providers = preferences.providers.map { preference in
            var selected = preference
            selected.representativeQuotaID = preference.providerID == .grok
                ? "ui-test.vanished"
                : states[preference.providerID]?.snapshot?.quotas.first?.id
            return selected
        }
        isRefreshing = false
    }
    #endif

    func credentialDraft(_ id: String) -> String {
        credentialDrafts[id] ?? ""
    }

    func updateCredentialDraft(_ value: String, id: String) {
        guard !isStopping else { return }
        credentialDrafts[id] = value
    }

    func hasCredentialDrafts(for providerID: ProviderID) -> Bool {
        credentialGroups
            .first(where: { $0.providerID == providerID })?
            .fields
            .contains(where: { !(credentialDrafts[$0.id] ?? "").isEmpty }) == true
    }

    func saveCredentials(for providerID: ProviderID) {
        guard !isStopping else { return }
        guard let fields = credentialGroups.first(where: { $0.providerID == providerID })?.fields else { return }
        let pending = fields.compactMap { field -> (CredentialField, String)? in
            let value = (credentialDrafts[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : (field, value)
        }
        guard !pending.isEmpty else { return }

        let operationID = UUID()
        let previousTask = credentialOperations.removeValue(forKey: providerID)?.task
        previousTask?.cancel()
        let task = Task { [weak self, credentialStore, coordinator] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled, let self else { return }
            defer { finishCredentialOperation(providerID: providerID, operationID: operationID) }
            do {
                for (field, value) in pending {
                    try Task.checkCancellation()
                    try await credentialStore.write(value, for: field.credentialID)
                    try Task.checkCancellation()
                    credentialDrafts.removeValue(forKey: field.id)
                }
                credentialErrorCodes.removeValue(forKey: providerID)
                try Task.checkCancellation()
                await coordinator.refresh(providerID)
            } catch is CancellationError {
                return
            } catch let error as CollectionError {
                credentialErrorCodes[providerID] = error.diagnosticCode
            } catch {
                credentialErrorCodes[providerID] = "keychain.untyped-error"
            }
        }
        credentialOperations[providerID] = CredentialOperation(id: operationID, task: task)
    }

    func deleteCredentials(for providerID: ProviderID) {
        guard !isStopping else { return }
        guard let fields = credentialGroups.first(where: { $0.providerID == providerID })?.fields else { return }
        let operationID = UUID()
        let previousTask = credentialOperations.removeValue(forKey: providerID)?.task
        previousTask?.cancel()
        let task = Task { [weak self, credentialStore, coordinator] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled, let self else { return }
            defer { finishCredentialOperation(providerID: providerID, operationID: operationID) }
            do {
                for field in fields {
                    try Task.checkCancellation()
                    try await credentialStore.delete(field.credentialID)
                    try Task.checkCancellation()
                    credentialDrafts.removeValue(forKey: field.id)
                }
                credentialErrorCodes.removeValue(forKey: providerID)
                try Task.checkCancellation()
                await coordinator.refresh(providerID)
            } catch is CancellationError {
                return
            } catch let error as CollectionError {
                credentialErrorCodes[providerID] = error.diagnosticCode
            } catch {
                credentialErrorCodes[providerID] = "keychain.untyped-error"
            }
        }
        credentialOperations[providerID] = CredentialOperation(id: operationID, task: task)
    }

    private func startRefresh(providerID: ProviderID? = nil) {
        guard !isStopping else { return }
        let operationID = UUID()
        let coordinator = coordinator
        let task = Task { [weak self, coordinator] in
            if let providerID {
                await coordinator.refresh(providerID)
            } else {
                await coordinator.refreshAll()
            }
            self?.finishRefreshOperation(operationID)
        }
        refreshOperations[operationID] = task
    }

    private func finishRefreshOperation(_ operationID: UUID) {
        refreshOperations.removeValue(forKey: operationID)
    }
    private func finishCredentialOperation(providerID: ProviderID, operationID: UUID) {
        guard credentialOperations[providerID]?.id == operationID else { return }
        credentialOperations.removeValue(forKey: providerID)
    }

    private func persistPreferences() {
        guard !isStopping else { return }
        preferenceSaveTask?.cancel()
        let value = preferences
        let store = preferencesStore
        preferenceSaveTask = Task { [weak self, store, value] in
            do {
                try await Task.sleep(for: .milliseconds(75))
                try Task.checkCancellation()
                try await store.save(value)
            } catch is CancellationError {
                return
            } catch {
                await self?.recordPreferenceSaveFailure()
            }
        }
    }

    private func recordPreferenceSaveFailure() async {
        await diagnostics.record(
            DiagnosticEvent(level: .error, category: "preferences", code: "preferences.save-failed")
        )
    }
}
