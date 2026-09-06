import Foundation

/// Converts a third-party JSON payload into TokenBall's normalized records.
///
/// Adapters live outside TokenBallCore: define a `Decodable` payload, implement
/// this protocol, and pass the adapter to `GenericJSONUsageParser`.
public protocol JSONUsageAdapter: Sendable {
    associatedtype Payload: Decodable & Sendable

    func usageRecords(from payload: Payload) throws -> [UsageRecord]
}

public enum GenericJSONUsageParserError: LocalizedError, Equatable, Sendable {
    case unsupportedTopLevel
    case invalidRecord(id: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTopLevel:
            return "JSON 顶层必须是单条 UsageRecord、UsageRecord 数组或包含 records 数组的对象"
        case .invalidRecord(_, let reason):
            return "JSON 用量记录无效：\(reason)"
        }
    }
}

/// Parses canonical TokenBall JSON or delegates custom JSON normalization to a
/// caller-supplied adapter. This type only produces `UsageRecord` values; the
/// repository remains independent from every producer's schema.
public struct GenericJSONUsageParser: Sendable {
    public init() {}

    /// Parses canonical JSON in any of these forms:
    /// - one `UsageRecord` object
    /// - an array of `UsageRecord` objects
    /// - `{ "records": [...] }`
    public func parse(data: Data) throws -> [UsageRecord] {
        let topLevel = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        let decoder = Self.makeDecoder()

        if topLevel is [Any] {
            return try Self.validated(decoder.decode([UsageRecord].self, from: data))
        }
        if let object = topLevel as? [String: Any] {
            if object["records"] != nil {
                return try Self.validated(
                    decoder.decode(UsageRecordEnvelope.self, from: data).records
                )
            }
            return try Self.validated([decoder.decode(UsageRecord.self, from: data)])
        }
        throw GenericJSONUsageParserError.unsupportedTopLevel
    }

    public func parse(content: String) throws -> [UsageRecord] {
        try parse(data: Data(content.utf8))
    }

    public func parse(contentsOf fileURL: URL) throws -> [UsageRecord] {
        try parse(data: Data(contentsOf: fileURL, options: [.mappedIfSafe]))
    }

    /// Decodes a producer-specific payload and lets an external adapter map it
    /// to normalized records without adding that producer to TokenBallCore.
    public func parse<Adapter: JSONUsageAdapter>(
        data: Data,
        using adapter: Adapter
    ) throws -> [UsageRecord] {
        let payload = try Self.makeDecoder().decode(Adapter.Payload.self, from: data)
        return try Self.validated(adapter.usageRecords(from: payload))
    }

    public func parse<Adapter: JSONUsageAdapter>(
        content: String,
        using adapter: Adapter
    ) throws -> [UsageRecord] {
        try parse(data: Data(content.utf8), using: adapter)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let timestamp = try? container.decode(Double.self) {
                return try date(fromUnixTimestamp: timestamp, codingPath: decoder.codingPath)
            }

            let value = try container.decode(String.self)
            if let timestamp = Double(value) {
                return try date(fromUnixTimestamp: timestamp, codingPath: decoder.codingPath)
            }

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let basicFormatter = ISO8601DateFormatter()
            basicFormatter.formatOptions = [.withInternetDateTime]
            if let date = fractionalFormatter.date(from: value) ?? basicFormatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "recordedAt must be ISO 8601 or a Unix timestamp"
            )
        }
        return decoder
    }

    private static func date(
        fromUnixTimestamp timestamp: Double,
        codingPath: [any CodingKey]
    ) throws -> Date {
        guard timestamp.isFinite else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Unix timestamp must be finite"
                )
            )
        }
        let seconds = abs(timestamp) >= 10_000_000_000 ? timestamp / 1_000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }

    private static func validated(_ records: [UsageRecord]) throws -> [UsageRecord] {
        for record in records {
            guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GenericJSONUsageParserError.invalidRecord(
                    id: record.id,
                    reason: "记录 ID 不能为空"
                )
            }
            guard !record.agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GenericJSONUsageParserError.invalidRecord(
                    id: record.id,
                    reason: "Agent 不能为空"
                )
            }
            guard !record.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GenericJSONUsageParserError.invalidRecord(
                    id: record.id,
                    reason: "模型不能为空"
                )
            }
            let tokenCounts = [
                record.freshInputTokens,
                record.outputTokens,
                record.cacheReadTokens,
                record.cacheWriteTokens
            ]
            guard tokenCounts.allSatisfy({ $0 >= 0 }) else {
                throw GenericJSONUsageParserError.invalidRecord(
                    id: record.id,
                    reason: "Token 数不能为负数"
                )
            }
            guard record.recordedAt.timeIntervalSince1970.isFinite else {
                throw GenericJSONUsageParserError.invalidRecord(
                    id: record.id,
                    reason: "记录时间无效"
                )
            }
        }
        return records
    }
}

private struct UsageRecordEnvelope: Decodable {
    let records: [UsageRecord]
}
