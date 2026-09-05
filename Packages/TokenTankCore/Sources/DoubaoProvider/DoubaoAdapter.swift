import Foundation
import TokenTankCore
import TokenTankDomain

public struct DoubaoAdapter: ProviderAdapter {
    public let id: ProviderID = .doubao
    public let displayName: String = "Doubao"
    public let defaultAbbreviation: String = "DB"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "volcano.arkcli.usage-plan",
            name: "Volcano arkcli plan usage",
            kind: .officialCLI,
            credentialOwnership: .externalProvider,
            documentationURL: URL(string: "https://github.com/volcengine/ark-cli"),
            detail: "Official arkcli usage plan --format json. Token Jar starts only the allowlisted arkcli executable with those literal arguments, never reads or copies Volcengine credentials, and never signs OpenAPI requests."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let data: Data
        do {
            data = try await context.doubaoPlan.readPlanUsage()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError {
            throw error
        } catch {
            throw CollectionError(
                kind: .transientNetwork,
                diagnosticCode: "doubao.arkcli.read-failed"
            )
        }
        return try Self.decodeSnapshot(from: data, refreshedAt: await context.clock.now())
    }

    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        let root = try doubaoObject(from: data)
        if let failed = root["ok"] as? Bool, failed == false {
            let message = doubaoString((root["error"] as? [String: Any])?["message"]) ?? ""
            if message.localizedCaseInsensitiveContains("auth login")
                || message.localizedCaseInsensitiveContains("refresh_token")
                || message.localizedCaseInsensitiveContains("sts")
            {
                throw CollectionError(
                    kind: .externalSessionMissing,
                    diagnosticCode: "doubao.arkcli.session-missing"
                )
            }
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "doubao.arkcli.command-failed")
        }

        var quotas: [RawQuotaItem] = []
        if let itemsValue = root["items"] ?? root["Items"] {
            guard let items = itemsValue as? [Any] else {
                throw doubaoSchemaError("doubao.items.invalid")
            }
            try appendPlanItems(items, to: &quotas)
        } else if let quotaUsageValue = root["QuotaUsage"] ?? root["quotaUsage"] ?? root["quota_usage"] {
            guard let quotaUsage = quotaUsageValue as? [Any] else {
                throw doubaoSchemaError("doubao.quota-usage.invalid")
            }
            try appendQuotaUsage(quotaUsage, path: "QuotaUsage", to: &quotas)
        } else {
            let result: [String: Any]
            if let value = root["Result"] ?? root["result"] {
                guard let object = value as? [String: Any] else {
                    throw doubaoSchemaError("doubao.result.invalid")
                }
                result = object
            } else {
                result = root
            }
            if let quotaUsageValue = result["QuotaUsage"] ?? result["quotaUsage"] ?? result["quota_usage"] {
                guard let quotaUsage = quotaUsageValue as? [Any] else {
                    throw doubaoSchemaError("doubao.quota-usage.invalid")
                }
                try appendQuotaUsage(quotaUsage, path: "Result.QuotaUsage", to: &quotas)
            } else {
                try appendNestedPlans(result, path: "", to: &quotas)
            }
        }

        guard !quotas.isEmpty else {
            throw doubaoMalformedError("doubao.response.empty-success")
        }
        guard Set(quotas.map(\.id)).count == quotas.count else {
            throw doubaoSchemaError("doubao.quota.duplicate-identity")
        }
        return ProviderSnapshot(
            providerID: .doubao,
            source: DoubaoAdapter().sourceDescriptor,
            quotas: quotas,
            refreshedAt: refreshedAt
        )
    }

    public static func decode(data: Data, refreshedAt: Date) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, refreshedAt: refreshedAt)
    }
}

private struct DoubaoDecimalValue {
    let value: Decimal
    let raw: String
}

private func doubaoDerivedRemaining(
    total: DoubaoDecimalValue?,
    used: DoubaoDecimalValue?
) -> DoubaoDecimalValue? {
    guard let total, let used else { return nil }
    let value = total.value - used.value
    return DoubaoDecimalValue(value: value, raw: NSDecimalNumber(decimal: value).stringValue)
}

private func doubaoDerivedPercentage(
    total: DoubaoDecimalValue?,
    used: DoubaoDecimalValue?
) -> DoubaoDecimalValue? {
    guard let total, let used, total.value > 0 else { return nil }
    let value = (used.value / total.value) * Decimal(100)
    return DoubaoDecimalValue(value: value, raw: NSDecimalNumber(decimal: value).stringValue)
}

private func doubaoObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { throw doubaoMalformedError("doubao.response.empty-body") }
    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw doubaoSchemaError("doubao.response.object-required")
        }
        return dictionary
    } catch let error as CollectionError {
        throw error
    } catch {
        throw doubaoMalformedError("doubao.response.invalid-json")
    }
}

private func appendNestedPlans(
    _ object: [String: Any],
    path: String,
    to quotas: inout [RawQuotaItem]
) throws {
    if objectContainsQuota(object) {
        try appendQuotaRow(object, path: path.isEmpty ? "plan" : path, index: 0, to: &quotas, tier: nil)
        return
    }
    for key in object.keys.sorted() {
        let nextPath = path.isEmpty ? key : "\(path).\(key)"
        if let nested = object[key] as? [String: Any] {
            try appendNestedPlans(nested, path: nextPath, to: &quotas)
        } else if let rows = object[key] as? [Any] {
            try appendQuotaUsage(rows, path: nextPath, to: &quotas, tier: nil)
        }
    }
}

private func appendPlanItems(
    _ items: [Any],
    to quotas: inout [RawQuotaItem]
) throws {
    for (index, value) in items.enumerated() {
        guard let item = value as? [String: Any] else {
            throw doubaoSchemaError("doubao.items.row-invalid")
        }
        if let subscribed = item["subscribed"] as? Bool, subscribed == false {
            continue
        }
        let product = doubaoString(item["product"] ?? item["Product"]) ?? "plan"
        let edition = doubaoString(item["edition"] ?? item["Edition"])
        let tier = doubaoString(item["tier"] ?? item["Tier"])
        let path = edition.map { "\(product).\($0)" } ?? product
        guard let periodsValue = item["periods"] ?? item["Periods"] else {
            try appendQuotaRow(item, path: path, index: index, to: &quotas, tier: tier)
            continue
        }
        guard let periods = periodsValue as? [Any] else {
            throw doubaoSchemaError("doubao.periods.invalid")
        }
        try appendQuotaUsage(periods, path: path, to: &quotas, tier: tier)
    }
}

private func objectContainsQuota(_ object: [String: Any]) -> Bool {
    doubaoDecimal(object["Used"] ?? object["used"]) != nil
        || doubaoDecimal(object["Quota"] ?? object["quota"] ?? object["Total"] ?? object["total"]) != nil
        || doubaoDecimal(object["Remaining"] ?? object["remaining"]) != nil
        || doubaoDecimal(object["Percent"] ?? object["percent"] ?? object["Percentage"] ?? object["percentage"]) != nil
}

private func appendQuotaUsage(
    _ rows: [Any],
    path: String,
    to quotas: inout [RawQuotaItem],
    tier: String? = nil
) throws {
    for (index, value) in rows.enumerated() {
        guard let row = value as? [String: Any] else {
            throw doubaoSchemaError("doubao.quota-usage.row-invalid")
        }
        try appendQuotaRow(row, path: path, index: index, to: &quotas, tier: tier)
    }
}

private func appendQuotaRow(
    _ row: [String: Any],
    path: String,
    index: Int,
    to quotas: inout [RawQuotaItem],
    tier: String? = nil
) throws {
    let level = doubaoString(
        row["label"]
            ?? row["Label"]
            ?? row["Level"]
            ?? row["level"]
            ?? row["Name"]
            ?? row["name"]
            ?? row["product"]
            ?? row["Product"]
    ) ?? "\(path)[\(index)]"
    let used = doubaoDecimal(row["Used"] ?? row["used"])
    let total = doubaoDecimal(row["Quota"] ?? row["quota"] ?? row["Total"] ?? row["total"])
    let remaining = doubaoDecimal(row["Remaining"] ?? row["remaining"])
    let percent = doubaoDecimal(row["Percent"] ?? row["percent"] ?? row["Percentage"] ?? row["percentage"])
    let resolvedRemaining = remaining ?? doubaoDerivedRemaining(total: total, used: used)
    let resolvedPercent = percent ?? doubaoDerivedPercentage(total: total, used: used)
    let resetValue = row["ResetTimestamp"]
        ?? row["resetTimestamp"]
        ?? row["ResetTime"]
        ?? row["resetTime"]
        ?? row["resetsAt"]
        ?? row["reset_at"]
        ?? row["resetAt"]
    guard used != nil || total != nil || remaining != nil || percent != nil || resetValue != nil else {
        throw doubaoSchemaError("doubao.quota-usage.values-missing")
    }
    var fields: [String: String] = ["path": path, "level": level]
    doubaoCopyScalarFields(from: row, into: &fields)
    if let used { fields["used"] = used.raw }
    if let total { fields["total"] = total.raw }
    if let remaining { fields["remaining"] = remaining.raw }
    if let percent { fields["percent"] = percent.raw }
    if let resetValue, let raw = doubaoRawText(resetValue) { fields["reset"] = raw }
    if let tier { fields["tier"] = tier }
    quotas.append(
        RawQuotaItem(
            id: StableSourceID.make(
                prefix: "arkcli",
                components: [path, level]
            ),
            originalName: path == "QuotaUsage" || path == "Result.QuotaUsage" ? level : "\(path).\(level)",
            used: used.map { SourceValue(value: $0.value, rawText: $0.raw) },
            remaining: resolvedRemaining.map { SourceValue(value: $0.value, rawText: $0.raw) },
            percentage: resolvedPercent.map {
                SourcePercentage(value: $0.value, rawText: $0.raw, meaning: .used)
            } ?? .missing(meaning: .used),
            resetsAt: doubaoDate(resetValue),
            sourceFields: fields
        )
    )
}

private func doubaoDecimal(_ value: Any?) -> DoubaoDecimalValue? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return DoubaoDecimalValue(value: decimal, raw: text)
    }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) {
        return DoubaoDecimalValue(value: number.decimalValue, raw: number.stringValue)
    }
    return nil
}

private func doubaoString(_ value: Any?) -> String? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) {
        return number.stringValue
    }
    return nil
}

private func doubaoRawText(_ value: Any?) -> String? {
    if let text = doubaoString(value) { return text }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) { return number.stringValue }
    if let flag = value as? Bool { return flag ? "true" : "false" }
    return nil
}

private func doubaoDate(_ value: Any?) -> Date? {
    if let text = doubaoString(value) {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return doubaoEpochDate(decimal)
    }
    guard let decimal = doubaoDecimal(value)?.value else { return nil }
    return doubaoEpochDate(decimal)
}

private func doubaoEpochDate(_ value: Decimal) -> Date? {
    let seconds = NSDecimalNumber(decimal: value).doubleValue
    guard seconds.isFinite, seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: abs(seconds) > 100_000_000_000 ? seconds / 1_000 : seconds)
}

private func doubaoCopyScalarFields(
    from object: [String: Any],
    prefix: String = "",
    into fields: inout [String: String]
) {
    for key in object.keys.sorted() {
        if let nested = object[key] as? [String: Any] {
            doubaoCopyScalarFields(from: nested, prefix: "\(prefix)\(key).", into: &fields)
        } else if let raw = doubaoRawText(object[key]) {
            fields["\(prefix)\(key)"] = raw
        }
    }
}

private func doubaoSchemaError(_ code: String) -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: code)
}

private func doubaoMalformedError(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
