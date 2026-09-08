import Foundation
import SQLite3

public protocol UsageRepository: Sendable {
    func fetchUsage(now: Date, calendar: Calendar) async throws -> UsageSnapshot

    /// Fetches the normalized aggregates used by the dashboard tabs. A
    /// default implementation keeps older repository test doubles source
    /// compatible while concrete stores can expose the richer data.
    func fetchDashboard(
        now: Date,
        sessionDate: Date,
        usdToCNYRate: Double,
        calendar: Calendar
    ) async throws -> DashboardSnapshot

    /// Fetches only the session rows for one local day. Concrete stores can
    /// use this fast path when the user changes dates without rebuilding all
    /// 140 days of dashboard aggregates.
    func fetchSessions(
        sessionDate: Date,
        usdToCNYRate: Double,
        calendar: Calendar
    ) async throws -> [DashboardSessionUsage]

    func fetchRollingHourCost(
        now: Date,
        usdToCNYRate: Double
    ) async throws -> Int64
}

public extension UsageRepository {
    func fetchDashboard(
        now: Date = Date(),
        sessionDate: Date = Date(),
        usdToCNYRate: Double = 7.2,
        calendar: Calendar = .current
    ) async throws -> DashboardSnapshot {
        DashboardSnapshot.empty(now: now, sessionDate: sessionDate, calendar: calendar)
    }

    func fetchSessions(
        sessionDate: Date,
        usdToCNYRate: Double = 7.2,
        calendar: Calendar = .current
    ) async throws -> [DashboardSessionUsage] {
        try await fetchDashboard(
            now: Date(),
            sessionDate: sessionDate,
            usdToCNYRate: usdToCNYRate,
            calendar: calendar
        ).sessions
    }

    func fetchRollingHourCost(
        now: Date = Date(),
        usdToCNYRate: Double = 7.2
    ) async throws -> Int64 {
        try await fetchDashboard(
            now: now,
            sessionDate: now,
            usdToCNYRate: usdToCNYRate,
            calendar: .current
        ).rollingHourCostMicrosCNY
    }
}

/// A mutable usage store owned entirely by TokenBall.
public protocol UsageRecordStore: UsageRepository {
    @discardableResult
    func append(_ record: UsageRecord) async throws -> Bool

    @discardableResult
    func importRecords(
        _ records: [UsageRecord],
        strategy: UsageImportStrategy
    ) async throws -> UsageImportResult

    @discardableResult
    func removeRecords(withIDPrefixes prefixes: [String]) async throws -> Int
}

/// The normalized record accepted by TokenBall's write and import APIs.
///
/// `freshInputTokens` must exclude tokens already represented by either cache
/// field. This keeps the storage contract independent from any producer's
/// database schema or token-accounting flags.
public struct UsageRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let agent: String
    public let model: String
    public let freshInputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public let costMicrosUSD: Int64
    /// Estimated DeepSeek Harness cost, represented in millionths of a CNY.
    public let costMicrosCNY: Int64
    public let recordedAt: Date
    /// Stable source session identifier. Nil is allowed for old/imported
    /// records that predate session metadata.
    public let sessionID: String?
    /// A short, user-facing title derived from the source session.
    public let sessionTitle: String?
    /// Absolute project/workspace path associated with the session.
    public let projectPath: String?
    public let sessionStartedAt: Date?
    public let sessionEndedAt: Date?
    /// Effective model-generation time represented by this row, in seconds.
    ///
    /// This is intentionally separate from the session lifecycle timestamps:
    /// a session may contain user think time, tool execution, or long idle
    /// gaps. Sources that cannot provide response-level timing leave this
    /// value nil, so the dashboard does not manufacture a misleading rate.
    public let generationDurationSeconds: Double?
    /// Number of effective model responses represented by this row.
    public let requestCount: Int

    public init(
        id: String = UUID().uuidString,
        agent: String,
        model: String,
        freshInputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0,
        costMicrosUSD: Int64 = 0,
        costMicrosCNY: Int64 = 0,
        recordedAt: Date = Date(),
        sessionID: String? = nil,
        sessionTitle: String? = nil,
        projectPath: String? = nil,
        sessionStartedAt: Date? = nil,
        sessionEndedAt: Date? = nil,
        requestCount: Int = 1,
        generationDurationSeconds: Double? = nil
    ) {
        self.id = id
        self.agent = agent
        self.model = model
        self.freshInputTokens = freshInputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costMicrosUSD = costMicrosUSD
        self.costMicrosCNY = costMicrosCNY
        self.recordedAt = recordedAt
        self.sessionID = Self.normalizedOptional(sessionID)
        self.sessionTitle = Self.normalizedOptional(sessionTitle)
        self.projectPath = Self.normalizedOptional(projectPath)
        self.sessionStartedAt = sessionStartedAt
        self.sessionEndedAt = sessionEndedAt
        if let generationDurationSeconds,
           generationDurationSeconds.isFinite,
           generationDurationSeconds > 0 {
            self.generationDurationSeconds = generationDurationSeconds
        } else {
            self.generationDurationSeconds = nil
        }
        self.requestCount = max(1, requestCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id, agent, model, freshInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, costMicrosUSD, costMicrosCNY, recordedAt
        case sessionID, sessionTitle, projectPath, sessionStartedAt, sessionEndedAt
        case generationDurationSeconds, requestCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            agent: try container.decode(String.self, forKey: .agent),
            model: try container.decode(String.self, forKey: .model),
            freshInputTokens: try container.decode(Int64.self, forKey: .freshInputTokens),
            outputTokens: try container.decode(Int64.self, forKey: .outputTokens),
            cacheReadTokens: try container.decodeIfPresent(Int64.self, forKey: .cacheReadTokens) ?? 0,
            cacheWriteTokens: try container.decodeIfPresent(Int64.self, forKey: .cacheWriteTokens) ?? 0,
            costMicrosUSD: try container.decodeIfPresent(Int64.self, forKey: .costMicrosUSD) ?? 0,
            costMicrosCNY: try container.decodeIfPresent(Int64.self, forKey: .costMicrosCNY) ?? 0,
            recordedAt: try container.decode(Date.self, forKey: .recordedAt),
            sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID),
            sessionTitle: try container.decodeIfPresent(String.self, forKey: .sessionTitle),
            projectPath: try container.decodeIfPresent(String.self, forKey: .projectPath),
            sessionStartedAt: try container.decodeIfPresent(Date.self, forKey: .sessionStartedAt),
            sessionEndedAt: try container.decodeIfPresent(Date.self, forKey: .sessionEndedAt),
            requestCount: try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? 1,
            generationDurationSeconds: try container.decodeIfPresent(
                Double.self,
                forKey: .generationDurationSeconds
            )
        )
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum UsageImportStrategy: Sendable {
    /// Preserve an existing record when its stable ID is encountered again.
    case insertOnly
    /// Insert new records and replace existing records with the same stable ID.
    case upsert
}

public struct UsageImportResult: Equatable, Sendable {
    public let importedCount: Int
    public let skippedCount: Int

    public init(importedCount: Int, skippedCount: Int) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
    }
}

public enum UsageRepositoryError: LocalizedError, Equatable, Sendable {
    case cannotPrepareStorage(path: String, message: String)
    case cannotOpen(message: String)
    case databaseBusy
    case schemaMismatch(missingColumns: [String])
    case invalidRecord(id: String, reason: String)
    case queryFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .cannotPrepareStorage:
            return "无法创建 TokenBall 数据目录"
        case .cannotOpen(let message):
            return "无法打开 TokenBall 数据库：\(message)"
        case .databaseBusy:
            return "TokenBall 数据库正忙，请稍后刷新"
        case .schemaMismatch(let missingColumns):
            return "TokenBall 数据库结构不兼容，缺少字段：\(missingColumns.joined(separator: "、"))"
        case .invalidRecord(_, let reason):
            return "用量记录无效：\(reason)"
        case .queryFailed(let message):
            return "访问用量记录失败：\(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .cannotPrepareStorage(let path, _):
            return "请确认 TokenBall 可以写入：\(path)"
        case .databaseBusy:
            return "等待当前写入完成后重试。"
        case .schemaMismatch:
            return "请备份后移除旧的 TokenBall 数据库，再重新启动应用。"
        case .invalidRecord:
            return "请修正导入数据后重试。"
        case .cannotOpen, .queryFailed:
            return "请检查 TokenBall 数据目录的读写权限，然后重试。"
        }
    }
}

public actor SQLiteUsageRepository: UsageRecordStore {
    public static var defaultDatabaseURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("TokenBall", isDirectory: true)
            .appendingPathComponent("usage.sqlite3", isDirectory: false)
    }

    private static let tableName = "tokenball_usage_records"
    private static let requiredColumns: Set<String> = [
        "record_id",
        "agent",
        "model",
        "fresh_input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
        "cost_micros_usd",
        "cost_micros_cny",
        "recorded_at",
        "session_id",
        "session_title",
        "project_path",
        "session_started_at",
        "session_ended_at",
        "generation_duration_seconds",
        "request_count"
    ]

    public nonisolated let databaseURL: URL
    private let busyTimeoutMilliseconds: Int32

    public init(
        databaseURL: URL = SQLiteUsageRepository.defaultDatabaseURL,
        busyTimeoutMilliseconds: Int32 = 1_500
    ) {
        self.databaseURL = databaseURL
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    }

    /// Appends one record without overwriting an existing record with the same ID.
    /// Returns `true` when the record was inserted and `false` for a duplicate ID.
    @discardableResult
    public func append(_ record: UsageRecord) async throws -> Bool {
        let result = try importRecordsSync([record], strategy: .insertOnly)
        return result.importedCount == 1
    }

    /// Imports records atomically. Validation happens before the transaction, so
    /// one invalid record leaves the store unchanged.
    @discardableResult
    public func importRecords(
        _ records: [UsageRecord],
        strategy: UsageImportStrategy = .upsert
    ) async throws -> UsageImportResult {
        try importRecordsSync(records, strategy: strategy)
    }

    /// Removes records belonging to superseded collector sources.
    @discardableResult
    public func removeRecords(withIDPrefixes prefixes: [String]) async throws -> Int {
        let prefixes = Array(
            Set(prefixes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        ).filter { !$0.isEmpty }
        guard !prefixes.isEmpty else { return 0 }

        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let sql = """
        DELETE FROM \(Self.tableName)
        WHERE substr(record_id, 1, ?) = ?
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw mapSQLiteError(code: prepareResult, message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        try execute("BEGIN IMMEDIATE", in: database)
        do {
            var removedCount = 0
            for prefix in prefixes {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, Int64(prefix.count))
                sqlite3_bind_text(statement, 2, prefix, -1, sqliteTransient)
                let stepResult = sqlite3_step(statement)
                guard stepResult == SQLITE_DONE else {
                    throw mapSQLiteError(code: stepResult, message: errorMessage(from: database))
                }
                removedCount += Int(sqlite3_changes(database))
            }
            try execute("COMMIT", in: database)
            return removedCount
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    public func fetchUsage(
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> UsageSnapshot {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let today = calendar.startOfDay(for: now)
        guard
            let firstDay = calendar.date(byAdding: .day, value: -13, to: today),
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        else {
            throw UsageRepositoryError.queryFailed(message: "无法计算本地日期范围")
        }

        let days = (0..<14).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: firstDay)
        }
        var dayIndexes: [Date: Int] = [:]
        for (index, day) in days.enumerated() {
            dayIndexes[calendar.startOfDay(for: day)] = index
        }

        let sql = """
        SELECT
            agent,
            model,
            fresh_input_tokens,
            output_tokens,
            cache_read_tokens,
            cache_write_tokens,
            cost_micros_usd,
            cost_micros_cny,
            recorded_at
        FROM \(Self.tableName)
        WHERE recorded_at >= ? AND recorded_at < ?
        ORDER BY recorded_at ASC
        """

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw mapSQLiteError(code: prepareResult, message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, firstDay.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, tomorrow.timeIntervalSince1970)

        var accumulators: [String: AgentAccumulator] = [:]
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw mapSQLiteError(code: stepResult, message: errorMessage(from: database))
            }

            let rawAgent = stringColumn(statement, index: 0, fallback: "Unknown")
            let model = stringColumn(statement, index: 1, fallback: "Unknown model")
            let identity = AgentIdentity.resolve(rawAgent)
            let costMicrosUSD = sqlite3_column_int64(statement, 6)
            let costMicrosCNY = sqlite3_column_int64(statement, 7)
            let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            let day = calendar.startOfDay(for: recordedAt)
            guard let dayIndex = dayIndexes[day] else { continue }

            var rowTokens = sqlite3_column_int64(statement, 2)
            rowTokens = TokenArithmetic.addingWithoutOverflow(
                rowTokens,
                sqlite3_column_int64(statement, 3)
            )
            rowTokens = TokenArithmetic.addingWithoutOverflow(
                rowTokens,
                sqlite3_column_int64(statement, 4)
            )
            rowTokens = TokenArithmetic.addingWithoutOverflow(
                rowTokens,
                sqlite3_column_int64(statement, 5)
            )

            var accumulator = accumulators[identity.id] ?? AgentAccumulator(identity: identity)
            accumulator.daily[dayIndex] = TokenArithmetic.addingWithoutOverflow(
                accumulator.daily[dayIndex],
                rowTokens
            )
            accumulator.fourteenDayTokens = TokenArithmetic.addingWithoutOverflow(
                accumulator.fourteenDayTokens,
                rowTokens
            )
            if dayIndex >= 7 {
                accumulator.sevenDayTokens = TokenArithmetic.addingWithoutOverflow(
                    accumulator.sevenDayTokens,
                    rowTokens
                )
            }
            if calendar.isDate(day, inSameDayAs: today) {
                accumulator.todayTokens = TokenArithmetic.addingWithoutOverflow(
                    accumulator.todayTokens,
                    rowTokens
                )
            }

            var modelAccumulator = accumulator.models[model] ?? ModelAccumulator()
            modelAccumulator.fourteenDayTokens = TokenArithmetic.addingWithoutOverflow(
                modelAccumulator.fourteenDayTokens,
                rowTokens
            )
            if dayIndex >= 7 {
                modelAccumulator.sevenDayTokens = TokenArithmetic.addingWithoutOverflow(
                    modelAccumulator.sevenDayTokens,
                    rowTokens
                )
            }
            if calendar.isDate(day, inSameDayAs: today) {
                modelAccumulator.todayTokens = TokenArithmetic.addingWithoutOverflow(
                    modelAccumulator.todayTokens,
                    rowTokens
                )
            }
            modelAccumulator.fourteenDayCostMicrosUSD = TokenArithmetic.addingWithoutOverflow(
                modelAccumulator.fourteenDayCostMicrosUSD,
                costMicrosUSD
            )
            if dayIndex >= 7 {
                modelAccumulator.sevenDayCostMicrosUSD = TokenArithmetic.addingWithoutOverflow(
                    modelAccumulator.sevenDayCostMicrosUSD,
                    costMicrosUSD
                )
            }
            modelAccumulator.fourteenDayCostMicrosCNY = TokenArithmetic.addingWithoutOverflow(
                modelAccumulator.fourteenDayCostMicrosCNY,
                costMicrosCNY
            )
            if dayIndex >= 7 {
                modelAccumulator.sevenDayCostMicrosCNY = TokenArithmetic.addingWithoutOverflow(
                    modelAccumulator.sevenDayCostMicrosCNY,
                    costMicrosCNY
                )
            }
            if calendar.isDate(day, inSameDayAs: today) {
                modelAccumulator.todayCostMicrosCNY = TokenArithmetic.addingWithoutOverflow(
                    modelAccumulator.todayCostMicrosCNY,
                    costMicrosCNY
                )
            }
            if calendar.isDate(day, inSameDayAs: today) {
                modelAccumulator.todayCostMicrosUSD = TokenArithmetic.addingWithoutOverflow(
                    modelAccumulator.todayCostMicrosUSD,
                    costMicrosUSD
                )
            }
            accumulator.models[model] = modelAccumulator
            accumulators[identity.id] = accumulator
        }

        let agents = accumulators.values
            .sorted { lhs, rhs in
                if lhs.identity.sortPriority != rhs.identity.sortPriority {
                    return lhs.identity.sortPriority < rhs.identity.sortPriority
                }
                return lhs.identity.displayName.localizedCaseInsensitiveCompare(
                    rhs.identity.displayName
                ) == .orderedAscending
            }
            .map { accumulator in
                let dailyUsage = zip(days, accumulator.daily).map { day, tokens in
                    DailyTokenUsage(date: day, tokens: tokens)
                }
                let models = accumulator.models.map { model, totals in
                    ModelTokenUsage(
                        model: model,
                        todayTokens: totals.todayTokens,
                        sevenDayTokens: totals.sevenDayTokens,
                        fourteenDayTokens: totals.fourteenDayTokens,
                        todayCostMicrosUSD: totals.todayCostMicrosUSD,
                        sevenDayCostMicrosUSD: totals.sevenDayCostMicrosUSD,
                        fourteenDayCostMicrosUSD: totals.fourteenDayCostMicrosUSD,
                        todayCostMicrosCNY: totals.todayCostMicrosCNY,
                        sevenDayCostMicrosCNY: totals.sevenDayCostMicrosCNY,
                        fourteenDayCostMicrosCNY: totals.fourteenDayCostMicrosCNY
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.todayTokens != rhs.todayTokens { return lhs.todayTokens > rhs.todayTokens }
                    if lhs.sevenDayTokens != rhs.sevenDayTokens { return lhs.sevenDayTokens > rhs.sevenDayTokens }
                    if lhs.fourteenDayTokens != rhs.fourteenDayTokens {
                        return lhs.fourteenDayTokens > rhs.fourteenDayTokens
                    }
                    return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
                }

                return AgentUsage(
                    id: accumulator.identity.id,
                    appType: accumulator.identity.appType,
                    displayName: accumulator.identity.displayName,
                    todayTokens: accumulator.todayTokens,
                    sevenDayTokens: accumulator.sevenDayTokens,
                    fourteenDayTokens: accumulator.fourteenDayTokens,
                    dailyUsage: dailyUsage,
                    models: models
                )
            }

        return UsageSnapshot(generatedAt: now, days: days, agents: agents)
    }

    /// Returns the rolling activity/model/project aggregates and the sessions
    /// for one local calendar date. The query deliberately reads normalized
    /// rows and aggregates in Swift so old databases and source-specific
    /// metadata remain harmlessly optional.
    public func fetchDashboard(
        now: Date = Date(),
        sessionDate: Date = Date(),
        usdToCNYRate: Double = 7.2,
        calendar: Calendar = .current
    ) async throws -> DashboardSnapshot {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let today = calendar.startOfDay(for: now)
        guard
            let dailyStart = calendar.date(byAdding: .day, value: -139, to: today),
            let modelStart = calendar.date(byAdding: .day, value: -89, to: today),
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
            let selectedStart = calendar.date(
                byAdding: .day,
                value: 0,
                to: calendar.startOfDay(for: sessionDate)
            ),
            let selectedEnd = calendar.date(byAdding: .day, value: 1, to: selectedStart)
        else {
            throw UsageRepositoryError.queryFailed(message: "无法计算仪表盘日期范围")
        }

        // Include all rows needed for the three rolling views in one read.
        let lowerBound = min(dailyStart, selectedStart)
        let upperBound = max(tomorrow, selectedEnd)
        let rows = try readDashboardRows(database: database, start: lowerBound, end: upperBound)

        let safeRate = usdToCNYRate.isFinite && usdToCNYRate >= 0 ? usdToCNYRate : 7.2
        var currentHourComponents = calendar.dateComponents(
            [.era, .year, .month, .day, .hour],
            from: now
        )
        currentHourComponents.minute = 0
        currentHourComponents.second = 0
        let currentHourStart = calendar.date(from: currentHourComponents) ?? now
        let rollingHourStart = now.addingTimeInterval(-3_600)
        let hourlyCosts = rows.reduce(into: (clock: Int64(0), rolling: Int64(0))) { totals, row in
            guard row.recordedAt <= now else { return }
            let cost = Self.cnyCost(
                usdMicros: row.costMicrosUSD,
                cnyMicros: row.costMicrosCNY,
                rate: safeRate
            )
            if row.recordedAt >= currentHourStart {
                totals.clock = TokenArithmetic.addingWithoutOverflow(totals.clock, cost)
            }
            if row.recordedAt >= rollingHourStart {
                totals.rolling = TokenArithmetic.addingWithoutOverflow(totals.rolling, cost)
            }
        }
        let dailyDays = (-139...0).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }
        var dailyBuckets = dailyDays.map { _ in DashboardBucket() }
        var modelBuckets: [DashboardKey: DashboardBucket] = [:]
        var projectBuckets: [DashboardKey: DashboardBucket] = [:]
        var sessionBuckets: [String: DashboardSessionBucket] = [:]
        var dayIndexes: [Date: Int] = [:]
        for (index, date) in dailyDays.enumerated() {
            dayIndexes[calendar.startOfDay(for: date)] = index
        }

        for row in rows {
            let day = calendar.startOfDay(for: row.recordedAt)
            guard let dayIndex = dayIndexes[day] else { continue }
            let costCNY = Self.cnyCost(usdMicros: row.costMicrosUSD, cnyMicros: row.costMicrosCNY, rate: safeRate)
            dailyBuckets[dayIndex].add(row: row, costMicrosCNY: costCNY, calendar: calendar)

            // Models and projects are restricted to the 90-day window.
            if day >= modelStart {
                let modelKey = DashboardKey(agent: row.agent, value: row.model)
                modelBuckets[modelKey, default: DashboardBucket()].add(row: row, costMicrosCNY: costCNY, calendar: calendar)
                let projectKey = DashboardKey(agent: row.agent, value: row.projectPath ?? "")
                projectBuckets[projectKey, default: DashboardBucket()].add(row: row, costMicrosCNY: costCNY, calendar: calendar)
            }

            if day >= selectedStart && day < selectedEnd {
                let sessionID = row.sessionID?.isEmpty == false ? row.sessionID! : "record:\(row.id)"
                // Session IDs are only stable within one source. Include the
                // canonical agent identity in the in-memory grouping key so a
                // Codex and an OpenCode session with the same source ID never
                // get merged into one dashboard row.
                let sourceID = AgentIdentity.resolve(row.agent).id
                let key = "\(sourceID):\(sessionID)"
                sessionBuckets[key, default: DashboardSessionBucket(key: key, sessionID: sessionID)].add(
                    row: row,
                    costMicrosCNY: costCNY,
                    calendar: calendar
                )
            }
        }

        let daily = zip(dailyDays, dailyBuckets).map { day, bucket in
            DailyDashboardUsage(
                date: day,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheWriteTokens: bucket.cacheWriteTokens,
                cacheReadTokens: bucket.cacheReadTokens,
                requestCount: bucket.requestCount,
                costMicrosCNY: bucket.costMicrosCNY
            )
        }
        let models = modelBuckets.map { key, bucket in
            DashboardModelUsage(
                model: key.value,
                agent: key.agent,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheWriteTokens: bucket.cacheWriteTokens,
                cacheReadTokens: bucket.cacheReadTokens,
                requestCount: bucket.requestCount,
                costMicrosCNY: bucket.costMicrosCNY
            )
        }.sorted(by: Self.dashboardModelSort)
        let projects = projectBuckets.map { key, bucket in
            DashboardProjectUsage(
                projectPath: key.value.isEmpty ? nil : key.value,
                agent: key.agent,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheWriteTokens: bucket.cacheWriteTokens,
                cacheReadTokens: bucket.cacheReadTokens,
                requestCount: bucket.requestCount,
                activeDays: bucket.activeDays,
                lastUsed: bucket.lastUsed,
                costMicrosCNY: bucket.costMicrosCNY
            )
        }.sorted(by: Self.dashboardProjectSort)
        let sessions = Self.dashboardSessions(from: sessionBuckets.values)

        return DashboardSnapshot(
            generatedAt: now,
            sessionDate: selectedStart,
            dailyUsage: daily,
            modelUsage: models,
            projectUsage: projects,
            sessions: sessions,
            usdToCNYRate: safeRate,
            currentHourCostMicrosCNY: hourlyCosts.clock,
            rollingHourCostMicrosCNY: hourlyCosts.rolling
        )
    }

    /// Reads and aggregates only one local day's rows. This avoids repeating
    /// the 140-day dashboard scan whenever the Sessions date changes.
    public func fetchSessions(
        sessionDate: Date,
        usdToCNYRate: Double = 7.2,
        calendar: Calendar = .current
    ) async throws -> [DashboardSessionUsage] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let start = calendar.startOfDay(for: sessionDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw UsageRepositoryError.queryFailed(message: "无法计算会话日期范围")
        }

        let rows = try readDashboardRows(database: database, start: start, end: end)
        let safeRate = usdToCNYRate.isFinite && usdToCNYRate >= 0 ? usdToCNYRate : 7.2
        var buckets: [String: DashboardSessionBucket] = [:]
        for row in rows {
            let sessionID = row.sessionID?.isEmpty == false ? row.sessionID! : "record:\(row.id)"
            let sourceID = AgentIdentity.resolve(row.agent).id
            let key = "\(sourceID):\(sessionID)"
            let costCNY = Self.cnyCost(
                usdMicros: row.costMicrosUSD,
                cnyMicros: row.costMicrosCNY,
                rate: safeRate
            )
            buckets[key, default: DashboardSessionBucket(key: key, sessionID: sessionID)].add(
                row: row,
                costMicrosCNY: costCNY,
                calendar: calendar
            )
        }
        return Self.dashboardSessions(from: buckets.values)
    }

    public func fetchRollingHourCost(
        now: Date = Date(),
        usdToCNYRate: Double = 7.2
    ) async throws -> Int64 {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let sql = """
        SELECT
            COALESCE(TOTAL(cost_micros_usd), 0),
            COALESCE(TOTAL(cost_micros_cny), 0)
        FROM \(Self.tableName)
        WHERE recorded_at >= ? AND recorded_at <= ?
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw mapSQLiteError(code: prepareResult, message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(-3_600).timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw mapSQLiteError(code: stepResult, message: errorMessage(from: database))
        }
        let usd = sqlite3_column_double(statement, 0)
        let cny = sqlite3_column_double(statement, 1)
        let safeRate = usdToCNYRate.isFinite && usdToCNYRate >= 0 ? usdToCNYRate : 7.2
        let total = (max(0, usd) * safeRate + max(0, cny)).rounded()
        guard total.isFinite, total < Double(Int64.max) else { return Int64.max }
        return max(0, Int64(total))
    }

    private func importRecordsSync(
        _ records: [UsageRecord],
        strategy: UsageImportStrategy
    ) throws -> UsageImportResult {
        try records.forEach(validate)
        guard !records.isEmpty else {
            return UsageImportResult(importedCount: 0, skippedCount: 0)
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql: String
        switch strategy {
        case .insertOnly:
            sql = """
            INSERT OR IGNORE INTO \(Self.tableName) (
                record_id, agent, model, fresh_input_tokens, output_tokens,
                cache_read_tokens, cache_write_tokens, cost_micros_usd, cost_micros_cny, recorded_at,
                session_id, session_title, project_path, session_started_at, session_ended_at,
                generation_duration_seconds, request_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        case .upsert:
            sql = """
            INSERT INTO \(Self.tableName) (
                record_id, agent, model, fresh_input_tokens, output_tokens,
                cache_read_tokens, cache_write_tokens, cost_micros_usd, cost_micros_cny, recorded_at,
                session_id, session_title, project_path, session_started_at, session_ended_at,
                generation_duration_seconds, request_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(record_id) DO UPDATE SET
                agent = excluded.agent,
                model = excluded.model,
                fresh_input_tokens = excluded.fresh_input_tokens,
                output_tokens = excluded.output_tokens,
                cache_read_tokens = excluded.cache_read_tokens,
                cache_write_tokens = excluded.cache_write_tokens,
                cost_micros_usd = excluded.cost_micros_usd,
                cost_micros_cny = excluded.cost_micros_cny,
                recorded_at = excluded.recorded_at,
                session_id = excluded.session_id,
                session_title = excluded.session_title,
                project_path = excluded.project_path,
                session_started_at = excluded.session_started_at,
                session_ended_at = excluded.session_ended_at,
                generation_duration_seconds = excluded.generation_duration_seconds,
                request_count = excluded.request_count
            """
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw mapSQLiteError(code: prepareResult, message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        try execute("BEGIN IMMEDIATE", in: database)
        do {
            var importedCount = 0
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(record, to: statement)

                let stepResult = sqlite3_step(statement)
                guard stepResult == SQLITE_DONE else {
                    throw mapSQLiteError(code: stepResult, message: errorMessage(from: database))
                }
                if sqlite3_changes(database) > 0 {
                    importedCount += 1
                }
            }
            try execute("COMMIT", in: database)
            return UsageImportResult(
                importedCount: importedCount,
                skippedCount: records.count - importedCount
            )
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private func validate(_ record: UsageRecord) throws {
        let id = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = record.agent.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = record.model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !id.isEmpty else {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "记录 ID 不能为空")
        }
        guard !agent.isEmpty else {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "Agent 不能为空")
        }
        guard !model.isEmpty else {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "模型不能为空")
        }
        let tokenCounts = [
            record.freshInputTokens,
            record.outputTokens,
            record.cacheReadTokens,
            record.cacheWriteTokens
        ]
        guard tokenCounts.allSatisfy({ $0 >= 0 }) else {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "Token 数不能为负数")
        }
        guard record.costMicrosUSD >= 0 else {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "价格不能为负数")
        }
        guard record.costMicrosCNY >= 0 else {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "价格不能为负数")
        }
        guard record.recordedAt.timeIntervalSince1970.isFinite else {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "记录时间无效")
        }
        if let sessionStartedAt = record.sessionStartedAt,
           !sessionStartedAt.timeIntervalSince1970.isFinite {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "会话开始时间无效")
        }
        if let sessionEndedAt = record.sessionEndedAt,
           !sessionEndedAt.timeIntervalSince1970.isFinite {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "会话结束时间无效")
        }
        if let generationDurationSeconds = record.generationDurationSeconds,
           !generationDurationSeconds.isFinite || generationDurationSeconds <= 0 {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "模型生成时长无效")
        }
        guard record.requestCount > 0 else {
            throw UsageRepositoryError.invalidRecord(id: record.id, reason: "请求数必须大于零")
        }
    }

    private func bind(_ record: UsageRecord, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, 1, record.id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, record.agent, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, record.model, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 4, record.freshInputTokens)
        sqlite3_bind_int64(statement, 5, record.outputTokens)
        sqlite3_bind_int64(statement, 6, record.cacheReadTokens)
        sqlite3_bind_int64(statement, 7, record.cacheWriteTokens)
        sqlite3_bind_int64(statement, 8, record.costMicrosUSD)
        sqlite3_bind_int64(statement, 9, record.costMicrosCNY)
        sqlite3_bind_double(statement, 10, record.recordedAt.timeIntervalSince1970)
        bindOptionalText(record.sessionID, to: statement, index: 11)
        bindOptionalText(record.sessionTitle, to: statement, index: 12)
        bindOptionalText(record.projectPath, to: statement, index: 13)
        bindOptionalDate(record.sessionStartedAt, to: statement, index: 14)
        bindOptionalDate(record.sessionEndedAt, to: statement, index: 15)
        bindOptionalDouble(record.generationDurationSeconds, to: statement, index: 16)
        sqlite3_bind_int64(statement, 17, Int64(record.requestCount))
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindOptionalDate(_ value: Date?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }

    private func bindOptionalDouble(_ value: Double?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func openDatabase() throws -> OpaquePointer {
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw UsageRepositoryError.cannotPrepareStorage(
                path: directory.path,
                message: error.localizedDescription
            )
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let database { sqlite3_close(database) }
            throw mapSQLiteError(code: openResult, message: message, opening: true)
        }

        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        do {
            try initializeSchema(in: database)
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private func initializeSchema(in database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS \(Self.tableName) (
                record_id TEXT PRIMARY KEY NOT NULL,
                agent TEXT NOT NULL,
                model TEXT NOT NULL,
                fresh_input_tokens INTEGER NOT NULL CHECK(fresh_input_tokens >= 0),
                output_tokens INTEGER NOT NULL CHECK(output_tokens >= 0),
                cache_read_tokens INTEGER NOT NULL CHECK(cache_read_tokens >= 0),
                cache_write_tokens INTEGER NOT NULL CHECK(cache_write_tokens >= 0),
                cost_micros_usd INTEGER NOT NULL DEFAULT 0 CHECK(cost_micros_usd >= 0),
                cost_micros_cny INTEGER NOT NULL DEFAULT 0 CHECK(cost_micros_cny >= 0),
                recorded_at REAL NOT NULL,
                session_id TEXT,
                session_title TEXT,
                project_path TEXT,
                session_started_at REAL,
                session_ended_at REAL,
                generation_duration_seconds REAL,
                request_count INTEGER NOT NULL DEFAULT 1 CHECK(request_count > 0)
            ) WITHOUT ROWID
            """,
            in: database
        )
        // Older TokenBall databases predate cost tracking. Keep them readable
        // and migrate in place without touching any external data source.
        let columns = try tableColumns(in: database)
        if !columns.contains("cost_micros_usd") {
            try execute(
                "ALTER TABLE \(Self.tableName) ADD COLUMN cost_micros_usd INTEGER NOT NULL DEFAULT 0",
                in: database
            )
        }
        if !columns.contains("cost_micros_cny") {
            try execute(
                "ALTER TABLE \(Self.tableName) ADD COLUMN cost_micros_cny INTEGER NOT NULL DEFAULT 0",
                in: database
            )
        }
        if !columns.contains("session_id") {
            try execute(
                "ALTER TABLE \(Self.tableName) ADD COLUMN session_id TEXT",
                in: database
            )
        }
        if !columns.contains("session_title") {
            try execute(
                "ALTER TABLE \(Self.tableName) ADD COLUMN session_title TEXT",
                in: database
            )
        }
        if !columns.contains("project_path") {
            try execute(
                "ALTER TABLE \(Self.tableName) ADD COLUMN project_path TEXT",
                in: database
            )
        }
        if !columns.contains("session_started_at") {
            try execute(
                "ALTER TABLE \(Self.tableName) ADD COLUMN session_started_at REAL",
                in: database
            )
        }
        if !columns.contains("session_ended_at") {
            try execute(
                "ALTER TABLE \(Self.tableName) ADD COLUMN session_ended_at REAL",
                in: database
            )
        }
        if !columns.contains("generation_duration_seconds") {
            try execute(
                "ALTER TABLE \(Self.tableName) ADD COLUMN generation_duration_seconds REAL",
                in: database
            )
        }
        if !columns.contains("request_count") {
            try execute(
                "ALTER TABLE \(Self.tableName) ADD COLUMN request_count INTEGER NOT NULL DEFAULT 1",
                in: database
            )
        }
        try execute(
            """
            CREATE INDEX IF NOT EXISTS tokenball_usage_records_recorded_at
            ON \(Self.tableName)(recorded_at)
            """,
            in: database
        )
        try validateSchema(in: database)
    }

    private func validateSchema(in database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(\(Self.tableName))",
            -1,
            &statement,
            nil
        )
        guard result == SQLITE_OK, let statement else {
            throw mapSQLiteError(code: result, message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw mapSQLiteError(code: stepResult, message: errorMessage(from: database))
            }
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }

        let missingColumns = Self.requiredColumns.subtracting(columns).sorted()
        guard missingColumns.isEmpty else {
            throw UsageRepositoryError.schemaMismatch(missingColumns: missingColumns)
        }
    }

    private func tableColumns(in database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(\(Self.tableName))",
            -1,
            &statement,
            nil
        )
        guard result == SQLITE_OK, let statement else {
            throw mapSQLiteError(code: result, message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw mapSQLiteError(code: stepResult, message: errorMessage(from: database))
            }
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? errorMessage(from: database)
            sqlite3_free(message)
            throw mapSQLiteError(code: result, message: detail)
        }
    }

    private func stringColumn(_ statement: OpaquePointer, index: Int32, fallback: String) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return fallback }
        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? fallback : string
    }

    private func optionalStringColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private func optionalDateColumn(_ statement: OpaquePointer, index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let seconds = sqlite3_column_double(statement, index)
        return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
    }

    private func optionalDoubleColumn(_ statement: OpaquePointer, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(statement, index)
        return value.isFinite && value > 0 ? value : nil
    }

    private func readDashboardRows(
        database: OpaquePointer,
        start: Date,
        end: Date
    ) throws -> [DashboardStoredRecord] {
        let sql = """
        SELECT
            record_id, agent, model, fresh_input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, cost_micros_usd,
            cost_micros_cny, recorded_at, session_id, session_title,
            project_path, session_started_at, session_ended_at,
            generation_duration_seconds, request_count
        FROM \(Self.tableName)
        WHERE recorded_at >= ? AND recorded_at < ?
        ORDER BY recorded_at ASC, record_id ASC
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw mapSQLiteError(code: prepareResult, message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)

        var rows: [DashboardStoredRecord] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw mapSQLiteError(code: stepResult, message: errorMessage(from: database))
            }
            rows.append(
                DashboardStoredRecord(
                    id: stringColumn(statement, index: 0, fallback: "record"),
                    agent: stringColumn(statement, index: 1, fallback: "Unknown"),
                    model: stringColumn(statement, index: 2, fallback: "Unknown model"),
                    inputTokens: max(0, sqlite3_column_int64(statement, 3)),
                    outputTokens: max(0, sqlite3_column_int64(statement, 4)),
                    cacheReadTokens: max(0, sqlite3_column_int64(statement, 5)),
                    cacheWriteTokens: max(0, sqlite3_column_int64(statement, 6)),
                    costMicrosUSD: max(0, sqlite3_column_int64(statement, 7)),
                    costMicrosCNY: max(0, sqlite3_column_int64(statement, 8)),
                    recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                    sessionID: optionalStringColumn(statement, index: 10),
                    sessionTitle: optionalStringColumn(statement, index: 11),
                    projectPath: optionalStringColumn(statement, index: 12),
                    sessionStartedAt: optionalDateColumn(statement, index: 13),
                    sessionEndedAt: optionalDateColumn(statement, index: 14),
                    generationDurationSeconds: optionalDoubleColumn(statement, index: 15),
                    requestCount: max(1, Int(sqlite3_column_int64(statement, 16)))
                )
            )
        }
        return rows
    }

    private static func dashboardSessions<S: Sequence>(
        from buckets: S
    ) -> [DashboardSessionUsage] where S.Element == DashboardSessionBucket {
        buckets.map { bucket in
            let output = Double(bucket.outputTokens)
            let speed: Double?
            if bucket.unmeasuredOutputTokens == 0,
               bucket.generationDurationSeconds > 0,
               bucket.generationDurationSeconds.isFinite {
                speed = output / bucket.generationDurationSeconds
            } else {
                speed = nil
            }
            let inputWithRead = bucket.inputTokens.addingReportingOverflow(bucket.cacheReadTokens)
            let denominator: (partialValue: Int64, overflow: Bool)
            if inputWithRead.overflow {
                denominator = (Int64.max, true)
            } else {
                denominator = inputWithRead.partialValue.addingReportingOverflow(bucket.cacheWriteTokens)
            }
            let inputTotal = denominator.overflow
                ? Double.greatestFiniteMagnitude
                : Double(denominator.partialValue)
            let cacheHit = inputTotal > 0 ? Double(bucket.cacheReadTokens) / inputTotal : 0
            return DashboardSessionUsage(
                sessionID: bucket.sessionID,
                sessionTitle: bucket.title,
                projectPath: bucket.projectPath,
                agent: bucket.agent,
                model: bucket.model,
                sessionStartedAt: bucket.startedAt,
                sessionEndedAt: bucket.endedAt,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheWriteTokens: bucket.cacheWriteTokens,
                cacheReadTokens: bucket.cacheReadTokens,
                requestCount: bucket.requestCount,
                costMicrosCNY: bucket.costMicrosCNY,
                tokensPerSecond: speed,
                cacheHitRate: cacheHit
            )
        }.sorted {
            if $0.costMicrosCNY != $1.costMicrosCNY { return $0.costMicrosCNY > $1.costMicrosCNY }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    private static func cnyCost(usdMicros: Int64, cnyMicros: Int64, rate: Double) -> Int64 {
        let converted = (Double(max(0, usdMicros)) * rate).rounded()
        let convertedMicros: Int64
        if !converted.isFinite || converted >= Double(Int64.max) {
            convertedMicros = Int64.max
        } else {
            convertedMicros = max(0, Int64(converted))
        }
        return TokenArithmetic.addingWithoutOverflow(convertedMicros, max(0, cnyMicros))
    }

    private static func dashboardModelSort(
        _ lhs: DashboardModelUsage,
        _ rhs: DashboardModelUsage
    ) -> Bool {
        if lhs.costMicrosCNY != rhs.costMicrosCNY { return lhs.costMicrosCNY > rhs.costMicrosCNY }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        if lhs.agent != rhs.agent { return lhs.agent < rhs.agent }
        return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
    }

    private static func dashboardProjectSort(
        _ lhs: DashboardProjectUsage,
        _ rhs: DashboardProjectUsage
    ) -> Bool {
        if lhs.costMicrosCNY != rhs.costMicrosCNY { return lhs.costMicrosCNY > rhs.costMicrosCNY }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        if lhs.agent != rhs.agent { return lhs.agent < rhs.agent }
        return (lhs.projectPath ?? "").localizedCaseInsensitiveCompare(rhs.projectPath ?? "") == .orderedAscending
    }

    private func errorMessage(from database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private func mapSQLiteError(
        code: Int32,
        message: String,
        opening: Bool = false
    ) -> UsageRepositoryError {
        if code == SQLITE_BUSY || code == SQLITE_LOCKED {
            return .databaseBusy
        }
        return opening ? .cannotOpen(message: message) : .queryFailed(message: message)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct AgentAccumulator {
    let identity: AgentIdentity
    var todayTokens: Int64 = 0
    var sevenDayTokens: Int64 = 0
    var fourteenDayTokens: Int64 = 0
    var daily: [Int64] = Array(repeating: 0, count: 14)
    var models: [String: ModelAccumulator] = [:]
}

private struct ModelAccumulator {
    var todayTokens: Int64 = 0
    var sevenDayTokens: Int64 = 0
    var fourteenDayTokens: Int64 = 0
    var todayCostMicrosUSD: Int64 = 0
    var sevenDayCostMicrosUSD: Int64 = 0
    var fourteenDayCostMicrosUSD: Int64 = 0
    var todayCostMicrosCNY: Int64 = 0
    var sevenDayCostMicrosCNY: Int64 = 0
    var fourteenDayCostMicrosCNY: Int64 = 0
}

private struct DashboardStoredRecord: Sendable {
    let id: String
    let agent: String
    let model: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheWriteTokens: Int64
    let costMicrosUSD: Int64
    let costMicrosCNY: Int64
    let recordedAt: Date
    let sessionID: String?
    let sessionTitle: String?
    let projectPath: String?
    let sessionStartedAt: Date?
    let sessionEndedAt: Date?
    let generationDurationSeconds: Double?
    let requestCount: Int
}

private struct DashboardKey: Hashable, Sendable {
    let agent: String
    let value: String
}

private struct CalendarDayKey: Hashable, Sendable {
    let era: Int
    let year: Int
    let month: Int
    let day: Int
}

private struct DashboardBucket: Sendable {
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var cacheWriteTokens: Int64 = 0
    var requestCount: Int = 0
    var costMicrosCNY: Int64 = 0
    var activeDays: Int = 0
    var lastUsed: Date?
    private var seenDays: Set<CalendarDayKey> = []

    mutating func add(row: DashboardStoredRecord, costMicrosCNY: Int64, calendar: Calendar) {
        inputTokens = TokenArithmetic.addingWithoutOverflow(inputTokens, row.inputTokens)
        outputTokens = TokenArithmetic.addingWithoutOverflow(outputTokens, row.outputTokens)
        cacheReadTokens = TokenArithmetic.addingWithoutOverflow(cacheReadTokens, row.cacheReadTokens)
        cacheWriteTokens = TokenArithmetic.addingWithoutOverflow(cacheWriteTokens, row.cacheWriteTokens)
        requestCount = requestCount.addingReportingOverflow(row.requestCount).overflow
            ? Int.max
            : requestCount + row.requestCount
        self.costMicrosCNY = TokenArithmetic.addingWithoutOverflow(self.costMicrosCNY, costMicrosCNY)
        let localDay = calendar.startOfDay(for: row.recordedAt)
        // Use calendar components rather than UTC arithmetic: the caller's
        // timezone defines a local day, including across DST transitions.
        let components = calendar.dateComponents([.era, .year, .month, .day], from: localDay)
        let dayKey = CalendarDayKey(
            era: components.era ?? 1,
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0
        )
        if seenDays.insert(dayKey).inserted { activeDays += 1 }
        if lastUsed == nil || row.recordedAt > lastUsed! { lastUsed = row.recordedAt }
    }
}

private struct DashboardSessionBucket: Sendable {
    let key: String
    let sessionID: String
    var title: String?
    var projectPath: String?
    var agent: String = "Unknown"
    var model: String = "Unknown model"
    var startedAt: Date?
    var endedAt: Date?
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var cacheWriteTokens: Int64 = 0
    var requestCount: Int = 0
    var costMicrosCNY: Int64 = 0
    /// Sum of response-level generation windows for rows with reliable timing.
    var generationDurationSeconds: TimeInterval = 0
    /// Output tokens from rows for which no reliable generation window exists.
    /// A session rate is withheld when this is non-zero rather than silently
    /// dividing only the measurable subset.
    var unmeasuredOutputTokens: Int64 = 0

    init(key: String, sessionID: String) {
        self.key = key
        self.sessionID = sessionID
        self.title = nil
        self.projectPath = nil
    }

    mutating func add(
        row: DashboardStoredRecord,
        costMicrosCNY: Int64,
        calendar: Calendar
    ) {
        // Prefer non-empty metadata, while keeping a deterministic fallback
        // when old rows contain no session fields at all.
        if let value = row.sessionTitle, !value.isEmpty, title == nil { title = value }
        if let value = row.projectPath, !value.isEmpty, projectPath == nil { projectPath = value }
        if agent == "Unknown" { agent = row.agent }
        if model == "Unknown model" { model = row.model }
        inputTokens = TokenArithmetic.addingWithoutOverflow(inputTokens, row.inputTokens)
        outputTokens = TokenArithmetic.addingWithoutOverflow(outputTokens, row.outputTokens)
        cacheReadTokens = TokenArithmetic.addingWithoutOverflow(cacheReadTokens, row.cacheReadTokens)
        cacheWriteTokens = TokenArithmetic.addingWithoutOverflow(cacheWriteTokens, row.cacheWriteTokens)
        requestCount = requestCount.addingReportingOverflow(row.requestCount).overflow
            ? Int.max
            : requestCount + row.requestCount
        self.costMicrosCNY = TokenArithmetic.addingWithoutOverflow(self.costMicrosCNY, costMicrosCNY)

        if let duration = row.generationDurationSeconds,
           duration.isFinite,
           duration > 0 {
            generationDurationSeconds += duration
        } else if row.outputTokens > 0 {
            unmeasuredOutputTokens = TokenArithmetic.addingWithoutOverflow(
                unmeasuredOutputTokens,
                row.outputTokens
            )
        }

        let started = row.sessionStartedAt ?? row.recordedAt
        let ended = row.sessionEndedAt ?? row.recordedAt
        if startedAt == nil || started < startedAt! { startedAt = started }
        if endedAt == nil || ended > endedAt! { endedAt = ended }
        // Touch the calendar so callers can pass a custom timezone without
        // changing the grouping semantics; this also documents that session
        // dates are local-calendar dates.
        _ = calendar.timeZone
    }
}
