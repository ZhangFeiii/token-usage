import Foundation
import SQLite3
import XCTest
@testable import TokenBallCore

final class LocalUsageCollectorTests: XCTestCase {
    func testCodexJSONLParserUsesLastUsageAndCumulativeFallback() throws {
        let jsonl = """
        {"type":"turn_context","timestamp":"2026-08-17T02:00:00.000Z","payload":{"model":"gpt-test","turn_id":"turn-1"}}
        {"type":"event_msg","timestamp":"2026-08-17T02:01:00.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120},"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}
        {"type":"event_msg","timestamp":"2026-08-17T02:01:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120},"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}
        {"type":"event_msg","timestamp":"2026-08-17T02:02:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":40,"cache_write_input_tokens":10,"output_tokens":30,"reasoning_output_tokens":8,"total_tokens":180}}}}
        """

        let records = CodexJSONLUsageParser().parse(
            content: jsonl,
            sourceID: "rollout-test"
        )

        XCTAssertEqual(records.count, 2)
        let first = try XCTUnwrap(records.first)
        XCTAssertEqual(first.id, "codex:rollout-test:2")
        XCTAssertEqual(first.agent, "codex")
        XCTAssertEqual(first.model, "gpt-test")
        XCTAssertEqual(first.freshInputTokens, 60)
        XCTAssertEqual(first.outputTokens, 20)
        XCTAssertEqual(first.cacheReadTokens, 30)
        XCTAssertEqual(first.cacheWriteTokens, 10)

        let fallback = try XCTUnwrap(records.last)
        XCTAssertEqual(fallback.id, "codex:rollout-test:4")
        XCTAssertEqual(fallback.freshInputTokens, 40)
        XCTAssertEqual(fallback.outputTokens, 10)
        XCTAssertEqual(fallback.cacheReadTokens, 10)
        XCTAssertEqual(fallback.cacheWriteTokens, 0)
    }

    func testOpenCodeSessionRowMappingNormalizesModelTokensAndMilliseconds() throws {
        let row = OpenCodeSessionRow(
            id: "session-1",
            sessionAgent: "build",
            model: #"{"id":"deepseek-v4","providerID":"deepseek","variant":"max"}"#,
            inputTokens: 100,
            outputTokens: 20,
            reasoningTokens: 5,
            cacheReadTokens: 30,
            cacheWriteTokens: 10,
            timeCreated: 1_786_000_000_000,
            timeUpdated: 1_786_629_030_650
        )

        let record = try XCTUnwrap(OpenCodeSessionRowMapper.usageRecord(from: row))

        XCTAssertEqual(record.id, "opencode:session:session-1")
        XCTAssertEqual(record.agent, "opencode")
        XCTAssertEqual(record.model, "deepseek-v4")
        XCTAssertEqual(record.freshInputTokens, 100)
        XCTAssertEqual(record.outputTokens, 25)
        XCTAssertEqual(record.cacheReadTokens, 30)
        XCTAssertEqual(record.cacheWriteTokens, 10)
        XCTAssertEqual(record.recordedAt.timeIntervalSince1970, 1_786_629_030.650, accuracy: 0.001)
    }

    func testOpenCodeSessionRowPricingSelectsCurrencyByModel() throws {
        // DeepSeek models are estimated in CNY using the Beijing peak/valley schedule.
        let deepSeekRow = OpenCodeSessionRow(
            id: "session-ds",
            sessionAgent: "build",
            model: #"{"id":"deepseek-v4-flash","providerID":"deepseek","variant":"max"}"#,
            inputTokens: 100,
            outputTokens: 20,
            reasoningTokens: 5,
            cacheReadTokens: 30,
            cacheWriteTokens: 10,
            timeCreated: 1_787_332_980_000,
            timeUpdated: 1_787_332_980_000
        )
        let deepSeekRecord = try XCTUnwrap(OpenCodeSessionRowMapper.usageRecord(from: deepSeekRow))
        XCTAssertEqual(deepSeekRecord.costMicrosCNY, 279)
        XCTAssertEqual(deepSeekRecord.costMicrosUSD, 0)

        // GPT models are billed in USD.
        let gptRow = OpenCodeSessionRow(
            id: "session-gpt",
            sessionAgent: "build",
            model: "gpt-5.6-luna",
            inputTokens: 100,
            outputTokens: 20,
            reasoningTokens: 0,
            cacheReadTokens: 30,
            cacheWriteTokens: 10,
            timeCreated: 1_787_332_980_000,
            timeUpdated: 1_787_332_980_000
        )
        let gptRecord = try XCTUnwrap(OpenCodeSessionRowMapper.usageRecord(from: gptRow))
        XCTAssertEqual(gptRecord.costMicrosUSD, 47)
        XCTAssertEqual(gptRecord.costMicrosCNY, 0)

        // Models without published rates stay free.
        let freeRow = OpenCodeSessionRow(
            id: "session-free",
            sessionAgent: "build",
            model: "custom-model",
            inputTokens: 100,
            outputTokens: 20,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            timeCreated: 1_787_332_980_000,
            timeUpdated: 1_787_332_980_000
        )
        let freeRecord = try XCTUnwrap(OpenCodeSessionRowMapper.usageRecord(from: freeRow))
        XCTAssertEqual(freeRecord.costMicrosUSD, 0)
        XCTAssertEqual(freeRecord.costMicrosCNY, 0)
    }

    func testCollectorImportsCanonicalJSONDirectoryOnceUntilFileChanges() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBallJSONImportTests-\(UUID().uuidString)", isDirectory: true)
        let importURL = rootURL.appendingPathComponent("imports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: importURL,
            withIntermediateDirectories: true
        )
        let document = """
        {
          "records": [
            {
              "id": "external:event-1",
              "agent": "external-agent",
              "model": "external-model",
              "freshInputTokens": 12,
              "outputTokens": 3,
              "cacheReadTokens": 4,
              "cacheWriteTokens": 1,
              "recordedAt": "2026-08-18T08:30:45Z"
            }
          ]
        }
        """
        try Data(document.utf8).write(
            to: importURL.appendingPathComponent("external.json")
        )

        let repository = SQLiteUsageRepository(
            databaseURL: rootURL.appendingPathComponent("usage.sqlite3")
        )
        let collector = LocalUsageCollector(
            store: repository,
            codexArchiveDirectoryURL: rootURL.appendingPathComponent("missing-codex"),
            codexSessionDirectoryURL: rootURL.appendingPathComponent("missing-codex-sessions"),
            openCodeDatabaseURL: rootURL.appendingPathComponent("missing-opencode.db"),
            deepSeekHarnessSessionDirectoryURLs: [
                rootURL.appendingPathComponent("missing-deepseek-harness")
            ],
            jsonImportDirectoryURL: importURL
        )

        let firstReport = await collector.collect()
        let unchangedReport = await collector.collect()

        XCTAssertEqual(firstReport.discoveredRecordCount, 1)
        XCTAssertEqual(firstReport.importedRecordCount, 1)
        XCTAssertTrue(firstReport.issues.isEmpty)
        XCTAssertEqual(unchangedReport.discoveredRecordCount, 0)
        XCTAssertEqual(unchangedReport.importedRecordCount, 0)
        XCTAssertTrue(unchangedReport.issues.isEmpty)
    }

    func testCollectorCachesOpenCodeDatabaseUntilMainFileChanges() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBallOpenCodeCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let openCodeDatabaseURL = rootURL.appendingPathComponent("opencode.db")
        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        try createOpenCodeDatabase(at: openCodeDatabaseURL, nowMilliseconds: nowMilliseconds)

        let repository = SQLiteUsageRepository(
            databaseURL: rootURL.appendingPathComponent("usage.sqlite3")
        )
        let collector = LocalUsageCollector(
            store: repository,
            codexArchiveDirectoryURL: rootURL.appendingPathComponent("missing-codex"),
            codexSessionDirectoryURL: rootURL.appendingPathComponent("missing-codex-sessions"),
            openCodeDatabaseURL: openCodeDatabaseURL,
            deepSeekHarnessSessionDirectoryURLs: [rootURL.appendingPathComponent("missing-dsh")],
            jsonImportDirectoryURL: rootURL.appendingPathComponent("imports")
        )

        let firstReport = await collector.collect()
        let unchangedReport = await collector.collect()

        XCTAssertEqual(firstReport.discoveredRecordCount, 1)
        XCTAssertTrue(firstReport.dataChanged)
        XCTAssertEqual(unchangedReport.discoveredRecordCount, 0)
        XCTAssertFalse(unchangedReport.dataChanged)

        let changedDate = Date().addingTimeInterval(120)
        let changedMilliseconds = Int64(changedDate.timeIntervalSince1970 * 1_000)
        try updateOpenCodeDatabase(
            at: openCodeDatabaseURL,
            nowMilliseconds: changedMilliseconds
        )
        // Some filesystems expose only coarse mtime resolution. Set a known
        // future timestamp so this test exercises the fingerprint even when
        // the SQLite update happens within one clock tick.
        try FileManager.default.setAttributes(
            [.modificationDate: changedDate],
            ofItemAtPath: openCodeDatabaseURL.path
        )

        let changedReport = await collector.collect()
        XCTAssertEqual(changedReport.discoveredRecordCount, 1)
        XCTAssertTrue(changedReport.dataChanged)
        let snapshot = try await repository.fetchUsage(now: changedDate)
        let openCode = try XCTUnwrap(snapshot.agents.first { $0.id == "opencode" })
        XCTAssertEqual(openCode.todayTokens, 75)
    }

    func testAdditionalSourcesAreCalledOnEveryCollectionButStableRowsAreCached() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBallAdditionalSourceCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let source = CountingAdditionalSource(
            sourceID: "future-agent",
            records: [UsageRecord(
                id: "future-cache-1",
                agent: "future-agent",
                model: "future-model",
                freshInputTokens: 42,
                outputTokens: 0,
                recordedAt: Date()
            )]
        )
        let repository = SQLiteUsageRepository(
            databaseURL: rootURL.appendingPathComponent("usage.sqlite3")
        )
        let collector = LocalUsageCollector(
            store: repository,
            codexArchiveDirectoryURL: rootURL.appendingPathComponent("missing-codex"),
            codexSessionDirectoryURL: rootURL.appendingPathComponent("missing-codex-sessions"),
            openCodeDatabaseURL: rootURL.appendingPathComponent("missing-opencode.db"),
            deepSeekHarnessSessionDirectoryURLs: [rootURL.appendingPathComponent("missing-dsh")],
            jsonImportDirectoryURL: rootURL.appendingPathComponent("imports"),
            additionalSources: [source]
        )

        let firstReport = await collector.collect()
        let secondReport = await collector.collect()

        XCTAssertEqual(firstReport.discoveredRecordCount, 1)
        XCTAssertTrue(firstReport.dataChanged)
        XCTAssertEqual(secondReport.discoveredRecordCount, 0)
        XCTAssertFalse(secondReport.dataChanged)
        let callCount = await source.callCount
        XCTAssertEqual(callCount, 2)
        let snapshot = try await repository.fetchUsage(now: Date())
        XCTAssertEqual(snapshot.todayTotal, 42)
    }

    func testCollectorImportsAllSelfOwnedSourcesAndPurgesLegacyCCSwitchRecords() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBallSelfOwnedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let now = Date()
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let codexArchiveURL = rootURL.appendingPathComponent("codex", isDirectory: true)
        let openCodeDatabaseURL = rootURL.appendingPathComponent("opencode.db")
        let harnessSessionURL = rootURL
            .appendingPathComponent("dsh", isDirectory: true)
            .appendingPathComponent("session-a", isDirectory: true)
        let importURL = rootURL.appendingPathComponent("imports", isDirectory: true)

        try FileManager.default.createDirectory(
            at: codexArchiveURL,
            withIntermediateDirectories: true
        )
        let codexTimestamp = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-60)
        )
        try Data("""
        {"type":"turn_context","timestamp":"\(codexTimestamp)","payload":{"model":"gpt-test"}}
        {"type":"event_msg","timestamp":"\(codexTimestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120},"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}
        """.utf8).write(to: codexArchiveURL.appendingPathComponent("rollout.jsonl"))

        try createOpenCodeDatabase(at: openCodeDatabaseURL, nowMilliseconds: nowMilliseconds)

        try FileManager.default.createDirectory(
            at: harnessSessionURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: harnessSessionURL.appendingPathComponent("session.jsonl.zstd"))

        try FileManager.default.createDirectory(
            at: importURL,
            withIntermediateDirectories: true
        )
        try Data("""
        {"records":[{"id":"external:event-1","agent":"external-agent","model":"external-model","freshInputTokens":12,"outputTokens":3,"recordedAt":\(Int64(now.timeIntervalSince1970))}]}
        """.utf8).write(to: importURL.appendingPathComponent("external.json"))

        let repository = SQLiteUsageRepository(
            databaseURL: rootURL.appendingPathComponent("usage.sqlite3")
        )
        // Records imported by the removed CC Switch statistics source must not
        // survive the migration and double count against self-owned sources.
        try await repository.append(
            UsageRecord(
                id: "cc-switch:legacy:1",
                agent: "codex",
                model: "legacy-model",
                freshInputTokens: 999,
                outputTokens: 1,
                recordedAt: now
            )
        )
        let collector = LocalUsageCollector(
            store: repository,
            codexArchiveDirectoryURL: codexArchiveURL,
            codexSessionDirectoryURL: rootURL.appendingPathComponent("missing-codex-sessions"),
            openCodeDatabaseURL: openCodeDatabaseURL,
            deepSeekHarnessSessionDirectoryURLs: [
                rootURL.appendingPathComponent("dsh", isDirectory: true)
            ],
            jsonImportDirectoryURL: importURL,
            zstdDecompressor: StaticDSHZstdDecompressor(content: """
            {"type":"request/context","data":{"model":"deepseek-v4-flash"}}
            {"type":"assistant/chunk","time":\(nowMilliseconds),"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":10}}}}
            """)
        )

        let firstReport = await collector.collect()
        XCTAssertTrue(firstReport.issues.isEmpty)
        XCTAssertEqual(firstReport.discoveredRecordCount, 4)
        XCTAssertEqual(firstReport.importedRecordCount, 4)

        var snapshot = try await repository.fetchUsage(now: now)
        XCTAssertEqual(snapshot.todayTotal, 310)
        let codex = try XCTUnwrap(snapshot.agents.first { $0.id == "codex" })
        XCTAssertEqual(codex.todayTokens, 120)
        XCTAssertEqual(codex.models.map(\.model), ["gpt-test"])
        let openCode = try XCTUnwrap(snapshot.agents.first { $0.id == "opencode" })
        XCTAssertEqual(openCode.todayTokens, 65)
        let deepSeek = try XCTUnwrap(snapshot.agents.first { $0.id == "deepseek" })
        XCTAssertEqual(deepSeek.todayTokens, 110)
        XCTAssertEqual(deepSeek.models.map(\.model), ["deepseek-v4-flash"])
        let external = try XCTUnwrap(snapshot.agents.first { $0.id == "other:external-agent" })
        XCTAssertEqual(external.todayTokens, 15)

        // The legacy cc-switch record was purged: its 1000 tokens are absent.
        let secondReport = await collector.collect()
        // All local files are unchanged, so the collector skips every source
        // read on the second pass and emits no snapshot invalidation.
        XCTAssertEqual(secondReport.discoveredRecordCount, 0)
        XCTAssertEqual(secondReport.importedRecordCount, 0)
        XCTAssertFalse(secondReport.dataChanged)
        XCTAssertTrue(secondReport.issues.isEmpty)
        snapshot = try await repository.fetchUsage(now: now)
        XCTAssertEqual(snapshot.todayTotal, 310)
    }

    func testCollectorPurgesLegacyCCSwitchRecordsWhenNoNewRecords() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBallLegacyPurgeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let now = Date()

        let repository = SQLiteUsageRepository(
            databaseURL: rootURL.appendingPathComponent("usage.sqlite3")
        )
        try await repository.append(
            UsageRecord(
                id: "cc-switch:legacy:1",
                agent: "codex",
                model: "legacy-model",
                freshInputTokens: 10,
                outputTokens: 1,
                recordedAt: now
            )
        )
        let collector = LocalUsageCollector(
            store: repository,
            codexArchiveDirectoryURL: rootURL.appendingPathComponent("missing-codex"),
            codexSessionDirectoryURL: rootURL.appendingPathComponent("missing-codex-sessions"),
            openCodeDatabaseURL: rootURL.appendingPathComponent("missing-opencode.db"),
            deepSeekHarnessSessionDirectoryURLs: [
                rootURL.appendingPathComponent("missing-deepseek-harness")
            ],
            jsonImportDirectoryURL: rootURL.appendingPathComponent("imports")
        )

        let report = await collector.collect()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.discoveredRecordCount, 0)
        XCTAssertEqual(report.importedRecordCount, 0)

        let snapshot = try await repository.fetchUsage(now: now)
        XCTAssertTrue(snapshot.agents.isEmpty)
        XCTAssertEqual(snapshot.todayTotal, 0)
    }

    func testCollectorImportsCodexSessionsFromNestedDirectories() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBallCodexSessionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let now = Date()
        let sessionURL = rootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("08", isDirectory: true)
            .appendingPathComponent("23", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionURL,
            withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        try Data("""
        {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"gpt-test"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120},"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}
        """.utf8).write(
            to: sessionURL.appendingPathComponent(
                "rollout-2026-08-23T02-00-00-01a02abb-c0a2-79d3-b168-d637fd9b8348.jsonl"
            )
        )

        let repository = SQLiteUsageRepository(
            databaseURL: rootURL.appendingPathComponent("usage.sqlite3")
        )
        let collector = LocalUsageCollector(
            store: repository,
            codexArchiveDirectoryURL: rootURL.appendingPathComponent("missing-archive"),
            codexSessionDirectoryURL: rootURL.appendingPathComponent("sessions"),
            openCodeDatabaseURL: rootURL.appendingPathComponent("missing-opencode.db"),
            deepSeekHarnessSessionDirectoryURLs: [
                rootURL.appendingPathComponent("missing-dsh")
            ],
            jsonImportDirectoryURL: rootURL.appendingPathComponent("imports")
        )

        let report = await collector.collect()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.discoveredRecordCount, 1)
        XCTAssertEqual(report.importedRecordCount, 1)

        let snapshot = try await repository.fetchUsage(now: now)
        let codex = try XCTUnwrap(snapshot.agents.first { $0.id == "codex" })
        XCTAssertEqual(codex.todayTokens, 120)
        XCTAssertEqual(codex.models.first?.model, "gpt-test")
        XCTAssertEqual(codex.models.first?.todayTokens, 120)
    }

    func testCollectorSkipsCodexSessionsOutsideTwentyWeekWindow() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBallCodexWindowTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sessionURL = rootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("07", isDirectory: true)
            .appendingPathComponent("01", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionURL,
            withIntermediateDirectories: true
        )
        let fileURL = sessionURL.appendingPathComponent(
            "rollout-2026-07-01T02-00-00-01a02abb-c0a2-79d3-b168-d637fd9b8348.jsonl"
        )
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        try Data("""
        {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"gpt-test"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}
        """.utf8).write(to: fileURL)
        let oldDate = Date().addingTimeInterval(-150 * 86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: fileURL.path
        )

        let repository = SQLiteUsageRepository(
            databaseURL: rootURL.appendingPathComponent("usage.sqlite3")
        )
        let collector = LocalUsageCollector(
            store: repository,
            codexArchiveDirectoryURL: rootURL.appendingPathComponent("missing-archive"),
            codexSessionDirectoryURL: rootURL.appendingPathComponent("sessions"),
            openCodeDatabaseURL: rootURL.appendingPathComponent("missing-opencode.db"),
            deepSeekHarnessSessionDirectoryURLs: [
                rootURL.appendingPathComponent("missing-dsh")
            ],
            jsonImportDirectoryURL: rootURL.appendingPathComponent("imports")
        )

        let report = await collector.collect()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.discoveredRecordCount, 0)
        XCTAssertEqual(report.importedRecordCount, 0)

        let snapshot = try await repository.fetchUsage(now: Date())
        XCTAssertTrue(snapshot.agents.isEmpty)
    }

    private func createOpenCodeDatabase(at databaseURL: URL, nowMilliseconds: Int64) throws {
        var databasePointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &databasePointer), SQLITE_OK)
        let database = try XCTUnwrap(databasePointer)
        defer { sqlite3_close(database) }

        try executeSQL(
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                agent TEXT,
                model TEXT,
                tokens_input INTEGER,
                tokens_output INTEGER,
                tokens_reasoning INTEGER,
                tokens_cache_read INTEGER,
                tokens_cache_write INTEGER,
                time_created INTEGER,
                time_updated INTEGER
            );
            """,
            database: database
        )
        try executeSQL(
            """
            INSERT INTO session (
                id, agent, model, tokens_input, tokens_output, tokens_reasoning,
                tokens_cache_read, tokens_cache_write, time_created, time_updated
            ) VALUES (
                'opencode-session-1', 'build',
                '{"id":"deepseek-v4","providerID":"deepseek","variant":"max"}',
                50, 10, 5, 0, 0, \(nowMilliseconds), \(nowMilliseconds)
            );
            """,
            database: database
        )
    }

    private func updateOpenCodeDatabase(at databaseURL: URL, nowMilliseconds: Int64) throws {
        var databasePointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &databasePointer), SQLITE_OK)
        let database = try XCTUnwrap(databasePointer)
        defer { sqlite3_close(database) }

        try executeSQL(
            """
            UPDATE session
            SET tokens_output = 20,
                time_updated = \(nowMilliseconds)
            WHERE id = 'opencode-session-1';
            """,
            database: database
        )
    }

    private func executeSQL(_ sql: String, database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw LocalUsageCollectorTestError.sqlite(detail)
        }
    }
}

private struct StaticDSHZstdDecompressor: ZstdDecompressing {
    let content: String

    func decompress(fileURL: URL) throws -> Data {
        Data(content.utf8)
    }
}

private actor CountingAdditionalSource: UsageSourceProvider {
    let sourceID: String
    let records: [UsageRecord]
    private(set) var callCount = 0

    init(sourceID: String, records: [UsageRecord]) {
        self.sourceID = sourceID
        self.records = records
    }

    func collectRecords() async throws -> [UsageRecord] {
        callCount += 1
        return records
    }
}

private enum LocalUsageCollectorTestError: Error {
    case sqlite(String)
}
