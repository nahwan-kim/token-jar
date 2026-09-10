import Foundation
import TokenTankCore
import TokenTankDomain

public struct GrokAdapter: ProviderAdapter {
    public let id: ProviderID = .grok
    public let displayName: String = "Grok"
    public let defaultAbbreviation: String = "GRK"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "grok.cli-proxy.credits",
            name: "Grok CLI SuperGrok credits",
            kind: .localSession,
            credentialOwnership: .externalProvider,
            documentationURL: URL(string: "https://github.com/steipete/CodexBar/blob/main/docs/grok.md"),
            detail: "Grok CLI ~/.grok/auth.json OAuth session plus cli-chat-proxy.grok.com/v1/billing?format=credits. Session expiry or one proxy authentication rejection triggers OAuth refresh through auth.x.ai and an atomic update of the same auth file. When that successful proxy snapshot omits usage, Token Jar may make a bearer-only grpc-web POST to grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig using the same captured session token. Proxy reset, source metadata, and account identity remain authoritative; web billing supplies usage only. Token Jar never imports browser cookies, never launches a CLI subprocess, never calls the xAI Management prepaid-balance API, and never maintains a separate token cache."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        var session = try await grokSourceSession(in: context, rejectedAccessToken: nil)
        var refreshedAt = await context.clock.now()
        var response = try await grokBillingResponse(token: session.accessToken, network: context.network)

        if response.statusCode == 401 || response.statusCode == 403 {
            let rejectedAccessToken = session.accessToken
            session = try await grokSourceSession(in: context, rejectedAccessToken: rejectedAccessToken)
            refreshedAt = await context.clock.now()
            response = try await grokBillingResponse(token: session.accessToken, network: context.network)
        }

        try grokValidate(response, now: refreshedAt)
        let proxySnapshot = try Self.decodeSnapshot(
            from: response.body,
            refreshedAt: refreshedAt,
            accountEmail: session.accountEmail
        )
        guard proxySnapshot.quotas.allSatisfy({ $0.percentage.value == nil }) else {
            return proxySnapshot
        }

        do {
            let webSnapshot = try await GrokWebBilling.fetch(
                token: session.accessToken,
                now: refreshedAt,
                network: context.network
            )
            guard webSnapshot.usedPercent != nil else {
                return proxySnapshot
            }
            return Self.applyingWebPercent(webSnapshot, to: proxySnapshot)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError where error.kind == .cancelled {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return proxySnapshot
        }
    }

    private static func applyingWebPercent(
        _ webSnapshot: GrokWebBillingSnapshot,
        to snapshot: ProviderSnapshot
    ) -> ProviderSnapshot {
        guard let percent = webSnapshot.usedPercent,
              webSnapshot.usedPercentIsWirePublished
                  || (percent == 0 && webSnapshot.usedPercentIsImplicitZero),
              percent.isFinite,
              (0...100).contains(percent)
        else {
            return snapshot
        }
        let raw = String(percent)
        guard let decimal = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            return snapshot
        }
        let remainingDecimal = Decimal(100) - decimal
        let rawRemaining = NSDecimalNumber(decimal: remainingDecimal).stringValue
        let webPercentSource = webSnapshot.usedPercentIsWirePublished
            ? "grok.com.grpc-web.published"
            : "grok.com.grpc-web.implicit-zero"
        let quotas = snapshot.quotas.map { quota -> RawQuotaItem in
            guard quota.id.rawValue == "credits" else { return quota }
            var sourceFields = quota.sourceFields
            if sourceFields["webPercentSource"] == nil {
                sourceFields["webPercentSource"] = webPercentSource
            }
            return RawQuotaItem(
                id: quota.id,
                originalName: quota.originalName,
                used: SourceValue(value: decimal, rawText: raw, unit: "%"),
                remaining: SourceValue(value: remainingDecimal, rawText: rawRemaining, unit: "%"),
                percentage: SourcePercentage(value: decimal, rawText: raw, meaning: .used),
                resetsAt: quota.resetsAt,
                sourceFields: sourceFields
            )
        }
        return ProviderSnapshot(
            providerID: snapshot.providerID,
            source: snapshot.source,
            quotas: quotas,
            refreshedAt: snapshot.refreshedAt,
            accountEmail: snapshot.accountEmail,
            accounts: snapshot.accounts
        )
    }
    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, refreshedAt: refreshedAt, accountEmail: nil)
    }

    private static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date,
        accountEmail: String?
    ) throws -> ProviderSnapshot {
        let root = try grokObject(from: data)
        let config = (root["config"] as? [String: Any]) ?? root
        var fields: [String: String] = [:]
        grokCopyScalarFields(from: config, into: &fields)
        if root["config"] != nil {
            grokCopyScalarFields(from: root, prefix: "root.", into: &fields)
        }

        let percent = grokCreditPercent(from: config, fields: &fields)
        let resetValue = grokNested(config, ["currentPeriod", "end"])
            ?? config["billingPeriodEnd"]
            ?? config["billing_period_end"]
        if let resetValue, let raw = grokRawText(resetValue) {
            fields["resetSource"] = raw
        }

        let remaining: SourceValue?
        if let percent {
            let leftover = Decimal(100) - percent.value
            remaining = leftover >= 0
                ? SourceValue(
                    value: leftover,
                    rawText: NSDecimalNumber(decimal: leftover).stringValue,
                    unit: "%"
                )
                : nil
        } else {
            remaining = nil
        }

        let quota = RawQuotaItem(
            id: "credits",
            originalName: "credits",
            used: percent.map { SourceValue(value: $0.value, rawText: $0.raw, unit: "%") },
            remaining: remaining,
            percentage: percent.map {
                SourcePercentage(value: $0.value, rawText: $0.raw, meaning: .used)
            } ?? .missing(meaning: .used),
            resetsAt: grokDate(resetValue),
            sourceFields: fields
        )
        return ProviderSnapshot(
            providerID: .grok,
            source: GrokAdapter().sourceDescriptor,
            quotas: [quota],
            refreshedAt: refreshedAt,
            accountEmail: accountEmail
        )
    }

    public static func decode(data: Data, refreshedAt: Date) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, refreshedAt: refreshedAt)
    }
}


private struct GrokDecimalValue {
    let value: Decimal
    let raw: String
}

private func grokSourceSession(
    in context: CollectionContext,
    rejectedAccessToken: String?
) async throws -> GrokSession {
    do {
        return try await context.grokSession.session(rejectedAccessToken: rejectedAccessToken)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as CollectionError {
        switch error.kind {
        case .authenticationRejected, .authenticationRevoked, .externalSessionMissing, .appCredentialMissing:
            throw CollectionError(
                kind: error.kind,
                diagnosticCode: error.diagnosticCode,
                recoveryAction: .signInSourceApp,
                retryAfter: error.retryAfter
            )
        default:
            throw error
        }
    } catch {
        throw CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "grok.cli-session.unavailable",
            recoveryAction: .signInSourceApp
        )
    }
}

private func grokBillingResponse(
    token: String,
    network: any NetworkClient
) async throws -> NetworkResponse {
    guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
        throw grokMalformedError("grok.credits.request-url-invalid")
    }
    let request = NetworkRequest(
        providerID: .grok,
        url: url,
        method: .get,
        headers: [
            "Accept": "application/json",
            "Authorization": "Bearer \(token)",
            "x-xai-token-auth": "xai-grok-cli",
        ]
    )
    do {
        return try await network.send(request)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as CollectionError {
        throw error
    } catch {
        throw CollectionError(kind: .transientNetwork, diagnosticCode: "grok.credits.network-failed")
    }
}

private func grokCreditPercent(
    from config: [String: Any],
    fields: inout [String: String]
) -> GrokDecimalValue? {
    if let explicit = grokNonnegativeDecimal(config["creditUsagePercent"] ?? config["credit_usage_percent"]) {
        fields["percentField"] = "creditUsagePercent"
        return explicit
    }
    let used = grokCents(config["onDemandUsed"] ?? config["on_demand_used"])
    let cap = grokCents(config["onDemandCap"] ?? config["on_demand_cap"])
    guard let used, let cap, cap.value > 0 else { return nil }
    let derived = (used.value / cap.value) * Decimal(100)
    let raw = NSDecimalNumber(decimal: derived).stringValue
    fields["percentField"] = "onDemandUsed/onDemandCap"
    fields["derivedPercentage"] = raw
    return GrokDecimalValue(value: derived, raw: raw)
}

private func grokCents(_ value: Any?) -> GrokDecimalValue? {
    if let object = value as? [String: Any] {
        return grokNonnegativeDecimal(object["val"])
    }
    return grokNonnegativeDecimal(value)
}

private func grokValidate(_ response: NetworkResponse, now: Date) throws {
    switch response.statusCode {
    case 200..<300:
        guard !response.body.isEmpty else {
            throw grokMalformedError("grok.credits.empty-body")
        }
    case 401:
        throw CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "grok.credits.authentication.rejected",
            recoveryAction: .signInSourceApp
        )
    case 403:
        throw CollectionError(
            kind: .authenticationRevoked,
            diagnosticCode: "grok.credits.authentication.revoked",
            recoveryAction: .signInSourceApp
        )
    case 429:
        throw CollectionError(
            kind: .rateLimited,
            diagnosticCode: "grok.credits.rate-limited",
            retryAfter: grokRetryAfter(response.headers, now: now)
        )
    default:
        throw CollectionError(kind: .transientNetwork, diagnosticCode: "grok.credits.http-\(response.statusCode)")
    }
}

private func grokRetryAfter(_ headers: [String: String], now: Date) -> Date? {
    let raw = headers.first { $0.key.lowercased() == "retry-after" }?.value
    guard let raw, let seconds = TimeInterval(raw), seconds > 0 else { return nil }
    return now.addingTimeInterval(seconds)
}

private func grokObject(from data: Data, code: String = "grok.credits.invalid-json") throws -> [String: Any] {
    guard !data.isEmpty else { throw grokMalformedError("grok.credits.empty-body") }
    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw grokSchemaError("grok.credits.object-required")
        }
        return dictionary
    } catch let error as CollectionError {
        throw error
    } catch {
        throw grokMalformedError(code)
    }
}

private func grokNested(_ object: [String: Any], _ path: [String]) -> Any? {
    var current: Any? = object
    for key in path {
        guard let nested = current as? [String: Any] else { return nil }
        current = nested[key]
    }
    return current
}

private func grokNonnegativeDecimal(_ value: Any?) -> GrokDecimalValue? {
    guard let parsed = grokDecimal(value), parsed.value >= 0 else { return nil }
    return parsed
}

private func grokDecimal(_ value: Any?) -> GrokDecimalValue? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return GrokDecimalValue(value: decimal, raw: text)
    }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) {
        return GrokDecimalValue(value: number.decimalValue, raw: number.stringValue)
    }
    return nil
}

private func grokString(_ value: Any?) -> String? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) {
        return number.stringValue
    }
    return nil
}

private func grokRawText(_ value: Any?) -> String? {
    if let text = grokString(value) { return text }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) { return number.stringValue }
    if let flag = value as? Bool { return flag ? "true" : "false" }
    return nil
}

private func grokDate(_ value: Any?) -> Date? {
    if let text = grokString(value) {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return grokEpochDate(decimal)
    }
    guard let decimal = grokDecimal(value)?.value else { return nil }
    return grokEpochDate(decimal)
}

private func grokEpochDate(_ value: Decimal) -> Date? {
    let seconds = NSDecimalNumber(decimal: value).doubleValue
    guard seconds.isFinite, seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: abs(seconds) > 100_000_000_000 ? seconds / 1_000 : seconds)
}

private func grokCopyScalarFields(
    from object: [String: Any],
    prefix: String = "",
    into fields: inout [String: String]
) {
    for key in object.keys.sorted() {
        if let nested = object[key] as? [String: Any] {
            grokCopyScalarFields(from: nested, prefix: "\(prefix)\(key).", into: &fields)
        } else if let raw = grokRawText(object[key]) {
            fields["\(prefix)\(key)"] = raw
        }
    }
}

private func grokSchemaError(_ code: String) -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: code)
}

private func grokMalformedError(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
