import Foundation
import SQLite3

public struct OpenCodeSessionRow: Equatable, Sendable {
    public let id: String
    public let sessionAgent: String
    public let model: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public let timeCreated: Int64
    public let timeUpdated: Int64
    public let sessionTitle: String?
    public let projectPath: String?
    public let requestCount: Int

    public init(
        id: String,
        sessionAgent: String,
        model: String,
        inputTokens: Int64,
        outputTokens: Int64,
        reasoningTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64,
        timeCreated: Int64,
        timeUpdated: Int64,
        sessionTitle: String? = nil,
        projectPath: String? = nil,
        requestCount: Int = 1
    ) {
        self.id = id
        self.sessionAgent = sessionAgent
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.timeCreated = timeCreated
        self.timeUpdated = timeUpdated
        self.sessionTitle = Self.nonEmpty(sessionTitle)
        self.projectPath = Self.nonEmpty(projectPath)
        self.requestCount = max(1, requestCount)
    }

    public var title: String? { sessionTitle }
    public var directory: String? { projectPath }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum OpenCodeSessionRowMapper {
    public static func usageRecord(from row: OpenCodeSessionRow) -> UsageRecord? {
        let sessionID = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }

        let input = max(0, row.inputTokens)
        let output = max(0, row.outputTokens)
        let reasoning = max(0, row.reasoningTokens)
        let cacheRead = max(0, row.cacheReadTokens)
        let cacheWrite = max(0, row.cacheWriteTokens)
        guard input > 0 || output > 0 || reasoning > 0 || cacheRead > 0 || cacheWrite > 0 else {
            return nil
        }

        let outputIncludingReasoning = TokenArithmetic.addingWithoutOverflow(output, reasoning)
        let rawTimestamp = row.timeUpdated > 0 ? row.timeUpdated : row.timeCreated
        guard rawTimestamp > 0 else { return nil }

        let modelName = modelName(from: row.model)
        let recordedAt = date(from: rawTimestamp)
        // GPT models are billed in USD; DeepSeek models are estimated in CNY.
        let costMicrosUSD = OpenAIModelPricing.costMicrosUSD(
            modelID: modelName,
            freshInputTokens: input,
            outputTokens: outputIncludingReasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
        let costMicrosCNY = DeepSeekHarnessPricing.costMicrosCNY(
            modelID: modelName,
            freshInputTokens: input,
            outputTokens: outputIncludingReasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            recordedAt: recordedAt
        )

        let startDate = row.timeCreated > 0 ? date(from: row.timeCreated) : recordedAt
        let endDate = row.timeUpdated > 0 ? date(from: row.timeUpdated) : recordedAt

        return UsageRecord(
            id: "opencode:session:\(sessionID)",
            agent: "opencode",
            model: modelName,
            freshInputTokens: input,
            outputTokens: outputIncludingReasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            costMicrosUSD: costMicrosUSD,
            costMicrosCNY: costMicrosCNY,
            recordedAt: recordedAt,
            sessionID: sessionID,
            sessionTitle: row.sessionTitle,
            projectPath: row.projectPath,
            sessionStartedAt: startDate,
            sessionEndedAt: endDate,
            requestCount: row.requestCount
        )
    }

    private static func modelName(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }

        if
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in ["id", "model", "modelID"] {
                if let value = object[key] as? String {
                    let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !model.isEmpty { return model }
                }
            }
        }
        return trimmed
    }

    private static func date(from timestamp: Int64) -> Date {
        let absolute = timestamp == Int64.min ? Int64.max : abs(timestamp)
        let seconds = absolute >= 10_000_000_000
            ? TimeInterval(timestamp) / 1_000
            : TimeInterval(timestamp)
        return Date(timeIntervalSince1970: seconds)
    }
}

struct OpenCodeUsageReader: Sendable {
    let databaseURL: URL
    var busyTimeoutMilliseconds: Int32 = 1_500

    func readRecords() throws -> [UsageRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw OpenCodeUsageReaderError.cannotOpen(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)

        // OpenCode's schema changes between releases. Build the projection
        // from columns that are actually present so old databases remain
        // readable and newly-added metadata is picked up automatically.
        let sessionColumns = try tableColumns("session", in: database)
        guard !sessionColumns.isEmpty else { return [] }
        let idExpression = columnOrLiteral("id", in: sessionColumns, fallback: "''")
        let agentExpression = columnOrLiteral("agent", in: sessionColumns, fallback: "''")
        let modelExpression = columnOrLiteral("model", in: sessionColumns, fallback: "''")
        let inputExpression = columnOrLiteral("tokens_input", in: sessionColumns, fallback: "0")
        let outputExpression = columnOrLiteral("tokens_output", in: sessionColumns, fallback: "0")
        let reasoningExpression = columnOrLiteral("tokens_reasoning", in: sessionColumns, fallback: "0")
        let cacheReadExpression = columnOrLiteral("tokens_cache_read", in: sessionColumns, fallback: "0")
        let cacheWriteExpression = columnOrLiteral("tokens_cache_write", in: sessionColumns, fallback: "0")
        let createdExpression = firstExistingColumn(
            ["time_created", "created_at", "createdAt"],
            in: sessionColumns,
            fallback: "0"
        )
        let updatedExpression = firstExistingColumn(
            ["time_updated", "updated_at", "updatedAt"],
            in: sessionColumns,
            fallback: "0"
        )
        let titleExpression = firstExistingColumn(
            ["title", "name"],
            in: sessionColumns,
            fallback: "NULL"
        )
        let pathExpression = firstExistingColumn(
            ["directory", "path", "project_path", "projectPath"],
            in: sessionColumns,
            fallback: "NULL"
        )
        let sql = """
        SELECT
            \(idExpression),
            COALESCE(\(agentExpression), ''),
            COALESCE(\(modelExpression), ''),
            COALESCE(\(inputExpression), 0),
            COALESCE(\(outputExpression), 0),
            COALESCE(\(reasoningExpression), 0),
            COALESCE(\(cacheReadExpression), 0),
            COALESCE(\(cacheWriteExpression), 0),
            COALESCE(\(createdExpression), 0),
            COALESCE(\(updatedExpression), 0),
            \(titleExpression),
            \(pathExpression)
        FROM session
        WHERE COALESCE(\(inputExpression), 0) != 0
           OR COALESCE(\(outputExpression), 0) != 0
           OR COALESCE(\(reasoningExpression), 0) != 0
           OR COALESCE(\(cacheReadExpression), 0) != 0
           OR COALESCE(\(cacheWriteExpression), 0) != 0
        """

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw OpenCodeUsageReaderError.queryFailed(errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [OpenCodeSessionRow] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw OpenCodeUsageReaderError.queryFailed(errorMessage(from: database))
            }

            let id = stringColumn(statement, index: 0)
            let row = OpenCodeSessionRow(
                id: id,
                sessionAgent: stringColumn(statement, index: 1),
                model: stringColumn(statement, index: 2),
                inputTokens: sqlite3_column_int64(statement, 3),
                outputTokens: sqlite3_column_int64(statement, 4),
                reasoningTokens: sqlite3_column_int64(statement, 5),
                cacheReadTokens: sqlite3_column_int64(statement, 6),
                cacheWriteTokens: sqlite3_column_int64(statement, 7),
                timeCreated: sqlite3_column_int64(statement, 8),
                timeUpdated: sqlite3_column_int64(statement, 9),
                sessionTitle: optionalStringColumn(statement, index: 10),
                projectPath: optionalStringColumn(statement, index: 11),
                requestCount: 1
            )
            rows.append(row)
        }

        let messageCounts = assistantMessageCounts(in: database)
        return rows.compactMap { row in
            let count = messageCounts[row.id] ?? 1
            let enriched = OpenCodeSessionRow(
                id: row.id,
                sessionAgent: row.sessionAgent,
                model: row.model,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                reasoningTokens: row.reasoningTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWriteTokens: row.cacheWriteTokens,
                timeCreated: row.timeCreated,
                timeUpdated: row.timeUpdated,
                sessionTitle: row.sessionTitle,
                projectPath: row.projectPath,
                requestCount: max(1, count)
            )
            return OpenCodeSessionRowMapper.usageRecord(from: enriched)
        }
    }

    private func tableColumns(_ table: String, in database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(\(table))",
            -1,
            &statement,
            nil
        )
        guard result == SQLITE_OK, let statement else {
            throw OpenCodeUsageReaderError.queryFailed(errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw OpenCodeUsageReaderError.queryFailed(errorMessage(from: database))
            }
            if let value = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: value))
            }
        }
        return columns
    }

    private func columnOrLiteral(_ column: String, in columns: Set<String>, fallback: String) -> String {
        columns.contains(column) ? "\"\(column)\"" : fallback
    }

    private func firstExistingColumn(_ candidates: [String], in columns: Set<String>, fallback: String) -> String {
        guard let candidate = candidates.first(where: columns.contains) else { return fallback }
        return "\"\(candidate)\""
    }

    private func assistantMessageCounts(in database: OpaquePointer) -> [String: Int] {
        guard let columns = try? tableColumns("message", in: database), !columns.isEmpty else {
            return [:]
        }
        let sessionColumn = ["session_id", "sessionID", "sessionId"].first(where: columns.contains)
        let roleColumn = ["role", "sender", "type"].first(where: columns.contains)
        let dataColumn = ["data", "payload", "json"].first(where: columns.contains)
        guard let sessionColumn else { return [:] }

        let assistantRoles = "('assistant', 'assistant_message', 'assistant/message')"
        var rolePredicates: [String] = []
        if let roleColumn {
            rolePredicates.append(
                "lower(COALESCE(\"\(roleColumn)\", '')) IN \(assistantRoles)"
            )
        }
        if let dataColumn {
            // OpenCode's current schema stores the message role inside the
            // JSON `data` column instead of exposing a dedicated role column.
            // Guard json_extract with json_valid so one malformed row cannot
            // make the entire usage read fail.
            let roleFromJSON = "CASE WHEN json_valid(\"\(dataColumn)\") THEN COALESCE(json_extract(\"\(dataColumn)\", '$.role'), '') ELSE '' END"
            rolePredicates.append("lower(\(roleFromJSON)) IN \(assistantRoles)")
        }
        guard !rolePredicates.isEmpty else { return [:] }
        let sql = """
        SELECT \"\(sessionColumn)\", COUNT(*)
        FROM message
        WHERE \(rolePredicates.joined(separator: " OR "))
        GROUP BY \"\(sessionColumn)\"
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }
        var counts: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: rawID)
            let rawCount = sqlite3_column_int64(statement, 1)
            counts[id] = rawCount > Int64(Int.max) ? Int.max : max(0, Int(rawCount))
        }
        return counts
    }

    private func stringColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalStringColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private func errorMessage(from database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }
}

private enum OpenCodeUsageReaderError: LocalizedError {
    case cannotOpen(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let message):
            return "Unable to open OpenCode usage database: \(message)"
        case .queryFailed(let message):
            return "Unable to read OpenCode sessions: \(message)"
        }
    }
}
