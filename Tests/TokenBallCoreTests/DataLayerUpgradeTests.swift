import Foundation
import SQLite3
import XCTest
@testable import TokenBallCore

final class DataLayerUpgradeTests: XCTestCase {
    private var directoryURL: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsageUpgradeTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("usage.sqlite3")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    func testUsageRecordDecodesLegacyAndCurrentMetadata() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let legacy = try decoder.decode(
            UsageRecord.self,
            from: Data(
                """
                {
                  "id":"legacy-1",
                  "agent":"codex",
                  "model":"gpt-5",
                  "freshInputTokens":10,
                  "outputTokens":2,
                  "recordedAt":1787041845.125
                }
                """.utf8
            )
        )

        XCTAssertNil(legacy.sessionID)
        XCTAssertNil(legacy.sessionTitle)
        XCTAssertNil(legacy.projectPath)
        XCTAssertNil(legacy.sessionStartedAt)
        XCTAssertNil(legacy.sessionEndedAt)
        XCTAssertEqual(legacy.requestCount, 1)

        let current = try decoder.decode(
            UsageRecord.self,
            from: Data(
                """
                {
                  "id":"current-1",
                  "agent":"codex",
                  "model":"gpt-5",
                  "freshInputTokens":10,
                  "outputTokens":2,
                  "cacheReadTokens":3,
                  "cacheWriteTokens":4,
                  "costMicrosUSD":12,
                  "costMicrosCNY":86,
                  "recordedAt":1787041845.125,
                  "sessionID":"sess-1",
                  "sessionTitle":"A real request",
                  "projectPath":"/tmp/project",
                  "sessionStartedAt":1787041800,
                  "sessionEndedAt":1787041840,
                  "generationDurationSeconds":12.5,
                  "requestCount":3
                }
                """.utf8
            )
        )

        XCTAssertEqual(current.sessionID, "sess-1")
        XCTAssertEqual(current.sessionTitle, "A real request")
        XCTAssertEqual(current.projectPath, "/tmp/project")
        XCTAssertEqual(current.sessionStartedAt?.timeIntervalSince1970, 1_787_041_800)
        XCTAssertEqual(current.sessionEndedAt?.timeIntervalSince1970, 1_787_041_840)
        XCTAssertEqual(current.requestCount, 3)
        XCTAssertEqual(current.costMicrosUSD, 12)
        XCTAssertEqual(current.costMicrosCNY, 86)
        XCTAssertEqual(try XCTUnwrap(current.generationDurationSeconds), 12.5, accuracy: 0.001)
    }

    func testSQLiteMigratesLegacySchemaInPlaceAndPreservesRows() async throws {
        let context = makeDateContext()
        try createLegacyUsageDatabase(at: databaseURL)

        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        let before = try await repository.fetchUsage(now: context.now, calendar: context.calendar)
        XCTAssertEqual(before.todayTotal, 15)
        XCTAssertEqual(before.agents.first?.models.first?.model, "legacy-model")

        let columns = try tableColumns(in: databaseURL, table: "tokenball_usage_records")
        for required in [
            "cost_micros_usd", "cost_micros_cny", "session_id", "session_title",
            "project_path", "session_started_at", "session_ended_at",
            "generation_duration_seconds", "request_count"
        ] {
            XCTAssertTrue(columns.contains(required), "migration did not add \(required)")
        }

        let migrated = UsageRecord(
            id: "new-metadata",
            agent: "codex",
            model: "gpt-5",
            freshInputTokens: 20,
            outputTokens: 5,
            costMicrosUSD: 100,
            recordedAt: context.now,
            sessionID: "sess-migrated",
            sessionTitle: "Migrated session",
            projectPath: "/tmp/migrated",
            sessionStartedAt: context.now.addingTimeInterval(-60),
            sessionEndedAt: context.now,
            requestCount: 2,
            generationDurationSeconds: 3
        )
        let inserted = try await repository.append(migrated)
        XCTAssertTrue(inserted)

        let after = try await repository.fetchDashboard(
            now: context.now,
            sessionDate: context.now,
            usdToCNYRate: 7.2,
            calendar: context.calendar
        )
        XCTAssertEqual(after.today?.inputTokens, 30)
        XCTAssertEqual(after.today?.outputTokens, 10)
        XCTAssertEqual(after.sessions.count, 2)
        let migratedSession = try XCTUnwrap(after.sessions.first { $0.sessionID == "sess-migrated" })
        XCTAssertEqual(migratedSession.requestCount, 2)
        XCTAssertEqual(migratedSession.sessionTitle, "Migrated session")
    }

    func testFetchDashboardAggregates140Days90DaysAndSelectedSessionsInCNY() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        let todayRecord = UsageRecord(
            id: "today-1",
            agent: "codex",
            model: "gpt-5",
            freshInputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 25,
            cacheWriteTokens: 5,
            costMicrosUSD: 1_000_000,
            costMicrosCNY: 2_000_000,
            recordedAt: context.now.addingTimeInterval(-1_800),
            sessionID: "today-session",
            sessionTitle: "Today",
            projectPath: "/workspace/main",
            sessionStartedAt: context.now.addingTimeInterval(-3_600),
            sessionEndedAt: context.now.addingTimeInterval(-1_800),
            requestCount: 2
        )
        let todayRecord2 = UsageRecord(
            id: "today-2",
            agent: "codex",
            model: "gpt-5",
            freshInputTokens: 50,
            outputTokens: 10,
            cacheReadTokens: 5,
            costMicrosUSD: 500_000,
            recordedAt: context.now.addingTimeInterval(-900),
            sessionID: "today-session",
            projectPath: "/workspace/main",
            sessionStartedAt: context.now.addingTimeInterval(-3_600),
            sessionEndedAt: context.now.addingTimeInterval(-900),
            requestCount: 1
        )
        let selectedCodex = UsageRecord(
            id: "selected-codex",
            agent: "codex",
            model: "gpt-5",
            freshInputTokens: 10,
            outputTokens: 5,
            cacheReadTokens: 20,
            cacheWriteTokens: 30,
            costMicrosUSD: 100_000,
            recordedAt: context.yesterday.addingTimeInterval(10 * 3_600),
            sessionID: "same-id",
            sessionTitle: "Codex session",
            projectPath: "/workspace/codex",
            sessionStartedAt: context.yesterday.addingTimeInterval(9 * 3_600),
            sessionEndedAt: context.yesterday.addingTimeInterval(10 * 3_600),
            requestCount: 2
        )
        let selectedOpenCode = UsageRecord(
            id: "selected-opencode",
            agent: "opencode",
            model: "deepseek-v4-flash",
            freshInputTokens: 20,
            outputTokens: 20,
            costMicrosUSD: 300_000,
            recordedAt: context.yesterday.addingTimeInterval(11 * 3_600),
            sessionID: "same-id",
            sessionTitle: "OpenCode session",
            projectPath: "/workspace/opencode",
            sessionStartedAt: context.yesterday.addingTimeInterval(11 * 3_600),
            sessionEndedAt: context.yesterday.addingTimeInterval(11 * 3_600 + 20),
            requestCount: 1
        )
        let day89 = UsageRecord(
            id: "day-89",
            agent: "codex",
            model: "inside-90",
            freshInputTokens: 89,
            outputTokens: 0,
            costMicrosUSD: 2_000_000,
            recordedAt: context.date(daysBefore: 89).addingTimeInterval(3_600),
            projectPath: "/workspace/inside"
        )
        let day90 = UsageRecord(
            id: "day-90",
            agent: "codex",
            model: "outside-90",
            freshInputTokens: 90,
            outputTokens: 0,
            costMicrosUSD: 3_000_000,
            recordedAt: context.date(daysBefore: 90).addingTimeInterval(3_600),
            projectPath: "/workspace/outside"
        )
        let day139 = UsageRecord(
            id: "day-139",
            agent: "codex",
            model: "old",
            freshInputTokens: 139,
            outputTokens: 0,
            costMicrosUSD: 400_000,
            recordedAt: context.date(daysBefore: 139).addingTimeInterval(3_600),
            projectPath: "/workspace/old"
        )

        try await repository.importRecords([
            todayRecord, todayRecord2, selectedCodex, selectedOpenCode,
            day89, day90, day139
        ])

        let snapshot = try await repository.fetchDashboard(
            now: context.now,
            sessionDate: context.yesterday,
            usdToCNYRate: 7.2,
            calendar: context.calendar
        )

        XCTAssertEqual(snapshot.dailyUsage.count, 140)
        XCTAssertEqual(snapshot.dailyUsage.first?.date, context.date(daysBefore: 139).startOfDay(in: context.calendar))
        XCTAssertEqual(snapshot.dailyUsage.last?.date, context.now.startOfDay(in: context.calendar))
        XCTAssertEqual(snapshot.dailyUsage.first?.tokens, 139)
        XCTAssertEqual(snapshot.dailyUsage[49].tokens, 90) // day -90 from a 140-day window
        XCTAssertEqual(snapshot.today?.tokens, 215)
        XCTAssertEqual(snapshot.usdToCNYRate, 7.2)

        // 90-day views include day -89 but exclude day -90.
        XCTAssertNotNil(snapshot.models.first { $0.model == "inside-90" })
        XCTAssertNil(snapshot.models.first { $0.model == "outside-90" })
        XCTAssertNotNil(snapshot.projects.first { $0.projectPath == "/workspace/inside" })
        XCTAssertNil(snapshot.projects.first { $0.projectPath == "/workspace/outside" })

        let todayModel = try XCTUnwrap(snapshot.models.first { $0.model == "gpt-5" && $0.agent == "codex" })
        XCTAssertEqual(todayModel.costMicrosCNY, 9_200_000 + 3_600_000 + 720_000)
        let todayProject = try XCTUnwrap(snapshot.projects.first { $0.projectPath == "/workspace/main" })
        XCTAssertEqual(todayProject.requestCount, 3)
        XCTAssertEqual(todayProject.activeDays, 1)
        XCTAssertEqual(todayProject.costMicrosCNY, 12_800_000)

        // The two sources deliberately reuse a session ID; they must remain
        // separate dashboard sessions.
        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(Set(snapshot.sessions.map(\.agent)), ["codex", "opencode"])
        let codexSession = try XCTUnwrap(snapshot.sessions.first { $0.agent == "codex" })
        XCTAssertEqual(codexSession.sessionID, "same-id")
        XCTAssertEqual(codexSession.requestCount, 2)
        XCTAssertEqual(codexSession.cacheHitRate, 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.currentHourCostMicrosCNY, 12_800_000)
    }

    func testCodexAndDeepSeekParsersAttachSessionMetadata() throws {
        let codex = CodexJSONLUsageParser().parse(
            content: """
            {"type":"session_meta","timestamp":"2026-08-17T03:00:00Z","payload":{"id":"codex-session","cwd":"/workspace/codex"}}
            {"type":"response_item","timestamp":"2026-08-17T03:00:01Z","payload":{"role":"user","content":[{"type":"input_text","text":"<system>ignore injected context</system>"}]}}
            {"type":"response_item","timestamp":"2026-08-17T03:00:02Z","payload":{"role":"user","content":[{"type":"input_text","text":"Analyze the billing report"}]}}
            {"type":"turn_context","timestamp":"2026-08-17T03:00:03Z","payload":{"model":"gpt-5"}}
            {"type":"event_msg","timestamp":"2026-08-17T03:00:04Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}
            """,
            sourceID: "rollout"
        )
        let codexRecord = try XCTUnwrap(codex.only)
        XCTAssertEqual(codexRecord.sessionID, "codex-session")
        XCTAssertEqual(codexRecord.sessionTitle, "Analyze the billing report")
        XCTAssertEqual(codexRecord.projectPath, "/workspace/codex")
        XCTAssertNotNil(codexRecord.sessionStartedAt)
        XCTAssertNotNil(codexRecord.sessionEndedAt)
        XCTAssertLessThanOrEqual(codexRecord.sessionStartedAt!, codexRecord.sessionEndedAt!)

        let dsh = DeepSeekHarnessJSONLUsageParser().parse(
            content: """
            {"type":"session","id":"dsh-session","createdAt":1786964400000,"cwd":"/workspace/dsh"}
            {"type":"session/title","time":1786964401000,"data":{"title":"DeepSeek task"}}
            {"type":"request/header","time":1786964402000,"data":{"header":{"config":{"model":"deepseek-v4-flash"}}}}
            {"type":"assistant/chunk","time":1786964403000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":20}}}}
            """,
            sourceID: "fallback-source"
        )
        let dshRecord = try XCTUnwrap(dsh.only)
        XCTAssertEqual(dshRecord.sessionID, "dsh-session")
        XCTAssertEqual(dshRecord.sessionTitle, "DeepSeek task")
        XCTAssertEqual(dshRecord.projectPath, "/workspace/dsh")
        XCTAssertNotNil(dshRecord.sessionStartedAt)
        XCTAssertNotNil(dshRecord.sessionEndedAt)
        XCTAssertEqual(dshRecord.model, "deepseek-v4-flash")
    }

    func testOpenCodeReaderHandlesCurrentJSONMessageRoleAndCountsResponses() throws {
        let url = directoryURL.appendingPathComponent("opencode-current.db")
        try createOpenCodeCurrentDatabase(at: url)

        let records = try OpenCodeUsageReader(databaseURL: url).readRecords()
        let record = try XCTUnwrap(records.only)
        XCTAssertEqual(record.sessionID, "ses-current")
        XCTAssertEqual(record.sessionTitle, "Current OpenCode session")
        XCTAssertEqual(record.projectPath, "/workspace/opencode")
        XCTAssertEqual(record.requestCount, 2)
        XCTAssertEqual(record.model, "deepseek-v4-flash")
        XCTAssertEqual(record.outputTokens, 25) // 20 output + 5 reasoning
    }

    func testECBParserAndDailyProviderCacheNetworkAndOfflineFallback() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
          <Cube><Cube time="2026-09-05"><Cube currency="USD" rate="1.08"/><Cube currency="CNY" rate="7.80"/></Cube></Cube>
        </gesmes:Envelope>
        """
        XCTAssertEqual(try ECBExchangeRateParser.parse(xml: xml), 7.80 / 1.08, accuracy: 0.000_000_1)
        XCTAssertThrowsError(try ECBExchangeRateParser.parse(xml: "<Cube><Cube currency=\"USD\" rate=\"1\"/></Cube>")) { error in
            XCTAssertEqual(error as? ECBExchangeRateParserError, .missingCurrencyRates)
        }
        XCTAssertThrowsError(try ECBExchangeRateParser.parse(xml: "not xml")) { error in
            XCTAssertEqual(error as? ECBExchangeRateParserError, .malformedXML)
        }

        let cacheURL = directoryURL.appendingPathComponent("exchange-rate.json")
        let loader = ExchangeRateLoaderProbe(payload: Data(xml.utf8))
        let provider = DailyUSDToCNYRateProvider(
            cacheURL: cacheURL,
            endpointURL: URL(string: "https://example.invalid/ecb.xml")!,
            dataLoader: { url in try await loader.load(url) }
        )
        let dayOne = Date(timeIntervalSince1970: 1_788_580_800)
        let first = await provider.currentRate(now: dayOne)
        let sameDay = await provider.currentRate(now: dayOne.addingTimeInterval(3_600))
        XCTAssertEqual(first.rate, 7.80 / 1.08, accuracy: 0.000_000_1)
        XCTAssertEqual(first, sameDay)
        let callsAfterSameDay = await loader.calls
        XCTAssertEqual(callsAfterSameDay, 1)

        await loader.setOffline(true)
        let dayTwo = dayOne.addingTimeInterval(86_400)
        let offline = await provider.currentRate(now: dayTwo)
        XCTAssertEqual(offline.rate, first.rate, accuracy: 0.000_000_1)
        XCTAssertFalse(offline.isFallback)
        XCTAssertEqual(offline.updatedAt, first.updatedAt)
        let callsAfterOffline = await loader.calls
        XCTAssertEqual(callsAfterOffline, 2)

        // The failed day is persisted too, so a newly created provider avoids
        // another network request on that same day.
        let restarted = DailyUSDToCNYRateProvider(
            cacheURL: cacheURL,
            endpointURL: URL(string: "https://example.invalid/ecb.xml")!,
            dataLoader: { url in try await loader.load(url) }
        )
        let persisted = await restarted.currentRate(now: dayTwo)
        XCTAssertEqual(persisted, offline)
        let callsAfterRestart = await loader.calls
        XCTAssertEqual(callsAfterRestart, 2)

        let fallbackCacheURL = directoryURL.appendingPathComponent("first-run-rate.json")
        let fallback = DailyUSDToCNYRateProvider(
            cacheURL: fallbackCacheURL,
            endpointURL: URL(string: "https://example.invalid/ecb.xml")!,
            dataLoader: { url in try await loader.load(url) }
        )
        let firstRun = await fallback.currentRate(now: dayOne)
        XCTAssertEqual(firstRun.rate, DailyUSDToCNYRateProvider.fallbackRate)
        XCTAssertTrue(firstRun.isFallback)
        XCTAssertNil(firstRun.updatedAt)
        let callsAfterFirstRun = await loader.calls
        XCTAssertEqual(callsAfterFirstRun, 3)
        _ = await fallback.currentRate(now: dayOne.addingTimeInterval(1_800))
        let callsAfterFallbackCache = await loader.calls
        XCTAssertEqual(callsAfterFallbackCache, 3)
    }

    func testAdditionalSourcesArePubliclyInjectableAndFailureIsIsolated() async throws {
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        let success = TestAdditionalSource(
            sourceID: "future-agent",
            records: [UsageRecord(
                id: "future-1",
                agent: "future-agent",
                model: "future-model",
                freshInputTokens: 42,
                outputTokens: 0,
                recordedAt: Date()
            )]
        )
        let failure = TestAdditionalSource(sourceID: "broken-agent", error: .unavailable)
        let collector = LocalUsageCollector(
            store: repository,
            codexArchiveDirectoryURL: directoryURL.appendingPathComponent("missing-codex"),
            codexSessionDirectoryURL: directoryURL.appendingPathComponent("missing-codex-sessions"),
            openCodeDatabaseURL: directoryURL.appendingPathComponent("missing-opencode.db"),
            deepSeekHarnessSessionDirectoryURLs: [directoryURL.appendingPathComponent("missing-dsh")],
            jsonImportDirectoryURL: directoryURL.appendingPathComponent("imports"),
            additionalSources: [success, failure]
        )

        let report = await collector.collect()
        XCTAssertEqual(report.discoveredRecordCount, 1)
        XCTAssertEqual(report.importedRecordCount, 1)
        XCTAssertEqual(report.issues.map { $0.source }, ["broken-agent"])
        let snapshot = try await repository.fetchUsage(now: Date())
        XCTAssertEqual(snapshot.todayTotal, 42)
    }

    private func makeDateContext() -> DateContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 17, hour: 12, minute: 45)
        )!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        return DateContext(calendar: calendar, now: now, yesterday: yesterday)
    }

    private func createLegacyUsageDatabase(at url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let database = pointer else {
            throw TestDatabaseError.cannotOpen
        }
        defer { sqlite3_close(database) }
        try executeSQL(
            """
            CREATE TABLE tokenball_usage_records (
                record_id TEXT PRIMARY KEY NOT NULL,
                agent TEXT NOT NULL,
                model TEXT NOT NULL,
                fresh_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL,
                cache_write_tokens INTEGER NOT NULL,
                recorded_at REAL NOT NULL
            );
            INSERT INTO tokenball_usage_records (
                record_id, agent, model, fresh_input_tokens, output_tokens,
                cache_read_tokens, cache_write_tokens, recorded_at
            ) VALUES ('legacy-row', 'codex', 'legacy-model', 10, 5, 0, 0, 1786956300);
            """,
            database: database
        )
    }

    private func createOpenCodeCurrentDatabase(at url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let database = pointer else {
            throw TestDatabaseError.cannotOpen
        }
        defer { sqlite3_close(database) }
        try executeSQL(
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                directory TEXT NOT NULL,
                title TEXT NOT NULL,
                agent TEXT,
                model TEXT,
                tokens_input INTEGER DEFAULT 0,
                tokens_output INTEGER DEFAULT 0,
                tokens_reasoning INTEGER DEFAULT 0,
                tokens_cache_read INTEGER DEFAULT 0,
                tokens_cache_write INTEGER DEFAULT 0,
                time_created INTEGER,
                time_updated INTEGER
            );
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                data TEXT NOT NULL
            );
            INSERT INTO session (
                id, directory, title, agent, model, tokens_input, tokens_output,
                tokens_reasoning, tokens_cache_read, tokens_cache_write,
                time_created, time_updated
            ) VALUES (
                'ses-current', '/workspace/opencode', 'Current OpenCode session',
                'build', '{"id":"deepseek-v4-flash","providerID":"deepseek"}',
                100, 20, 5, 10, 0, 1786956000000, 1786956300000
            );
            INSERT INTO message (id, session_id, data) VALUES
                ('msg-1', 'ses-current', '{"role":"user"}'),
                ('msg-2', 'ses-current', '{"role":"assistant"}'),
                ('msg-3', 'ses-current', '{"role":"assistant","finish":"stop"}'),
                ('msg-4', 'ses-current', '{"role":"tool"}');
            """,
            database: database
        )
    }

    private func tableColumns(in url: URL, table: String) throws -> Set<String> {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = pointer
        else { throw TestDatabaseError.cannotOpen }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw TestDatabaseError.cannotQuery }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: value))
            }
        }
        return columns
    }

    private func executeSQL(_ sql: String, database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(message)
            throw TestDatabaseError.sqlite(detail)
        }
    }
}

private struct DateContext {
    let calendar: Calendar
    let now: Date
    let yesterday: Date

    func date(daysBefore: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysBefore, to: now)!
    }
}

private extension Date {
    func startOfDay(in calendar: Calendar) -> Date {
        calendar.startOfDay(for: self)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}

private enum TestDatabaseError: Error {
    case cannotOpen
    case cannotQuery
    case sqlite(String)
}

private actor ExchangeRateLoaderProbe {
    private let payload: Data
    private var offline = false
    private(set) var calls = 0

    init(payload: Data) {
        self.payload = payload
    }

    func setOffline(_ value: Bool) {
        offline = value
    }

    func load(_ url: URL) throws -> Data {
        calls += 1
        if offline { throw ProbeError.offline }
        return payload
    }
}

private struct TestAdditionalSource: UsageSourceProvider {
    enum SourceError: Error {
        case unavailable
    }

    let sourceID: String
    let records: [UsageRecord]
    let error: SourceError?

    init(sourceID: String, records: [UsageRecord] = [], error: SourceError? = nil) {
        self.sourceID = sourceID
        self.records = records
        self.error = error
    }

    func collectRecords() async throws -> [UsageRecord] {
        if let error { throw error }
        return records
    }
}

private enum ProbeError: Error {
    case offline
}
