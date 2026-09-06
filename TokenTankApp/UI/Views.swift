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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text(verbatim: model.menuBarLabelText()))
    }

    private var accessibilityLabel: Text {
        guard !model.preferences.visibleProviders.isEmpty else {
            return Text("menu.summary.empty")
        }
        return Text(verbatim: model.menuBarLabelText())
    }
}

private struct DetailWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleView {
        TitleView()
    }

    func updateNSView(_ nsView: TitleView, context: Context) {
        nsView.title = title
    }

    final class TitleView: NSView {
        var title = "" {
            didSet { window?.title = title }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.title = title
        }
    }
}

struct DetailPopoverView: View {
    @ObservedObject var model: AppModel
    var isStandaloneWindow = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            if case let .available(version, url) = model.updateStatus {
                UpdateAvailableBanner(version: version, releaseURL: url)
            }

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
        .frame(
            minWidth: 480, maxWidth: isStandaloneWindow ? .infinity : 480,
            minHeight: 640, maxHeight: isStandaloneWindow ? .infinity : 640
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            if isStandaloneWindow {
                DetailWindowTitle(title: model.language.appName)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
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
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                Text("detail.title")
                    .font(.headline)
                StatusLED(title: overview.title, tint: overview.tint)
                    .accessibilityIdentifier("detail.overall-status")
            }

            Spacer()

            if !isStandaloneWindow {
                toolbarButton("action.open_window", symbol: "arrow.up.forward.square", identifier: "action.open-window") {
                    openWindow(id: "detail")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .help(Text("action.open_window"))
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
                tint: .blue
            )
        }

        var hasStale = false
        var hasRefreshing = false
        var hasUnavailable = false
        for providerID in ProviderID.allCases {
            if providerID == .codex {
                let accounts = model.codexAccounts()
                if accounts.contains(where: { $0.failure?.kind.requiresAuthenticationAction == true }) {
                    return StatusPresentation(title: "state.authentication_required", tint: .red)
                }
                hasStale = hasStale || accounts.contains(where: \.isStale)
            }
            switch model.states[providerID] ?? .neverLoaded {
            case .authenticationActionRequired:
                return StatusPresentation(
                    title: "state.authentication_required",
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
                tint: .orange
            )
        }
        if hasRefreshing {
            return StatusPresentation(
                title: "state.refreshing",
                tint: .blue
            )
        }
        if hasUnavailable {
            return StatusPresentation(
                title: "state.unavailable",
                tint: .secondary
            )
        }
        return StatusPresentation(
            title: "state.fresh",
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
private struct UpdateAvailableBanner: View {
    let version: String
    let releaseURL: URL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("settings.updates.status.available")
                    Text(verbatim: version)
                        .monospacedDigit()
                }
                .font(.callout.weight(.semibold))

                Text("settings.updates.manual_install_short")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link("settings.updates.release", destination: releaseURL)
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("updates.available.release")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("updates.available.banner")
    }
}

private struct StatusPresentation {
    let title: LocalizedStringKey
    let tint: Color
}

private struct StatusLED: View {
    let title: LocalizedStringKey
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
            .shadow(color: tint.opacity(0.5), radius: 2)
            .padding(3)
            .background(tint.opacity(0.12), in: Circle())
            .help(Text(title))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityAddTraits(.isImage)
    }
}

struct ProviderDetailView: View {
    @Environment(\.locale) private var locale
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
                if providerID == .codex, !snapshot.accounts.isEmpty {
                    codexAccountContent(snapshot)
                } else {
                    snapshotContent(snapshot)
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

    @ViewBuilder
    private func snapshotContent(_ snapshot: ProviderSnapshot) -> some View {
        if providerID == .codex {
            CodexQuotaColumns(quotas: snapshot.quotas, refreshedAt: snapshot.refreshedAt, now: now)
        } else if snapshot.quotas.isEmpty {
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
                            scopedLimit: QuotaDisplayFormatter.claudeFableLimit(
                                for: quota,
                                in: snapshot.quotas
                            )
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func codexAccountContent(_ snapshot: ProviderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CodexAccountPresentation.accounts(for: state)) { account in
                CodexAccountDetailView(
                    account: account,
                    fallbackRefreshedAt: snapshot.refreshedAt,
                    now: now,
                    retry: retry,
                    configure: configure
                )
            }
        }
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: providerID.displayName)
                        .font(.headline)
                        .fixedSize()
                        .accessibilityIdentifier("provider.\(providerID.rawValue).name")
                    if !hasAccountCards,
                       let planName = QuotaDisplayFormatter.planName(
                        for: providerID,
                        quotas: state.snapshot?.quotas ?? [],
                        locale: locale
                       ) {
                        Text(verbatim: planName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(planName)
                            .accessibilityIdentifier("provider.\(providerID.rawValue).plan")
                    }
                }
                if !hasAccountCards, let email = state.snapshot?.accountEmail {
                    Text(verbatim: email)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(email)
                        .accessibilityIdentifier("provider.\(providerID.rawValue).account")
                }
            }

            Spacer()

            FreshnessText(refreshedAt: state.snapshot?.refreshedAt, now: now)
                .accessibilityIdentifier("provider.\(providerID.rawValue).refreshed")
            StatusLED(title: presentation.title, tint: presentation.tint)
                .accessibilityIdentifier(presentation.identifier)
        }
    }

    private var brandTint: Color { BrandIcon.tint(for: providerID) }
    private var hasAccountCards: Bool {
        providerID == .codex && !(state.snapshot?.accounts.isEmpty ?? true)
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .neverLoaded, .refreshing, .fresh:
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
                tint: .secondary,
                identifier: "state.unavailable"
            )
        case .refreshing:
            ProviderStatusPresentation(
                title: "state.refreshing",
                tint: .blue,
                identifier: "state.refreshing"
            )
        case let .fresh(snapshot):
            ProviderStatusPresentation(
                title: snapshot.accounts.contains(where: { $0.failure?.kind.requiresAuthenticationAction == true })
                    ? "state.authentication_required" : (snapshot.hasStaleAccounts ? "state.stale" : "state.fresh"),
                tint: snapshot.accounts.contains(where: { $0.failure?.kind.requiresAuthenticationAction == true })
                    ? .red : (snapshot.hasStaleAccounts ? .orange : .green),
                identifier: snapshot.accounts.contains(where: { $0.failure?.kind.requiresAuthenticationAction == true })
                    ? "state.authentication-required" : (snapshot.hasStaleAccounts ? "state.stale" : "state.fresh")
            )
        case .stale:
            ProviderStatusPresentation(
                title: "state.stale",
                tint: .orange,
                identifier: "state.stale"
            )
        case .authenticationActionRequired:
            ProviderStatusPresentation(
                title: "state.authentication_required",
                tint: .red,
                identifier: "state.authentication-required"
            )
        }
    }
}

private struct FreshnessText: View {
    @Environment(\.locale) private var locale
    let refreshedAt: Date?
    let now: Date

    var body: some View {
        Text(verbatim: QuotaDisplayFormatter.refreshAge(refreshedAt, now: now, locale: locale))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(refreshedAt.map { QuotaDisplayFormatter.timestamp($0, locale: locale) } ?? "—")
    }
}

private struct CodexAccountDetailView: View {
    @Environment(\.locale) private var locale
    let account: ProviderAccountSnapshot
    let fallbackRefreshedAt: Date
    let now: Date
    let retry: () -> Void
    let configure: () -> Void

    private var accessibilityID: String { "provider.codex.account.\(account.sourceID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: CodexAccountPresentation.identity(for: account, locale: locale))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(CodexAccountPresentation.identity(for: account, locale: locale))
                    .accessibilityIdentifier("\(accessibilityID).email")
                Spacer(minLength: 4)
                FreshnessText(refreshedAt: account.refreshedAt, now: now)
                    .accessibilityIdentifier("\(accessibilityID).refreshed")
                StatusLED(title: status.title, tint: status.tint)
                    .accessibilityIdentifier("\(accessibilityID).status")
            }
            if let failure = account.failure {
                FailureView(failure: failure, retry: retry, configure: configure, identifierPrefix: accessibilityID)
            }
            CodexQuotaColumns(quotas: account.quotas,
                              refreshedAt: account.refreshedAt ?? fallbackRefreshedAt,
                              now: now, identifierPrefix: accessibilityID)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityID)
    }

    private var status: StatusPresentation {
        if let failure = account.failure {
            return failure.kind.requiresAuthenticationAction
                ? StatusPresentation(title: "state.authentication_required", tint: .red)
                : StatusPresentation(title: "state.stale", tint: .orange)
        }
        return account.hasData
            ? StatusPresentation(title: "state.fresh", tint: .green)
            : StatusPresentation(title: "state.unavailable", tint: .secondary)
    }
}

private struct CodexQuotaColumns: View {
    @Environment(\.locale) private var locale
    let quotas: [RawQuotaItem]
    let refreshedAt: Date
    let now: Date
    var identifierPrefix: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let weekly = QuotaDisplayFormatter.defaultCodexQuota(quotas) {
                    QuotaValueView(quota: weekly, refreshedAt: refreshedAt, now: now,
                                   identifierPrefix: identifierPrefix)
                } else {
                    HStack {
                        Text("codex.weekly")
                        Spacer()
                        Text(verbatim: "—")
                    }
                    .font(.caption)
                    .padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                let tickets = QuotaDisplayFormatter.codexResetCredits(quotas, now: now)
                HStack {
                    Text("codex.tickets")
                    Spacer(minLength: 4)
                    Text(verbatim: tickets.count.map {
                        QuotaDisplayFormatter.number($0, locale: locale, maximumFractionDigits: 0)
                    } ?? "—")
                    .monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                Text(verbatim: QuotaDisplayFormatter.ticketExpiry(tickets.expiresAt, locale: locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(tickets.expiresAt.map { QuotaDisplayFormatter.timestamp($0, locale: locale) } ?? "—")
                    .accessibilityIdentifier("\(identifierPrefix ?? "provider.codex").ticket-expiry")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifierPrefix ?? "provider.codex").reset-credits")
        }
    }
}
private struct ProviderStatusPresentation {
    let title: LocalizedStringKey
    let tint: Color
    let identifier: String
}

private struct FailureView: View {
    let failure: CollectionError
    let retry: () -> Void
    let configure: () -> Void
    var identifierPrefix: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(errorKey)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier(identifier("error.\(failure.kind.rawValue)"))
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
                .accessibilityIdentifier(identifier("action.\(failure.recoveryAction.rawValue)"))
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
            .accessibilityIdentifier(identifier("action.\(failure.recoveryAction.rawValue)"))
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
    private func identifier(_ suffix: String) -> String {
        identifierPrefix.map { "\($0).\(suffix)" } ?? suffix
    }
}

struct QuotaValueView: View {
    @Environment(\.locale) private var locale
    let quota: RawQuotaItem
    let refreshedAt: Date
    let now: Date
    var scopedLimit: QuotaDisplayFormatter.ScopedLimit? = nil
    var identifierPrefix: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: QuotaDisplayFormatter.name(for: quota, locale: locale))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .help(QuotaDisplayFormatter.name(for: quota, locale: locale))

                if let reset = quota.resetsAt {
                    Text(verbatim: QuotaDisplayFormatter.resetCountdown(reset, relativeTo: now, locale: locale))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("field.reset")
                }

                Spacer(minLength: 6)

                if let remainingPercentage {
                    Text(verbatim: QuotaDisplayFormatter.percentageValue(remainingPercentage, locale: locale))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(gaugeTint)
                } else if let remaining = QuotaDisplayFormatter.value(quota.remaining, locale: locale) {
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
            .accessibilityLabel(Text(verbatim: QuotaDisplayFormatter.name(for: quota, locale: locale) + ", ") + Text("quota.percentage.remaining"))
            .accessibilityValue(accessibilityValue(headlineValue))

            if let remainingPercentage {
                percentageGauge(for: remainingPercentage)
            }
            if let scopedLimit {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: scopedLimit.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(verbatim: QuotaDisplayFormatter.percentageValue(scopedLimit.remaining, locale: locale))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(percentageTint(for: scopedLimit.remaining))
                    }
                    percentageGauge(for: scopedLimit.remaining)
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("quota.scoped.\(scopedLimit.id)")
                .accessibilityLabel(Text(verbatim: "\(scopedLimit.title), ") + Text("quota.percentage.remaining"))
                .accessibilityValue(Text(verbatim: QuotaDisplayFormatter.percentageValue(scopedLimit.remaining, locale: locale)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifierPrefix.map { "\($0).quota.\(quota.id.rawValue)" } ?? "quota.\(quota.id.rawValue)")
    }

    private func percentageGauge(for remaining: Decimal) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.16))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(percentageTint(for: remaining))
                    .scaleEffect(
                        x: min(1, max(0, NSDecimalNumber(decimal: remaining / 100).doubleValue)),
                        y: 1,
                        anchor: .leading
                    )
            }
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }

    private var remainingPercentage: Decimal? {
        QuotaDisplayFormatter.remainingPercentage(quota.percentage)
    }

    private var headlineValue: String? {
        if let remainingPercentage {
            return QuotaDisplayFormatter.percentageValue(remainingPercentage, locale: locale)
        }
        return QuotaDisplayFormatter.value(quota.remaining, locale: locale)
    }


    private var gaugeTint: Color {
        guard let remainingPercentage else { return .secondary.opacity(0.3) }
        return percentageTint(for: remainingPercentage)
    }

    private func accessibilityValue(_ value: String?) -> Text {
        let text = value.map { Text(verbatim: $0) } ?? Text("field.not_provided")
        guard let reset = quota.resetsAt else { return text }
        return text + Text(verbatim: ", ") + Text("quota.reset")
            + Text(verbatim: " " + QuotaDisplayFormatter.resetCountdown(reset, relativeTo: now, locale: locale))
    }

    private func percentageTint(for remaining: Decimal) -> Color {
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
            return defaultCodexQuota(quotas).map { [$0] } ?? []
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
    static func defaultCodexQuota(_ quotas: [RawQuotaItem]) -> RawQuotaItem? {
        quotas.first { isCodexWindowQuota($0) && !isCodexSparkQuota($0) && codexWindowMinutes($0) == 10_080 }
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

    struct ScopedLimit: Equatable {
        let id: String
        let title: String
        let remaining: Decimal
    }

    static func claudeFableLimit(
        for quota: RawQuotaItem,
        in quotas: [RawQuotaItem],
        locale: Locale = .current
    ) -> ScopedLimit? {
        guard quota.originalName == "weekly_all" || quota.originalName == "seven_day" else {
            return nil
        }
        guard let fable = quotas.first(where: { $0.originalName.hasPrefix("weekly_scoped.") }),
              let remaining = remainingPercentage(fable.percentage)
        else {
            return nil
        }
        let title = fable.originalName.split(separator: ".").last.map(String.init) ?? "Fable"
        return ScopedLimit(id: fable.id.rawValue, title: title, remaining: remaining)
    }

    struct ResetCredits: Equatable {
        let count: Decimal?
        let expiresAt: Date?
    }

    static func codexResetCredits(_ quotas: [RawQuotaItem], now: Date) -> ResetCredits {
        let count = quotas.first { $0.id.rawValue == "rateLimitResetCredits" }?.remaining?.value
        let expiry = quotas.compactMap { quota -> Date? in
            guard quota.id.rawValue.hasPrefix("rateLimitResetCredit."),
                  let expiry = quota.resetsAt ?? dateFromSourceFields(quota.sourceFields),
                  expiry > now else { return nil }
            return expiry
        }.min()
        return ResetCredits(count: count, expiresAt: count == 0 ? nil : expiry)
    }

    static func ticketExpiry(_ date: Date?, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMdHm")
        return formatter.string(from: date)
    }

    static func refreshAge(_ date: Date?, now: Date, locale: Locale = .current) -> String {
        guard let date else { return "—" }
        let korean = locale.language.languageCode?.identifier == "ko"
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        guard minutes > 0 else { return korean ? "방금" : "now" }
        return korean ? "\(minutes)분 전" : "\(minutes)m ago"
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

    static func timestamp(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    static func resetCountdown(_ date: Date, relativeTo now: Date, locale: Locale = .current) -> String {
        let korean = locale.language.languageCode?.identifier == "ko"
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return korean ? "리셋 대기 중" : "Reset pending" }
        guard seconds >= 3_600 else { return korean ? "1시간 미만" : "<1h" }
        let hours = Int(seconds / 3_600)
        let days = hours / 24
        let remainder = hours % 24
        if days > 0 {
            return korean ? "\(days)일 \(remainder)시간" : "\(days)d \(remainder)h"
        }
        return korean ? "\(hours)시간" : "\(hours)h"
    }

    private static func isCodexWindowQuota(_ quota: RawQuotaItem) -> Bool {
        let id = quota.id.rawValue
        if id.hasPrefix("rateLimitReset") { return false }
        let limitID = quota.sourceFields["limitId"] ?? id.split(separator: ".").first.map(String.init)
        let limitName = quota.sourceFields["limitName"] ?? quota.originalName
        let window = quota.sourceFields["window"]?.lowercased()
        guard window == "primary" || (window == "secondary" && codexWindowMinutes(quota) != nil) else { return false }
        let identity = "\(limitID ?? "") \(limitName)".lowercased()
        return limitID == "codex"
            || limitID == "rateLimits"
            || identity.contains("spark")
    }

    private static func codexWindowMinutes(_ quota: RawQuotaItem) -> Int? {
        quota.sourceFields["windowDurationMins"].flatMap(Int.init)
    }

    private static func isCodexSparkQuota(_ quota: RawQuotaItem) -> Bool {
        let limitID = quota.sourceFields["limitId"] ?? ""
        let limitName = quota.sourceFields["limitName"] ?? quota.originalName
        return "\(limitID) \(limitName)".localizedCaseInsensitiveContains("spark")
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
        if isCodexWindowQuota(quota) {
            let window: String
            switch codexWindowMinutes(quota) {
            case 10_080: window = korean ? "주간" : "Weekly"
            case 300: window = korean ? "5시간" : "5-hour"
            case let minutes?: window = korean ? "\(minutes)분" : "\(minutes)-minute"
            case nil: window = korean ? "사용량" : "Usage"
            }
            return window
        }
        switch quota.originalName {
        case "session", "five_hour", "5h":
            return korean ? "5시간" : "5-hour"
        case "weekly_all", "seven_day", "weekly", "credits":
            return korean ? "주간" : "Weekly"
        case "individualUsage.plan.autoPercentUsed":
            return korean ? "Cursor 모델" : "Cursor Models"
        case "individualUsage.plan.apiPercentUsed":
            return korean ? "기타 모델" : "Other Models"
        default:
            break
        }
        if quota.originalName.hasSuffix(".5h") {
            return korean ? "5시간" : "5-hour"
        }
        if quota.originalName.hasSuffix(".weekly") {
            return korean ? "주간" : "Weekly"
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

    static func number(
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
    @Environment(\.locale) private var locale

    var body: some View {
        TabView {
            providerPreferences
                .tabItem {
                    Label("settings.providers", systemImage: "list.bullet")
                        .accessibilityIdentifier("settings.providers.tab")
                }
            sourceSettings
                .tabItem {
                    Label("settings.sources", systemImage: "network")
                        .accessibilityIdentifier("settings.sources.tab")
                }
        }
        .frame(minWidth: 620, minHeight: 520)
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
            Section {
                Picker("settings.language", selection: $model.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.language.picker")
            }
            updateSettings
            Section("settings.summary") {
                ForEach(model.orderedPreferences) { preference in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Toggle(isOn: binding(for: preference, keyPath: \.isVisible)) {
                                Label {
                                    Text(verbatim: preference.providerID.displayName)
                                        .fontWeight(.medium)
                                } icon: {
                                    ProviderBrandIcon(
                                        providerID: preference.providerID,
                                        pointSize: 14,
                                        color: BrandIcon.hasColorVariant(preference.providerID)
                                    )
                                }
                            }
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("settings.visible.\(preference.providerID.rawValue)")

                            TextField(
                                "settings.abbreviation",
                                text: binding(for: preference, keyPath: \.abbreviation)
                            )
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 72)
                            .accessibilityLabel(Text("settings.abbreviation"))
                            .accessibilityIdentifier("settings.abbreviation.\(preference.providerID.rawValue)")
                            .help(Text("settings.abbreviation"))

                            HStack(spacing: 4) {
                                Button {
                                    model.move(preference.providerID, offset: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .disabled(model.isFirst(preference.providerID))
                                .accessibilityLabel(Text("settings.move_up"))
                                .accessibilityIdentifier("settings.move-up.\(preference.providerID.rawValue)")
                                .help(Text("settings.move_up"))
                                Button {
                                    model.move(preference.providerID, offset: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .disabled(model.isLast(preference.providerID))
                                .accessibilityLabel(Text("settings.move_down"))
                                .accessibilityIdentifier("settings.move-down.\(preference.providerID.rawValue)")
                                .help(Text("settings.move_down"))
                            }
                            .buttonStyle(.borderless)
                        }
                        .controlSize(.small)

                        if preference.providerID != .codex {
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
                                    Text(verbatim: QuotaDisplayFormatter.name(for: quota, locale: locale)).tag(Optional(quota.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("settings.quota.\(preference.providerID.rawValue)")
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
                                    .accessibilityIdentifier("action.choose-another.\(preference.providerID.rawValue)")
                                }
                                .accessibilityElement(children: .contain)
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.providers.content")
    }

    private var updateSettings: some View {
        Section("settings.updates") {
            Toggle(
                "settings.updates.automatic",
                isOn: $model.automaticallyChecksForUpdates
            )
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("settings.updates.automatic")

            Button("settings.updates.check_now") {
                model.checkForUpdates()
            }
            .controlSize(.small)
            .disabled(isCheckingForUpdates)
            .accessibilityIdentifier("settings.updates.check-now")

            updateStatusView

            Text("settings.updates.privacy")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.updates.privacy")

            Text("settings.updates.manual_install_warning")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.updates.manual-install-warning")
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch model.updateStatus {
        case .idle:
            updateStatusLabel("settings.updates.status.idle", symbol: "questionmark.circle", tint: .secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("settings.updates.status.checking")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.updates.status")
        case .upToDate:
            updateStatusLabel("settings.updates.status.up_to_date", symbol: "checkmark.circle", tint: .green)
        case let .available(version, url):
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .accessibilityHidden(true)
                    Text("settings.updates.status.available")
                    Text(verbatim: version)
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                Link("settings.updates.release", destination: url)
                    .font(.caption)
                    .accessibilityIdentifier("settings.updates.release")
            }
            .foregroundStyle(.blue)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.updates.status")
        case .failed:
            updateStatusLabel("settings.updates.status.failed", symbol: "exclamationmark.triangle", tint: .orange)
        }
    }

    private func updateStatusLabel(
        _ title: LocalizedStringKey,
        symbol: String,
        tint: Color
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .accessibilityIdentifier("settings.updates.status")
    }

    private var isCheckingForUpdates: Bool {
        if case .checking = model.updateStatus {
            return true
        }
        return false
    }

    private var sourceSettings: some View {
        Form {
            Text("settings.sources.explanation")
                .foregroundStyle(.secondary)
            Section {
                ForEach(ProviderID.allCases) { providerID in
                    if let source = model.sourceDescriptor(for: providerID) {
                        DisclosureGroup {
                            Text(sourceDetailKey(for: providerID))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            if let url = source.documentationURL {
                                Link("settings.source.documentation", destination: url)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: providerID.displayName)
                                    .fontWeight(.medium)
                                Text(verbatim: source.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("state.unavailable")
                    }
                }
            }
        }
        .formStyle(.grouped)
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
