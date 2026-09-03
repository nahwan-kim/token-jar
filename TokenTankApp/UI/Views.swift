import AppKit
import SwiftUI
import TokenTankDomain

struct MenuBarLabelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.preferences.visibleProviders.isEmpty {
                Image(systemName: "chart.bar.fill")
                    .accessibilityLabel(Text("menu.summary.empty"))
            }
            ForEach(model.preferences.visibleProviders) { preference in
                HStack(spacing: 3) {
                    Text(verbatim: preference.abbreviation)
                    Text(verbatim: model.menuPercentage(for: preference))
                    if model.states[preference.providerID]?.isStale == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityLabel(Text("state.stale"))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menu-bar.summary")
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: Text {
        let visibleProviders = model.preferences.visibleProviders
        guard !visibleProviders.isEmpty else { return Text("menu.summary.empty") }
        return visibleProviders.enumerated().reduce(Text(verbatim: "")) { result, entry in
            let (index, preference) = entry
            var component = Text(
                verbatim: "\(index == 0 ? "" : ", ")\(preference.abbreviation) \(model.menuPercentage(for: preference))"
            )
            if model.states[preference.providerID]?.isStale == true {
                component = component + Text(verbatim: " ") + Text("state.stale")
            }
            return result + component
        }
    }
}

struct DetailPopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("detail.title")
                    .font(.headline)
                Spacer()
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("state.refreshing"))
                }
                Button {
                    model.refreshAll()
                } label: {
                    Label("action.retry", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(Text("action.refresh.help"))
                .accessibilityLabel(Text("action.refresh.help"))
                .accessibilityIdentifier("action.refresh")

                Button {
                    showSettings()
                } label: {
                    Label("settings.title", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help(Text("settings.title"))
                .accessibilityLabel(Text("settings.title"))
                .accessibilityIdentifier("action.settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("action.quit", systemImage: "power")
                        .labelStyle(.iconOnly)
                }
                .help(Text("action.quit"))
                .accessibilityLabel(Text("action.quit"))
                .accessibilityIdentifier("action.quit")
            }
            .padding()

            Divider()

            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(ProviderID.allCases) { providerID in
                            ProviderDetailView(
                                providerID: providerID,
                                state: model.states[providerID] ?? .neverLoaded,
                                now: context.date,
                                retry: { model.refresh(providerID) },
                                configure: { showSettings() }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 520, height: 620)
        .task {
            #if UITEST
            model.installUITestStates()
            #else
            model.ensureStarted()
            #endif
        }
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct ProviderDetailView: View {
    let providerID: ProviderID
    let state: CollectionState
    let now: Date
    let retry: () -> Void
    let configure: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                statusView

                if let snapshot = state.snapshot {
                    if snapshot.quotas.isEmpty {
                        Text("state.source.empty")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.quotas) { quota in
                            QuotaValueView(quota: quota, refreshedAt: snapshot.refreshedAt, now: now)
                            if quota.id != snapshot.quotas.last?.id {
                                Divider()
                            }
                        }
                    }
                    Text(verbatim: snapshot.source.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(Text("detail.source"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(verbatim: providerID.displayName)
                    .font(.headline)
                Spacer()
                stateBadge
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider.\(providerID.rawValue)")
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .neverLoaded:
            Label("state.never_loaded", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .refreshing:
            Label("state.refreshing", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .fresh:
            EmptyView()
        case let .stale(_, failure, _):
            FailureView(failure: failure, retry: retry, configure: configure)
        case let .authenticationActionRequired(_, failure):
            FailureView(failure: failure, retry: retry, configure: configure)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .neverLoaded:
            Text("state.unavailable")
                .badgeStyle(.secondary)
                .accessibilityIdentifier("state.unavailable")
        case .refreshing:
            Text("state.refreshing")
                .badgeStyle(.secondary)
                .accessibilityIdentifier("state.refreshing")
        case .fresh:
            Text("state.fresh")
                .badgeStyle(.green)
                .accessibilityIdentifier("state.fresh")
        case .stale:
            Text("state.stale")
                .badgeStyle(.orange)
                .accessibilityIdentifier("state.stale")
        case .authenticationActionRequired:
            Text("state.authentication_required")
                .badgeStyle(.red)
                .accessibilityIdentifier("state.authentication-required")
        }
    }
}

private struct FailureView: View {
    let failure: CollectionError
    let retry: () -> Void
    let configure: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(errorKey)
                    .font(.callout)
                    .accessibilityIdentifier("error.\(failure.kind.rawValue)")
                Text(verbatim: failure.diagnosticCode)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .privacySensitive()
            }
            Spacer()
            if failure.recoveryAction == .signInSourceApp
                || failure.recoveryAction == .waitForNextRefresh
                || failure.recoveryAction == .allowAccessInSystemSettings {
                Text(actionKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("action.\(failure.recoveryAction.rawValue)")
            } else if failure.recoveryAction != .none {
                Button(actionKey) {
                    switch failure.recoveryAction {
                    case .retry:
                        retry()
                    case .signInTokenTank:
                        configure()
                    case .signInSourceApp, .allowAccessInSystemSettings, .waitForNextRefresh, .none:
                        break
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("action.\(failure.recoveryAction.rawValue)")
            }
        }
    }

    private var errorKey: LocalizedStringKey {
        switch failure.kind {
        case .transientNetwork: "error.network"
        case .offline: "error.offline"
        case .rateLimited: "error.rate_limited"
        case .sourceUnavailable: "error.source_unavailable"
        case .schemaChanged, .malformedResponse: "error.schema"
        case .authenticationRejected, .authenticationRevoked: "error.authentication"
        case .externalSessionMissing: "error.external_session_missing"
        case .appCredentialMissing: "error.app_credential_missing"
        case .keychainUnavailable: "error.keychain"
        case .permissionDenied: "error.permission"
        case .unsafePath: "error.unsafe_path"
        case .cancelled: "error.cancelled"
        }
    }

    private var actionKey: LocalizedStringKey {
        switch failure.recoveryAction {
        case .retry: "action.retry"
        case .waitForNextRefresh: "action.wait"
        case .signInSourceApp: "action.sign_in_source"
        case .signInTokenTank: "action.sign_in_token_tank"
        case .allowAccessInSystemSettings: "action.allow_system_settings"
        case .none: "action.none"
        }
    }
}

struct QuotaValueView: View {
    let quota: RawQuotaItem
    let refreshedAt: Date
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: quota.originalName)
                .font(.body.weight(.medium))
                .textSelection(.enabled)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                valueRow(identifier: "used", label: "quota.used", value: formatted(quota.used))
                valueRow(identifier: "remaining", label: "quota.remaining", value: formatted(quota.remaining))
                valueRow(identifier: "percentage", label: percentageLabel, value: formattedPercentage)
                valueRow(identifier: "reset", label: "quota.reset", value: formattedReset)
                valueRow(
                    identifier: "refreshed",
                    label: "quota.refreshed",
                    value: refreshedAt.formatted(date: .abbreviated, time: .standard)
                )
            }
            .font(.caption)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quota.\(quota.id.rawValue)")
    }

    @ViewBuilder
    private func valueRow(
        identifier: String,
        label: LocalizedStringKey,
        value: String?
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            if let value {
                Text(verbatim: value)
                    .textSelection(.enabled)
            } else {
                Text("field.not_provided")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("field.\(identifier)")
        .accessibilityLabel(Text(label))
        .accessibilityValue(accessibilityValue(value))
    }

    private func accessibilityValue(_ value: String?) -> Text {
        if let value {
            return Text(verbatim: value)
        }
        return Text("field.not_provided")
    }

    private func formatted(_ value: SourceValue?) -> String? {
        guard let value else { return nil }
        guard let unit = value.unit, !unit.isEmpty else { return value.rawText }
        return "\(value.rawText) \(unit)"
    }

    private var percentageLabel: LocalizedStringKey {
        switch quota.percentage.meaning {
        case .used: "quota.percentage.used"
        case .remaining: "quota.percentage.remaining"
        }
    }

    private var formattedPercentage: String? {
        guard let raw = quota.percentage.rawText else { return nil }
        return raw.contains("%") ? raw : "\(raw)%"
    }

    private var formattedReset: String? {
        guard let reset = quota.resetsAt else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return "\(reset.formatted(date: .abbreviated, time: .standard)) (\(relative.localizedString(for: reset, relativeTo: now)))"
    }
}

struct ProviderSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            providerPreferences
                .tabItem {
                    Label("settings.providers", systemImage: "list.bullet")
                        .accessibilityIdentifier("settings.providers.tab")
                }
            credentialSettings
                .tabItem {
                    Label("settings.credentials", systemImage: "key")
                        .accessibilityIdentifier("settings.credentials.tab")
                }
            sourceSettings
                .tabItem {
                    Label("settings.sources", systemImage: "network")
                        .accessibilityIdentifier("settings.sources.tab")
                }
        }
        .padding()
        .task {
            #if UITEST
            model.installUITestStates()
            #else
            model.ensureStarted()
            #endif
        }
    }

    private var providerPreferences: some View {
        Form {
            Section("settings.summary") {
                ForEach(model.orderedPreferences) { preference in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(
                                isOn: binding(for: preference, keyPath: \.isVisible)
                            ) {
                                Text(verbatim: preference.providerID.displayName)
                            }
                            TextField(
                                "settings.abbreviation",
                                text: binding(for: preference, keyPath: \.abbreviation)
                            )
                            .frame(width: 90)
                            Button {
                                model.move(preference.providerID, offset: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(model.isFirst(preference.providerID))
                            .accessibilityLabel(Text("settings.move_up"))
                            Button {
                                model.move(preference.providerID, offset: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(model.isLast(preference.providerID))
                            .accessibilityLabel(Text("settings.move_down"))
                        }

                        Picker(
                            "settings.representative_quota",
                            selection: binding(for: preference, keyPath: \.representativeQuotaID)
                        ) {
                            if let selected = preference.representativeQuotaID,
                               !model.quotas(for: preference.providerID).contains(where: { $0.id == selected }) {
                                Text("state.selected_unavailable").tag(Optional(selected))
                            }
                            Text("settings.representative.none").tag(RawQuotaID?.none)
                            ForEach(model.quotas(for: preference.providerID)) { quota in
                                Text(verbatim: quota.originalName).tag(Optional(quota.id))
                            }
                        }
                        if let selected = preference.representativeQuotaID,
                           !model.quotas(for: preference.providerID).contains(where: { $0.id == selected }) {
                            HStack {
                                Label("state.selected_unavailable", systemImage: "exclamationmark.triangle")
                                Button("settings.representative.none") {
                                    var updated = preference
                                    updated.representativeQuotaID = nil
                                    model.updatePreference(updated)
                                }
                                .controlSize(.small)
                                .accessibilityIdentifier(
                                    "action.choose-another.\(preference.providerID.rawValue)"
                                )
                            }
                            .accessibilityElement(children: .contain)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .accessibilityIdentifier("settings.providers.content")
    }

    private var credentialSettings: some View {
        Form {
            Text("settings.credentials.explanation")
                .foregroundStyle(.secondary)
            ForEach(model.credentialGroups) { group in
                Section {
                    ForEach(group.fields) { field in
                        SecureField(
                            LocalizedStringKey(field.labelKey),
                            text: Binding(
                                get: { model.credentialDraft(field.id) },
                                set: { model.updateCredentialDraft($0, id: field.id) }
                            )
                        )
                        .textContentType(.password)
                        .privacySensitive()
                    }
                    HStack {
                        Button("settings.credentials.save") {
                            model.saveCredentials(for: group.providerID)
                        }
                        .disabled(!model.hasCredentialDrafts(for: group.providerID))
                        Button("settings.credentials.delete", role: .destructive) {
                            model.deleteCredentials(for: group.providerID)
                        }
                    }
                    if let code = model.credentialErrorCodes[group.providerID] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("error.keychain")
                                .foregroundStyle(.red)
                            Text(verbatim: code)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(verbatim: group.providerID.displayName)
                } footer: {
                    Text("settings.credentials.keychain_footer")
                }
            }
        }
        .accessibilityIdentifier("settings.credentials.content")
    }

    private var sourceSettings: some View {
        Form {
            Text("settings.sources.explanation")
                .foregroundStyle(.secondary)
            ForEach(ProviderID.allCases) { providerID in
                Section {
                    if let source = model.sourceDescriptor(for: providerID) {
                        LabeledContent("detail.source", value: source.name)
                        Text(sourceDetailKey(for: providerID))
                            .foregroundStyle(.secondary)
                        if let url = source.documentationURL {
                            Link("settings.source.documentation", destination: url)
                        }
                    } else {
                        Text("state.unavailable")
                    }
                } header: {
                    Text(verbatim: providerID.displayName)
                }
            }
        }
        .accessibilityIdentifier("settings.sources.content")
    }

    private func sourceDetailKey(for providerID: ProviderID) -> LocalizedStringKey {
        switch providerID {
        case .codex: "source.detail.codex"
        case .claude: "source.detail.claude"
        case .grok: "source.detail.grok"
        case .cursor: "source.detail.cursor"
        case .doubao: "source.detail.doubao"
        }
    }

    private func binding<Value>(
        for preference: ProviderPreference,
        keyPath: WritableKeyPath<ProviderPreference, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.preference(for: preference.providerID)[keyPath: keyPath] },
            set: { value in
                var updated = model.preference(for: preference.providerID)
                updated[keyPath: keyPath] = value
                model.updatePreference(updated)
            }
        )
    }
}

private enum BadgeColor {
    case secondary
    case green
    case orange
    case red

    var foreground: Color {
        switch self {
        case .secondary: .secondary
        case .green: .green
        case .orange: .orange
        case .red: .red
        }
    }
}

private extension View {
    func badgeStyle(_ color: BadgeColor) -> some View {
        self
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.foreground.opacity(0.12), in: Capsule())
    }
}
