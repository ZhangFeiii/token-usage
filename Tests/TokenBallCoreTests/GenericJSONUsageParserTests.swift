import Foundation
import XCTest
@testable import TokenBallCore

final class GenericJSONUsageParserTests: XCTestCase {
    private let parser = GenericJSONUsageParser()

    func testParsesCanonicalSingleArrayAndEnvelopeDocuments() throws {
        let record = """
        {
          "id": "adapter:event-1",
          "agent": "vendor-agent",
          "model": "vendor-model",
          "freshInputTokens": 120,
          "outputTokens": 30,
          "cacheReadTokens": 40,
          "cacheWriteTokens": 10,
          "recordedAt": "2026-08-18T08:30:45.125Z"
        }
        """

        let single = try parser.parse(content: record)
        let array = try parser.parse(content: "[\(record)]")
        let envelope = try parser.parse(content: "{\"records\":[\(record)]}")

        XCTAssertEqual(single, array)
        XCTAssertEqual(array, envelope)
        let parsed = try XCTUnwrap(single.first)
        XCTAssertEqual(parsed.id, "adapter:event-1")
        XCTAssertEqual(parsed.agent, "vendor-agent")
        XCTAssertEqual(parsed.model, "vendor-model")
        XCTAssertEqual(parsed.freshInputTokens, 120)
        XCTAssertEqual(parsed.outputTokens, 30)
        XCTAssertEqual(parsed.cacheReadTokens, 40)
        XCTAssertEqual(parsed.cacheWriteTokens, 10)
        XCTAssertEqual(parsed.recordedAt.timeIntervalSince1970, 1_787_041_845.125, accuracy: 0.001)
    }

    func testCanonicalParserAcceptsUnixMilliseconds() throws {
        let records = try parser.parse(
            content: """
            {
              "id": "adapter:event-ms",
              "agent": "vendor-agent",
              "model": "vendor-model",
              "freshInputTokens": 1,
              "outputTokens": 2,
              "cacheReadTokens": 0,
              "cacheWriteTokens": 0,
              "recordedAt": 1787041845125
            }
            """
        )

        XCTAssertEqual(
            try XCTUnwrap(records.first).recordedAt.timeIntervalSince1970,
            1_787_041_845.125,
            accuracy: 0.001
        )
    }

    func testCustomAdapterNormalizesProducerPayloadWithoutCoreChanges() throws {
        let records = try parser.parse(
            content: """
            {
              "source": "third-party",
              "events": [
                {
                  "requestID": "req-7",
                  "engine": "custom-1",
                  "promptTokens": 90,
                  "cachedTokens": 30,
                  "completionTokens": 20,
                  "createdAt": "2026-08-18T08:30:45Z"
                }
              ]
            }
            """,
            using: VendorAdapter()
        )

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, "third-party:req-7")
        XCTAssertEqual(record.agent, "third-party")
        XCTAssertEqual(record.model, "custom-1")
        XCTAssertEqual(record.freshInputTokens, 60)
        XCTAssertEqual(record.outputTokens, 20)
        XCTAssertEqual(record.cacheReadTokens, 30)
        XCTAssertEqual(record.cacheWriteTokens, 0)
    }

    func testRejectsUnsupportedTopLevelJSON() {
        XCTAssertThrowsError(try parser.parse(content: "42")) { error in
            XCTAssertEqual(
                error as? GenericJSONUsageParserError,
                .unsupportedTopLevel
            )
        }
    }

    func testRejectsInvalidNormalizedRecordBeforeStoreImport() {
        let document = """
        {
          "id": "adapter:invalid",
          "agent": "vendor-agent",
          "model": "vendor-model",
          "freshInputTokens": -1,
          "outputTokens": 0,
          "cacheReadTokens": 0,
          "cacheWriteTokens": 0,
          "recordedAt": "2026-08-18T08:30:45Z"
        }
        """

        XCTAssertThrowsError(try parser.parse(content: document)) { error in
            XCTAssertEqual(
                error as? GenericJSONUsageParserError,
                .invalidRecord(id: "adapter:invalid", reason: "Token 数不能为负数")
            )
        }
    }
}

private struct VendorAdapter: JSONUsageAdapter {
    struct Payload: Decodable, Sendable {
        let source: String
        let events: [Event]
    }

    struct Event: Decodable, Sendable {
        let requestID: String
        let engine: String
        let promptTokens: Int64
        let cachedTokens: Int64
        let completionTokens: Int64
        let createdAt: Date
    }

    func usageRecords(from payload: Payload) -> [UsageRecord] {
        payload.events.map { event in
            UsageRecord(
                id: "\(payload.source):\(event.requestID)",
                agent: payload.source,
                model: event.engine,
                freshInputTokens: max(0, event.promptTokens - event.cachedTokens),
                outputTokens: event.completionTokens,
                cacheReadTokens: event.cachedTokens,
                recordedAt: event.createdAt
            )
        }
    }
}
