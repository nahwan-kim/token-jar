import AppKit
import SwiftUI
import TokenTankDomain

struct MenuBarLabelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.preferences.visibleProviders.isEmpty {
                Image(systemName: "chart.bar.fill")
            } else if let image = MenuBarSummaryRenderer.image(for: model) {
                Image(nsImage: image)
                    .renderingMode(.template)
            } else {
                // MenuBarExtra renders only the first Text in a nested label tree.
                Text(verbatim: model.menuBarLabelText())
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
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
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)

                Image(systemName: overview.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(overview.tint, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                    }
            }
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
                    VStack(alignment: .leading, spacing: 8) {
                        let quotas = QuotaDisplayFormatter.displayedQuotas(
                            snapshot.quotas,
                            providerID: providerID
                        )
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                                count: quotas.count > 1 ? 2 : 1
                            ),
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(quotas) { quota in
                                QuotaValueView(
                                    quota: quota,
                                    refreshedAt: snapshot.refreshedAt,
                                    now: now,
                                    trailingChip: QuotaDisplayFormatter.claudeFableChip(
                                        for: quota,
                                        in: snapshot.quotas
                                    )
                                )
                            }
                        }
                        if providerID == .codex,
                           let resetLine = QuotaDisplayFormatter.codexResetCreditsLine(
                            snapshot.quotas,
                            now: now
                           ) {
                            Text(verbatim: resetLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("quota.rateLimitResetCredits")
                        }
                    }
                }

            }
        }
        .padding(14)
        .background(brandTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(brandTint.opacity(0.34), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider.\(providerID.rawValue)")
    }

    private var providerHeader: some View {
        HStack(spacing: 10) {
            ProviderBrandIcon(
                providerID: providerID,
                pointSize: 18,
                color: BrandIcon.hasColorVariant(providerID)
            )
            .frame(width: 30, height: 30)
            .background(brandTint.opacity(0.18), in: Circle())
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: providerID.displayName)
                    .font(.headline)
                if let email = state.snapshot?.accountEmail {
                    Text(verbatim: email)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(email)
                        .accessibilityIdentifier("provider.\(providerID.rawValue).account")
                }
                if let planName = QuotaDisplayFormatter.planName(
                    for: providerID,
                    quotas: state.snapshot?.quotas ?? []
                ) {
                    Text(verbatim: planName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("provider.\(providerID.rawValue).plan")
                }
            }

            Spacer()

            Text(presentation.title)
                .badgeStyle(presentation.badgeColor)
                .accessibilityIdentifier(presentation.identifier)
        }
    }

    private var brandTint: Color { BrandIcon.tint(for: providerID) }

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
    var trailingChip: QuotaDisplayFormatter.LimitChip? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: QuotaDisplayFormatter.name(for: quota))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if let reset = quota.resetsAt {
                    Text(verbatim: QuotaDisplayFormatter.relativeTime(reset, relativeTo: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("field.reset")
                }

                Spacer(minLength: 6)

                if let remainingPercentage {
                    Text(verbatim: QuotaDisplayFormatter.percentageValue(remainingPercentage))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(gaugeTint)
                } else if let remaining = QuotaDisplayFormatter.value(quota.remaining) {
                    Text(verbatim: remaining)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                } else {
                    Text("field.not_provided")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("field.percentage")
            .accessibilityLabel(Text("quota.percentage.remaining"))
            .accessibilityValue(accessibilityValue(headlineValue))

            if remainingPercentage != nil {
                percentageGauge
            }
            if let trailingChip {
                HStack(spacing: 6) {
                    Text(verbatim: trailingChip.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(chipTint(for: trailingChip.remaining).opacity(0.16), in: Capsule())
                        .foregroundStyle(chipTint(for: trailingChip.remaining))
                    Text(verbatim: QuotaDisplayFormatter.percentageValue(trailingChip.remaining))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(chipTint(for: trailingChip.remaining))
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("quota.chip.\(trailingChip.id)")
                .accessibilityLabel(Text(verbatim: trailingChip.title))
                .accessibilityValue(Text(verbatim: QuotaDisplayFormatter.percentageValue(trailingChip.remaining)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quota.\(quota.id.rawValue)")
    }

    private var percentageGauge: some View {
        Capsule()
            .fill(.secondary.opacity(0.16))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(gaugeTint)
                    .scaleEffect(x: gaugeFill, y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }

    private var remainingPercentage: Decimal? {
        QuotaDisplayFormatter.remainingPercentage(quota.percentage)
    }

    private var headlineValue: String? {
        if let remainingPercentage {
            return QuotaDisplayFormatter.percentageValue(remainingPercentage)
        }
        return QuotaDisplayFormatter.value(quota.remaining)
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

    private func chipTint(for remaining: Decimal) -> Color {
        let value = NSDecimalNumber(decimal: remaining).doubleValue
        if value > 50 { return Color(nsColor: .systemGreen) }
        if value >= 20 { return Color(nsColor: .systemYellow) }
        return Color(nsColor: .systemRed)
    }
}

enum QuotaDisplayFormatter {
    static func displayedQuotas(
        _ quotas: [RawQuotaItem],
        providerID: ProviderID
    ) -> [RawQuotaItem] {
        let filtered: [RawQuotaItem]
        switch providerID {
        case .codex:
            filtered = quotas.filter(isCodexWeeklyQuota)
        case .claude:
            filtered = quotas.filter(isClaudePopupQuota)
        case .grok:
            filtered = quotas
        case .cursor:
            filtered = quotas.filter(isCursorPopupQuota)
        case .doubao:
            filtered = quotas.filter(isDoubaoPopupQuota)
        }
        return filtered.isEmpty ? quotas : filtered
    }

    static func planName(
        for providerID: ProviderID,
        quotas: [RawQuotaItem],
        locale: Locale = .current
    ) -> String? {
        let displayed = displayedQuotas(quotas, providerID: providerID)
        let sample = displayed.first ?? quotas.first
        switch providerID {
        case .cursor:
            guard let membership = quotas.lazy.compactMap({ $0.sourceFields["membershipType"] }).first,
                  !membership.isEmpty
            else { return nil }
            return readableName(membership, locale: locale)
        case .doubao:
            guard let sample else { return nil }
            let rawName = sample.originalName
            let base: String
            if rawName.hasSuffix(".weekly") {
                base = String(rawName.dropLast(7))
            } else if rawName.hasSuffix(".5h") {
                base = String(rawName.dropLast(3))
            } else if rawName.hasSuffix(".monthly") {
                base = String(rawName.dropLast(8))
            } else {
                base = sample.sourceFields["path"] ?? rawName
            }
            var parts = [readableNamePath(base, locale: locale)]
            if let tier = sample.sourceFields["tier"], !tier.isEmpty {
                parts.append(readableName(tier, locale: locale))
            }
            return parts.joined(separator: " · ")
        case .codex:
            guard let sample else { return nil }
            let limitName = sample.sourceFields["limitName"] ?? sample.originalName
            let normalized = limitName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.caseInsensitiveCompare("Codex") != .orderedSame else {
                return nil
            }
            return readableName(normalized, locale: locale)
        case .claude, .grok:
            return nil
        }
    }

    struct LimitChip: Equatable {
        let id: String
        let title: String
        let remaining: Decimal
    }

    static func claudeFableChip(
        for quota: RawQuotaItem,
        in quotas: [RawQuotaItem],
        locale: Locale = .current
    ) -> LimitChip? {
        guard quota.originalName == "weekly_all" || quota.originalName == "seven_day" else {
            return nil
        }
        guard let fable = quotas.first(where: { $0.originalName.hasPrefix("weekly_scoped.") }),
              let remaining = remainingPercentage(fable.percentage)
        else {
            return nil
        }
        let title = fable.originalName.split(separator: ".").last.map(String.init) ?? "Fable"
        return LimitChip(id: fable.id.rawValue, title: title, remaining: remaining)
    }

    static func codexResetCreditsLine(
        _ quotas: [RawQuotaItem],
        now: Date,
        locale: Locale = .current
    ) -> String? {
        guard let credits = quotas.first(where: { $0.id.rawValue == "rateLimitResetCredits" }) else {
            return nil
        }
        let remaining = credits.remaining.map { number($0.value, locale: locale, maximumFractionDigits: 0) }
            ?? "—"
        let korean = (locale.language.languageCode?.identifier ?? "en") == "ko"
        let expiry = quotas.compactMap { quota -> Date? in
            guard quota.id.rawValue.hasPrefix("rateLimitResetCredit.") else { return nil }
            return quota.resetsAt ?? dateFromSourceFields(quota.sourceFields)
        }.min()
        if let expiry {
            let when = relativeTime(expiry, relativeTo: now, locale: locale)
            return korean
                ? "리셋권 \(remaining)개 · \(when)"
                : "\(remaining) reset credits · \(when)"
        }
        return korean
            ? "리셋권 \(remaining)개"
            : "\(remaining) reset credits"
    }

    static func name(for quota: RawQuotaItem, locale: Locale = .current) -> String {
        if let compactName = compactName(for: quota, locale: locale) {
            return compactName
        }
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

    private static func isCodexWeeklyQuota(_ quota: RawQuotaItem) -> Bool {
        let id = quota.id.rawValue
        if id.hasPrefix("rateLimitReset") { return false }
        let limitID = quota.sourceFields["limitId"] ?? id.split(separator: ".").first.map(String.init)
        guard limitID == "codex" || limitID == "rateLimits" else { return false }
        return quota.sourceFields["window"] == "primary"
    }

    private static func isClaudePopupQuota(_ quota: RawQuotaItem) -> Bool {
        switch quota.originalName {
        case "session", "weekly_all", "five_hour", "seven_day":
            return true
        default:
            return false
        }
    }

    private static func isCursorPopupQuota(_ quota: RawQuotaItem) -> Bool {
        switch quota.originalName {
        case "individualUsage.plan.autoPercentUsed", "individualUsage.plan.apiPercentUsed":
            return true
        default:
            return false
        }
    }

    private static func isDoubaoPopupQuota(_ quota: RawQuotaItem) -> Bool {
        let name = quota.originalName
        return name == "5h"
            || name == "weekly"
            || name.hasSuffix(".5h")
            || name.hasSuffix(".weekly")
    }

    private static func compactName(for quota: RawQuotaItem, locale: Locale) -> String? {
        let korean = (locale.language.languageCode?.identifier ?? "en") == "ko"
        if isCodexWeeklyQuota(quota) {
            return korean ? "주간 한도" : "Weekly limit"
        }
        switch quota.originalName {
        case "session", "five_hour", "5h":
            return korean ? "5시간 한도" : "5-hour limit"
        case "weekly_all", "seven_day", "weekly", "credits":
            return korean ? "주간 한도" : "Weekly limit"
        case "individualUsage.plan.autoPercentUsed":
            return korean ? "Cursor 모델" : "Cursor Models"
        case "individualUsage.plan.apiPercentUsed":
            return korean ? "기타 모델" : "Other Models"
        default:
            break
        }
        if quota.originalName.hasSuffix(".5h") {
            let prefix = String(quota.originalName.dropLast(3))
            return "\(readableNamePath(prefix, locale: locale)) · \(korean ? "5시간" : "5-hour")"
        }
        if quota.originalName.hasSuffix(".weekly") {
            let prefix = String(quota.originalName.dropLast(7))
            return "\(readableNamePath(prefix, locale: locale)) · \(korean ? "주간" : "Weekly")"
        }
        return nil
    }

    private static func readableNamePath(_ raw: String, locale: Locale) -> String {
        raw.split(separator: ".", omittingEmptySubsequences: true)
            .map { readableName(String($0), locale: locale) }
            .joined(separator: " · ")
    }

    private static func dateFromSourceFields(_ fields: [String: String]) -> Date? {
        for key in ["expiresAt", "expires_at", "resetsAt", "resetAt", "reset_at"] {
            guard let raw = fields[key] else { continue }
            if let date = ISO8601DateFormatter().date(from: raw) { return date }
            if let decimal = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) {
                let seconds = NSDecimalNumber(decimal: decimal).doubleValue
                if seconds > 0 {
                    return Date(
                        timeIntervalSince1970: abs(seconds) > 100_000_000_000 ? seconds / 1_000 : seconds
                    )
                }
            }
        }
        return nil
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
            "rateLimitResetCredits": ("Reset credits", "리셋권"),
            "individualUsage": ("Individual usage", "개인 사용량"),
            "teamUsage": ("Team usage", "팀 사용량"),
            "plan": ("Plan", "플랜"),
            "agent-plan": ("Agent plan", "Agent 플랜"),
            "coding-plan": ("Coding plan", "코딩 플랜"),
            "agent-plan-team": ("Team agent plan", "팀 Agent 플랜"),
            "coding-plan-team": ("Team coding plan", "팀 코딩 플랜"),
            "personal": ("Personal", "개인"),
            "pro": ("Pro", "Pro"),
            "pro_plus": ("Pro+", "Pro+"),
            "pro-plus": ("Pro+", "Pro+"),
            "business": ("Business", "Business"),
            "ultra": ("Ultra", "Ultra"),
            "free": ("Free", "Free"),
            "hobby": ("Hobby", "Hobby"),
            "medium": ("Medium", "Medium"),
            "lite": ("Lite", "Lite"),
            "plus": ("Plus", "Plus"),
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
                                Label {
                                    Text(verbatim: preference.providerID.displayName)
                                } icon: {
                                    ProviderBrandIcon(
                                        providerID: preference.providerID,
                                        pointSize: 14,
                                        color: BrandIcon.hasColorVariant(preference.providerID)
                                    )
                                }
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
