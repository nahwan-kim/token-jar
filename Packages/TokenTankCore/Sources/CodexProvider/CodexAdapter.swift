import Foundation
import TokenTankCore
import TokenTankDomain

public struct CodexAdapter: ProviderAdapter {
    public let id: ProviderID = .codex
    public let displayName: String = "Codex"
    public let defaultAbbreviation: String = "CDX"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "codex.app-server.account-rate-limits",
            name: "Codex app-server",
            kind: .officialCLI,
            credentialOwnership: .externalProvider,
            documentationURL: URL(string: "https://developers.openai.com/codex/app-server/"),
            detail: "Official Codex app-server account/rateLimits/read source. Token Tank starts only the documented stdio server and never reads, copies, or refreshes Codex credentials."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let data: Data
        do {
            data = try await context.codexAccount.readRateLimits()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError {
            throw error
        } catch {
            throw CollectionError(
                kind: .transientNetwork,
                diagnosticCode: "codex.app-server.read-failed"
            )
        }

        let refreshedAt = await context.clock.now()
        return try Self.decodeSnapshot(from: data, refreshedAt: refreshedAt)
    }

    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        let rawRoot = try codexObject(from: data, code: "codex.response.invalid-json")
        let root: [String: Any]
        if let result = rawRoot["result"] as? [String: Any],
           result["rateLimits"] != nil || result["rateLimitsByLimitId"] != nil
        {
            root = result
        } else {
            root = rawRoot
        }
        var buckets: [(id: String, object: [String: Any])] = []

        if let keyedValue = root["rateLimitsByLimitId"] {
            guard let keyed = keyedValue as? [String: Any], !keyed.isEmpty else {
                throw codexSchemaError("codex.rate-limits-by-id.invalid")
            }
            for limitID in keyed.keys.sorted() {
                guard let object = keyed[limitID] as? [String: Any] else {
                    throw codexSchemaError("codex.rate-limit-bucket.invalid")
                }
                buckets.append((limitID, object))
            }
        } else {
            guard let object = root["rateLimits"] as? [String: Any] else {
                throw codexSchemaError("codex.rate-limits.missing")
            }
            let limitID = codexString(object["limitId"])
                ?? codexString(object["limitID"])
                ?? codexString(object["id"])
                ?? "rateLimits"
            buckets.append((limitID, object))
        }

        var quotas: [RawQuotaItem] = []
        for bucket in buckets {
            try appendBucket(bucket.object, limitID: bucket.id, to: &quotas)
        }
        try appendResetCreditItems(from: root, to: &quotas)
        guard !quotas.isEmpty else {
            throw codexMalformedError("codex.response.empty-success")
        }
        guard Set(quotas.map(\.id)).count == quotas.count else {
            throw codexSchemaError("codex.quota.duplicate-identity")
        }

        return ProviderSnapshot(
            providerID: .codex,
            source: CodexAdapter().sourceDescriptor,
            quotas: quotas,
            refreshedAt: refreshedAt
        )
    }

    internal static func decode(data: Data, refreshedAt: Date) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, refreshedAt: refreshedAt)
    }

    private static func appendBucket(
        _ bucket: [String: Any],
        limitID: String,
        to quotas: inout [RawQuotaItem]
    ) throws {
        let limitName = codexString(bucket["name"])
            ?? codexString(bucket["limitName"])
            ?? codexString(bucket["limit_name"])
            ?? limitID
        let beforeCount = quotas.count

        for windowName in ["primary", "secondary"] {
            guard let value = bucket[windowName], !(value is NSNull) else { continue }
            guard let window = value as? [String: Any] else {
                throw codexSchemaError("codex.window.invalid")
            }
            guard let usedPercent = codexDecimal(window["usedPercent"])
                ?? codexDecimal(window["used_percent"])
            else {
                throw codexSchemaError("codex.window.used-percent.missing")
            }

            let duration = codexDecimal(window["windowDurationMins"])
                ?? codexDecimal(window["windowDurationMinutes"])
                ?? codexDecimal(window["window_duration_mins"])
            let resetValue = window["resetsAt"]
                ?? window["resetAt"]
                ?? window["reset_at"]
            let resetDate = codexDate(resetValue)
            let remainingPercent = Decimal(100) - usedPercent.value
            var fields: [String: String] = [
                "limitId": limitID,
                "limitName": limitName,
                "window": windowName,
                "usedPercent": codexRawText(window["usedPercent"] ?? window["used_percent"]) ?? ""
            ]
            if let duration {
                fields["windowDurationMins"] = duration.raw
            }
            if let resetValue, let raw = codexRawText(resetValue) {
                fields["resetsAt"] = raw
            }
            codexCopyScalarFields(from: window, into: &fields)

            let itemID = "\(limitID).\(windowName)"
            quotas.append(
                RawQuotaItem(
                    id: RawQuotaID(rawValue: itemID),
                    originalName: limitName,
                    used: SourceValue(value: usedPercent.value, rawText: usedPercent.raw, unit: "%"),
                    remaining: SourceValue(
                        value: remainingPercent,
                        rawText: NSDecimalNumber(decimal: remainingPercent).stringValue,
                        unit: "%"
                    ),
                    percentage: SourcePercentage(
                        value: usedPercent.value,
                        rawText: usedPercent.raw,
                        meaning: .used
                    ),
                    resetsAt: resetDate,
                    sourceFields: fields
                )
            )
        }

        if let value = bucket["credits"], !(value is NSNull) {
            guard let credits = value as? [String: Any], !credits.isEmpty else {
                throw codexSchemaError("codex.credits.invalid")
            }
            var fields: [String: String] = [
                "limitId": limitID,
                "limitName": limitName,
                "item": "credits"
            ]
            codexCopyScalarFields(from: credits, into: &fields)
            let balanceValue = credits["balance"]
                ?? credits["remaining"]
                ?? credits["remainingCredits"]
            let balance = codexDecimal(balanceValue)
            let resetValue = credits["resetsAt"]
                ?? credits["resetAt"]
                ?? credits["reset_at"]
            if let balanceValue, let raw = codexRawText(balanceValue) {
                fields["balance"] = raw
            }
            if let resetValue, let raw = codexRawText(resetValue) {
                fields["resetsAt"] = raw
            }
            quotas.append(
                RawQuotaItem(
                    id: RawQuotaID(rawValue: "\(limitID).credits"),
                    originalName: codexString(credits["name"]) ?? "credits",
                    used: nil,
                    remaining: balance.map {
                        SourceValue(value: $0.value, rawText: $0.raw)
                    },
                    percentage: .missing(meaning: .remaining),
                    resetsAt: codexDate(resetValue),
                    sourceFields: fields
                )
            )
        }

        guard quotas.count > beforeCount else {
            throw codexSchemaError("codex.rate-limit-bucket.empty")
        }
    }
    private static func appendResetCreditItems(
        from root: [String: Any],
        to quotas: inout [RawQuotaItem]
    ) throws {
        guard let value = root["rateLimitResetCredits"], !(value is NSNull) else { return }
        guard let summary = value as? [String: Any] else {
            throw codexSchemaError("codex.reset-credits.invalid")
        }
        guard let available = codexDecimal(summary["availableCount"] ?? summary["available_count"]) else {
            throw codexSchemaError("codex.reset-credits.available-count.missing")
        }
        var fields: [String: String] = ["item": "rateLimitResetCredits"]
        codexCopyScalarFields(from: summary, into: &fields)
        fields["availableCount"] = available.raw
        quotas.append(
            RawQuotaItem(
                id: RawQuotaID(rawValue: "rateLimitResetCredits"),
                originalName: "rateLimitResetCredits",
                used: nil,
                remaining: SourceValue(value: available.value, rawText: available.raw, unit: "credits"),
                percentage: .missing(meaning: .remaining),
                resetsAt: nil,
                sourceFields: fields
            )
        )

        guard let creditsValue = summary["credits"], !(creditsValue is NSNull) else { return }
        guard let credits = creditsValue as? [Any] else {
            throw codexSchemaError("codex.reset-credits.details.invalid")
        }
        for (index, creditValue) in credits.enumerated() {
            guard let credit = creditValue as? [String: Any] else {
                throw codexSchemaError("codex.reset-credit.invalid")
            }
            var creditFields: [String: String] = ["item": "rateLimitResetCredit"]
            codexCopyScalarFields(from: credit, into: &creditFields)
            let creditID = codexString(credit["id"]) ?? String(index)
            quotas.append(
                RawQuotaItem(
                    id: RawQuotaID(rawValue: "rateLimitResetCredit.\(creditID)"),
                    originalName: codexString(credit["title"]) ?? creditID,
                    used: nil,
                    remaining: nil,
                    percentage: .missing(meaning: .remaining),
                    resetsAt: nil,
                    sourceFields: creditFields
                )
            )
        }
    }
}

private struct CodexDecimalValue {
    let value: Decimal
    let raw: String
}

private func codexObject(from data: Data, code: String) throws -> [String: Any] {
    guard !data.isEmpty else { throw codexMalformedError(code) }
    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw codexSchemaError("codex.response.object-required")
        }
        return dictionary
    } catch let error as CollectionError {
        throw error
    } catch {
        throw codexMalformedError(code)
    }
}

private func codexDecimal(_ value: Any?) -> CodexDecimalValue? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return CodexDecimalValue(value: decimal, raw: text)
    }
    guard let number = value as? NSNumber, !JSONScalar.isBoolean(number) else { return nil }
    return CodexDecimalValue(value: number.decimalValue, raw: number.stringValue)
}

private func codexRawText(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) { return number.stringValue }
    return nil
}

private func codexString(_ value: Any?) -> String? {
    guard let raw = codexRawText(value) else { return nil }
    return raw.isEmpty ? nil : raw
}

private func codexDate(_ value: Any?) -> Date? {
    if let text = value as? String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        if let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) {
            return codexEpochDate(decimal)
        }
        return nil
    }
    guard let decimal = codexDecimal(value)?.value else { return nil }
    return codexEpochDate(decimal)
}

private func codexEpochDate(_ value: Decimal) -> Date? {
    let seconds = NSDecimalNumber(decimal: value).doubleValue
    guard seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: abs(seconds) > 100_000_000_000 ? seconds / 1_000 : seconds)
}

private func codexCopyScalarFields(from object: [String: Any], into fields: inout [String: String]) {
    for key in object.keys.sorted() {
        guard let raw = codexRawText(object[key]) else { continue }
        fields[key] = raw
    }
}

private func codexSchemaError(_ code: String) -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: code)
}

private func codexMalformedError(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
