import Foundation

/// Abstraction over zstd so the reader can be exercised without a system
/// compressor in tests.
public protocol ZstdDecompressing: Sendable {
    func decompress(fileURL: URL) throws -> Data
}

public enum ZstdDecompressionError: LocalizedError, Equatable, Sendable {
    case executableNotFound(path: String)
    case failed(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "未找到 zstd 命令：\(path)"
        case .failed(let path, let message):
            return "无法解压 DeepSeek Harness 日志 \(path)：\(message)"
        }
    }
}

/// Uses the local zstd command instead of linking a decompression library.
public struct ZstdCommandDecompressor: ZstdDecompressing {
    public let executableURL: URL

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL ?? Self.defaultExecutableURL()
    }

    public func decompress(fileURL: URL) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ZstdDecompressionError.executableNotFound(path: executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-d", "-c", "--", fileURL.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Drain stdout before waiting: session logs can exceed a pipe buffer.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "zstd 退出失败"
            throw ZstdDecompressionError.failed(path: fileURL.path, message: message)
        }
        return data
    }

    private static func defaultExecutableURL() -> URL {
        let fileManager = FileManager.default
        var candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/zstd" })
        }
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first {
            fileManager.isExecutableFile(atPath: $0.path)
        } ?? URL(fileURLWithPath: candidates[0])
    }
}

/// The published DeepSeek per-million-token CNY schedule. Cache writes are
/// priced as cache misses because DSH does not document a separate write rate.
public enum DeepSeekHarnessPricing {
    public enum ModelTier: Sendable {
        case flash
        case pro
        case visionExp
    }

    public static func tier(for modelID: String) -> ModelTier? {
        let normalized = modelID.lowercased()
        // `deepseek-v4-flash-vision-exp` includes both words: vision wins.
        if normalized.contains("vision-exp") { return .visionExp }
        if normalized.contains("pro") { return .pro }
        if normalized.contains("flash") { return .flash }
        return nil
    }

    public static func costMicrosCNY(
        modelID: String,
        freshInputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0,
        recordedAt: Date
    ) -> Int64 {
        guard let tier = tier(for: modelID) else { return 0 }
        let peak = isPeakBeijingTime(recordedAt)
        let rates = rates(for: tier, peak: peak)
        var micros = Decimal(max(0, freshInputTokens)) * rates.cacheMiss
        micros += Decimal(max(0, cacheReadTokens)) * rates.cacheHit
        // Inference: cache writes are charged at the cache-miss input rate.
        micros += Decimal(max(0, cacheWriteTokens)) * rates.cacheMiss
        micros += Decimal(max(0, outputTokens)) * rates.output
        var rounded = Decimal()
        var value = micros
        NSDecimalRound(&rounded, &value, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    public static func isPeakBeijingTime(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let hour = calendar.component(.hour, from: date)
        return (9..<12).contains(hour) || (14..<18).contains(hour)
    }

    private static func rates(for tier: ModelTier, peak: Bool) -> (
        cacheHit: Decimal,
        cacheMiss: Decimal,
        output: Decimal
    ) {
        switch (tier, peak) {
        case (.flash, false), (.visionExp, false): return (0.05, 1.5, 4.5)
        case (.flash, true), (.visionExp, true): return (0.10, 3, 9)
        case (.pro, false): return (0.15, 4.5, 13.5)
        case (.pro, true): return (0.30, 9, 27)
        }
    }
}

/// Parses DeepSeek Harness session JSONL events into stable normalized records.
public struct DeepSeekHarnessJSONLUsageParser: Sendable {
    public init() {}

    public func parse(data: Data, sourceID: String) -> [UsageRecord] {
        parse(content: String(decoding: data, as: UTF8.self), sourceID: sourceID)
    }

    public func parse(content: String, sourceID: String) -> [UsageRecord] {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basicFormatter = ISO8601DateFormatter()
        basicFormatter.formatOptions = [.withInternetDateTime]
        func parseDate(_ value: Any?) -> Date? {
            if let number = value as? NSNumber {
                let raw = number.doubleValue
                guard raw.isFinite else { return nil }
                return Date(timeIntervalSince1970: abs(raw) >= 10_000_000_000 ? raw / 1_000 : raw)
            }
            if let string = value as? String {
                if let numeric = Double(string), numeric.isFinite {
                    return Date(timeIntervalSince1970: abs(numeric) >= 10_000_000_000 ? numeric / 1_000 : numeric)
                }
                return fractionalFormatter.date(from: string) ?? basicFormatter.date(from: string)
            }
            return nil
        }

        var modelID = "unknown"
        var chunkCandidates: [String: Candidate] = [:]
        var messageCandidates: [String: Candidate] = [:]
        var sessionID: String?
        var projectPath: String?
        var sessionTitle: String?
        var sessionStartedAt: Date?
        var sessionEndedAt: Date?

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let lineData = String(rawLine).data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = event["type"] as? String ?? ""
            let data = event["data"] as? [String: Any] ?? [:]
            if let value = string(
                event["id"] ?? event["sessionID"] ?? event["sessionId"]
                    ?? data["id"] ?? data["sessionID"] ?? data["sessionId"]
            ) {
                sessionID = value
            }
            projectPath = string(
                event["cwd"] ?? event["directory"] ?? event["projectPath"]
                    ?? data["cwd"] ?? data["directory"] ?? data["projectPath"]
            ) ?? projectPath
            let lineDate = parseDate(event["time"] ?? event["timestamp"] ?? data["time"] ?? data["timestamp"])
            if let lineDate {
                if sessionStartedAt == nil || lineDate < sessionStartedAt! { sessionStartedAt = lineDate }
                if sessionEndedAt == nil || lineDate > sessionEndedAt! { sessionEndedAt = lineDate }
            }
            if let createdAt = parseDate(event["createdAt"] ?? data["createdAt"]) {
                sessionStartedAt = createdAt
            }
            if type.lowercased().contains("session/title") || type.lowercased() == "session_title" {
                sessionTitle = string(event["title"] ?? data["title"] ?? data["name"]) ?? sessionTitle
            }

            if type == "request/header",
               let header = data["header"] as? [String: Any],
               let config = header["config"] as? [String: Any],
               let value = string(config["model"])
            {
                modelID = value
                projectPath = string(config["cwd"] ?? config["directory"]) ?? projectPath
                sessionID = string(header["id"] ?? header["sessionID"] ?? header["sessionId"]) ?? sessionID
                continue
            }
            if type == "request/context" {
                if let value = string(data["model"]) { modelID = value }
                projectPath = string(data["cwd"] ?? data["directory"]) ?? projectPath
                continue
            }

            guard type == "assistant/chunk" || type == "assistant/message",
                  let key = usageKey(data: data),
                  let usage = usage(in: data, eventType: type),
                  let timestamp = parseDate(event["time"] ?? data["time"])
            else { continue }

            let messageModel = type == "assistant/message" ? model(from: data) : nil
            let candidate = Candidate(
                key: key,
                modelID: messageModel ?? modelID,
                usage: usage,
                recordedAt: timestamp
            )
            if type == "assistant/chunk" {
                // A chunk usage event is canonical; repeated chunks for one
                // (turn, step) are updates, so the latest entry wins.
                chunkCandidates[key] = candidate
            } else {
                // Older sessions sometimes only retain message-level usage.
                messageCandidates[key] = candidate
                // A message can carry the concrete provider model while the
                // preceding request header only had a routing alias.
                if let messageModel, let chunk = chunkCandidates[key] {
                    chunkCandidates[key] = Candidate(
                        key: chunk.key,
                        modelID: messageModel,
                        usage: chunk.usage,
                        recordedAt: chunk.recordedAt
                    )
                }
            }
        }

        let candidates = chunkCandidates.merging(messageCandidates) { chunk, _ in chunk }
        let normalizedSourceID = sourceID.isEmpty ? "session" : sourceID
        let resolvedSessionID = sessionID ?? (sourceID.isEmpty ? nil : sourceID)
        return candidates.values
            .sorted { $0.key < $1.key }
            .compactMap { candidate in
                guard candidate.usage.hasUsage else { return nil }
                let cost = DeepSeekHarnessPricing.costMicrosCNY(
                    modelID: candidate.modelID,
                    freshInputTokens: candidate.usage.inputTokens,
                    outputTokens: candidate.usage.outputTokens,
                    cacheReadTokens: candidate.usage.cacheReadTokens,
                    cacheWriteTokens: candidate.usage.cacheWriteTokens,
                    recordedAt: candidate.recordedAt
                )
                return UsageRecord(
                    id: "deepseek-harness:\(normalizedSourceID):\(candidate.key)",
                    agent: "deepseek-harness",
                    model: candidate.modelID,
                    freshInputTokens: candidate.usage.inputTokens,
                    outputTokens: candidate.usage.outputTokens,
                    cacheReadTokens: candidate.usage.cacheReadTokens,
                    cacheWriteTokens: candidate.usage.cacheWriteTokens,
                    costMicrosCNY: cost,
                    recordedAt: candidate.recordedAt,
                    sessionID: resolvedSessionID,
                    sessionTitle: sessionTitle,
                    projectPath: projectPath,
                    sessionStartedAt: sessionStartedAt,
                    sessionEndedAt: sessionEndedAt,
                    requestCount: 1
                )
            }
    }

    private func usageKey(data: [String: Any]) -> String? {
        guard let turn = string(data["turn"]), let step = string(data["step"]) else { return nil }
        return "\(turn):\(step)"
    }

    private func usage(in data: [String: Any], eventType: String) -> Usage? {
        let container: [String: Any]?
        if eventType == "assistant/chunk" {
            container = (data["chunk"] as? [String: Any])?["usage"] as? [String: Any]
        } else {
            container = (data["message"] as? [String: Any])?["usage"] as? [String: Any]
                ?? data["usage"] as? [String: Any]
        }
        guard let container else { return nil }
        return Usage(
            inputTokens: integer(container["inputTokens"]),
            outputTokens: integer(container["outputTokens"]),
            cacheReadTokens: integer(container["cacheReadTokens"]),
            cacheWriteTokens: integer(container["cacheWriteTokens"])
        )
    }

    private func model(from data: [String: Any]) -> String? {
        guard let message = data["message"] as? [String: Any] else { return nil }
        if let source = message["source"] as? [String: Any] {
            return string(source["model"])
                ?? string((source["model"] as? [String: Any])?["id"])
        }
        return string(message["model"])
    }

    private func string(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func integer(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return max(0, number.int64Value) }
        if let string = value as? String, let parsed = Int64(string) { return max(0, parsed) }
        return 0
    }

}

private struct Candidate: Sendable {
    let key: String
    let modelID: String
    let usage: DeepSeekHarnessJSONLUsageParser.Usage
    let recordedAt: Date
}

extension DeepSeekHarnessJSONLUsageParser {
    fileprivate struct Usage: Sendable {
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let cacheWriteTokens: Int64

        var hasUsage: Bool {
            inputTokens > 0 || outputTokens > 0 || cacheReadTokens > 0 || cacheWriteTokens > 0
        }
    }
}
