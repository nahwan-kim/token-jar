import Foundation
import TokenTankCore
import TokenTankDomain

public struct GrokAdapter: ProviderAdapter {
    public let id: ProviderID = .grok
    public let displayName: String = "Grok"
    public let defaultAbbreviation: String = "GRK"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "xai.management-api.prepaid-balance",
            name: "xAI Management API prepaid balance",
            kind: .officialAPI,
            credentialOwnership: .tokenTank,
            documentationURL: URL(string: "https://docs.x.ai/developers/management-api-guide"),
            detail: "Official xAI developer prepaid balance. This source is never presented as consumer SuperGrok subscription quota."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        do {
            _ = try await grokCredentials(in: context)
            return .available(sourceDescriptor)
        } catch let error as CollectionError {
            if error.kind == .appCredentialMissing {
                return .needsConfiguration(code: error.diagnosticCode)
            }
            return .unavailable(error)
        } catch {
            return .unavailable(
                CollectionError(kind: .keychainUnavailable, diagnosticCode: "grok.credentials.unavailable")
            )
        }
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let credentials = try await grokCredentials(in: context)
        let now = await context.clock.now()
        guard let url = URL(string: "https://management-api.x.ai/v1/billing/teams/\(credentials.teamID)/prepaid/balance") else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "grok.request.url-invalid")
        }

        let request = NetworkRequest(
            providerID: .grok,
            url: url,
            method: .get,
            headers: [
                "Authorization": "Bearer \(credentials.apiKey)",
                "Accept": "application/json"
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
            throw CollectionError(kind: .transientNetwork, diagnosticCode: "grok.network.failed")
        }
        try grokValidate(response, now: now)
        return try Self.decodeSnapshot(from: response.body, refreshedAt: now)
    }

    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        let root = try grokObject(from: data)
        let (balanceKey, balanceValue): (String, Any?)
        if let total = root["total"] as? [String: Any], total["val"] != nil {
            balanceKey = "total.val"
            balanceValue = total["val"]
        } else if root["balance"] != nil {
            balanceKey = "balance"
            balanceValue = root["balance"]
        } else if root["prepaid_balance"] != nil {
            balanceKey = "prepaid_balance"
            balanceValue = root["prepaid_balance"]
        } else if root["prepaidBalance"] != nil {
            balanceKey = "prepaidBalance"
            balanceValue = root["prepaidBalance"]
        } else {
            throw grokSchemaError("grok.balance.missing")
        }
        guard let balance = grokDecimal(balanceValue) else {
            throw grokSchemaError("grok.balance.invalid")
        }

        var fields: [String: String] = ["balanceField": balanceKey, balanceKey: balance.raw]
        grokCopyScalarFields(from: root, into: &fields)
        if let total = root["total"] as? [String: Any] {
            grokCopyScalarFields(from: total, prefix: "total.", into: &fields)
        }
        let unit = grokString(root["currency"])
            ?? grokString(root["unit"])
            ?? (balanceKey == "total.val" ? "USD cents" : nil)
        let resetValue = root["resetsAt"]
            ?? root["resetAt"]
            ?? root["reset_at"]
            ?? root["expiresAt"]
            ?? root["expires_at"]
        if let resetValue, let raw = grokRawText(resetValue) {
            fields["resetSource"] = raw
        }

        var quotas: [RawQuotaItem] = [
            RawQuotaItem(
                id: RawQuotaID(rawValue: "prepaid-balance"),
                originalName: balanceKey,
                used: nil,
                remaining: SourceValue(value: balance.value, rawText: balance.raw, unit: unit),
                percentage: .missing(meaning: .remaining),
                resetsAt: grokDate(resetValue),
                sourceFields: fields
            )
        ]
        guard let changes = root["changes"] as? [Any] else {
            throw grokSchemaError("grok.balance-changes.missing-or-invalid")
        }
        for value in changes {
            guard let change = value as? [String: Any] else {
                throw grokSchemaError("grok.balance-change.invalid")
            }
            guard
                let amountObject = change["amount"] as? [String: Any],
                let amount = grokDecimal(amountObject["val"])
            else {
                throw grokSchemaError("grok.balance-change.amount-invalid")
            }
            guard let changeName = grokString(change["changeOrigin"])
                ?? grokString(change["change_origin"])
            else {
                throw grokSchemaError("grok.balance-change.origin-missing")
            }
            guard grokString(change["createTime"] ?? change["create_time"] ?? change["createTs"]) != nil else {
                throw grokSchemaError("grok.balance-change.time-missing")
            }
            var changeFields: [String: String] = [:]
            grokCopyScalarFields(from: change, into: &changeFields)
            quotas.append(
                RawQuotaItem(
                    id: StableSourceID.make(
                        prefix: "grok-change",
                        components: changeFields.keys.sorted().map {
                            "\($0)=\(changeFields[$0] ?? "")"
                        }
                    ),
                    originalName: changeName,
                    used: SourceValue(value: amount.value, rawText: amount.raw, unit: unit),
                    remaining: nil,
                    percentage: .missing(meaning: .used),
                    resetsAt: nil,
                    sourceFields: changeFields
                )
            )
        }
        guard Set(quotas.map(\.id)).count == quotas.count else {
            throw grokSchemaError("grok.balance-change.duplicate-identity")
        }
        return ProviderSnapshot(
            providerID: .grok,
            source: GrokAdapter().sourceDescriptor,
            quotas: quotas,
            refreshedAt: refreshedAt
        )
    }

    internal static func decode(data: Data, refreshedAt: Date) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, refreshedAt: refreshedAt)
    }
}

private struct GrokCredentials {
    let apiKey: String
    let teamID: String
}

private struct GrokDecimalValue {
    let value: Decimal
    let raw: String
}

private func grokCredentials(in context: CollectionContext) async throws -> GrokCredentials {
    let keyID = CredentialID(providerID: .grok, name: "management-api-key")
    let teamID = CredentialID(providerID: .grok, name: "team-id")
    do {
        guard let apiKey = try await context.credentials.read(keyID),
              let team = try await context.credentials.read(teamID)
        else {
            throw CollectionError(kind: .appCredentialMissing, diagnosticCode: "grok.credentials.missing")
        }
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTeamID = team.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty, !normalizedTeamID.isEmpty else {
            throw CollectionError(kind: .appCredentialMissing, diagnosticCode: "grok.credentials.missing")
        }
        guard grokTeamIDIsAllowed(normalizedTeamID) else {
            throw CollectionError(kind: .malformedResponse, diagnosticCode: "grok.team-id.invalid")
        }
        return GrokCredentials(apiKey: normalizedAPIKey, teamID: normalizedTeamID)
    } catch let error as CollectionError {
        throw error
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw CollectionError(kind: .keychainUnavailable, diagnosticCode: "grok.credentials.unavailable")
    }
}

private func grokTeamIDIsAllowed(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 256 else { return false }
    return bytes.allSatisfy { byte in
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x2D
            || byte == 0x5F
    }
}

private func grokValidate(_ response: NetworkResponse, now: Date) throws {
    switch response.statusCode {
    case 200..<300:
        guard !response.body.isEmpty else { throw grokMalformedError("grok.response.empty-body") }
    case 401:
        throw CollectionError(kind: .authenticationRejected, diagnosticCode: "grok.authentication.rejected")
    case 403:
        throw CollectionError(kind: .authenticationRevoked, diagnosticCode: "grok.authentication.revoked")
    case 429:
        throw CollectionError(
            kind: .rateLimited,
            diagnosticCode: "grok.rate-limited",
            retryAfter: grokRetryAfter(response.header("Retry-After"), now: now)
        )
    case 408, 500...599:
        throw CollectionError(kind: .transientNetwork, diagnosticCode: "grok.server.transient")
    default:
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "grok.http.\(response.statusCode)")
    }
}

private func grokRetryAfter(_ value: String?, now: Date) -> Date? {
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

private func grokObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { throw grokMalformedError("grok.response.empty-body") }
    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw grokSchemaError("grok.response.object-required")
        }
        return dictionary
    } catch let error as CollectionError {
        throw error
    } catch {
        throw grokMalformedError("grok.response.invalid-json")
    }
}

private func grokDecimal(_ value: Any?) -> GrokDecimalValue? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return GrokDecimalValue(value: decimal, raw: text)
    }
    guard let number = value as? NSNumber, !JSONScalar.isBoolean(number) else { return nil }
    return GrokDecimalValue(value: number.decimalValue, raw: number.stringValue)
}

private func grokRawText(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) { return number.stringValue }
    return nil
}

private func grokString(_ value: Any?) -> String? {
    guard let raw = grokRawText(value) else { return nil }
    return raw.isEmpty ? nil : raw
}

private func grokDate(_ value: Any?) -> Date? {
    if let text = value as? String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return grokEpochDate(decimal)
    }
    guard let decimal = grokDecimal(value)?.value else { return nil }
    return grokEpochDate(decimal)
}

private func grokEpochDate(_ value: Decimal) -> Date? {
    let seconds = NSDecimalNumber(decimal: value).doubleValue
    guard seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: abs(seconds) > 100_000_000_000 ? seconds / 1_000 : seconds)
}

private func grokCopyScalarFields(from object: [String: Any], into fields: inout [String: String]) {
    grokCopyScalarFields(from: object, prefix: "", into: &fields)
}
private func grokCopyScalarFields(
    from object: [String: Any],
    prefix: String,
    into fields: inout [String: String]
) {
    for key in object.keys.sorted() {
        if let nested = object[key] as? [String: Any] {
            grokCopyScalarFields(
                from: nested,
                prefix: "\(prefix)\(key).",
                into: &fields
            )
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
