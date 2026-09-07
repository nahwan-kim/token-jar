import Foundation
import TokenTankCore
import TokenTankDomain

struct GrokWebBillingSnapshot: Sendable, Equatable {
    let usedPercent: Double?
    let resetsAt: Date?
    let usedPercentIsWirePublished: Bool
    let usedPercentIsImplicitZero: Bool
}

enum GrokWebBillingError: Error, Equatable, Sendable {
    case emptyResponse
    case invalidResponse
    case requestFailed(Int)
    case rpcFailed(Int, String)
    case parseFailed
}

enum GrokWebBilling {
    static let endpoint = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    static let requestTimeout: TimeInterval = 6
    static let requestBody = Data([0, 0, 0, 0, 0])

    // Billing response config is field 1; credit_usage_percent is config field 1 (proto fixed32).
    private static let knownBillingMessagePaths: Set<[UInt64]> = [
        [1],
        [1, 2], [1, 3], [1, 4], [1, 5], [1, 6], [1, 7], [1, 8], [1, 12],
        [1, 6, 1], [1, 6, 2], [1, 6, 3], [1, 8, 2], [1, 8, 3],
        [1, 6, 3, 2], [1, 6, 3, 3],
    ]
    private static let criticalBillingPaths: Set<[UInt64]> = [
        [1], [1, 1], [1, 8], [1, 8, 1], [1, 8, 2], [1, 8, 2, 1],
        [1, 8, 3], [1, 8, 3, 1],
    ]

    private static func expectedWireType(for path: [UInt64]) -> UInt64? {
        switch path {
        case [1], [1, 8], [1, 8, 2], [1, 8, 3]:
            2
        case [1, 1]:
            5
        case [1, 8, 1], [1, 8, 2, 1], [1, 8, 3, 1]:
            0
        default:
            nil
        }
    }

    static func fetch(
        token: String,
        now: Date,
        network: any NetworkClient
    ) async throws -> GrokWebBillingSnapshot {
        try Task.checkCancellation()
        let request = NetworkRequest(
            providerID: .grok,
            url: endpoint,
            method: .post,
            headers: [
                "Authorization": "Bearer \(token)",
                "Origin": "https://grok.com",
                "Referer": "https://grok.com/?_s=usage",
                "Accept": "*/*",
                "Content-Type": "application/grpc-web+proto",
                "x-grpc-web": "1",
                "x-user-agent": "connect-es/2.1.1",
                "User-Agent": "TokenJar",
            ],
            body: requestBody,
            timeout: requestTimeout
        )
        let response: NetworkResponse
        do {
            response = try await network.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectionError where error.kind == .cancelled {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            throw GrokWebBillingError.requestFailed(response.statusCode)
        }
        try validateGRPCResponseHeaders(response.headers)
        return try parseGRPCWebResponse(response.body, now: now)
    }

    static func parseGRPCWebResponse(
        _ data: Data,
        now: Date = Date()
    ) throws -> GrokWebBillingSnapshot {
        let framed = try decodeFrames(data)
        guard !framed.payloads.isEmpty else {
            throw GrokWebBillingError.emptyResponse
        }

        var scan = ProtobufScan()
        for payload in framed.payloads {
            let result = scanProtobuf(payload, depth: 0, path: [], order: 0)
            scan.merge(result.scan)
        }
        guard scan.isComplete else {
            throw GrokWebBillingError.parseFailed
        }

        let parsedPercent = scan.fixed32Fields
            .filter { field in
                field.path == [1, 1] && field.value.isFinite && field.value >= 0 && field.value <= 100
            }
            .min { lhs, rhs in
                lhs.order < rhs.order
            }
            .map { Double($0.value) }

        let resetFields = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            guard let date = epochDate(field.value) else { return nil }
            return (field.path, date)
        }
        let futureResets = resetFields.filter { $0.date > now }
        let reset = futureResets
            .filter { $0.path == [1, 5, 1] }
            .map(\.date)
            .min()
            ?? futureResets.map(\.date).min()

        let periodType = scan.varintFields.first { field in
            field.path == [1, 8, 1] && (field.value == 1 || field.value == 2)
        }?.value
        let currentPeriodStart = resetFields.first { $0.path == [1, 8, 2, 1] }?.date
        let currentPeriodEnd = resetFields.first { $0.path == [1, 8, 3, 1] }?.date
        let hasActiveCurrentPeriod = periodType != nil
            && currentPeriodStart.map { $0 <= now } == true
            && currentPeriodEnd.map { $0 > now } == true
        let implicitZero = parsedPercent == nil
            && scan.fixed32Fields.isEmpty
            && framed.payloads.count == 1
            && hasActiveCurrentPeriod
        guard let percent = parsedPercent ?? (implicitZero ? 0 : nil) else {
            throw GrokWebBillingError.parseFailed
        }
        return GrokWebBillingSnapshot(
            usedPercent: percent,
            resetsAt: reset,
            usedPercentIsWirePublished: parsedPercent != nil,
            usedPercentIsImplicitZero: implicitZero
        )
    }

    private static func looksLikeProtobufPayload(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    private struct FramedPayloads {
        let payloads: [Data]
    }

    private static func decodeFrames(_ data: Data) throws -> FramedPayloads {
        guard !data.isEmpty else { throw GrokWebBillingError.emptyResponse }
        let bytes = [UInt8](data)
        guard let first = bytes.first else { throw GrokWebBillingError.emptyResponse }
        if first & 0x80 != 0, first != 0x80 {
            throw GrokWebBillingError.invalidResponse
        }

        // A gRPC-web data or trailer frame starts with 0x00 or 0x80. Other first bytes
        // are accepted only as an explicitly supported unframed protobuf payload.
        guard first == 0 || first == 0x80 else {
            guard looksLikeProtobufPayload(data) else { throw GrokWebBillingError.invalidResponse }
            return FramedPayloads(payloads: [data])
        }

        var index = 0
        var payloads: [Data] = []
        var sawTrailer = false
        while index < bytes.count {
            guard index + 5 <= bytes.count else { throw GrokWebBillingError.invalidResponse }
            let flags = bytes[index]
            guard flags == 0 || flags == 0x80 else { throw GrokWebBillingError.invalidResponse }
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            guard length >= 0, length <= bytes.count - start else {
                throw GrokWebBillingError.invalidResponse
            }
            let end = start + length
            let payload = Data(bytes[start..<end])
            if flags == 0x80 {
                guard !sawTrailer else { throw GrokWebBillingError.invalidResponse }
                sawTrailer = true
                try validateGRPCTrailer(payload)
            } else {
                guard !sawTrailer else { throw GrokWebBillingError.invalidResponse }
                payloads.append(payload)
            }
            index = end
        }
        return FramedPayloads(payloads: payloads)
    }

    private static func validateGRPCResponseHeaders(_ fields: [String: String]) throws {
        var normalized: [String: String] = [:]
        for (key, value) in fields {
            let lowerKey = key.lowercased()
            guard lowerKey == "grpc-status" || lowerKey == "grpc-message" else { continue }
            normalized[lowerKey] = try decodedTrailerValue(value)
        }
        try validateGRPCStatusFields(normalized)
    }

    private static func validateGRPCTrailer(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GrokWebBillingError.invalidResponse
        }
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw GrokWebBillingError.invalidResponse
            }
            let key = String(line[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !key.isEmpty, fields[key] == nil else {
                throw GrokWebBillingError.invalidResponse
            }
            let rawValue = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = try decodedTrailerValue(rawValue)
        }
        try validateGRPCStatusFields(fields)
    }

    private static func validateGRPCStatusFields(_ fields: [String: String]) throws {
        guard let rawStatus = fields["grpc-status"] else { return }
        guard let status = Int(rawStatus), (0...16).contains(status) else {
            throw GrokWebBillingError.invalidResponse
        }
        guard status != 0 else { return }
        throw GrokWebBillingError.rpcFailed(status, fields["grpc-message"] ?? "")
    }

    private static func decodedTrailerValue(_ value: String) throws -> String {
        guard !value.contains("%") || value.removingPercentEncoding != nil else {
            throw GrokWebBillingError.invalidResponse
        }
        return value.removingPercentEncoding ?? value
    }

    private struct ProtobufScan {
        struct Fixed32Field {
            let path: [UInt64]
            let value: Float
            let order: Int
        }

        struct VarintField {
            let path: [UInt64]
            let value: UInt64
        }

        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []
        var seenCriticalPaths: Set<[UInt64]> = []
        var isComplete = true

        mutating func merge(_ other: ProtobufScan) {
            if !seenCriticalPaths.isDisjoint(with: other.seenCriticalPaths) {
                isComplete = false
            }
            fixed32Fields.append(contentsOf: other.fixed32Fields)
            varintFields.append(contentsOf: other.varintFields)
            seenCriticalPaths.formUnion(other.seenCriticalPaths)
            isComplete = isComplete && other.isComplete
        }
    }

    private static func scanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int
    ) -> (scan: ProtobufScan, order: Int) {
        let bytes = [UInt8](data)
        var scan = ProtobufScan()
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            guard let key = readVarint(bytes, index: &index), key >> 3 > 0, key >> 3 <= 536_870_911 else {
                scan.isComplete = false
                return (scan, nextOrder)
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]
            if let expectedWireType = expectedWireType(for: fieldPath),
               expectedWireType != wireType {
                scan.isComplete = false
                return (scan, nextOrder)
            }
            if criticalBillingPaths.contains(fieldPath),
               !scan.seenCriticalPaths.insert(fieldPath).inserted {
                scan.isComplete = false
                return (scan, nextOrder)
            }

            switch wireType {
            case 0:
                guard let value = readVarint(bytes, index: &index) else {
                    scan.isComplete = false
                    return (scan, nextOrder)
                }
                scan.varintFields.append(ProtobufScan.VarintField(path: fieldPath, value: value))
            case 1:
                guard index + 8 <= bytes.count else {
                    scan.isComplete = false
                    return (scan, nextOrder)
                }
                index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    scan.isComplete = false
                    return (scan, nextOrder)
                }
                let start = index
                let end = index + Int(length)
                if depth < 4, knownBillingMessagePaths.contains(fieldPath) {
                    let nested = scanProtobuf(
                        Data(bytes[start..<end]),
                        depth: depth + 1,
                        path: fieldPath,
                        order: nextOrder)
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else {
                    scan.isComplete = false
                    return (scan, nextOrder)
                }
                let bitPattern = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(
                    ProtobufScan.Fixed32Field(
                        path: fieldPath,
                        value: Float(bitPattern: bitPattern),
                        order: nextOrder))
                nextOrder += 1
                index += 4
            default:
                scan.isComplete = false
                return (scan, nextOrder)
            }
        }
        return (scan, nextOrder)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            if shift == 63, byte > 1 { return nil }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func epochDate(_ value: UInt64) -> Date? {
        guard value >= 1_700_000_000, value <= 2_100_000_000 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }
}
