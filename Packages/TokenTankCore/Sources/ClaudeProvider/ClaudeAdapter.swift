import Foundation
import TokenTankCore
import TokenTankDomain

public struct ClaudeAdapter: ProviderAdapter {
    public let id: ProviderID = .claude
    public let displayName: String = "Claude"
    public let defaultAbbreviation: String = "CLD"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "claude.oauth.usage",
            name: "Claude Code OAuth usage",
            kind: .localSession,
            credentialOwnership: .externalProvider,
            documentationURL: URL(string: "https://github.com/steipete/CodexBar/blob/main/docs/claude.md"),
            detail: "Claude Code OAuth session with Anthropic's OAuth usage endpoint. Token Jar uses the owner-managed session without copying credentials and fails closed when live usage is unavailable."
        )
    }

    /// Reset tickets change rarely; the supplemental request runs at most this often per account.
    public static let resetCreditsInterval: TimeInterval = 30 * 60

    private let memory = ClaudeAccountMemory()

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let accounts = try await context.claudeSession.accounts()
        guard !accounts.isEmpty else {
            throw CollectionError(
                kind: .externalSessionMissing,
                diagnosticCode: "claude.session.credentials-missing",
                recoveryAction: .signInSourceApp
            )
        }
        await memory.retain(sourceIDs: Set(accounts.map(\.sourceID)))

        var readings: [(account: ClaudeAccount, result: Result<ProviderAccountSnapshot, CollectionError>)] = []
        var seenTokens: Set<String> = []
        for account in accounts {
            do {
                if let snapshot = try await fetchAccount(account, context: context, seenTokens: &seenTokens) {
                    readings.append((account, .success(snapshot)))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CollectionError where error.kind == .cancelled {
                throw error
            } catch let error as CollectionError {
                readings.append((account, .failure(error)))
            }
        }

        if readings.count == 1 {
            let snapshot = try readings[0].result.get()
            return ProviderSnapshot(
                providerID: .claude,
                source: sourceDescriptor,
                quotas: snapshot.quotas,
                refreshedAt: snapshot.refreshedAt ?? Date(timeIntervalSince1970: 0),
                accountEmail: snapshot.accountEmail,
                accounts: [snapshot]
            )
        }
        guard readings.contains(where: { (try? $0.result.get()) != nil }) else {
            throw (readings.first.map { reading -> CollectionError in
                if case let .failure(error) = reading.result { return error }
                return claudeMalformedError("claude.oauth.accounts.empty")
            }) ?? claudeMalformedError("claude.oauth.accounts.empty")
        }
        let now = await context.clock.now()
        let snapshots = readings.map { reading -> ProviderAccountSnapshot in
            switch reading.result {
            case let .success(snapshot):
                return snapshot
            case let .failure(error):
                return ProviderAccountSnapshot(
                    sourceID: reading.account.sourceID,
                    quotas: [],
                    accountEmail: reading.account.email,
                    failure: error,
                    failedAt: now
                )
            }
        }
        return ProviderSnapshot(
            providerID: .claude,
            source: sourceDescriptor,
            accounts: snapshots,
            refreshedAt: snapshots.compactMap(\.refreshedAt).max() ?? now
        )
    }

    /// One account's usage. Returns `nil` when the account signs in with a token another
    /// account already used in this collection (the same login found in two places).
    private func fetchAccount(
        _ account: ClaudeAccount,
        context: CollectionContext,
        seenTokens: inout Set<String>
    ) async throws -> ProviderAccountSnapshot? {
        var repairAvailable = context.allowsClaudeRecovery
        var session = try await claudeSourceSession(
            account: account.sourceID,
            in: context,
            rejectedAccessToken: nil,
            repairAvailable: &repairAvailable
        )
        guard seenTokens.insert(session.accessToken).inserted else { return nil }
        var response = try await claudeResponse(
            path: "/api/oauth/usage",
            token: session.accessToken,
            timeout: 30,
            network: context.network
        )
        if response.statusCode == 401 {
            let rejectedToken = session.accessToken
            session = try await claudeSourceSession(
                account: account.sourceID,
                in: context,
                rejectedAccessToken: rejectedToken,
                repairAvailable: &repairAvailable
            )
            guard session.accessToken != rejectedToken else {
                throw CollectionError(
                    kind: .authenticationRejected,
                    diagnosticCode: "claude.oauth.authentication-rejected",
                    recoveryAction: .signInSourceApp
                )
            }
            seenTokens.insert(session.accessToken)
            response = try await claudeResponse(
                path: "/api/oauth/usage",
                token: session.accessToken,
                timeout: 30,
                network: context.network
            )
        }
        let validationNow = await context.clock.now()
        try claudeValidate(response, now: validationNow)
        let primaryQuotas = try Self.decodeQuotas(from: response.body)
        let refreshedAt = await context.clock.now()

        let tokenDigest = ClaudeAccountMemory.digest(session.accessToken)
        let profile: ClaudeProfile?
        if let cached = await memory.profile(for: account.sourceID, tokenDigest: tokenDigest) {
            profile = cached
        } else {
            profile = try await claudeProfile(token: session.accessToken, network: context.network)
            if let profile {
                await memory.storeProfile(profile, for: account.sourceID, tokenDigest: tokenDigest)
            }
        }

        let identity = account.accountUUID ?? profile?.email ?? account.email
        let resetCredits: [RawQuotaItem]
        if let cached = await memory.resetCredits(
            for: account.sourceID,
            identity: identity,
            now: refreshedAt,
            maximumAge: Self.resetCreditsInterval
        ) {
            resetCredits = cached
        } else if let fetched = try await claudeResetCredits(token: session.accessToken, network: context.network) {
            await memory.storeResetCredits(fetched, for: account.sourceID, identity: identity, fetchedAt: refreshedAt)
            resetCredits = fetched
        } else {
            resetCredits = await memory.lastResetCredits(for: account.sourceID, identity: identity) ?? []
        }

        let quotas = primaryQuotas + Self.activeResetCredits(resetCredits, now: refreshedAt)
        let plan = claudeNonempty(session.subscriptionType)
            ?? profile?.organizationPlan
            ?? claudeNonempty(session.rateLimitTier)
        return ProviderAccountSnapshot(
            sourceID: account.sourceID,
            quotas: quotas,
            refreshedAt: refreshedAt,
            accountEmail: account.email ?? profile?.email,
            plan: plan
        )
    }

    /// Drops reset tickets whose `ends_at` has passed and recomputes the summary count.
    public static func activeResetCredits(_ items: [RawQuotaItem], now: Date) -> [RawQuotaItem] {
        guard let summaryIndex = items.firstIndex(where: { $0.id.rawValue == "rateLimitResetCredits" }) else {
            return items
        }
        let grants = items.filter { $0.id.rawValue.hasPrefix("rateLimitResetCredit.") }
        let active = grants.filter { grant in grant.resetsAt.map { $0 > now } ?? true }
        guard active.count != grants.count else { return items }
        var total = Decimal.zero
        for grant in active {
            total += grant.remaining?.value ?? 0
        }
        let summary = items[summaryIndex]
        let raw = NSDecimalNumber(decimal: total).stringValue
        let recomputed = RawQuotaItem(
            id: summary.id,
            originalName: summary.originalName,
            used: summary.used,
            remaining: SourceValue(value: total, rawText: raw, unit: summary.remaining?.unit ?? "credits"),
            percentage: summary.percentage,
            resetsAt: summary.resetsAt,
            sourceFields: summary.sourceFields
        )
        return [recomputed] + active
    }

    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        let quotas = try decodeQuotas(from: data)
        return ProviderSnapshot(
            providerID: .claude,
            source: ClaudeAdapter().sourceDescriptor,
            quotas: quotas,
            refreshedAt: refreshedAt
        )
    }

    public static func decodeResetCredits(from data: Data) throws -> [RawQuotaItem] {
        let root = try claudeObject(from: data)
        guard let emberValue = root["cedar_ember"], !(emberValue is NSNull) else { return [] }
        guard let ember = emberValue as? [String: Any] else {
            throw claudeSchemaError("claude.oauth.reset-credits.invalid")
        }
        if let eligible = ember["eligible"] {
            guard let number = eligible as? NSNumber, JSONScalar.isBoolean(number) else {
                throw claudeSchemaError("claude.oauth.reset-credits.eligible-invalid")
            }
        }
        guard let grantsValue = ember["grants"], !(grantsValue is NSNull) else { return [] }
        guard let grants = grantsValue as? [Any] else {
            throw claudeSchemaError("claude.oauth.reset-credits.grants-invalid")
        }
        if grants.isEmpty, (ember["eligible"] as? NSNumber)?.boolValue != true {
            return []
        }

        var rows: [RawQuotaItem] = []
        var grantIDs: Set<String> = []
        var total = Decimal.zero
        for value in grants {
            guard let grant = value as? [String: Any],
                  let grantID = grant["id"] as? String,
                  claudeSafeGrantID(grantID),
                  grantIDs.insert(grantID).inserted,
                  let count = claudeNonnegativeInteger(grant["resets_left"])
            else { throw claudeSchemaError("claude.oauth.reset-credit.invalid") }
            _ = try claudeOptionalDate(grant, key: "starts_at")
            let endsAt = try claudeOptionalDate(grant, key: "ends_at")
            let paused = try claudeOptionalBoolean(grant, key: "paused")
            let usableNow = try claudeOptionalBoolean(grant, key: "usable_now")
            var summed = Decimal.zero
            var accumulated = total
            var increment = count.value
            guard NSDecimalAdd(&summed, &accumulated, &increment, .plain) == .noError,
                  !NSDecimalIsNotANumber(&summed)
            else { throw claudeSchemaError("claude.oauth.reset-credits.sum-invalid") }
            total = summed

            var fields = ["item": "cedar_ember.grant", "resets_left": count.raw]
            if let raw = grant["starts_at"] as? String { fields["starts_at"] = raw }
            if let raw = grant["ends_at"] as? String { fields["ends_at"] = raw }
            if let paused { fields["paused"] = String(paused) }
            if let usableNow { fields["usable_now"] = String(usableNow) }
            rows.append(RawQuotaItem(
                id: RawQuotaID(rawValue: "rateLimitResetCredit.\(grantID)"),
                originalName: claudeNonempty(grant["label"] as? String) ?? grantID,
                used: nil,
                remaining: SourceValue(value: count.value, rawText: count.raw, unit: "credits"),
                percentage: .missing(meaning: .remaining),
                resetsAt: endsAt,
                sourceFields: fields
            ))
        }
        let totalRaw = NSDecimalNumber(decimal: total).stringValue
        let summary = RawQuotaItem(
            id: RawQuotaID(rawValue: "rateLimitResetCredits"),
            originalName: "rateLimitResetCredits",
            used: nil,
            remaining: SourceValue(value: total, rawText: totalRaw, unit: "credits"),
            percentage: .missing(meaning: .remaining),
            resetsAt: nil,
            sourceFields: ["item": "cedar_ember"]
        )
        return [summary] + rows
    }


    private static func decodeQuotas(from data: Data) throws -> [RawQuotaItem] {
        let root = try claudeObject(from: data)
        var quotas: [RawQuotaItem] = []
        var identities: Set<RawQuotaID> = []

        var hasLimits = false
        if let value = root["limits"], !(value is NSNull) {
            guard let limits = value as? [Any] else {
                throw claudeSchemaError("claude.oauth.usage.limits-invalid")
            }
            hasLimits = !limits.isEmpty
            for limit in limits {
                try claudeAppendLimit(limit, to: &quotas, identities: &identities)
            }
        }

        let standardWindows = ["five_hour", "seven_day"]
        let scopedWindows = ["seven_day_opus", "seven_day_sonnet"]
        let supplementalWindows = ["seven_day_oauth_apps", "seven_day_routines", "seven_day_cowork"]
        for name in (hasLimits ? scopedWindows + supplementalWindows : standardWindows + scopedWindows + supplementalWindows) {
            try claudeAppendWindow(root[name], name: name, to: &quotas, identities: &identities)
        }
        try claudeAppendExtraUsage(root["extra_usage"], to: &quotas, identities: &identities)

        guard !quotas.isEmpty else {
            throw claudeMalformedError("claude.oauth.usage.empty-success")
        }
        return quotas
    }
}

private struct ClaudeDecimalValue {
    let value: Decimal
    let raw: String
}

private func claudeSourceSession(
    account sourceID: String,
    in context: CollectionContext,
    rejectedAccessToken: String?,
    repairAvailable: inout Bool
) async throws -> ClaudeSession {
    do {
        return try await context.claudeSession.session(
            account: sourceID,
            allowInteraction: false,
            rejectedAccessToken: rejectedAccessToken
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as CollectionError {
        guard error.recoveryAction == .repairClaudeConnection, repairAvailable else { throw error }
        // Each collection grants one attempt, not permission for every reread or HTTP retry.
        repairAvailable = false
        try Task.checkCancellation()
        return try await context.claudeSession.session(
            account: sourceID,
            allowInteraction: true,
            rejectedAccessToken: rejectedAccessToken
        )
    } catch {
        throw CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "claude.oauth.session-unavailable",
            recoveryAction: .signInSourceApp
        )
    }
}

private func claudeHeaders(_ token: String) -> [String: String] {
    [
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": "Bearer \(token)",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-cli/2.1.280 (external, cli)",
    ]
}

private func claudeResponse(
    path: String,
    token: String,
    timeout: TimeInterval,
    network: any NetworkClient
) async throws -> NetworkResponse {
    guard let url = URL(string: "https://api.anthropic.com\(path)") else {
        throw claudeMalformedError("claude.oauth.request-url-invalid")
    }
    let request = NetworkRequest(
        providerID: .claude,
        url: url,
        method: .get,
        headers: claudeHeaders(token),
        timeout: timeout
    )
    do {
        return try await network.send(request)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as CollectionError {
        throw error
    } catch {
        throw CollectionError(kind: .transientNetwork, diagnosticCode: "claude.oauth.network-failed")
    }
}

private func claudeValidate(_ response: NetworkResponse, now: Date) throws {
    switch response.statusCode {
    case 200:
        guard !response.body.isEmpty else {
            throw claudeMalformedError("claude.oauth.usage.empty-body")
        }
    case 401:
        throw CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "claude.oauth.authentication-rejected",
            recoveryAction: .signInSourceApp
        )
    case 403:
        throw CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "claude.oauth.scope-rejected",
            recoveryAction: .signInSourceApp
        )
    case 429:
        throw CollectionError(
            kind: .rateLimited,
            diagnosticCode: "claude.oauth.rate-limited",
            retryAfter: claudeRetryAfter(response.header("Retry-After"), now: now)
        )
    default:
        throw CollectionError(kind: .transientNetwork, diagnosticCode: "claude.oauth.http-error")
    }
}

private func claudeRetryAfter(_ raw: String?, now: Date) -> Date {
    if let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
       let seconds = TimeInterval(raw), seconds.isFinite, (0...86_400).contains(seconds) {
        return now.addingTimeInterval(seconds)
    }
    if let raw {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        if let date = formatter.date(from: raw),
           date > now,
           date.timeIntervalSince(now) <= 86_400 {
            return date
        }
    }
    return now.addingTimeInterval(300)
}

struct ClaudeProfile: Sendable, Equatable {
    let email: String?
    let organizationPlan: String?
}

/// `nil` when the profile could not be read; the collection continues without it.
private func claudeProfile(token: String, network: any NetworkClient) async throws -> ClaudeProfile? {
    do {
        let response = try await claudeResponse(
            path: "/api/oauth/profile",
            token: token,
            timeout: 15,
            network: network
        )
        guard response.statusCode == 200, !response.body.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { return nil }
        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]
        let email = claudeNonempty(account?["email"] as? String)
            ?? claudeNonempty(account?["emailAddress"] as? String)
            ?? claudeNonempty(root["email"] as? String)
        let plan = claudeNonempty(organization?["plan"] as? String)
            ?? claudeNonempty(organization?["subscription_type"] as? String)
            ?? claudeNonempty(organization?["organization_type"] as? String)
        return ClaudeProfile(email: email, organizationPlan: plan)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as CollectionError where error.kind == .cancelled {
        throw error
    } catch {
        return nil
    }
}

/// `nil` when the supplemental reset request failed; the caller keeps its previous value.
private func claudeResetCredits(token: String, network: any NetworkClient) async throws -> [RawQuotaItem]? {
    do {
        let response = try await claudeResponse(
            path: "/api/oauth/usage?cedar_ember=1&skip_spend=1",
            token: token,
            timeout: 15,
            network: network
        )
        guard response.statusCode == 200, !response.body.isEmpty else { return nil }
        return try? ClaudeAdapter.decodeResetCredits(from: response.body)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as CollectionError where error.kind == .cancelled {
        throw error
    } catch {
        return nil
    }
}

private func claudeSafeGrantID(_ value: String) -> Bool {
    guard (1...40).contains(value.utf8.count) else { return false }
    return value.utf8.allSatisfy {
        (48...57).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
    }
}

private func claudeNonnegativeInteger(_ value: Any?) -> ClaudeDecimalValue? {
    guard let number = value as? NSNumber, !JSONScalar.isBoolean(number), number.doubleValue.isFinite else { return nil }
    let decimal = number.decimalValue
    var candidate = decimal
    guard !NSDecimalIsNotANumber(&candidate) else { return nil }
    var rounded = Decimal.zero
    NSDecimalRound(&rounded, &candidate, 0, .plain)
    guard decimal >= 0, rounded == decimal else { return nil }
    return ClaudeDecimalValue(value: decimal, raw: number.stringValue)
}

private func claudeOptionalBoolean(_ object: [String: Any], key: String) throws -> Bool? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let number = value as? NSNumber, JSONScalar.isBoolean(number) else {
        throw claudeSchemaError("claude.oauth.reset-credit.\(key)-invalid")
    }
    return number.boolValue
}

private func claudeAppendLimit(
    _ value: Any,
    to quotas: inout [RawQuotaItem],
    identities: inout Set<RawQuotaID>
) throws {
    guard let limit = value as? [String: Any],
          let kind = claudeNonempty(limit["kind"] as? String),
          ["session", "weekly_all", "weekly_scoped"].contains(kind),
          let percent = claudePercentage(limit["percent"])
    else { throw claudeSchemaError("claude.oauth.usage.limit-invalid") }
    let scopeName: String?
    if kind == "weekly_scoped" {
        scopeName = try claudeScopeName(limit["scope"], required: true)
    } else {
        scopeName = nil
    }
    let originalName = scopeName.map { "\(kind).\($0)" } ?? kind
    let resetsAt = try claudeOptionalDate(limit, key: "resets_at")
    var fields = ["kind": kind, "percent": percent.raw]
    if let group = claudeNonempty(limit["group"] as? String) { fields["group"] = group }
    if let scopeName { fields["scope"] = scopeName }
    if let raw = limit["resets_at"] as? String { fields["resets_at"] = raw }
    if let active = limit["is_active"] {
        guard let active = active as? Bool else {
            throw claudeSchemaError("claude.oauth.usage.limit-active-invalid")
        }
        fields["is_active"] = String(active)
    }
    let identity = ["limit", kind, scopeName ?? "all"]
    try claudeAppendQuota(
        identity: identity,
        originalName: originalName,
        percent: percent,
        resetsAt: resetsAt,
        fields: fields,
        to: &quotas,
        identities: &identities
    )
}

private func claudeAppendWindow(
    _ value: Any?,
    name: String,
    to quotas: inout [RawQuotaItem],
    identities: inout Set<RawQuotaID>
) throws {
    guard let value, !(value is NSNull) else { return }
    guard let window = value as? [String: Any] else {
        throw claudeSchemaError("claude.oauth.usage.window-invalid")
    }
    guard let utilization = window["utilization"], !(utilization is NSNull) else { return }
    guard let percent = claudePercentage(utilization) else {
        throw claudeSchemaError("claude.oauth.usage.window-invalid")
    }
    let resetsAt = try claudeOptionalDate(window, key: "resets_at")
    var fields = ["window": name, "utilization": percent.raw]
    if let raw = window["resets_at"] as? String { fields["resets_at"] = raw }
    try claudeAppendQuota(
        identity: ["window", name],
        originalName: name,
        percent: percent,
        resetsAt: resetsAt,
        fields: fields,
        to: &quotas,
        identities: &identities
    )
}

private func claudeAppendExtraUsage(
    _ value: Any?,
    to quotas: inout [RawQuotaItem],
    identities: inout Set<RawQuotaID>
) throws {
    guard let value, !(value is NSNull), let extra = value as? [String: Any],
          extra["is_enabled"] as? Bool == true,
          let used = claudeNonnegativeDecimal(extra["used_credits"]),
          let limit = claudeNonnegativeDecimal(extra["monthly_limit"]), limit.value > 0
    else { return }

    let percent: ClaudeDecimalValue?
    if let utilization = extra["utilization"], !(utilization is NSNull) {
        guard let parsed = claudePercentage(utilization) else { return }
        percent = parsed
    } else {
        percent = nil
    }
    let remainingValue = limit.value - used.value
    let remaining = remainingValue >= 0
        ? SourceValue(
            value: remainingValue,
            rawText: NSDecimalNumber(decimal: remainingValue).stringValue,
            unit: claudeNonempty(extra["currency"] as? String)
        )
        : nil
    var fields = [
        "used_credits": used.raw,
        "monthly_limit": limit.raw,
    ]
    if let percent { fields["utilization"] = percent.raw }
    if let currency = claudeNonempty(extra["currency"] as? String) { fields["currency"] = currency }
    let id = StableSourceID.make(prefix: "claude", components: ["extra_usage"])
    guard identities.insert(id).inserted else {
        throw claudeSchemaError("claude.oauth.usage.duplicate-identity")
    }
    quotas.append(RawQuotaItem(
        id: id,
        originalName: "extra_usage",
        used: SourceValue(value: used.value, rawText: used.raw, unit: fields["currency"]),
        remaining: remaining,
        percentage: percent.map {
            SourcePercentage(value: $0.value, rawText: $0.raw, meaning: .used)
        } ?? .missing(meaning: .used),
        resetsAt: nil,
        sourceFields: fields
    ))
}

private func claudeAppendQuota(
    identity: [String],
    originalName: String,
    percent: ClaudeDecimalValue,
    resetsAt: Date?,
    fields: [String: String],
    to quotas: inout [RawQuotaItem],
    identities: inout Set<RawQuotaID>
) throws {
    let id = StableSourceID.make(prefix: "claude", components: identity)
    guard identities.insert(id).inserted else {
        throw claudeSchemaError("claude.oauth.usage.duplicate-identity")
    }
    let remainingValue = Decimal(100) - percent.value
    let remaining = remainingValue >= 0
        ? SourceValue(
            value: remainingValue,
            rawText: NSDecimalNumber(decimal: remainingValue).stringValue,
            unit: "%"
        )
        : nil
    quotas.append(RawQuotaItem(
        id: id,
        originalName: originalName,
        used: SourceValue(value: percent.value, rawText: percent.raw, unit: "%"),
        remaining: remaining,
        percentage: SourcePercentage(value: percent.value, rawText: percent.raw, meaning: .used),
        resetsAt: resetsAt,
        sourceFields: fields
    ))
}

private func claudeScopeName(_ value: Any?, required: Bool) throws -> String? {
    guard let value, !(value is NSNull) else {
        if required { throw claudeSchemaError("claude.oauth.usage.limit-scope-missing") }
        return nil
    }
    guard let scope = value as? [String: Any], let model = scope["model"] as? [String: Any],
          let name = claudeNonempty(model["display_name"] as? String)
            ?? claudeNonempty(model["id"] as? String)
    else { throw claudeSchemaError("claude.oauth.usage.limit-scope-invalid") }
    return name
}

private func claudePercentage(_ value: Any?) -> ClaudeDecimalValue? {
    claudeNonnegativeDecimal(value)
}

private func claudeNonnegativeDecimal(_ value: Any?) -> ClaudeDecimalValue? {
    let parsed: ClaudeDecimalValue?
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        parsed = ClaudeDecimalValue(value: decimal, raw: text)
    } else if let number = value as? NSNumber, !JSONScalar.isBoolean(number) {
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        parsed = ClaudeDecimalValue(value: number.decimalValue, raw: number.stringValue)
    } else {
        return nil
    }
    guard let parsed, parsed.value >= 0 else { return nil }
    return parsed
}

private func claudeOptionalDate(_ object: [String: Any], key: String) throws -> Date? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let raw = value as? String, let date = claudeDate(raw) else {
        throw claudeSchemaError("claude.oauth.usage.reset-invalid")
    }
    return date
}

private func claudeDate(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    return ISO8601DateFormatter().date(from: raw)
}

private func claudeNonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func claudeObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { throw claudeMalformedError("claude.oauth.usage.empty-body") }
    do {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw claudeSchemaError("claude.oauth.usage.object-required")
        }
        return dictionary
    } catch let error as CollectionError {
        throw error
    } catch {
        throw claudeMalformedError("claude.oauth.usage.invalid-json")
    }
}

private func claudeSchemaError(_ code: String) -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: code)
}

private func claudeMalformedError(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
