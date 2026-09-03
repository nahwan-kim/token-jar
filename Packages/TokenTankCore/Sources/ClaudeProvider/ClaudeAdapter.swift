import Foundation
import TokenTankCore
import TokenTankDomain

public struct ClaudeAdapter: ProviderAdapter {
    public let id: ProviderID = .claude
    public let displayName: String = "Claude"
    public let defaultAbbreviation: String = "CLD"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "anthropic.organization-admin-api.usage-report.messages",
            name: "Anthropic organization Admin API",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: URL(string: "https://platform.claude.com/docs/en/manage-claude/usage-cost-api"),
            detail: "Official Anthropic organization API usage report. Values are labeled as organization API usage and never presented as Claude Pro/Max consumer subscription quota."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        do {
            _ = try await claudeCredential(in: context)
            return .available(sourceDescriptor)
        } catch let error as CollectionError {
            if error.kind == .appCredentialMissing {
                return .needsConfiguration(code: error.diagnosticCode)
            }
            return .unavailable(error)
        } catch {
            return .unavailable(
                CollectionError(kind: .keychainUnavailable, diagnosticCode: "claude.credentials.unavailable")
            )
        }
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let apiKey = try await claudeCredential(in: context)
        let now = await context.clock.now()
        let bounds = claudeMonthBounds(now)
        var page: String?
        var seenPages = Set<String>()
        var allBuckets: [Any] = []
        var cumulativeResponseBytes = 0

        for _ in 0..<100 {
            let url = try claudeUsageURL(bounds: bounds, page: page)
            let request = NetworkRequest(
                providerID: .claude,
                url: url,
                method: .get,
                headers: [
                    "x-api-key": apiKey,
                    "anthropic-version": "2023-06-01",
                    "Accept": "application/json",
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
                throw CollectionError(kind: .transientNetwork, diagnosticCode: "claude.network.failed")
            }
            try claudeValidate(response, now: now)
            cumulativeResponseBytes += response.body.count
            guard cumulativeResponseBytes <= 4 * 1024 * 1024 else {
                throw claudeMalformedError("claude.usage.aggregate-size-limit")
            }
            let root = try claudeObject(from: response.body)
            guard let buckets = root["data"] as? [Any] else {
                throw claudeSchemaError("claude.usage.data-missing")
            }
            allBuckets.append(contentsOf: buckets)

            let hasMore = try claudeHasMore(root["has_more"])
            guard hasMore else {
                let combined = try JSONSerialization.data(
                    withJSONObject: ["data": allBuckets],
                    options: [.sortedKeys]
                )
                return try Self.decodeSnapshot(from: combined, refreshedAt: now)
            }
            guard
                let nextPage = root["next_page"] as? String,
                !nextPage.isEmpty,
                seenPages.insert(nextPage).inserted
            else {
                throw claudeSchemaError("claude.usage.pagination-invalid")
            }
            page = nextPage
        }

        throw claudeSchemaError("claude.usage.pagination-limit")
    }

    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        let root = try claudeObject(from: data)
        guard let buckets = root["data"] as? [Any] else {
            throw claudeSchemaError("claude.usage.data-missing")
        }
        guard !buckets.isEmpty else {
            throw claudeMalformedError("claude.usage.empty-success")
        }

        var quotas: [RawQuotaItem] = []
        for (bucketIndex, bucketValue) in buckets.enumerated() {
            guard let bucket = bucketValue as? [String: Any] else {
                throw claudeSchemaError("claude.usage.bucket-invalid")
            }
            guard let results = bucket["results"] as? [Any] else {
                throw claudeSchemaError("claude.usage.results-missing")
            }
            let bucketStart = bucket["starting_at"] ?? bucket["startingAt"] ?? bucket["start"]
            let bucketEnd = bucket["ending_at"] ?? bucket["endingAt"] ?? bucket["end"]
            let bucketStartRaw = claudeRawText(bucketStart)
            let bucketEndRaw = claudeRawText(bucketEnd)

            for (resultIndex, resultValue) in results.enumerated() {
                guard let result = resultValue as? [String: Any] else {
                    throw claudeSchemaError("claude.usage.result-invalid")
                }
                let dimensionKeys = claudeDimensionKeys
                let dimensions = dimensionKeys.compactMap { key -> String? in
                    claudeRawText(result[key]).map { "\(key)=\($0)" }
                }
                let identity = [
                    bucketStartRaw ?? "bucket-\(bucketIndex)",
                    bucketEndRaw ?? "bucket-end-unknown",
                ] + (dimensions.isEmpty ? ["aggregate-\(resultIndex)"] : dimensions)
                let usageValues = claudeUsageValues(in: result)
                for usage in usageValues {
                    var fields: [String: String] = [
                        "category": usage.name,
                        "categoryPath": usage.path,
                    ]
                    if let bucketStartRaw { fields["starting_at"] = bucketStartRaw }
                    if let bucketEndRaw { fields["ending_at"] = bucketEndRaw }
                    for key in dimensionKeys {
                        if let raw = claudeRawText(result[key]) { fields[key] = raw }
                    }
                    fields[usage.name] = usage.raw

                    let itemID = StableSourceID.make(
                        prefix: "claude",
                        components: identity + [usage.path]
                    )
                    quotas.append(
                        RawQuotaItem(
                            id: itemID,
                            originalName: usage.name,
                            used: SourceValue(value: usage.value, rawText: usage.raw, unit: usage.unit),
                            remaining: nil,
                            percentage: .missing(meaning: .used),
                            resetsAt: nil,
                            sourceFields: fields
                        )
                    )
                }
            }
        }
        guard !quotas.isEmpty else {
            throw claudeMalformedError("claude.usage.no-usage-fields")
        }
        guard Set(quotas.map(\.id)).count == quotas.count else {
            throw claudeSchemaError("claude.usage.duplicate-identity")
        }

        return ProviderSnapshot(
            providerID: .claude,
            source: ClaudeAdapter().sourceDescriptor,
            quotas: quotas,
            refreshedAt: refreshedAt
        )
    }

    internal static func decode(data: Data, refreshedAt: Date) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, refreshedAt: refreshedAt)
    }
}

private struct ClaudeUsageValue {
    let name: String
    let path: String
    let value: Decimal
    let raw: String
    let unit: String?
}

private let claudeDimensionKeys = [
    "account_id",
    "api_key_id",
    "context_window",
    "inference_geo",
    "model",
    "service_account_id",
    "service_tier",
    "speed",
    "workspace_id",
]

private struct ClaudeMonthBounds {
    let start: String
    let end: String
}

private func claudeUsageURL(bounds: ClaudeMonthBounds, page: String?) throws -> URL {
    var components = URLComponents(
        string: "https://api.anthropic.com/v1/organizations/usage_report/messages"
    )!
    components.queryItems = [
        URLQueryItem(name: "starting_at", value: bounds.start),
        URLQueryItem(name: "ending_at", value: bounds.end),
        URLQueryItem(name: "bucket_width", value: "1d"),
    ]
    if let page {
        components.queryItems?.append(URLQueryItem(name: "page", value: page))
    }
    guard let url = components.url else {
        throw claudeSchemaError("claude.request.url-invalid")
    }
    return url
}

private func claudeHasMore(_ value: Any?) throws -> Bool {
    guard let value else {
        throw claudeSchemaError("claude.usage.has-more-missing")
    }
    guard let number = value as? NSNumber, JSONScalar.isBoolean(number) else {
        throw claudeSchemaError("claude.usage.has-more-invalid")
    }
    return number.boolValue
}

private func claudeCredential(in context: CollectionContext) async throws -> String {
    let id = CredentialID(providerID: .claude, name: "admin-api-key")
    do {
        guard let value = try await context.credentials.read(id),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CollectionError(kind: .appCredentialMissing, diagnosticCode: "claude.credentials.missing")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch let error as CollectionError {
        throw error
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw CollectionError(kind: .keychainUnavailable, diagnosticCode: "claude.credentials.unavailable")
    }
}

private func claudeMonthBounds(_ now: Date) -> ClaudeMonthBounds {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents([.year, .month], from: now)
    let startDate = calendar.date(from: components) ?? now
    let endDate = now
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return ClaudeMonthBounds(start: formatter.string(from: startDate), end: formatter.string(from: endDate))
}

private func claudeValidate(_ response: NetworkResponse, now: Date) throws {
    switch response.statusCode {
    case 200..<300:
        guard !response.body.isEmpty else {
            throw claudeMalformedError("claude.response.empty-body")
        }
    case 401:
        throw CollectionError(kind: .authenticationRejected, diagnosticCode: "claude.authentication.rejected")
    case 403:
        throw CollectionError(kind: .authenticationRevoked, diagnosticCode: "claude.authentication.revoked")
    case 429:
        throw CollectionError(
            kind: .rateLimited,
            diagnosticCode: "claude.rate-limited",
            retryAfter: claudeRetryAfter(response.header("Retry-After"), now: now)
        )
    case 408, 500...599:
        throw CollectionError(kind: .transientNetwork, diagnosticCode: "claude.server.transient")
    default:
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "claude.http.\(response.statusCode)")
    }
}

private func claudeRetryAfter(_ value: String?, now: Date) -> Date? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = TimeInterval(trimmed), seconds >= 0 {
        return now.addingTimeInterval(seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: trimmed)
}

private func claudeObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { throw claudeMalformedError("claude.response.empty-body") }
    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw claudeSchemaError("claude.response.object-required")
        }
        return dictionary
    } catch let error as CollectionError {
        throw error
    } catch {
        throw claudeMalformedError("claude.response.invalid-json")
    }
}

private func claudeUsageValues(in result: [String: Any]) -> [ClaudeUsageValue] {
    var values: [ClaudeUsageValue] = []
    for key in result.keys.sorted() where !claudeDimensionKeys.contains(key) {
        let path = key
        claudeCollectUsageValues(result[key], name: key, path: path, into: &values)
    }
    return values
}

private func claudeCollectUsageValues(
    _ value: Any?,
    name: String,
    path: String,
    into values: inout [ClaudeUsageValue]
) {
    if let number = claudeDecimal(value) {
        let lowerPath = path.lowercased()
        let unit: String?
        if lowerPath.contains("request") {
            unit = "requests"
        } else if lowerPath.contains("token") || lowerPath.contains("input") || lowerPath.contains("output") {
            unit = "tokens"
        } else {
            unit = nil
        }
        values.append(
            ClaudeUsageValue(
                name: name,
                path: path,
                value: number.value,
                raw: number.raw,
                unit: unit
            )
        )
        return
    }
    guard let object = value as? [String: Any] else { return }
    for key in object.keys.sorted() {
        let childPath = "\(path).\(key)"
        claudeCollectUsageValues(object[key], name: key, path: childPath, into: &values)
    }
}

private struct ClaudeDecimalValue {
    let value: Decimal
    let raw: String
}

private func claudeDecimal(_ value: Any?) -> ClaudeDecimalValue? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return ClaudeDecimalValue(value: decimal, raw: text)
    }
    guard let number = value as? NSNumber, !JSONScalar.isBoolean(number) else { return nil }
    return ClaudeDecimalValue(value: number.decimalValue, raw: number.stringValue)
}

private func claudeRawText(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) { return number.stringValue }
    return nil
}

private func claudeSchemaError(_ code: String) -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: code)
}

private func claudeMalformedError(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
