import Foundation
import TokenTankCore
import TokenTankDomain

public struct CursorAdapter: ProviderAdapter {
    public let id: ProviderID = .cursor
    public let displayName: String = "Cursor"
    public let defaultAbbreviation: String = "CUR"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "cursor.app-session.usage-summary",
            name: "Cursor.app owner session usage summary",
            kind: .localSession,
            credentialOwnership: .externalProvider,
            documentationURL: URL(string: "https://prod.cursor.com/help/models-and-usage/usage-limits"),
            detail: "Read-only Cursor.app owner session and usage summary. The local SQLite layout and endpoint are undocumented; schema changes fail closed, and raw credentials are never persisted, copied, refreshed, or exposed."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        do {
            let now = await context.clock.now()
            _ = try await cursorSession(in: context, now: now)
            return .available(sourceDescriptor)
        } catch is CancellationError {
            return .unavailable(
                CollectionError(kind: .cancelled, diagnosticCode: "cursor.app-session.cancelled")
            )
        } catch let error as CollectionError {
            if error.kind == .externalSessionMissing {
                return .needsConfiguration(code: error.diagnosticCode)
            }
            return .unavailable(error)
        } catch {
            return .unavailable(
                CollectionError(kind: .sourceUnavailable, diagnosticCode: "cursor.app-session.unavailable")
            )
        }
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let now = await context.clock.now()
        let session = try await cursorSession(in: context, now: now)
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
            throw cursorSchemaError("cursor.usage-summary.request-url-invalid")
        }
        let request = NetworkRequest(
            providerID: .cursor,
            url: url,
            method: .get,
            headers: [
                "Accept": "application/json",
                "Cookie": "WorkosCursorSessionToken=\(session.userID)%3A%3A\(session.token)",
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
            throw CollectionError(kind: .transientNetwork, diagnosticCode: "cursor.usage-summary.network-failed")
        }
        try cursorValidate(response, now: now)
        return try Self.decodeSnapshot(
            from: response.body,
            subject: session.identity,
            refreshedAt: now,
            accountEmail: session.accountEmail
        )
    }

    /// Decodes a usage-summary response without a session context. Fetches use the
    /// subject from the structurally checked local session token after the Provider
    /// endpoint authenticates that token; fixtures use a non-sensitive synthetic subject.
    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, subject: "fixture-subject", refreshedAt: refreshedAt)
    }

    /// Decodes a response with the normalized JWT subject used to derive opaque IDs.
    public static func decodeSnapshot(
        from data: Data,
        subject: String,
        refreshedAt: Date = Date(),
        accountEmail: String? = nil
    ) throws -> ProviderSnapshot {
        let normalizedSubject = try cursorNormalizedSubject(subject)
        let root = try cursorObject(from: data)
        let metadata = try cursorRootMetadata(from: root)
        var quotas: [RawQuotaItem] = []
        var identities: Set<RawQuotaID> = []

        if let value = root["individualUsage"], !(value is NSNull) {
            guard let individual = value as? [String: Any] else {
                throw cursorSchemaError("cursor.usage-summary.individual-usage-invalid")
            }
            try cursorAppendBlock(
                from: individual["plan"],
                path: "individualUsage.plan",
                subject: normalizedSubject,
                metadata: metadata,
                plan: true,
                to: &quotas,
                identities: &identities
            )
            try cursorAppendBlock(
                from: individual["onDemand"],
                path: "individualUsage.onDemand",
                subject: normalizedSubject,
                metadata: metadata,
                plan: false,
                to: &quotas,
                identities: &identities
            )
            try cursorAppendBlock(
                from: individual["overall"],
                path: "individualUsage.overall",
                subject: normalizedSubject,
                metadata: metadata,
                plan: false,
                to: &quotas,
                identities: &identities
            )
        } else if root["individualUsage"] != nil {
            // A JSON null usage container is the same as an omitted source block.
        }

        if let value = root["teamUsage"], !(value is NSNull) {
            guard let team = value as? [String: Any] else {
                throw cursorSchemaError("cursor.usage-summary.team-usage-invalid")
            }
            try cursorAppendBlock(
                from: team["onDemand"],
                path: "teamUsage.onDemand",
                subject: normalizedSubject,
                metadata: metadata,
                plan: false,
                to: &quotas,
                identities: &identities
            )
            try cursorAppendBlock(
                from: team["pooled"],
                path: "teamUsage.pooled",
                subject: normalizedSubject,
                metadata: metadata,
                plan: false,
                to: &quotas,
                identities: &identities
            )
        } else if root["teamUsage"] != nil {
            // A JSON null usage container is the same as an omitted source block.
        }

        guard !quotas.isEmpty else {
            throw cursorMalformedError("cursor.usage-summary.empty-success")
        }
        return ProviderSnapshot(
            providerID: .cursor,
            source: CursorAdapter().sourceDescriptor,
            quotas: quotas,
            refreshedAt: refreshedAt,
            accountEmail: accountEmail
        )
    }

    internal static func decode(data: Data, refreshedAt: Date) throws -> ProviderSnapshot {
        try decodeSnapshot(from: data, refreshedAt: refreshedAt)
    }
}

private struct CursorSession {
    let userID: String
    let identity: String
    let token: String
    let accountEmail: String?
}

private struct CursorDecimalValue {
    let value: Decimal
    let raw: String
}

private struct CursorRootMetadata {
    let fields: [String: String]
    let resetDate: Date?
}

private let cursorSQLiteRequest = ExternalFileRequest(
    providerID: .cursor,
    root: .home,
    relativePath: "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
    maximumBytes: 64 * 1024 * 1024
)

private let cursorSQLiteKey = "cursorAuth/accessToken"
private let cursorSQLiteEmailKey = "cursorAuth/cachedEmail"
private let cursorSourceID = "cursor.app-session.usage-summary"

private func cursorSession(
    in context: CollectionContext,
    now: Date
) async throws -> CursorSession {
    let values: [String: String]
    do {
        values = try await context.sqlite.values(
            in: cursorSQLiteRequest,
            table: "ItemTable",
            keyColumn: "key",
            valueColumn: "value",
            keys: [cursorSQLiteKey, cursorSQLiteEmailKey]
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as CollectionError {
        if error.kind == .externalSessionMissing {
            throw cursorSessionMissing()
        }
        throw error
    } catch {
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "cursor.app-session.read-failed")
    }

    guard let token = values[cursorSQLiteKey], !token.isEmpty else {
        throw cursorSessionMissing()
    }
    return try cursorParseJWT(token, now: now, accountEmail: values[cursorSQLiteEmailKey])
}

private func cursorParseJWT(
    _ token: String,
    now: Date,
    accountEmail: String? = nil
) throws -> CursorSession {
    guard token.utf8.count <= 32 * 1024 else {
        throw cursorJWTMalformed()
    }
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3,
          segments.allSatisfy({ cursorBase64URLData(from: $0) != nil }),
          let payloadData = cursorBase64URLData(from: segments[1])
    else {
        throw cursorJWTMalformed()
    }

    let payloadObject: Any
    do {
        payloadObject = try JSONSerialization.jsonObject(with: payloadData, options: [])
    } catch {
        throw cursorJWTMalformed()
    }
    guard let payload = payloadObject as? [String: Any],
          let subjectValue = payload["sub"],
          let subject = subjectValue as? String,
          let expiryValue = payload["exp"],
          let expiryNumber = expiryValue as? NSNumber,
          !JSONScalar.isBoolean(expiryNumber)
    else {
        throw cursorJWTMalformed()
    }

    let userID = try cursorUserID(subject)
    let expiryDecimal = expiryNumber.decimalValue
    guard expiryDecimal >= 0 else { throw cursorJWTMalformed() }
    let expirySeconds = NSDecimalNumber(decimal: expiryDecimal).doubleValue
    guard expirySeconds.isFinite else { throw cursorJWTMalformed() }
    let expiry = Date(timeIntervalSince1970: expirySeconds)
    guard expiry.timeIntervalSince1970 > now.timeIntervalSince1970 + 60 else {
        throw CollectionError(kind: .authenticationRevoked, diagnosticCode: "cursor.app-session.expired")
    }
    return CursorSession(
        userID: userID,
        identity: userID.lowercased(),
        token: token,
        accountEmail: accountEmail
    )
}

private func cursorBase64URLData(from segment: Substring) -> Data? {
    let value = String(segment)
    guard !value.isEmpty,
          value.utf8.allSatisfy({ byte in
              (byte >= 65 && byte <= 90)
                  || (byte >= 97 && byte <= 122)
                  || (byte >= 48 && byte <= 57)
                  || byte == 45
                  || byte == 95
          })
    else { return nil }
    let remainder = value.utf8.count % 4
    guard remainder != 1 else { return nil }
    var standard = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    standard += String(repeating: "=", count: (4 - remainder) % 4)
    guard let data = Data(base64Encoded: standard) else { return nil }
    let canonical = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    guard canonical == value else { return nil }
    return data
}

private func cursorUserID(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= 1_024,
          let last = trimmed.split(separator: "|", omittingEmptySubsequences: true).last
    else {
        throw cursorJWTMalformed()
    }
    let userID = String(last)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard !userID.isEmpty,
          userID.utf8.count <= 256,
          userID.unicodeScalars.allSatisfy(allowed.contains)
    else {
        throw cursorJWTMalformed()
    }
    return userID
}

private func cursorNormalizedSubject(_ value: String) throws -> String {
    try cursorUserID(value).lowercased()
}

private func cursorRootMetadata(from root: [String: Any]) throws -> CursorRootMetadata {
    let allowedKeys: Set<String> = [
        "billingCycleStart",
        "billingCycleEnd",
        "membershipType",
        "limitType",
        "isUnlimited",
        "autoModelSelectedDisplayMessage",
        "namedModelSelectedDisplayMessage",
        "individualUsage",
        "teamUsage",
    ]
    guard Set(root.keys).isSubset(of: allowedKeys) else {
        throw cursorSchemaError("cursor.usage-summary.root.unknown-fields")
    }

    var fields: [String: String] = ["source": cursorSourceID]
    var cycleStart: Date?
    var resetDate: Date?

    for key in ["billingCycleStart", "billingCycleEnd"] {
        guard let value = root[key], !(value is NSNull) else { continue }
        guard let raw = cursorScalarRawText(value), let date = cursorCycleDate(value) else {
            throw cursorSchemaError("cursor.usage-summary.root.\(key)-invalid")
        }
        fields[key] = raw
        if key == "billingCycleStart" {
            cycleStart = date
        } else {
            resetDate = date
            fields["resetSource"] = raw
        }
    }
    if let cycleStart, let resetDate, resetDate <= cycleStart {
        throw cursorSchemaError("cursor.usage-summary.root.billing-cycle-invalid")
    }

    for key in [
        "membershipType",
        "limitType",
        "autoModelSelectedDisplayMessage",
        "namedModelSelectedDisplayMessage",
    ] {
        guard let value = root[key], !(value is NSNull) else { continue }
        guard let raw = value as? String else {
            throw cursorSchemaError("cursor.usage-summary.root.\(key)-invalid")
        }
        fields[key] = raw
    }
    if let value = root["isUnlimited"], !(value is NSNull) {
        guard let bool = cursorBoolean(value) else {
            throw cursorSchemaError("cursor.usage-summary.root.isUnlimited-invalid")
        }
        fields["isUnlimited"] = bool ? "true" : "false"
    }
    return CursorRootMetadata(fields: fields, resetDate: resetDate)
}

private func cursorAppendBlock(
    from value: Any?,
    path: String,
    subject: String,
    metadata: CursorRootMetadata,
    plan: Bool,
    to quotas: inout [RawQuotaItem],
    identities: inout Set<RawQuotaID>
) throws {
    guard let value, !(value is NSNull) else { return }
    guard let object = value as? [String: Any] else {
        throw cursorSchemaError("cursor.usage-summary.\(path)-invalid")
    }
    let allowedKeys: Set<String> = if plan {
        [
            "enabled",
            "used",
            "limit",
            "remaining",
            "breakdown",
            "autoPercentUsed",
            "apiPercentUsed",
            "totalPercentUsed",
        ]
    } else {
        ["enabled", "used", "limit", "remaining"]
    }
    guard Set(object.keys).isSubset(of: allowedKeys) else {
        throw cursorSchemaError("cursor.usage-summary.\(path).unknown-fields")
    }

    var fields = metadata.fields
    fields["usageBlock"] = path
    var numeric: [String: CursorDecimalValue] = [:]
    for key in ["used", "limit", "remaining"] + (plan ? ["autoPercentUsed", "apiPercentUsed", "totalPercentUsed"] : []) {
        guard let value = object[key], !(value is NSNull) else { continue }
        guard let parsed = cursorNonnegativeDecimal(value) else {
            throw cursorSchemaError("cursor.usage-summary.\(path).\(key)-invalid")
        }
        numeric[key] = parsed
        fields[key] = parsed.raw
    }
    if let value = object["enabled"], !(value is NSNull) {
        guard let enabled = cursorBoolean(value) else {
            throw cursorSchemaError("cursor.usage-summary.\(path).enabled-invalid")
        }
        fields["enabled"] = enabled ? "true" : "false"
    }

    var breakdownQuotas: [RawQuotaItem] = []
    let breakdown = try cursorBreakdown(
        from: plan ? object["breakdown"] : nil,
        planPath: path,
        subject: subject,
        metadataFields: fields,
        resetDate: metadata.resetDate,
        to: &breakdownQuotas,
        identities: &identities
    )
    let hasDirectQuota = numeric["used"] != nil
        || numeric["limit"] != nil
        || numeric["remaining"] != nil
        || !breakdown.isEmpty
        || numeric["autoPercentUsed"] != nil
        || numeric["apiPercentUsed"] != nil
        || numeric["totalPercentUsed"] != nil
    guard hasDirectQuota else {
        if object.isEmpty || Set(object.keys) == ["enabled"] { return }
        throw cursorSchemaError("cursor.usage-summary.\(path).quota-fields-missing")
    }

    var remaining = numeric["remaining"].map {
        SourceValue(value: $0.value, rawText: $0.raw, unit: "cents")
    }
    if remaining == nil,
       let used = numeric["used"],
       let limit = numeric["limit"]
    {
        let derived = limit.value - used.value
        guard derived >= 0 else {
            throw cursorSchemaError("cursor.usage-summary.\(path).remaining-negative")
        }
        let raw = cursorDecimalRaw(derived)
        remaining = SourceValue(value: derived, rawText: raw, unit: "cents")
        fields["derivedRemaining"] = raw
    }

    let blockPercentage: SourcePercentage
    if let explicit = numeric["totalPercentUsed"] {
        blockPercentage = SourcePercentage(value: explicit.value, rawText: explicit.raw, meaning: .used)
    } else if let used = numeric["used"], let limit = numeric["limit"], limit.value > 0 {
        let derived = (used.value / limit.value) * Decimal(100)
        let raw = cursorDecimalRaw(derived)
        fields["derivedPercentage"] = raw
        blockPercentage = SourcePercentage(value: derived, rawText: raw, meaning: .used)
    } else {
        blockPercentage = .missing(meaning: .used)
    }

    try cursorAppendQuota(
        subject: subject,
        path: path,
        originalName: path,
        used: numeric["used"].map {
            SourceValue(value: $0.value, rawText: $0.raw, unit: "cents")
        },
        remaining: remaining,
        percentage: blockPercentage,
        resetsAt: metadata.resetDate,
        sourceFields: fields,
        to: &quotas,
        identities: &identities
    )
    quotas.append(contentsOf: breakdownQuotas)

    if plan {
        for key in ["autoPercentUsed", "apiPercentUsed", "totalPercentUsed"] {
            guard let value = numeric[key] else { continue }
            var percentageFields = metadata.fields
            percentageFields["usageBlock"] = path
            percentageFields["percentage"] = value.raw
            percentageFields["percentageField"] = key
            try cursorAppendQuota(
                subject: subject,
                path: "\(path).\(key)",
                originalName: "\(path).\(key)",
                used: SourceValue(value: value.value, rawText: value.raw, unit: "%"),
                remaining: nil,
                percentage: SourcePercentage(value: value.value, rawText: value.raw, meaning: .used),
                resetsAt: metadata.resetDate,
                sourceFields: percentageFields,
                to: &quotas,
                identities: &identities
            )
        }
    }
}

private func cursorBreakdown(
    from value: Any?,
    planPath: String,
    subject: String,
    metadataFields: [String: String],
    resetDate: Date?,
    to quotas: inout [RawQuotaItem],
    identities: inout Set<RawQuotaID>
) throws -> [String] {
    guard let value, !(value is NSNull) else { return [] }
    guard let object = value as? [String: Any] else {
        throw cursorSchemaError("cursor.usage-summary.\(planPath).breakdown-invalid")
    }
    guard Set(object.keys).isSubset(of: ["included", "bonus", "total"]) else {
        throw cursorSchemaError("cursor.usage-summary.\(planPath).breakdown.unknown-fields")
    }
    var names: [String] = []
    for key in ["included", "bonus", "total"] {
        guard let rawValue = object[key], !(rawValue is NSNull) else { continue }
        guard let value = cursorNonnegativeDecimal(rawValue) else {
            throw cursorSchemaError("cursor.usage-summary.\(planPath).breakdown.\(key)-invalid")
        }
        names.append(key)
        var fields = metadataFields
        fields["breakdownField"] = key
        fields["value"] = value.raw
        fields["breakdown.\(key)"] = value.raw
        try cursorAppendQuota(
            subject: subject,
            path: "\(planPath).breakdown.\(key)",
            originalName: "\(planPath).breakdown.\(key)",
            used: SourceValue(value: value.value, rawText: value.raw, unit: "cents"),
            remaining: nil,
            percentage: .missing(meaning: .used),
            resetsAt: resetDate,
            sourceFields: fields,
            to: &quotas,
            identities: &identities
        )
    }
    return names
}

private func cursorAppendQuota(
    subject: String,
    path: String,
    originalName: String,
    used: SourceValue?,
    remaining: SourceValue?,
    percentage: SourcePercentage,
    resetsAt: Date?,
    sourceFields: [String: String],
    to quotas: inout [RawQuotaItem],
    identities: inout Set<RawQuotaID>
) throws {
    let id = StableSourceID.make(prefix: "cursor", components: [subject, path])
    guard identities.insert(id).inserted else {
        throw cursorSchemaError("cursor.usage-summary.duplicate-identity")
    }
    quotas.append(
        RawQuotaItem(
            id: id,
            originalName: originalName,
            used: used,
            remaining: remaining,
            percentage: percentage,
            resetsAt: resetsAt,
            sourceFields: sourceFields
        )
    )
}

private func cursorObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { throw cursorMalformedError("cursor.usage-summary.empty-body") }
    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw cursorSchemaError("cursor.usage-summary.object-required")
        }
        return dictionary
    } catch let error as CollectionError {
        throw error
    } catch {
        throw cursorMalformedError("cursor.usage-summary.invalid-json")
    }
}

private func cursorScalarRawText(_ value: Any) -> String? {
    if let text = value as? String { return text }
    if let number = value as? NSNumber, !JSONScalar.isBoolean(number) {
        return number.stringValue
    }
    return nil
}

private func cursorBoolean(_ value: Any) -> Bool? {
    guard let number = value as? NSNumber, JSONScalar.isBoolean(number) else { return nil }
    return number.boolValue
}

private func cursorNonnegativeDecimal(_ value: Any) -> CursorDecimalValue? {
    let parsed: CursorDecimalValue?
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        parsed = CursorDecimalValue(value: decimal, raw: text)
    } else if let number = value as? NSNumber, !JSONScalar.isBoolean(number) {
        parsed = CursorDecimalValue(value: number.decimalValue, raw: number.stringValue)
    } else {
        return nil
    }
    guard parsed!.value >= 0 else { return nil }
    return parsed
}

private func cursorDecimalRaw(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
}

private func cursorCycleDate(_ value: Any) -> Date? {
    if let text = value as? String {
        guard !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
    guard let decimal = cursorNonnegativeDecimal(value)?.value else { return nil }
    let seconds = NSDecimalNumber(decimal: decimal).doubleValue
    guard seconds.isFinite else { return nil }
    return Date(timeIntervalSince1970: abs(seconds) > 100_000_000_000 ? seconds / 1_000 : seconds)
}

private func cursorValidate(_ response: NetworkResponse, now: Date) throws {
    switch response.statusCode {
    case 200..<300:
        guard !response.body.isEmpty else { throw cursorMalformedError("cursor.usage-summary.empty-body") }
    case 401:
        throw CollectionError(kind: .authenticationRevoked, diagnosticCode: "cursor.usage-summary.authentication-rejected")
    case 403:
        throw CollectionError(kind: .authenticationRevoked, diagnosticCode: "cursor.usage-summary.authentication-rejected")
    case 429:
        throw CollectionError(
            kind: .rateLimited,
            diagnosticCode: "cursor.usage-summary.rate-limited",
            retryAfter: cursorRetryAfter(response.header("Retry-After"), now: now)
        )
    case 408, 500...599:
        throw CollectionError(kind: .transientNetwork, diagnosticCode: "cursor.usage-summary.server-transient")
    default:
        throw CollectionError(kind: .sourceUnavailable, diagnosticCode: "cursor.usage-summary.http.\(response.statusCode)")
    }
}

private func cursorRetryAfter(_ value: String?, now: Date) -> Date? {
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

private func cursorSessionMissing() -> CollectionError {
    CollectionError(kind: .externalSessionMissing, diagnosticCode: "cursor.app-session.missing")
}

private func cursorJWTMalformed() -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: "cursor.app-session.jwt-invalid")
}

private func cursorSchemaError(_ code: String) -> CollectionError {
    CollectionError(kind: .schemaChanged, diagnosticCode: code)
}

private func cursorMalformedError(_ code: String) -> CollectionError {
    CollectionError(kind: .malformedResponse, diagnosticCode: code)
}
