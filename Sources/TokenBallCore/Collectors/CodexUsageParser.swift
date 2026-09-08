import Foundation

/// Official per-million-token USD rates for OpenAI GPT models, mirroring the
/// reference pricing table of the retired statistics source. Codex and
/// OpenCode sessions both use this table for GPT models; DeepSeek models are
/// priced separately in CNY.
public enum OpenAIModelPricing {
    public static func hasPublishedRate(modelID: String) -> Bool {
        rates(for: modelID) != nil
    }

    public static func costMicrosUSD(
        modelID: String,
        freshInputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0
    ) -> Int64 {
        guard let rates = rates(for: modelID) else { return 0 }
        var micros = Decimal(max(0, freshInputTokens)) * rates.input
        micros += Decimal(max(0, outputTokens)) * rates.output
        micros += Decimal(max(0, cacheReadTokens)) * rates.cacheRead
        micros += Decimal(max(0, cacheWriteTokens)) * rates.cacheWrite
        var rounded = Decimal()
        var value = micros
        NSDecimalRound(&rounded, &value, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    private struct Rates {
        let input: Decimal
        let output: Decimal
        let cacheRead: Decimal
        let cacheWrite: Decimal
    }

    private static func rates(for modelID: String) -> Rates? {
        switch modelID.lowercased() {
        case "gpt-5.6-luna":
            return Rates(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25)
        case "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-low", "gpt-5.6-medium",
             "gpt-5.6-high", "gpt-5.6-xhigh", "gpt-5.6-minimal":
            return Rates(input: 5, output: 30, cacheRead: 0.50, cacheWrite: 6.25)
        case "gpt-5.6-terra":
            return Rates(input: 2, output: 12, cacheRead: 0.20, cacheWrite: 2.50)
        case "gpt-5.5", "gpt-5.5-low", "gpt-5.5-medium", "gpt-5.5-high",
             "gpt-5.5-xhigh", "gpt-5.5-minimal":
            return Rates(input: 5, output: 30, cacheRead: 0.50, cacheWrite: 0)
        case "gpt-5.4", "gpt-5.4-high", "gpt-5.4-medium", "gpt-5.4-low":
            return Rates(input: 2.50, output: 15, cacheRead: 0.25, cacheWrite: 0)
        case "gpt-5.4-mini":
            return Rates(input: 0.75, output: 4.50, cacheRead: 0.075, cacheWrite: 0)
        case "gpt-5.4-nano":
            return Rates(input: 0.20, output: 1.25, cacheRead: 0.02, cacheWrite: 0)
        case "gpt-5.2", "gpt-5.2-low", "gpt-5.2-medium", "gpt-5.2-high":
            return Rates(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0)
        case "gpt-5.1", "gpt-5.1-low", "gpt-5.1-medium", "gpt-5.1-high",
             "gpt-5.1-minimal", "gpt-5.1-codex", "gpt-5.1-codex-mini",
             "gpt-5.1-codex-max", "gpt-5.1-codex-max-high", "gpt-5.1-codex-max-xhigh":
            return Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)
        case "gpt-5", "gpt-5-low", "gpt-5-medium", "gpt-5-high", "gpt-5-minimal":
            return Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)
        default:
            // Absence from the published table means "unpriced", not free.
            return nil
        }
    }
}

/// Parses the token-count events emitted by Codex archived session JSONL files.
public struct CodexJSONLUsageParser: Sendable {
    /// A response longer than this is not considered measurable from the
    /// archived event stream. The logs expose completion/boundary timestamps,
    /// but not a guaranteed model-generation start timestamp; refusing an
    /// implausibly long window is safer than reporting a rate diluted by a
    /// hidden tool or idle interval.
    private static let maximumGenerationWindowSeconds: TimeInterval = 5 * 60

    public init() {}

    public func parse(data: Data, sourceID: String) -> [UsageRecord] {
        let content = String(decoding: data, as: UTF8.self)
        return parse(content: content, sourceID: sourceID)
    }

    public func parse(content: String, sourceID: String) -> [UsageRecord] {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basicFormatter = ISO8601DateFormatter()
        basicFormatter.formatOptions = [.withInternetDateTime]
        func parseDate(_ value: String?) -> Date? {
            guard let value else { return nil }
            return fractionalFormatter.date(from: value) ?? basicFormatter.date(from: value)
        }

        var currentModel = "unknown"
        var previousTotal: TokenCounts?
        var records: [UsageRecord] = []
        var sessionID: String?
        var projectPath: String?
        var sessionTitle: String?
        var sessionStartedAt: Date?
        var sessionEndedAt: Date?
        var generationStartAt: Date?
        var lastAssistantEventAt: Date?
        var pendingToolBoundaryAt: Date?

        for (offset, rawLine) in content.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
            guard
                !line.isEmpty,
                let data = String(line).data(using: .utf8),
                let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = envelope["payload"] as? [String: Any]
            else { continue }

            let eventDate = parseDate(
                (envelope["timestamp"] as? String)
                    ?? (payload["timestamp"] as? String)
            )
            if let eventDate {
                if sessionStartedAt == nil || eventDate < sessionStartedAt! {
                    sessionStartedAt = eventDate
                }
                if sessionEndedAt == nil || eventDate > sessionEndedAt! {
                    sessionEndedAt = eventDate
                }
            }

            let envelopeType = envelope["type"] as? String
            let payloadType = payload["type"] as? String

            if envelopeType == "session_meta" {
                sessionID = Self.nonEmptyString(
                    payload["id"] ?? payload["session_id"] ?? payload["sessionID"]
                ) ?? sessionID
                projectPath = Self.nonEmptyString(
                    payload["cwd"] ?? payload["directory"] ?? payload["project_path"]
                ) ?? projectPath
                if let date = parseDate(
                    payload["timestamp"] as? String
                        ?? envelope["timestamp"] as? String
                ) {
                    sessionStartedAt = date
                }
            }

            if envelopeType == "response_item" || payloadType == "message" {
                let role = Self.nonEmptyString(payload["role"])
                    ?? Self.nonEmptyString((payload["message"] as? [String: Any])?["role"])
                if role?.lowercased() == "user", sessionTitle == nil {
                    let candidate = Self.title(from: payload["content"])
                        ?? Self.title(from: (payload["message"] as? [String: Any])?["content"])
                    if let candidate { sessionTitle = candidate }
                }
            }

            // Codex does not persist a model response's start time directly,
            // but it does persist task boundaries and completed assistant
            // items. Keep an active response window from the task/tool
            // boundary up to the last assistant item immediately preceding a
            // token_count event. Tool execution therefore never becomes part
            // of the measured generation duration.
            if envelopeType == "event_msg" {
                switch payloadType {
                case "task_started":
                    generationStartAt = eventDate
                    lastAssistantEventAt = nil
                    pendingToolBoundaryAt = nil
                case "item_completed":
                    if let eventDate {
                        if Self.isAssistantItemCompleted(payload) {
                            lastAssistantEventAt = eventDate
                        } else if Self.isToolBoundaryItemCompleted(payload) {
                            pendingToolBoundaryAt = eventDate
                        }
                    }
                default:
                    break
                }
            } else if envelopeType == "response_item",
                      Self.isAssistantResponseItem(payload),
                      let eventDate {
                lastAssistantEventAt = eventDate
            } else if envelopeType == "response_item",
                      Self.isToolBoundaryResponseItem(payload),
                      let eventDate {
                pendingToolBoundaryAt = eventDate
            }

            if envelopeType == "turn_context" {
                currentModel = Self.modelName(from: payload["model"]) ?? currentModel
                continue
            }

            guard
                envelopeType == "event_msg",
                payloadType == "token_count",
                let info = payload["info"] as? [String: Any]
            else { continue }

            if let model = Self.modelName(from: payload["model"]) {
                currentModel = model
            }

            let total = Self.tokenCounts(from: info["total_token_usage"])
            let isRepeatedTotal = total != nil && total == previousTotal
            let last = Self.tokenCounts(from: info["last_token_usage"])
            let counts = last ?? total?.delta(since: previousTotal)
            if let total { previousTotal = total }

            guard
                !isRepeatedTotal,
                let counts,
                counts.hasUsage,
                let timestamp = (envelope["timestamp"] as? String)
                    ?? (payload["timestamp"] as? String),
                let recordedAt = fractionalFormatter.date(from: timestamp)
                    ?? basicFormatter.date(from: timestamp)
            else { continue }

            let cachedInput = TokenArithmetic.addingWithoutOverflow(
                counts.cacheReadTokens,
                counts.cacheWriteTokens
            )
            let freshInput = max(0, counts.inputTokens - min(counts.inputTokens, cachedInput))
            let normalizedSourceID = sourceID.isEmpty ? "session" : sourceID
            let generationDurationSeconds = Self.generationDuration(
                startedAt: generationStartAt,
                assistantEventAt: lastAssistantEventAt,
                usageAt: recordedAt
            )

            records.append(
                UsageRecord(
                    id: "codex:\(normalizedSourceID):\(offset + 1)",
                    agent: "codex",
                    model: currentModel,
                    freshInputTokens: freshInput,
                    outputTokens: counts.outputTokens,
                    cacheReadTokens: counts.cacheReadTokens,
                    cacheWriteTokens: counts.cacheWriteTokens,
                    costMicrosUSD: OpenAIModelPricing.costMicrosUSD(
                        modelID: currentModel,
                        freshInputTokens: freshInput,
                        outputTokens: counts.outputTokens,
                        cacheReadTokens: counts.cacheReadTokens,
                        cacheWriteTokens: counts.cacheWriteTokens
                    ),
                    costMicrosCNY: DeepSeekHarnessPricing.costMicrosCNY(
                        modelID: currentModel,
                        freshInputTokens: freshInput,
                        outputTokens: counts.outputTokens,
                        cacheReadTokens: counts.cacheReadTokens,
                        cacheWriteTokens: counts.cacheWriteTokens,
                        recordedAt: recordedAt
                    ),
                    recordedAt: recordedAt,
                    sessionID: sessionID,
                    sessionTitle: sessionTitle,
                    projectPath: projectPath,
                    sessionStartedAt: sessionStartedAt,
                    sessionEndedAt: sessionEndedAt,
                    generationDurationSeconds: generationDurationSeconds
                )
            )

            // A token_count closes the response whose usage it reports. The
            // next model response begins after this boundary (usually after a
            // tool output), so never carry the prior response's start/end
            // marker into the next row.
            generationStartAt = pendingToolBoundaryAt ?? recordedAt
            lastAssistantEventAt = nil
            pendingToolBoundaryAt = nil
        }

        // Session metadata often appears before usage events, but malformed or
        // hand-edited logs can place it later. Apply the final metadata to all
        // rows after parsing so every request groups into one session.
        let resolvedSessionID = Self.nonEmptyString(sessionID) ?? Self.nonEmptyString(sourceID)
        return records.map { record in
            UsageRecord(
                id: record.id,
                agent: record.agent,
                model: record.model,
                freshInputTokens: record.freshInputTokens,
                outputTokens: record.outputTokens,
                cacheReadTokens: record.cacheReadTokens,
                cacheWriteTokens: record.cacheWriteTokens,
                costMicrosUSD: record.costMicrosUSD,
                costMicrosCNY: record.costMicrosCNY,
                recordedAt: record.recordedAt,
                sessionID: resolvedSessionID,
                sessionTitle: sessionTitle,
                projectPath: projectPath,
                sessionStartedAt: sessionStartedAt,
                sessionEndedAt: sessionEndedAt,
                requestCount: 1,
                generationDurationSeconds: record.generationDurationSeconds
            )
        }
    }

    private static func generationDuration(
        startedAt: Date?,
        assistantEventAt: Date?,
        usageAt: Date
    ) -> TimeInterval? {
        guard let startedAt, let assistantEventAt else { return nil }
        // A malformed/out-of-order log must not create a negative duration;
        // cap the end at the usage event because token_count is the enclosing
        // response's accounting boundary.
        let end = min(assistantEventAt, usageAt)
        let duration = end.timeIntervalSince(startedAt)
        guard duration > 0, duration <= maximumGenerationWindowSeconds else {
            return nil
        }
        return duration
    }

    private static func isAssistantResponseItem(_ payload: [String: Any]) -> Bool {
        guard let rawType = payload["type"] as? String else { return false }
        let type = rawType.lowercased().replacingOccurrences(of: "_", with: "")
        switch type {
        case "reasoning", "customtoolcall", "functioncall", "toolcall", "agentmessage", "assistantmessage":
            return true
        case "message":
            let role = nonEmptyString(payload["role"])
                ?? nonEmptyString((payload["message"] as? [String: Any])?["role"])
            return role?.lowercased() == "assistant"
        default:
            return false
        }
    }

    private static func isAssistantItemCompleted(_ payload: [String: Any]) -> Bool {
        guard
            let item = payload["item"] as? [String: Any],
            let rawType = item["type"] as? String
        else { return false }
        let type = rawType.lowercased().replacingOccurrences(of: "_", with: "")
        return type == "reasoning"
            || type == "agentmessage"
            || type == "assistantmessage"
            || type == "assistantoutput"
    }

    private static func isToolBoundaryResponseItem(_ payload: [String: Any]) -> Bool {
        guard let rawType = payload["type"] as? String else { return false }
        let type = rawType.lowercased().replacingOccurrences(of: "_", with: "")
        return type == "customtoolcalloutput"
            || type == "functioncalloutput"
            || type == "toolcalloutput"
            || type == "toolresult"
    }

    private static func isToolBoundaryItemCompleted(_ payload: [String: Any]) -> Bool {
        guard
            let item = payload["item"] as? [String: Any],
            let rawType = item["type"] as? String
        else { return false }
        let type = rawType.lowercased().replacingOccurrences(of: "_", with: "")
        return type == "commandexecution"
            || type == "collabagenttoolcall"
            || type == "contextcompaction"
            || type == "extension"
            || type == "filechange"
            || type == "imageview"
            || type == "mcptoolcall"
            || type == "subagentactivity"
            || type == "toolcall"
            || type == "toolresult"
            || type == "tooloutput"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func title(from value: Any?) -> String? {
        let raw: String?
        if let string = value as? String {
            raw = string
        } else if let values = value as? [[String: Any]] {
            raw = values.compactMap { item in
                (item["text"] as? String)
                    ?? (item["input_text"] as? String)
                    ?? ((item["content"] as? String))
            }.joined(separator: " ")
        } else if let dictionary = value as? [String: Any] {
            raw = (dictionary["text"] as? String)
                ?? (dictionary["input_text"] as? String)
                ?? (dictionary["content"] as? String)
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        let normalized = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !isInjectedContext(normalized) else { return nil }
        if normalized.count <= 120 { return normalized }
        return String(normalized.prefix(117)) + "…"
    }

    private static func isInjectedContext(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        let prefixes = ["<system", "system:", "you are chatgpt", "environment_context", "app-context"]
        if prefixes.contains(where: lowercased.hasPrefix) { return true }
        let markers = ["<environment_context>", "<instructions>", "agents.md", "codex instructions"]
        return markers.contains(where: lowercased.contains)
    }

    private static func tokenCounts(from value: Any?) -> TokenCounts? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return TokenCounts(
            inputTokens: nonnegativeInteger(dictionary["input_tokens"]),
            outputTokens: nonnegativeInteger(dictionary["output_tokens"]),
            cacheReadTokens: nonnegativeInteger(dictionary["cached_input_tokens"]),
            cacheWriteTokens: nonnegativeInteger(dictionary["cache_write_input_tokens"])
        )
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int64 {
        let integer: Int64
        if let number = value as? NSNumber {
            integer = number.int64Value
        } else if let string = value as? String, let parsed = Int64(string) {
            integer = parsed
        } else {
            integer = 0
        }
        return max(0, integer)
    }

    private static func modelName(from value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dictionary = value as? [String: Any] {
            return modelName(from: dictionary["id"])
                ?? modelName(from: dictionary["model"])
        }
        return nil
    }
}

private struct TokenCounts: Equatable {
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheWriteTokens: Int64

    var hasUsage: Bool {
        inputTokens > 0 || outputTokens > 0 || cacheReadTokens > 0 || cacheWriteTokens > 0
    }

    func delta(since previous: TokenCounts?) -> TokenCounts {
        guard let previous else { return self }
        return TokenCounts(
            inputTokens: Self.componentDelta(inputTokens, previous.inputTokens),
            outputTokens: Self.componentDelta(outputTokens, previous.outputTokens),
            cacheReadTokens: Self.componentDelta(cacheReadTokens, previous.cacheReadTokens),
            cacheWriteTokens: Self.componentDelta(cacheWriteTokens, previous.cacheWriteTokens)
        )
    }

    private static func componentDelta(_ current: Int64, _ previous: Int64) -> Int64 {
        current >= previous ? current - previous : current
    }
}
