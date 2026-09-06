import XCTest
@testable import TokenBallCore

final class DeepSeekHarnessUsageReaderTests: XCTestCase {
    func testParserUsesLatestChunkOnceAndBackfillsMessageModel() throws {
        let content = """
        {"type":"request/header","data":{"header":{"config":{"model":"deepseek-v4-flash"}}}}
        {"type":"assistant/chunk","time":1787332980000,"data":{"turn":1,"step":2,"chunk":{"type":"usage","usage":{"inputTokens":3,"outputTokens":4,"reasoningTokens":99}}}}
        {"type":"assistant/chunk","time":1787332990000,"data":{"turn":1,"step":2,"chunk":{"type":"usage","usage":{"inputTokens":8236,"outputTokens":712,"cacheReadTokens":0,"reasoningTokens":388}}}}
        {"type":"assistant/message","time":1787333000000,"data":{"turn":1,"step":2,"message":{"source":{"model":"deepseek-v4-flash-vision-exp"},"usage":{"inputTokens":999,"outputTokens":999}}}}
        """

        let records = DeepSeekHarnessJSONLUsageParser().parse(content: content, sourceID: "session-a")

        let record = try XCTUnwrap(records.only)
        XCTAssertEqual(record.id, "deepseek-harness:session-a:1:2")
        XCTAssertEqual(record.model, "deepseek-v4-flash-vision-exp")
        XCTAssertEqual(record.freshInputTokens, 8_236)
        XCTAssertEqual(record.outputTokens, 712)
        XCTAssertEqual(record.costMicrosCNY, 15_558)
    }

    func testPricingUsesBeijingPeakWindowAndVisionBeforeFlash() {
        let offPeak = Date(timeIntervalSince1970: 1_787_332_980) // 2026-08-22 01:23 +0800
        let peak = Date(timeIntervalSince1970: 1_787_361_400) // 09:16 +0800

        XCTAssertEqual(
            DeepSeekHarnessPricing.costMicrosCNY(
                modelID: "deepseek-v4-flash-vision-exp",
                freshInputTokens: 100,
                outputTokens: 10,
                cacheReadTokens: 20,
                cacheWriteTokens: 30,
                recordedAt: offPeak
            ),
            241
        )
        XCTAssertEqual(
            DeepSeekHarnessPricing.costMicrosCNY(
                modelID: "deepseek-v4-pro",
                freshInputTokens: 100,
                outputTokens: 10,
                cacheReadTokens: 20,
                cacheWriteTokens: 30,
                recordedAt: peak
            ),
            1_446
        )
        XCTAssertTrue(DeepSeekHarnessPricing.isPeakBeijingTime(peak))
        XCTAssertFalse(DeepSeekHarnessPricing.isPeakBeijingTime(offPeak))
    }

    func testCollectorReadsInjectedZstdSessionOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBallDSHTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        let compressedURL = sessionURL.appendingPathComponent("session.jsonl.zstd")
        try Data().write(to: compressedURL)

        let repository = SQLiteUsageRepository(databaseURL: root.appendingPathComponent("usage.sqlite3"))
        let collector = LocalUsageCollector(
            store: repository,
            codexArchiveDirectoryURL: root.appendingPathComponent("missing-codex"),
            codexSessionDirectoryURL: root.appendingPathComponent("missing-codex-sessions"),
            openCodeDatabaseURL: root.appendingPathComponent("missing-opencode.db"),
            deepSeekHarnessSessionDirectoryURLs: [root],
            jsonImportDirectoryURL: root.appendingPathComponent("imports"),
            zstdDecompressor: StaticZstdDecompressor(content: """
            {"type":"request/context","data":{"model":"deepseek-v4-flash"}}
            {"type":"assistant/chunk","time":1787332980000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":10}}}}
            """)
        )

        let first = await collector.collect()
        let second = await collector.collect()
        XCTAssertEqual(first.discoveredRecordCount, 1)
        XCTAssertEqual(first.importedRecordCount, 1)
        XCTAssertEqual(second.discoveredRecordCount, 0)
        XCTAssertEqual(second.importedRecordCount, 0)

        let snapshot = try await repository.fetchUsage(
            now: Date(timeIntervalSince1970: 1_787_332_980),
            calendar: beijingCalendar
        )
        XCTAssertEqual(snapshot.agents.first?.displayName, "DSH")
        XCTAssertEqual(snapshot.agents.first?.models.first?.todayCostMicrosCNY, 195)
    }

    private var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
}

private struct StaticZstdDecompressor: ZstdDecompressing {
    let content: String

    func decompress(fileURL: URL) throws -> Data {
        Data(content.utf8)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
