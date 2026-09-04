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
                    Text(verbatim: model.menuValue(for: preference))
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
                verbatim: "\(index == 0 ? "" : ", ")\(preference.abbreviation) \(model.menuValue(for: preference))"
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
            header

            Divider()

            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(14)
                }
            }
        }
        .frame(width: 480, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            #if UITEST
            model.installUITestStates()
            #else
            model.ensureStarted()
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: overview.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(overview.tint)
                .frame(width: 34, height: 34)
                .background(overview.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("detail.title")
                    .font(.headline)
                Text(overview.title)
                    .font(.caption)
                    .foregroundStyle(overview.tint)
                    .accessibilityIdentifier("detail.overall-status")
            }

            Spacer()

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("state.refreshing"))
            }

            toolbarButton("action.refresh.help", symbol: "arrow.clockwise", identifier: "action.refresh") {
                model.refreshAll()
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("action.refresh.help"))

            toolbarButton("settings.title", symbol: "gearshape", identifier: "action.settings") {
                showSettings()
            }
            .help(Text("settings.title"))

            toolbarButton("action.quit", symbol: "power", identifier: "action.quit") {
                NSApp.terminate(nil)
            }
            .help(Text("action.quit"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func toolbarButton(
        _ label: LocalizedStringKey,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }

    private var overview: StatusPresentation {
        if model.isRefreshing {
            return StatusPresentation(
                title: "state.refreshing",
                symbol: "arrow.triangle.2.circlepath",
                tint: .blue
            )
        }

        var hasStale = false
        var hasRefreshing = false
        var hasUnavailable = false
        for providerID in ProviderID.allCases {
            switch model.states[providerID] ?? .neverLoaded {
            case .authenticationActionRequired:
                return StatusPresentation(
                    title: "state.authentication_required",
                    symbol: "exclamationmark.shield.fill",
                    tint: .red
                )
            case .stale:
                hasStale = true
            case .neverLoaded:
                hasUnavailable = true
            case .refreshing:
                hasRefreshing = true
            case .fresh:
                break
            }
        }

        if hasStale {
            return StatusPresentation(
                title: "state.stale",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if hasRefreshing {
            return StatusPresentation(
                title: "state.refreshing",
                symbol: "arrow.triangle.2.circlepath",
                tint: .blue
            )
        }
        if hasUnavailable {
            return StatusPresentation(
                title: "state.unavailable",
                symbol: "questionmark.circle.fill",
                tint: .secondary
            )
        }
        return StatusPresentation(
            title: "state.fresh",
            symbol: "checkmark.circle.fill",
            tint: .green
        )
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct StatusPresentation {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
}

struct ProviderDetailView: View {
    let providerID: ProviderID
    let state: CollectionState
    let now: Date
    let retry: () -> Void
    let configure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerHeader

            statusView

            if let snapshot = state.snapshot {
                if snapshot.quotas.isEmpty {
                    Label("state.source.empty", systemImage: "tray")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(snapshot.quotas) { quota in
                            QuotaValueView(quota: quota, refreshedAt: snapshot.refreshedAt, now: now)
                        }
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle")
                    Text(verbatim: snapshot.source.name)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("detail.source"))
                .accessibilityValue(Text(verbatim: snapshot.source.name))
            }
        }
        .padding(14)
        .background(presentation.tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(presentation.tint.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider.\(providerID.rawValue)")
    }

    private var providerHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: presentation.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(presentation.tint)
                .frame(width: 30, height: 30)
                .background(presentation.tint.opacity(0.13), in: Circle())
                .accessibilityHidden(true)

            Text(verbatim: providerID.displayName)
                .font(.headline)

            Spacer()

            Text(presentation.title)
                .badgeStyle(presentation.badgeColor)
                .accessibilityIdentifier(presentation.identifier)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .neverLoaded:
            Label("state.never_loaded", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .refreshing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("state.refreshing")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .fresh:
            EmptyView()
        case let .stale(_, failure, _):
            FailureView(failure: failure, retry: retry, configure: configure)
        case let .authenticationActionRequired(_, failure):
            FailureView(failure: failure, retry: retry, configure: configure)
        }
    }

    private var presentation: ProviderStatusPresentation {
        switch state {
        case .neverLoaded:
            ProviderStatusPresentation(
                title: "state.unavailable",
                symbol: "questionmark.circle.fill",
                tint: .secondary,
                badgeColor: .secondary,
                identifier: "state.unavailable"
            )
        case .refreshing:
            ProviderStatusPresentation(
                title: "state.refreshing",
                symbol: "arrow.triangle.2.circlepath",
                tint: .blue,
                badgeColor: .blue,
                identifier: "state.refreshing"
            )
        case .fresh:
            ProviderStatusPresentation(
                title: "state.fresh",
                symbol: "checkmark.circle.fill",
                tint: .green,
                badgeColor: .green,
                identifier: "state.fresh"
            )
        case .stale:
            ProviderStatusPresentation(
                title: "state.stale",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                badgeColor: .orange,
                identifier: "state.stale"
            )
        case .authenticationActionRequired:
            ProviderStatusPresentation(
                title: "state.authentication_required",
                symbol: "exclamationmark.shield.fill",
                tint: .red,
                badgeColor: .red,
                identifier: "state.authentication-required"
            )
        }
    }
}

private struct ProviderStatusPresentation {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let badgeColor: BadgeColor
    let identifier: String
}

private struct FailureView: View {
    let failure: CollectionError
    let retry: () -> Void
    let configure: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(errorKey)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("error.\(failure.kind.rawValue)")
                Text(verbatim: failure.diagnosticCode)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .privacySensitive()
            }

            Spacer(minLength: 8)

            recoveryView
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var recoveryView: some View {
        if failure.recoveryAction == .signInSourceApp
            || failure.recoveryAction == .waitForNextRefresh
            || failure.recoveryAction == .allowAccessInSystemSettings {
            Text(actionKey)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: QuotaDisplayFormatter.name(for: quota))
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(2)

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 0) {
                    if let remainingPercentage {
                        Text(verbatim: QuotaDisplayFormatter.percentageValue(remainingPercentage))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(gaugeTint)
                    } else {
                        Text("field.not_provided")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("quota.remaining")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("field.percentage")
                .accessibilityLabel(Text("quota.percentage.remaining"))
                .accessibilityValue(
                    accessibilityValue(
                        remainingPercentage.map { QuotaDisplayFormatter.percentageValue($0) }
                    )
                )
            }

            percentageGauge

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                valueRow(identifier: "used", label: "quota.used", value: QuotaDisplayFormatter.value(quota.used))
                valueRow(
                    identifier: "remaining",
                    label: "quota.remaining",
                    value: QuotaDisplayFormatter.value(quota.remaining)
                )
                valueRow(
                    identifier: "reset",
                    label: "quota.reset",
                    value: quota.resetsAt.map { QuotaDisplayFormatter.resetTime($0, relativeTo: now) }
                )
                valueRow(
                    identifier: "refreshed",
                    label: "quota.refreshed",
                    value: QuotaDisplayFormatter.relativeTime(refreshedAt, relativeTo: now)
                )
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.primary.opacity(0.07), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quota.\(quota.id.rawValue)")
    }

    private var percentageGauge: some View {
        Capsule()
            .fill(.secondary.opacity(0.16))
            .frame(height: 10)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(gaugeTint)
                    .scaleEffect(x: gaugeFill, y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .accessibilityHidden(true)
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
                    .fontWeight(.medium)
                    .monospacedDigit()
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

    private var remainingPercentage: Decimal? {
        QuotaDisplayFormatter.remainingPercentage(quota.percentage)
    }

    private var gaugeFill: Double {
        guard let remainingPercentage else { return 0 }
        return NSDecimalNumber(decimal: remainingPercentage / 100).doubleValue
    }

    private var gaugeTint: Color {
        guard let remainingPercentage else { return .secondary.opacity(0.3) }
        let value = NSDecimalNumber(decimal: remainingPercentage).doubleValue
        if value > 50 {
            return Color(nsColor: .systemGreen)
        }
        if value >= 20 {
            return Color(nsColor: .systemYellow)
        }
        return Color(nsColor: .systemRed)
    }

    private func accessibilityValue(_ value: String?) -> Text {
        if let value {
            return Text(verbatim: value)
        }
        return Text("field.not_provided")
    }
}

enum QuotaDisplayFormatter {
    static func name(for quota: RawQuotaItem, locale: Locale = .current) -> String {
        var components = quota.originalName
            .split(separator: ".", omittingEmptySubsequences: true)
            .map { readableName(String($0), locale: locale) }

        if let window = quota.sourceFields["window"] {
            let readableWindow = readableName(window, locale: locale)
            if !components.contains(where: { $0.localizedCaseInsensitiveContains(readableWindow) }) {
                components.append(readableWindow)
            }
        }

        return components.joined(separator: " · ")
    }

    static func value(_ sourceValue: SourceValue?, locale: Locale = .current) -> String? {
        guard let sourceValue else { return nil }
        let unit = sourceValue.unit?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch unit?.lowercased() {
        case "%":
            return "\(number(sourceValue.value, locale: locale, maximumFractionDigits: 2))%"
        case "cents":
            return currency(sourceValue.value / 100, code: "USD", locale: locale)
        case "usd":
            return currency(sourceValue.value, code: "USD", locale: locale)
        case .some(let unit) where !unit.isEmpty:
            return "\(number(sourceValue.value, locale: locale, maximumFractionDigits: 2)) \(unit)"
        default:
            return number(sourceValue.value, locale: locale, maximumFractionDigits: 2)
        }
    }

    static func percentage(_ percentage: SourcePercentage, locale: Locale = .current) -> String? {
        guard let value = percentage.value else { return nil }
        return "\(number(value, locale: locale, maximumFractionDigits: 2))%"
    }
    static func remainingPercentage(_ percentage: SourcePercentage) -> Decimal? {
        guard let value = percentage.value else { return nil }
        let remaining = percentage.meaning == .used ? Decimal(100) - value : value
        return min(max(remaining, 0), 100)
    }

    static func percentageValue(_ value: Decimal, locale: Locale = .current) -> String {
        "\(number(value, locale: locale, maximumFractionDigits: 2))%"
    }

    static func resetTime(_ date: Date, relativeTo now: Date, locale: Locale = .current) -> String {
        "\(relativeTime(date, relativeTo: now, locale: locale)) · \(absoluteTime(date, locale: locale))"
    }

    static func relativeTime(_ date: Date, relativeTo now: Date, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func absoluteTime(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func readableName(_ raw: String, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let korean = language == "ko"
        let knownNames: [String: (en: String, ko: String)] = [
            "session": ("Session", "세션"),
            "weekly_all": ("Weekly", "주간"),
            "weekly_scoped": ("Weekly scoped", "주간 범위"),
            "five_hour": ("5-hour", "5시간"),
            "seven_day": ("7-day", "7일"),
            "5h": ("5-hour", "5시간"),
            "weekly": ("Weekly", "주간"),
            "monthly": ("Monthly", "월간"),
            "credits": ("Credits", "크레딧"),
            "rateLimitResetCredits": ("Rate-limit reset credits", "한도 리셋 크레딧"),
            "individualUsage": ("Individual usage", "개인 사용량"),
            "teamUsage": ("Team usage", "팀 사용량"),
            "plan": ("Plan", "플랜"),
            "agent-plan": ("Agent plan", "Agent 플랜"),
            "coding-plan": ("Coding plan", "코딩 플랜"),
            "agent-plan-team": ("Team agent plan", "팀 Agent 플랜"),
            "coding-plan-team": ("Team coding plan", "팀 코딩 플랜"),
            "personal": ("Personal", "개인"),
            "team": ("Team", "팀"),
            "onDemand": ("On-demand", "온디맨드"),
            "overall": ("Overall", "전체"),
            "pooled": ("Pooled", "공동"),
            "breakdown": ("Breakdown", "세부 내역"),
            "included": ("Included", "포함"),
            "bonus": ("Bonus", "보너스"),
            "total": ("Total", "합계"),
            "autoPercentUsed": ("Auto usage", "자동 사용량"),
            "apiPercentUsed": ("API usage", "API 사용량"),
            "totalPercentUsed": ("Total usage", "전체 사용량"),
            "primary": ("Primary", "기본"),
            "secondary": ("Secondary", "보조"),
        ]
        if let knownName = knownNames[raw] {
            return korean ? knownName.ko : knownName.en
        }

        let spaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spaced.isEmpty else { return raw }
        return spaced.prefix(1).uppercased(with: locale) + spaced.dropFirst()
    }

    private static func number(
        _ value: Decimal,
        locale: Locale,
        maximumFractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
    }

    private static func currency(_ value: Decimal, code: String, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? "\(code) \(NSDecimalNumber(decimal: value).stringValue)"
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
    case blue
    case green
    case orange
    case red

    var foreground: Color {
        switch self {
        case .secondary: .secondary
        case .blue: .blue
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
