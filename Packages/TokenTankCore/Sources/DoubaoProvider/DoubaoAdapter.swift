import CryptoKit
import Foundation
import TokenTankCore
import TokenTankDomain

public enum DoubaoSourceMode: String, CaseIterable, Codable, Sendable {
    case codingPlan = "coding-plan"
    case agentPlan = "agent-plan"

    fileprivate var action: String {
        switch self {
        case .codingPlan: "GetCodingPlanUsage"
        case .agentPlan: "GetAFPUsage"
        }
    }

    fileprivate var host: String {
        switch self {
        case .codingPlan: "open.volcengineapi.com"
        case .agentPlan: "ark.cn-beijing.volces.com"
        }
    }

    fileprivate var displayName: String {
        switch self {
        case .codingPlan: "Coding Plan"
        case .agentPlan: "Agent Plan"
        }
    }
}

public struct DoubaoAdapter: ProviderAdapter {
    public let id: ProviderID = .doubao
    public let displayName: String = "Doubao"
    public let defaultAbbreviation: String = "DB"
    public let mode: DoubaoSourceMode

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "volcano-openapi.\(mode.rawValue).usage",
            name: "Volcano OpenAPI \(mode.displayName)",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: URL(string: "https://api.volcengine.com/api-docs/view?action=\(mode.action)&serviceCode=ark&version=2024-01-01"),
            detail: "Official Volcano OpenAPI \(mode.displayName) usage only; plan modes are selected independently and are never merged."
        )
    }

    public init(mode: DoubaoSourceMode = .codingPlan) {
        self.mode = mode
    }

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        do {
            _ = try await doubaoCredentials(in: context)
            return .available(sourceDescriptor)
        } catch let error as CollectionError {
            if error.kind == .appCredentialMissing {
                return .needsConfiguration(code: error.diagnosticCode)
            }
            return .unavailable(error)
        } catch {
            return .unavailable(
                CollectionError(kind: .keychainUnavailable, diagnosticCode: "doubao.credentials.unavailable")
            )
        }
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let credentials = try await doubaoCredentials(in: context)
        let now = await context.clock.now()
        let body = Data("{}".utf8)
        let request = try Self.signedRequest(
            mode: mode,
            accessKeyID: credentials.accessKeyID,
            secretAccessKey: credentials.secretAccessKey,
            date: now,
            body: body
        )
        let response: NetworkResponse
        do {
            response = try await context.network.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError {
            throw error
        } catch {
            throw CollectionError(kind: .transientNetwork, diagnosticCode: "doubao.network.failed")
        }
        try doubaoValidate(response, now: now)
        return try Self.decodeSnapshot(from: response.body, mode: mode, refreshedAt: now)
    }

    public static func decodeSnapshot(
        from data: Data,
        mode: DoubaoSourceMode,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        let root = try doubaoObject(from: data)
        var quotas: [RawQuotaItem] = []

        if let quotaUsageValue = root["QuotaUsage"] ?? root["quotaUsage"] ?? root["quota_usage"] {
            guard let quotaUsage = quotaUsageValue as? [Any] else {
                throw doubaoSchemaError("doubao.quota-usage.invalid")
            }
            try appendQuotaUsage(quotaUsage, mode: mode, to: &quotas)
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
                try appendQuotaUsage(quotaUsage, mode: mode, to: &quotas)
            } else {
                try appendResultPeriods(result, mode: mode, to: &quotas)
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
            source: DoubaoAdapter(mode: mode).sourceDescriptor,
            quotas: quotas,
            refreshedAt: refreshedAt
        )
    }

    internal static func decode(data: Data, mode: DoubaoSourceMode, refreshedAt: Date) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, mode: mode, refreshedAt: refreshedAt)
    }

    internal static func signedRequest(
        mode: DoubaoSourceMode,
        accessKeyID: String,
        secretAccessKey: String,
        date: Date,
        body: Data = Data("{}".utf8)
    ) throws -> NetworkRequest {
        let host = mode.host
        let queryItems = [
            URLQueryItem(name: "Action", value: mode.action),
            URLQueryItem(name: "Version", value: "2024-01-01")
        ]
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/"
        components.queryItems = queryItems
        guard let url = components.url else {
            throw doubaoSchemaError("doubao.request.url-invalid")
        }

        let xDate = doubaoXDate(date)
        let shortDate = String(xDate.prefix(8))
        let payloadHash = doubaoSHA256Hex(body)
        let canonicalQuery = doubaoCanonicalQuery(queryItems)
        let contentType = "application/json"
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders =
            "content-type:\(contentType)\n" +
            "host:\(host)\n" +
            "x-content-sha256:\(payloadHash)\n" +
            "x-date:\(xDate)\n"
        let canonicalRequest =
            "POST\n" +
            "/\n" +
            "\(canonicalQuery)\n" +
            canonicalHeaders +
            "\n" +
            "\(signedHeaders)\n" +
            payloadHash
        let credentialScope = "\(shortDate)/cn-beijing/ark/request"
        let stringToSign =
            "HMAC-SHA256\n" +
            "\(xDate)\n" +
            "\(credentialScope)\n" +
            doubaoSHA256Hex(Data(canonicalRequest.utf8))
        let signingKey = doubaoSigningKey(
            secretAccessKey: secretAccessKey,
            date: shortDate,
            region: "cn-beijing",
            service: "ark"
        )
        let signature = doubaoHMACHex(key: signingKey, message: stringToSign)
        let authorization =
            "HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), " +
            "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        return NetworkRequest(
            providerID: .doubao,
            url: url,
            method: .post,
            headers: [
                "Content-Type": contentType,
                "Host": host,
                "X-Date": xDate,
                "X-Content-Sha256": payloadHash,
                "Authorization": authorization
            ],
            body: body
        )
    }
}

private struct DoubaoCredentials {
    let accessKeyID: String
    let secretAccessKey: String
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
    return DoubaoDecimalValue(
        value: value,
        raw: NSDecimalNumber(decimal: value).stringValue
    )
}

private func doubaoDerivedPercentage(
    total: DoubaoDecimalValue?,
    used: DoubaoDecimalValue?
) -> DoubaoDecimalValue? {
    guard let total, let used, total.value > 0 else { return nil }
    let value = (used.value / total.value) * Decimal(100)
    return DoubaoDecimalValue(
        value: value,
        raw: NSDecimalNumber(decimal: value).stringValue
    )
}

private func doubaoCredentials(in context: CollectionContext) async throws -> DoubaoCredentials {
    let accessKeyID = CredentialID(providerID: .doubao, name: "access-key-id")
    let secretAccessKey = CredentialID(providerID: .doubao, name: "secret-access-key")
    do {
        guard let access = try await context.credentials.read(accessKeyID),
              !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let secret = try await context.credentials.read(secretAccessKey),
              !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CollectionError(kind: .appCredentialMissing, diagnosticCode: "doubao.credentials.missing")
        }
        return DoubaoCredentials(
            accessKeyID: access.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    } catch let error as CollectionError {
        throw error
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw CollectionError(kind: .keychainUnavailable, diagnosticCode: "doubao.credentials.unavailable")
    }
}

private func doubaoValidate(_ response: NetworkResponse, now: Date) throws {
    switch response.statusCode {
    case 200..<300:
        guard !response.body.isEmpty else { throw doubaoMalformedError("doubao.response.empty-body") }
    case 401:
        throw CollectionError(kind: .authenticationRejected, diagnosticCode: "doubao.authentication.rejected")
    case 403:
        throw CollectionError(kind: .authenticationRevoked, diagnosticCode: "doubao.authentication.revoked")
    case 429:
        throw CollectionError(
            kind: .rateLimited,
            diagnosticCode: "doubao.rate-limited",
            retryAfter: doubaoRetryAfter(response.header("Retry-After"), now: now)
        )
    case 408, 500...599:
        throw CollectionError(kind: .transientNetwork, diagnosticCode: "doubao.server.transient")
    default:
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "doubao.http.\(response.statusCode)")
    }
}

private func doubaoRetryAfter(_ value: String?, now: Date) -> Date? {
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

private func appendQuotaUsage(
    _ rows: [Any],
    mode: DoubaoSourceMode,
    to quotas: inout [RawQuotaItem]
) throws {
    for (index, value) in rows.enumerated() {
        guard let row = value as? [String: Any] else {
            throw doubaoSchemaError("doubao.quota-usage.row-invalid")
        }
        let level = doubaoString(row["Level"] ?? row["level"] ?? row["Name"] ?? row["name"])
            ?? "QuotaUsage[\(index)]"
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
        guard used != nil || total != nil || remaining != nil || percent != nil || resetValue != nil else {
            throw doubaoSchemaError("doubao.quota-usage.values-missing")
        }
        var fields: [String: String] = [
            "mode": mode.rawValue,
            "level": level
        ]
        doubaoCopyScalarFields(from: row, into: &fields)
        if let used { fields["used"] = used.raw }
        if let total { fields["total"] = total.raw }
        if let remaining { fields["remaining"] = remaining.raw }
        if let percent { fields["percent"] = percent.raw }
        if let resetValue, let raw = doubaoRawText(resetValue) { fields["reset"] = raw }
        quotas.append(
            RawQuotaItem(
                id: StableSourceID.make(
                    prefix: mode.rawValue,
                    components: [
                        level,
                        doubaoRawText(resetValue) ?? "row-\(index)",
                    ]
                ),
                originalName: level,
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
}

private func appendResultPeriods(
    _ result: [String: Any],
    mode: DoubaoSourceMode,
    to quotas: inout [RawQuotaItem]
) throws {
    for key in result.keys.sorted() {
        guard let period = result[key] as? [String: Any] else { continue }
        let used = doubaoDecimal(period["Used"] ?? period["used"])
        let total = doubaoDecimal(period["Quota"] ?? period["quota"] ?? period["Total"] ?? period["total"])
        let remaining = doubaoDecimal(period["Remaining"] ?? period["remaining"])
        let percent = doubaoDecimal(period["Percent"] ?? period["percent"] ?? period["Percentage"] ?? period["percentage"])
        let resolvedRemaining = remaining ?? doubaoDerivedRemaining(total: total, used: used)
        let resolvedPercent = percent ?? doubaoDerivedPercentage(total: total, used: used)
        let resetValue = period["ResetTime"]
            ?? period["resetTime"]
            ?? period["ResetTimestamp"]
            ?? period["resetTimestamp"]
            ?? period["resetsAt"]
        guard used != nil || total != nil || remaining != nil || percent != nil || resetValue != nil else {
            continue
        }
        var fields: [String: String] = [
            "mode": mode.rawValue,
            "period": key
        ]
        doubaoCopyScalarFields(from: period, into: &fields)
        if let used { fields["used"] = used.raw }
        if let total { fields["total"] = total.raw }
        if let remaining { fields["remaining"] = remaining.raw }
        if let percent { fields["percent"] = percent.raw }
        if let resetValue, let raw = doubaoRawText(resetValue) { fields["reset"] = raw }
        quotas.append(
            RawQuotaItem(
                id: RawQuotaID(rawValue: "\(mode.rawValue).\(key)"),
                originalName: key,
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
}

private func doubaoDecimal(_ value: Any?) -> DoubaoDecimalValue? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return DoubaoDecimalValue(value: decimal, raw: text)
    }
    guard let number = value as? NSNumber, !JSONScalar.isBoolean(number) else { return nil }
    return DoubaoDecimalValue(value: number.decimalValue, raw: number.stringValue)
}

private func doubaoRawText(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) { return number.stringValue }
    return nil
}

private func doubaoString(_ value: Any?) -> String? {
    guard let raw = doubaoRawText(value) else { return nil }
    return raw.isEmpty ? nil : raw
}

private func doubaoDate(_ value: Any?) -> Date? {
    if let text = value as? String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return doubaoEpochDate(decimal)
    }
    guard let decimal = doubaoDecimal(value)?.value else { return nil }
    return doubaoEpochDate(decimal)
}

private func doubaoEpochDate(_ value: Decimal) -> Date? {
    let seconds = NSDecimalNumber(decimal: value).doubleValue
    guard seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: abs(seconds) > 100_000_000_000 ? seconds / 1_000 : seconds)
}

private func doubaoCopyScalarFields(from object: [String: Any], into fields: inout [String: String]) {
    for key in object.keys.sorted() {
        guard let raw = doubaoRawText(object[key]) else { continue }
        fields[key] = raw
    }
}

private func doubaoCanonicalQuery(_ items: [URLQueryItem]) -> String {
    items
        .sorted {
            if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
            return $0.name < $1.name
        }
        .map { "\(doubaoPercentEncode($0.name))=\(doubaoPercentEncode($0.value ?? ""))" }
        .joined(separator: "&")
}

private func doubaoPercentEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func doubaoXDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
}

private func doubaoSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func doubaoHMAC(_ key: Data, _ message: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
}

private func doubaoHMACHex(key: Data, message: String) -> String {
    doubaoHMAC(key, message).map { String(format: "%02x", $0) }.joined()
}

private func doubaoSigningKey(
    secretAccessKey: String,
    date: String,
    region: String,
    service: String
) -> Data {
    let key = Data(secretAccessKey.utf8)
    let dateKey = doubaoHMAC(key, date)
    let regionKey = doubaoHMAC(dateKey, region)
    let serviceKey = doubaoHMAC(regionKey, service)
    return doubaoHMAC(serviceKey, "request")
}

private func doubaoSchemaError(_ code: String) -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: code)
}

private func doubaoMalformedError(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
