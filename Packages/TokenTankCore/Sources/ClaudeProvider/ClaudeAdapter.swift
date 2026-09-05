import Foundation
import TokenTankCore
import TokenTankDomain

public struct ClaudeAdapter: ProviderAdapter {
    public let id: ProviderID = .claude
    public let displayName: String = "Claude"
    public let defaultAbbreviation: String = "CLD"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "claude.code.local-usage-cache",
            name: "Claude Code local usage cache",
            kind: .localSession,
            credentialOwnership: .externalProvider,
            documentationURL: URL(string: "https://www.onorca.dev/docs/agents/usage-tracking"),
            detail: "Read-only Claude Code ~/.claude.json cachedUsageUtilization. This is the same local session and weekly usage Orca displays. Token Jar never reads Claude credentials, never calls the organization Admin API, and never presents invented quota."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        do {
            _ = try await claudeUsageCache(in: context)
            return .available(sourceDescriptor)
        } catch is CancellationError {
            return .unavailable(
                CollectionError(kind: .cancelled, diagnosticCode: "claude.usage-cache.cancelled")
            )
        } catch let error as CollectionError {
            return .unavailable(error)
        } catch {
            return .unavailable(
                CollectionError(kind: .sourceUnavailable, diagnosticCode: "claude.usage-cache.unavailable")
            )
        }
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let now = await context.clock.now()
        let data = try await claudeUsageCache(in: context)
        return try Self.decodeSnapshot(from: data, refreshedAt: now)
    }

    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        let root = try claudeObject(from: data)
        guard let cache = root["cachedUsageUtilization"] as? [String: Any] else {
            throw claudeSchemaError("claude.usage-cache.missing")
        }
        guard let utilization = cache["utilization"] as? [String: Any] else {
            throw claudeSchemaError("claude.usage-cache.utilization-missing")
        }

        var quotas: [RawQuotaItem] = []
        if let limits = utilization["limits"] as? [Any], !limits.isEmpty {
            for (index, value) in limits.enumerated() {
                try claudeAppendLimit(value, index: index, to: &quotas)
            }
        } else {
            for key in claudeWindowKeys {
                try claudeAppendWindow(utilization[key], name: key, to: &quotas)
            }
        }
        guard !quotas.isEmpty else {
            throw claudeMalformedError("claude.usage-cache.empty")
        }
        guard Set(quotas.map(\.id)).count == quotas.count else {
            throw claudeSchemaError("claude.usage-cache.duplicate-identity")
        }

        return ProviderSnapshot(
            providerID: .claude,
            source: ClaudeAdapter().sourceDescriptor,
            quotas: quotas,
            refreshedAt: refreshedAt,
            accountEmail: claudeAccountEmail(from: root)
        )
    }

    public static func decode(data: Data, refreshedAt: Date) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, refreshedAt: refreshedAt)
    }
}

let claudeUsageCacheRequest = ExternalFileRequest(
    providerID: .claude,
    relativePath: ".claude.json",
    maximumBytes: 32 * 1024 * 1024
)

private let claudeWindowKeys = [
    "five_hour",
    "seven_day",
    "seven_day_opus",
    "seven_day_sonnet",
]

private func claudeUsageCache(in context: CollectionContext) async throws -> Data {
    do {
        return try await context.externalSessions.read(claudeUsageCacheRequest)
    } catch let error as CollectionError {
        if error.kind == .externalSessionMissing {
            throw CollectionError(
                kind: .externalSessionMissing,
                diagnosticCode: "claude.usage-cache.missing"
            )
        }
        throw error
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "claude.usage-cache.unavailable")
    }
}

private func claudeAppendLimit(
    _ value: Any,
    index: Int,
    to quotas: inout [RawQuotaItem]
) throws {
    guard let limit = value as? [String: Any] else {
        throw claudeSchemaError("claude.usage-cache.limit-invalid")
    }
    guard let kind = claudeString(limit["kind"]), !kind.isEmpty else {
        throw claudeSchemaError("claude.usage-cache.limit-kind-missing")
    }
    guard let percent = claudeNonnegativeDecimal(limit["percent"]) else {
        throw claudeSchemaError("claude.usage-cache.limit-percent-missing")
    }
    let scopeName = claudeScopeName(limit["scope"])
    let originalName = scopeName.map { "\(kind).\($0)" } ?? kind
    var fields: [String: String] = [
        "kind": kind,
        "percent": percent.raw,
    ]
    if let group = claudeString(limit["group"]) { fields["group"] = group }
    if let resetRaw = claudeString(limit["resets_at"]) { fields["resets_at"] = resetRaw }
    if let scopeName { fields["scope"] = scopeName }
    quotas.append(
        claudeQuota(
            identity: ["limit", kind, scopeName ?? "\(index)"],
            originalName: originalName,
            percent: percent,
            resetsAt: claudeDate(limit["resets_at"]),
            fields: fields
        )
    )
}

private func claudeAppendWindow(
    _ value: Any?,
    name: String,
    to quotas: inout [RawQuotaItem]
) throws {
    guard let value, !(value is NSNull) else { return }
    guard let window = value as? [String: Any] else {
        throw claudeSchemaError("claude.usage-cache.window-invalid")
    }
    guard let percent = claudeNonnegativeDecimal(window["utilization"]) else {
        return
    }
    var fields: [String: String] = [
        "window": name,
        "utilization": percent.raw,
    ]
    if let resetRaw = claudeString(window["resets_at"]) { fields["resets_at"] = resetRaw }
    quotas.append(
        claudeQuota(
            identity: ["window", name],
            originalName: name,
            percent: percent,
            resetsAt: claudeDate(window["resets_at"]),
            fields: fields
        )
    )
}

private func claudeQuota(
    identity: [String],
    originalName: String,
    percent: ClaudeDecimalValue,
    resetsAt: Date?,
    fields: [String: String]
) -> RawQuotaItem {
    let remainingPercent = Decimal(100) - percent.value
    return RawQuotaItem(
        id: StableSourceID.make(prefix: "claude", components: identity),
        originalName: originalName,
        used: SourceValue(value: percent.value, rawText: percent.raw, unit: "%"),
        remaining: remainingPercent >= 0
            ? SourceValue(
                value: remainingPercent,
                rawText: NSDecimalNumber(decimal: remainingPercent).stringValue,
                unit: "%"
            )
            : nil,
        percentage: SourcePercentage(value: percent.value, rawText: percent.raw, meaning: .used),
        resetsAt: resetsAt,
        sourceFields: fields
    )
}

private func claudeAccountEmail(from root: [String: Any]) -> String? {
    guard let oauthAccount = root["oauthAccount"] as? [String: Any] else { return nil }
    return oauthAccount["emailAddress"] as? String
}

private func claudeScopeName(_ value: Any?) -> String? {
    guard let object = value as? [String: Any] else { return nil }
    if let model = object["model"] as? [String: Any] {
        return claudeString(model["display_name"]) ?? claudeString(model["id"])
    }
    return claudeString(object["display_name"]) ?? claudeString(object["surface"])
}

private struct ClaudeDecimalValue {
    let value: Decimal
    let raw: String
}

private func claudeNonnegativeDecimal(_ value: Any?) -> ClaudeDecimalValue? {
    let parsed: ClaudeDecimalValue?
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        parsed = ClaudeDecimalValue(value: decimal, raw: text)
    } else if let number = value as? NSNumber, !JSONScalar.isBoolean(number) {
        parsed = ClaudeDecimalValue(value: number.decimalValue, raw: number.stringValue)
    } else {
        return nil
    }
    guard parsed!.value >= 0 else { return nil }
    return parsed
}

private func claudeString(_ value: Any?) -> String? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) {
        return number.stringValue
    }
    return nil
}

private func claudeDate(_ value: Any?) -> Date? {
    guard let text = claudeString(value) else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text)
}

private func claudeObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { throw claudeMalformedError("claude.usage-cache.empty-body") }
    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw claudeSchemaError("claude.usage-cache.object-required")
        }
        return dictionary
    } catch let error as CollectionError {
        throw error
    } catch {
        throw claudeMalformedError("claude.usage-cache.invalid-json")
    }
}

private func claudeSchemaError(_ code: String) -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: code)
}

private func claudeMalformedError(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
