import Foundation
import SQLite3
import XCTest
@testable import TokenBallCore

final class UsageRepositoryTests: XCTestCase {
    private var directoryURL: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBallTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("usage.sqlite3")
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    func testDefaultStoreLivesInTokenBallApplicationSupportDirectory() {
        let path = SQLiteUsageRepository.defaultDatabaseURL.standardizedFileURL.path
        XCTAssertTrue(path.contains("/Application Support/TokenBall/"), path)
        XCTAssertTrue(path.hasSuffix("/usage.sqlite3"), path)
    }

    func testMissingStoreIsCreatedWithTokenBallSchemaAndEmptySnapshot() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)

        let snapshot = try await repository.fetchUsage(
            now: context.now,
            calendar: context.calendar
        )

        XCTAssertTrue(snapshot.agents.isEmpty)
        XCTAssertEqual(snapshot.days.count, 14)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertEqual(try tableNames(in: databaseURL), ["tokenball_usage_records"])
    }

    func testAppendAndImportAggregateDaysModelsAndUnknownAgent() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        let records = [
            record(
                id: "c1",
                agent: "codex",
                model: "gpt-a",
                freshInput: 60,
                output: 20,
                cacheRead: 30,
                cacheWrite: 10,
                costMicrosUSD: 1_250_000,
                date: context.now
            ),
            record(
                id: "o1",
                agent: "opencode",
                model: "deepseek",
                freshInput: 50,
                output: 10,
                cacheRead: 5,
                cacheWrite: 2,
                date: context.now
            ),
            record(
                id: "c2",
                agent: "codex",
                model: "gpt-b",
                freshInput: 100,
                output: 20,
                cacheRead: 100,
                date: context.yesterday
            ),
            record(
                id: "u1",
                agent: "my-agent",
                model: "custom",
                freshInput: 7,
                output: 3,
                date: context.now
            )
        ]

        let result = try await repository.importRecords(records)
        let snapshot = try await repository.fetchUsage(
            now: context.now,
            calendar: context.calendar
        )

        XCTAssertEqual(result, UsageImportResult(importedCount: 4, skippedCount: 0))
        XCTAssertEqual(snapshot.agents.map(\.displayName), ["Codex", "OpenCode", "my-agent"])
        let codex = try XCTUnwrap(snapshot.agents.first { $0.id == "codex" })
        XCTAssertEqual(codex.todayTokens, 120)
        XCTAssertEqual(codex.sevenDayTokens, 340)
        XCTAssertEqual(codex.fourteenDayTokens, 340)
        XCTAssertEqual(codex.models.first { $0.model == "gpt-a" }?.todayTokens, 120)
        XCTAssertEqual(codex.models.first { $0.model == "gpt-a" }?.todayCostMicrosUSD, 1_250_000)
        XCTAssertEqual(codex.models.first { $0.model == "gpt-b" }?.sevenDayTokens, 220)
        XCTAssertEqual(snapshot.todayTotal, 197)
        XCTAssertEqual(snapshot.sevenDayTotal, 417)
        XCTAssertEqual(snapshot.fourteenDayTotal, 417)
        XCTAssertEqual(snapshot.fourteenDayAverage, 29)
        XCTAssertEqual(codex.dailyUsage.count, 14)
    }

    func testFourteenDayWindowKeepsSevenDayTotalsSeparate() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        try await repository.importRecords([
            record(id: "today", freshInput: 100, date: context.now),
            record(id: "day-6", freshInput: 60, date: context.date(daysBefore: 6)),
            record(id: "day-7", freshInput: 70, date: context.date(daysBefore: 7)),
            record(id: "day-13", freshInput: 130, date: context.date(daysBefore: 13)),
            record(id: "day-14", freshInput: 140, date: context.date(daysBefore: 14))
        ])

        let snapshot = try await repository.fetchUsage(
            now: context.now,
            calendar: context.calendar
        )

        let codex = try XCTUnwrap(snapshot.agents.first { $0.id == "codex" })
        let model = try XCTUnwrap(codex.models.first { $0.model == "gpt" })
        XCTAssertEqual(codex.dailyUsage.map(\.tokens), [130, 0, 0, 0, 0, 0, 70, 60, 0, 0, 0, 0, 0, 100])
        XCTAssertEqual(codex.sevenDayTokens, 160)
        XCTAssertEqual(codex.fourteenDayTokens, 360)
        XCTAssertEqual(model.sevenDayTokens, 160)
        XCTAssertEqual(model.fourteenDayTokens, 360)
        XCTAssertEqual(snapshot.fourteenDayAverage, 25)
    }

    func testAppendIsIdempotentForStableRecordID() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        let original = record(id: "request-1", freshInput: 10, date: context.now)
        let duplicate = record(id: "request-1", freshInput: 999, date: context.now)

        let insertedOriginal = try await repository.append(original)
        let insertedDuplicate = try await repository.append(duplicate)
        XCTAssertTrue(insertedOriginal)
        XCTAssertFalse(insertedDuplicate)

        let snapshot = try await repository.fetchUsage(
            now: context.now,
            calendar: context.calendar
        )
        XCTAssertEqual(snapshot.todayTotal, 10)
    }

    func testImportSupportsInsertOnlyAndUpsert() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        try await repository.append(
            record(id: "existing", freshInput: 10, date: context.now)
        )

        let insertOnlyResult = try await repository.importRecords(
            [
                record(id: "existing", freshInput: 50, date: context.now),
                record(id: "new", freshInput: 5, date: context.now)
            ],
            strategy: .insertOnly
        )
        var snapshot = try await repository.fetchUsage(
            now: context.now,
            calendar: context.calendar
        )
        XCTAssertEqual(insertOnlyResult, UsageImportResult(importedCount: 1, skippedCount: 1))
        XCTAssertEqual(snapshot.todayTotal, 15)

        let upsertResult = try await repository.importRecords(
            [record(id: "existing", freshInput: 50, date: context.now)],
            strategy: .upsert
        )
        snapshot = try await repository.fetchUsage(
            now: context.now,
            calendar: context.calendar
        )
        XCTAssertEqual(upsertResult, UsageImportResult(importedCount: 1, skippedCount: 0))
        XCTAssertEqual(snapshot.todayTotal, 55)
    }

    func testInvalidBulkImportDoesNotWritePartialData() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        let valid = record(id: "valid", freshInput: 10, date: context.now)
        let invalid = record(id: "invalid", freshInput: -1, date: context.now)

        do {
            try await repository.importRecords([valid, invalid])
            XCTFail("Expected invalid import to fail")
        } catch let error as UsageRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(id: "invalid", reason: "Token 数不能为负数")
            )
        }

        let snapshot = try await repository.fetchUsage(
            now: context.now,
            calendar: context.calendar
        )
        XCTAssertTrue(snapshot.agents.isEmpty)
    }

    func testRemoveRecordsByCollectorIDPrefix() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        try await repository.importRecords([
            record(id: "legacy:1", freshInput: 10, date: context.now),
            record(id: "codex:1", freshInput: 20, date: context.now),
            record(id: "opencode:1", freshInput: 30, date: context.now),
            record(id: "json:1", freshInput: 40, date: context.now)
        ])

        let removed = try await repository.removeRecords(
            withIDPrefixes: ["codex:", "opencode:"]
        )
        let snapshot = try await repository.fetchUsage(
            now: context.now,
            calendar: context.calendar
        )

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(snapshot.todayTotal, 50)
    }

    func testAliasesFoldIntoOneAgent() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        try await repository.importRecords([
            record(id: "desktop", agent: "claude-desktop", model: "sonnet", freshInput: 12, output: 8, date: context.now),
            record(id: "cli", agent: "claude", model: "opus", freshInput: 20, output: 10, date: context.now)
        ])

        let snapshot = try await repository.fetchUsage(
            now: context.now,
            calendar: context.calendar
        )

        XCTAssertEqual(snapshot.agents.filter { $0.id == "claude" }.count, 1)
        XCTAssertEqual(snapshot.agents.first { $0.id == "claude" }?.todayTokens, 50)
    }

    func testDashboardUsesResponseGenerationWindowsInsteadOfSessionLifetime() async throws {
        let context = makeDateContext()
        let repository = SQLiteUsageRepository(databaseURL: databaseURL)
        try await repository.importRecords([
            UsageRecord(
                id: "measured-1",
                agent: "codex",
                model: "gpt",
                freshInputTokens: 100,
                outputTokens: 100,
                recordedAt: context.now.addingTimeInterval(-100),
                sessionID: "measured",
                sessionStartedAt: context.now.addingTimeInterval(-7_200),
                sessionEndedAt: context.now.addingTimeInterval(-100),
                generationDurationSeconds: 10
            ),
            UsageRecord(
                id: "measured-2",
                agent: "codex",
                model: "gpt",
                freshInputTokens: 50,
                outputTokens: 50,
                recordedAt: context.now.addingTimeInterval(-50),
                sessionID: "measured",
                sessionStartedAt: context.now.addingTimeInterval(-7_200),
                sessionEndedAt: context.now.addingTimeInterval(-50),
                generationDurationSeconds: 5
            ),
            UsageRecord(
                id: "unmeasured",
                agent: "opencode",
                model: "gpt",
                freshInputTokens: 20,
                outputTokens: 20,
                recordedAt: context.now.addingTimeInterval(-25),
                sessionID: "unmeasured",
                sessionStartedAt: context.now.addingTimeInterval(-7_200),
                sessionEndedAt: context.now.addingTimeInterval(-25)
            )
        ])

        let snapshot = try await repository.fetchDashboard(
            now: context.now,
            sessionDate: context.now,
            usdToCNYRate: 7.2,
            calendar: context.calendar
        )

        let measured = try XCTUnwrap(snapshot.sessions.first { $0.sessionID == "measured" })
        XCTAssertEqual(try XCTUnwrap(measured.tokensPerSecond), 10, accuracy: 0.001)
        let unmeasured = try XCTUnwrap(snapshot.sessions.first { $0.sessionID == "unmeasured" })
        XCTAssertNil(unmeasured.tokensPerSecond)
    }

    private func record(
        id: String,
        agent: String = "codex",
        model: String = "gpt",
        freshInput: Int64,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        costMicrosUSD: Int64 = 0,
        date: Date
    ) -> UsageRecord {
        UsageRecord(
            id: id,
            agent: agent,
            model: model,
            freshInputTokens: freshInput,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            costMicrosUSD: costMicrosUSD,
            recordedAt: date
        )
    }

    private func tableNames(in url: URL) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            throw DatabaseTestError.cannotOpen
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement
        else {
            throw DatabaseTestError.cannotQuery
        }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                names.append(String(cString: value))
            }
        }
        return names
    }

    private func makeDateContext() -> DateContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 17, hour: 12)
        )!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        return DateContext(calendar: calendar, now: now, yesterday: yesterday)
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

private enum DatabaseTestError: Error {
    case cannotOpen
    case cannotQuery
}
