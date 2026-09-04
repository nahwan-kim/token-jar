import Combine
import Foundation
import TokenTankCore
import TokenTankDomain
import TokenTankProviders

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

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var states: [ProviderID: CollectionState]
    @Published private(set) var preferences = UserPreferences()
    @Published private(set) var isRefreshing = false
    @Published private(set) var credentialErrorCodes: [ProviderID: String] = [:]
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

    init(
        adapters suppliedAdapters: [any ProviderAdapter]? = nil,
        credentialStore suppliedCredentialStore: (any AppCredentialStore)? = nil,
        preferencesStore suppliedPreferencesStore: (any PreferencesStore)? = nil,
        context suppliedContext: CollectionContext? = nil
    ) {
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

    func menuValue(for preference: ProviderPreference) -> String {
        guard
            let quota = menuQuota(for: preference),
            let remaining = QuotaDisplayFormatter.remainingPercentage(quota.percentage)
        else { return "—" }
        return "\(Self.roundedPercent(remaining))%"
    }

    func menuQuota(for preference: ProviderPreference) -> RawQuotaItem? {
        let quotas = states[preference.providerID]?.snapshot?.quotas ?? []
        if let selectedID = preference.representativeQuotaID {
            return quotas.first(where: { $0.id == selectedID })
        }
        return QuotaDisplayFormatter.displayedQuotas(
            quotas,
            providerID: preference.providerID
        ).first
    }
    private static func roundedPercent(_ value: Decimal) -> Int {
        var rounded = Decimal()
        var source = value
        NSDecimalRound(&rounded, &source, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    func menuBarLabelText() -> String {
        preferences.visibleProviders.map { preference in
            "\(preference.abbreviation) \(menuValue(for: preference))"
        }.joined(separator: "  ")
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

    func move(_ providerID: ProviderID, offset: Int) {
        guard !isStopping else { return }
        var ordered = orderedPreferences
        guard
            let sourceIndex = ordered.firstIndex(where: { $0.providerID == providerID }),
            ordered.indices.contains(sourceIndex + offset)
        else { return }
        ordered.swapAt(sourceIndex, sourceIndex + offset)
        for index in ordered.indices { ordered[index].order = index }
        preferences = UserPreferences(providers: ordered).normalized()
        persistPreferences()
    }

    func isFirst(_ providerID: ProviderID) -> Bool {
        orderedPreferences.first?.providerID == providerID
    }

    func isLast(_ providerID: ProviderID) -> Bool {
        orderedPreferences.last?.providerID == providerID
    }

    func quotas(for providerID: ProviderID) -> [RawQuotaItem] {
        states[providerID]?.snapshot?.quotas ?? []
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
            sourceFields: [String: String] = [:]
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
            return ProviderSnapshot(
                providerID: providerID,
                source: sourceDescriptors[providerID]!,
                quotas: [quota],
                refreshedAt: now.addingTimeInterval(-30)
            )
        }

        let codex = snapshot(
            .codex,
            originalName: "Primary window",
            used: 0,
            remaining: 100,
            percentage: 0,
            meaning: .used,
            resetsAt: now.addingTimeInterval(3_600)
        )
        let claude = snapshot(
            .claude,
            originalName: "Monthly tokens",
            used: 10,
            remaining: nil,
            percentage: 10,
            meaning: .used,
            resetsAt: nil
        )
        let doubao = snapshot(
            .doubao,
            originalName: "5h",
            used: nil,
            remaining: 0,
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
                    diagnosticCode: "ui-test.grok.authentication"
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
