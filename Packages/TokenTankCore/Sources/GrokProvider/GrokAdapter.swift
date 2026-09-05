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
            detail: "Read-only Grok CLI ~/.grok/auth.json session plus cli-chat-proxy.grok.com/v1/billing?format=credits. This is the CodexBar SuperGrok credits path. Token Jar never copies or refreshes the token, never imports browser cookies, never uses grok agent stdio, and never calls the xAI Management prepaid-balance API."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        do {
            let now = await context.clock.now()
            _ = try grokSession(from: try await grokAuthFile(in: context), now: now)
            return .available(sourceDescriptor)
        } catch is CancellationError {
            return .unavailable(
                CollectionError(kind: .cancelled, diagnosticCode: "grok.cli-session.cancelled")
            )
        } catch let error as CollectionError {
            if error.kind == .externalSessionMissing {
                return .needsConfiguration(code: error.diagnosticCode)
            }
            return .unavailable(error)
        } catch {
            return .unavailable(
                CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.cli-session.unavailable")
            )
        }
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let now = await context.clock.now()
        let session = try grokSession(from: try await grokAuthFile(in: context), now: now)
        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
            throw grokMalformedError("grok.credits.request-url-invalid")
        }
        let request = NetworkRequest(
            providerID: .grok,
            url: url,
            method: .get,
            headers: [
                "Accept": "application/json",
                "Authorization": "Bearer \(session.token)",
                "x-xai-token-auth": "xai-grok-cli",
            ]
        )
        let response: NetworkResponse
        do {
            response = try await context.network.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError {
            throw error
        } catch {
            throw CollectionError(kind: .transientNetwork, diagnosticCode: "grok.credits.network-failed")
        }
        try grokValidate(response, now: now)
        return try Self.decodeSnapshot(
            from: response.body,
            refreshedAt: now,
            accountEmail: session.accountEmail
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

let grokAuthFileRequest = ExternalFileRequest(
    providerID: .grok,
    relativePath: ".grok/auth.json",
    maximumBytes: 64 * 1024
)

private struct GrokSession {
    let token: String
    let accountEmail: String?
}

private struct GrokDecimalValue {
    let value: Decimal
    let raw: String
}

private func grokAuthFile(in context: CollectionContext) async throws -> Data {
    do {
        return try await context.externalSessions.read(grokAuthFileRequest)
    } catch let error as CollectionError {
        if error.kind == .externalSessionMissing {
            throw CollectionError(
                kind: .externalSessionMissing,
                diagnosticCode: "grok.cli-session.missing"
            )
        }
        throw error
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.cli-session.unavailable")
    }
}

private func grokSession(from data: Data, now: Date) throws -> GrokSession {
    let root = try grokObject(from: data, code: "grok.cli-session.invalid-json")
    let preferred = grokPreferredEntry(from: root)
    guard let token = grokString(preferred["key"]), grokTokenLooksUsable(token) else {
        throw CollectionError(kind: .authenticationRejected, diagnosticCode: "grok.cli-session.token-missing")
    }
    if let expiry = grokDate(preferred["expires_at"]), expiry.timeIntervalSince1970 <= now.timeIntervalSince1970 + 60 {
        throw CollectionError(kind: .authenticationRevoked, diagnosticCode: "grok.cli-session.expired")
    }
    return GrokSession(token: token, accountEmail: preferred["email"] as? String)
}

private func grokPreferredEntry(from root: [String: Any]) -> [String: Any] {
    let scopes = root.keys.sorted()
    if let preferred = scopes.first(where: { $0.hasPrefix("https://auth.x.ai::") }),
       let entry = root[preferred] as? [String: Any]
    {
        return entry
    }
    if let entry = root["https://accounts.x.ai/sign-in"] as? [String: Any] {
        return entry
    }
    for key in scopes {
        if let entry = root[key] as? [String: Any], grokString(entry["key"]) != nil {
            return entry
        }
    }
    return [:]
}

private func grokTokenLooksUsable(_ token: String) -> Bool {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 8_192 else { return false }
    let lowered = trimmed.lowercased()
    if lowered.hasPrefix("xai-") { return false }
    if lowered.contains("cookie:") { return false }
    if trimmed.contains("="), trimmed.contains(";") { return false }
    return trimmed.unicodeScalars.allSatisfy { scalar in
        scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value != 0x7F)
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
        throw CollectionError(kind: .authenticationRejected, diagnosticCode: "grok.credits.authentication.rejected")
    case 403:
        throw CollectionError(kind: .authenticationRevoked, diagnosticCode: "grok.credits.authentication.revoked")
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
