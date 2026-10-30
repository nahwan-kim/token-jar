import Foundation
import TokenTankCore
import TokenTankDomain

public struct AntigravityAdapter: ProviderAdapter {
    public let id: ProviderID = .antigravity
    public let displayName: String = "Antigravity"
    public let defaultAbbreviation: String = "AGY"

    public var sourceDescriptor: ProviderSourceDescriptor {
        ProviderSourceDescriptor(
            id: "antigravity.cli-proxy.quota-summary",
            name: "Antigravity quota summary",
            kind: .localSession,
            credentialOwnership: .externalProvider,
            documentationURL: URL(string: "https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md"),
            detail: "Antigravity Google OAuth sign-ins kept by CLIProxyAPI (~/.cli-proxy-api/auths/antigravity-*.json, else ~/.cli-proxy-api), one account per enabled file, plus daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary for the Gemini and Claude/GPT 5-hour and weekly limits and cloudcode-pa.googleapis.com/v1internal:loadCodeAssist for the plan name. Token Jar only reads the auth files; CLIProxyAPI renews each token before it expires, so Token Jar sends no refresh grant and writes nothing."
        )
    }

    public init() {}

    public func probeAvailability(context: CollectionContext) async -> ProviderAvailability {
        .available(sourceDescriptor)
    }

    public func fetchSnapshot(context: CollectionContext) async throws -> ProviderSnapshot {
        let reads = try await antigravityAccounts(in: context)
        var outcomes: [(AntigravityAccountRead, Result<AccountUsage, CollectionError>)] = []
        for account in reads {
            guard let session = account.session else {
                outcomes.append((account, .failure(account.failure ?? antigravityMissingSession())))
                continue
            }
            do {
                outcomes.append((account, .success(try await usage(session: session, context: context))))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CollectionError where error.kind == .cancelled {
                throw error
            } catch let error as CollectionError {
                outcomes.append((account, .failure(error)))
            }
        }

        if outcomes.count == 1 {
            let usage = try outcomes[0].1.get()
            return ProviderSnapshot(
                providerID: .antigravity,
                source: sourceDescriptor,
                quotas: usage.quotas,
                refreshedAt: usage.refreshedAt,
                accountEmail: outcomes[0].0.accountEmail
            )
        }
        guard outcomes.contains(where: { (try? $0.1.get()) != nil }) else {
            if case let .failure(error)? = outcomes.first?.1 { throw error }
            throw antigravityMissingSession()
        }
        let now = await context.clock.now()
        let accounts = outcomes.map { account, outcome -> ProviderAccountSnapshot in
            switch outcome {
            case let .success(usage):
                return ProviderAccountSnapshot(
                    sourceID: account.sourceID,
                    quotas: usage.quotas,
                    refreshedAt: usage.refreshedAt,
                    accountEmail: account.accountEmail,
                    plan: usage.plan
                )
            case let .failure(error):
                return ProviderAccountSnapshot(
                    sourceID: account.sourceID,
                    quotas: [],
                    accountEmail: account.accountEmail,
                    failure: error,
                    failedAt: now
                )
            }
        }
        return ProviderSnapshot(
            providerID: .antigravity,
            source: sourceDescriptor,
            accounts: accounts,
            refreshedAt: accounts.compactMap(\.refreshedAt).max() ?? now
        )
    }

    private struct AccountUsage {
        let quotas: [RawQuotaItem]
        let plan: String?
        let refreshedAt: Date
    }

    private func usage(session: AntigravitySession, context: CollectionContext) async throws -> AccountUsage {
        let refreshedAt = await context.clock.now()
        let response = try await antigravitySend(
            url: AntigravityRequestPolicy.quotaSummaryURL,
            body: AntigravityRequestPolicy.quotaSummaryBody(projectID: session.projectID),
            token: session.accessToken,
            network: context.network
        )
        try antigravityValidate(response, now: refreshedAt)
        let plan = await planName(session: session, network: context.network)
        try Task.checkCancellation()
        return AccountUsage(
            quotas: try Self.decodeQuotas(from: response.body, plan: plan),
            plan: plan,
            refreshedAt: refreshedAt
        )
    }

    /// The subscription name is decoration: any failure leaves it out instead of failing usage.
    private func planName(session: AntigravitySession, network: any NetworkClient) async -> String? {
        guard let response = try? await antigravitySend(
            url: AntigravityRequestPolicy.loadCodeAssistURL,
            body: AntigravityRequestPolicy.loadCodeAssistBody,
            token: session.accessToken,
            network: network
        ), (200..<300).contains(response.statusCode) else { return nil }
        return Self.decodePlan(from: response.body)
    }

    /// `paidTier.name` (for example "Google AI Pro"), else a name for `currentTier.id`.
    public static func decodePlan(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let paid = root["paidTier"] as? [String: Any],
           let name = antigravityString(paid["name"]) {
            return ProviderAccountSnapshot.validatedPlan(name)
        }
        guard let tier = root["currentTier"] as? [String: Any] else { return nil }
        switch antigravityString(tier["id"]) {
        case "standard-tier": return "Paid"
        case "free-tier": return "Free"
        case "legacy-tier": return "Legacy"
        default: return ProviderAccountSnapshot.validatedPlan(antigravityString(tier["name"]))
        }
    }

    public static func decodeSnapshot(
        from data: Data,
        refreshedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: .antigravity,
            source: AntigravityAdapter().sourceDescriptor,
            quotas: try decodeQuotas(from: data, plan: nil),
            refreshedAt: refreshedAt
        )
    }

    /// One quota per enabled bucket: `<group>.<window>` such as `gemini.5h` or `3p.weekly`, in group
    /// order with the 5-hour window before the weekly one.
    static func decodeQuotas(from data: Data, plan: String?) throws -> [RawQuotaItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw antigravityMalformedError("antigravity.summary.invalid-json")
        }
        let summary = (root["response"] as? [String: Any]) ?? (root["summary"] as? [String: Any]) ?? root
        guard let groups = summary["groups"] as? [Any] else {
            throw antigravitySchemaError("antigravity.summary.groups-missing")
        }
        var quotas: [RawQuotaItem] = []
        for groupValue in groups {
            guard let group = groupValue as? [String: Any],
                  let buckets = group["buckets"] as? [Any]
            else { throw antigravitySchemaError("antigravity.summary.group-invalid") }
            let groupName = antigravityString(group["displayName"]) ?? antigravityString(group["name"])
            var groupQuotas: [RawQuotaItem] = []
            for bucketValue in buckets {
                guard let bucket = bucketValue as? [String: Any] else {
                    throw antigravitySchemaError("antigravity.summary.bucket-invalid")
                }
                if bucket["disabled"] as? Bool == true { continue }
                groupQuotas.append(try quota(from: bucket, groupName: groupName, plan: plan))
            }
            quotas += groupQuotas.enumerated().sorted { lhs, rhs in
                let left = windowRank(lhs.element), right = windowRank(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
        }
        guard !quotas.isEmpty else {
            throw antigravityMalformedError("antigravity.summary.empty")
        }
        guard Set(quotas.map(\.id)).count == quotas.count else {
            throw antigravitySchemaError("antigravity.summary.duplicate-bucket")
        }
        return quotas
    }

    private static func quota(from bucket: [String: Any], groupName: String?, plan: String?) throws -> RawQuotaItem {
        guard let bucketID = antigravityIdentifier(bucket["bucketId"] ?? bucket["id"]) else {
            throw antigravitySchemaError("antigravity.summary.bucket-id-invalid")
        }
        let window = antigravityIdentifier(bucket["window"]) ?? "window"
        let groupKey = bucketID.hasSuffix("-\(window)") && bucketID.count > window.count + 1
            ? String(bucketID.dropLast(window.count + 1))
            : bucketID
        var fields: [String: String] = ["bucketId": bucketID, "window": window]
        if let groupName {
            fields["group"] = groupName
            fields["antigravityGroup"] = groupLabel(groupName)
        }
        if let description = antigravityString(bucket["description"]) { fields["description"] = description }
        if let plan { fields["plan"] = plan }

        let fractionValue = bucket["remainingFraction"]
            ?? (bucket["remaining"] as? [String: Any])?["remainingFraction"]
        let percentage: SourcePercentage
        let remaining: SourceValue?
        let used: SourceValue?
        if let fractionValue {
            guard let fraction = antigravityDecimal(fractionValue), fraction >= 0, fraction <= 1 else {
                throw antigravitySchemaError("antigravity.summary.fraction-invalid")
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
        if let value = bucket["resetTime"], !(value is NSNull) {
            guard let raw = antigravityString(value), let date = antigravityDate(raw) else {
                throw antigravitySchemaError("antigravity.summary.reset-invalid")
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

private func antigravityMissingSession() -> CollectionError {
    CollectionError(
        kind: .externalSessionMissing,
        diagnosticCode: "antigravity.session.token-missing",
        recoveryAction: .signInSourceApp
    )
}

private func antigravityAccounts(in context: CollectionContext) async throws -> [AntigravityAccountRead] {
    do {
        return try await context.antigravitySession.accounts()
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as CollectionError {
        throw error
    } catch {
        throw CollectionError(
            kind: .sourceUnavailable,
            diagnosticCode: "antigravity.session.unavailable",
            recoveryAction: .signInSourceApp
        )
    }
}

private func antigravitySend(
    url: URL,
    body: Data,
    token: String,
    network: any NetworkClient
) async throws -> NetworkResponse {
    let request = NetworkRequest(
        providerID: .antigravity,
        url: url,
        method: .post,
        headers: [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "User-Agent": AntigravityRequestPolicy.userAgent,
        ],
        body: body,
        timeout: AntigravityRequestPolicy.timeout
    )
    do {
        return try await network.send(request)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as CollectionError {
        throw error
    } catch {
        throw CollectionError(kind: .transientNetwork, diagnosticCode: "antigravity.summary.network-failed")
    }
}

private func antigravityValidate(_ response: NetworkResponse, now: Date) throws {
    switch response.statusCode {
    case 200..<300:
        guard !response.body.isEmpty else {
            throw antigravityMalformedError("antigravity.summary.empty-body")
        }
    case 401:
        throw CollectionError(
            kind: .authenticationRejected,
            diagnosticCode: "antigravity.summary.authentication.rejected",
            recoveryAction: .signInSourceApp
        )
    case 403:
        throw CollectionError(
            kind: .authenticationRevoked,
            diagnosticCode: "antigravity.summary.authentication.revoked",
            recoveryAction: .signInSourceApp
        )
    case 429:
        let retryAfter = response.header("retry-after")
            .flatMap(TimeInterval.init)
            .flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil }
        throw CollectionError(
            kind: .rateLimited,
            diagnosticCode: "antigravity.summary.rate-limited",
            retryAfter: retryAfter
        )
    default:
        throw CollectionError(
            kind: .transientNetwork,
            diagnosticCode: "antigravity.summary.http-\(response.statusCode)"
        )
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
