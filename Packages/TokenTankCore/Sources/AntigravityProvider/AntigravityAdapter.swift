import Foundation
import TokenTankCore
import TokenTankDomain

public struct AntigravityAdapter: ProviderAdapter {
    public let id: ProviderID = .antigravity
    public let displayName: String = "Antigravity"
    public let defaultAbbreviation: String = "AGY"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "antigravity.agy.usage",
            name: "Antigravity CLI usage",
            kind: .officialCLI,
            credentialOwnership: .externalProvider,
            documentationURL: URL(string: "https://antigravity.google"),
            detail: "Official Antigravity CLI agy --output-format json --log-file /dev/null -p /usage: the read-only usage command answers from the CLI's own Keychain sign-in without a model turn, with the Gemini and Claude/GPT 5-hour and weekly limits and the separate Gemini 4 Argon weekly limit. Token Jar starts only the allowlisted agy executable with those literal arguments, reads only the attributes of agy's Keychain item through /usr/bin/security, never its token, and sends no request of its own; agy renews its sign-in itself."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let data: Data
        do {
            data = try await context.antigravityUsage.readUsage()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError {
            throw error
        } catch {
            throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "antigravity.agy.read-failed")
        }
        return try Self.decodeSnapshot(from: data, refreshedAt: await context.clock.now())
    }

    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: .antigravity,
            source: AntigravityAdapter().sourceDescriptor,
            quotas: try decodeQuotas(from: data),
            refreshedAt: refreshedAt
        )
    }

    /// One quota per bucket: `<group>.<window>` such as `gemini.5h` or `3p.weekly`, in group
    /// order with the 5-hour window before the weekly one.
    static func decodeQuotas(from data: Data) throws -> [RawQuotaItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw antigravityMalformedError("antigravity.usage.invalid-json")
        }
        guard let groups = root["groups"] as? [Any] else {
            throw antigravitySchemaError("antigravity.usage.groups-missing")
        }
        var quotas: [RawQuotaItem] = []
        for groupValue in groups {
            guard let group = groupValue as? [String: Any],
                  let buckets = group["buckets"] as? [Any]
            else { throw antigravitySchemaError("antigravity.usage.group-invalid") }
            let groupName = antigravityString(group["name"])
            var groupQuotas: [RawQuotaItem] = []
            for bucketValue in buckets {
                guard let bucket = bucketValue as? [String: Any] else {
                    throw antigravitySchemaError("antigravity.usage.bucket-invalid")
                }
                groupQuotas.append(try quota(from: bucket, groupName: groupName))
            }
            quotas += groupQuotas.enumerated().sorted { lhs, rhs in
                let left = windowRank(lhs.element), right = windowRank(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
        }
        guard !quotas.isEmpty else {
            throw antigravityMalformedError("antigravity.usage.empty")
        }
        guard Set(quotas.map(\.id)).count == quotas.count else {
            throw antigravitySchemaError("antigravity.usage.duplicate-bucket")
        }
        return quotas
    }

    private static func quota(from bucket: [String: Any], groupName: String?) throws -> RawQuotaItem {
        guard let bucketID = antigravityIdentifier(bucket["id"]) else {
            throw antigravitySchemaError("antigravity.usage.bucket-id-invalid")
        }
        // An unknown window (a future "daily") is kept; a bucket without one is schema drift.
        guard let window = antigravityIdentifier(bucket["window"]) else {
            throw antigravitySchemaError("antigravity.usage.window-invalid")
        }
        let groupKey = bucketID.hasSuffix("-\(window)") && bucketID.count > window.count + 1
            ? String(bucketID.dropLast(window.count + 1))
            : bucketID
        var fields: [String: String] = ["bucketId": bucketID, "window": window]
        if let groupName {
            fields["group"] = groupName
            fields["antigravityGroup"] = groupLabel(groupName)
        }

        let percentage: SourcePercentage
        let remaining: SourceValue?
        let used: SourceValue?
        if let fractionValue = bucket["remaining_fraction"] {
            guard let fraction = antigravityDecimal(fractionValue), fraction >= 0, fraction <= 1 else {
                throw antigravitySchemaError("antigravity.usage.fraction-invalid")
            }
            let left = fraction * 100
            let raw = NSDecimalNumber(decimal: left).stringValue
            let usedDecimal = Decimal(100) - left
            percentage = SourcePercentage(value: left, rawText: raw, meaning: .remaining)
            remaining = SourceValue(value: left, rawText: raw, unit: "%")
            used = SourceValue(value: usedDecimal, rawText: NSDecimalNumber(decimal: usedDecimal).stringValue, unit: "%")
            fields["remainingFraction"] = NSDecimalNumber(decimal: fraction).stringValue
        } else {
            percentage = .missing(meaning: .remaining)
            remaining = nil
            used = nil
        }
        let resetsAt: Date?
        if let value = bucket["reset_time"], !(value is NSNull) {
            guard let raw = antigravityString(value), let date = antigravityDate(raw) else {
                throw antigravitySchemaError("antigravity.usage.reset-invalid")
            }
            fields["resetTime"] = raw
            resetsAt = date
        } else {
            resetsAt = nil
        }
        return RawQuotaItem(
            id: RawQuotaID(rawValue: bucketID),
            originalName: "\(groupKey).\(window)",
            used: used,
            remaining: remaining,
            percentage: percentage,
            resetsAt: resetsAt,
            sourceFields: fields
        )
    }

    /// A tile-sized group name: "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude/GPT".
    static func groupLabel(_ name: String) -> String {
        let suffix = " models"
        var label = name
        if label.lowercased().hasSuffix(suffix), label.count > suffix.count {
            label = String(label.dropLast(suffix.count))
        }
        return label.replacingOccurrences(of: " and ", with: "/")
    }

    private static func windowRank(_ quota: RawQuotaItem) -> Int {
        switch quota.sourceFields["window"] {
        case "5h": 0
        case "weekly": 1
        default: 2
        }
    }
}

private func antigravityString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 512,
          !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return trimmed
}

/// A bucket or window identifier such as `gemini-5h` or `weekly`.
private func antigravityIdentifier(_ value: Any?) -> String? {
    guard let raw = antigravityString(value), raw.count <= 64 else { return nil }
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    guard raw.allSatisfy(allowed.contains) else { return nil }
    return raw
}

private func antigravityDecimal(_ value: Any?) -> Decimal? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let double = number.doubleValue
    guard double.isFinite else { return nil }
    return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
}

private func antigravityDate(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: raw)
}

private func antigravitySchemaError(_ code: String) -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: code)
}

private func antigravityMalformedError(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
