import XCTest
@testable import TokenBallCore

final class OpenAIModelPricingTests: XCTestCase {
    func testPricingMatchesReferenceRates() {
        // gpt-5.6-luna: 60 fresh + 20 out + 30 cache read + 10 cache write
        // → 60×0.20 + 20×1.20 + 30×0.02 + 10×0.25 = 39.1 µUSD → 39
        XCTAssertEqual(
            OpenAIModelPricing.costMicrosUSD(
                modelID: "gpt-5.6-luna",
                freshInputTokens: 60,
                outputTokens: 20,
                cacheReadTokens: 30,
                cacheWriteTokens: 10
            ),
            39
        )

        // gpt-5.6-sol: 1M fresh input → $5
        XCTAssertEqual(
            OpenAIModelPricing.costMicrosUSD(
                modelID: "gpt-5.6-sol",
                freshInputTokens: 1_000_000,
                outputTokens: 0
            ),
            5_000_000
        )

        // Bare gpt-5.6 is a Sol alias.
        XCTAssertEqual(
            OpenAIModelPricing.costMicrosUSD(
                modelID: "gpt-5.6",
                freshInputTokens: 1_000_000,
                outputTokens: 0
            ),
            5_000_000
        )

        // gpt-5.6-terra: 100 fresh + 10 out → 200 + 120 = 320 µUSD
        XCTAssertEqual(
            OpenAIModelPricing.costMicrosUSD(
                modelID: "gpt-5.6-terra",
                freshInputTokens: 100,
                outputTokens: 10
            ),
            320
        )

        // Legacy GPT-5.5 family prices cache writes at zero.
        XCTAssertEqual(
            OpenAIModelPricing.costMicrosUSD(
                modelID: "gpt-5.5",
                freshInputTokens: 100,
                outputTokens: 10,
                cacheReadTokens: 20
            ),
            810
        )
    }

    func testPricingReturnsZeroForModelsWithoutPublishedRates() {
        XCTAssertTrue(OpenAIModelPricing.hasPublishedRate(modelID: "gpt-5.6-sol"))
        XCTAssertFalse(OpenAIModelPricing.hasPublishedRate(modelID: "codex-auto-review"))
        XCTAssertEqual(
            OpenAIModelPricing.costMicrosUSD(
                modelID: "codex-auto-review",
                freshInputTokens: 100,
                outputTokens: 10
            ),
            0
        )
        XCTAssertEqual(
            OpenAIModelPricing.costMicrosUSD(
                modelID: "unknown-model",
                freshInputTokens: 100,
                outputTokens: 10
            ),
            0
        )
    }

    func testCodexParserAttachesUSDCostForKnownModels() throws {
        let jsonl = """
        {"type":"turn_context","timestamp":"2026-08-23T02:00:00.000Z","payload":{"model":"gpt-5.6-luna"}}
        {"type":"event_msg","timestamp":"2026-08-23T02:01:00.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120},"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}
        """

        let record = try XCTUnwrap(
            CodexJSONLUsageParser().parse(content: jsonl, sourceID: "rollout-test").only
        )
        XCTAssertEqual(record.model, "gpt-5.6-luna")
        XCTAssertEqual(record.costMicrosUSD, 39)
        XCTAssertEqual(record.costMicrosCNY, 0)
    }

    func testCodexParserPricesDeepSeekRoutingInCNY() throws {
        let jsonl = """
        {"type":"turn_context","timestamp":"2026-08-23T02:00:00.000Z","payload":{"model":"deepseek-v4-flash"}}
        {"type":"event_msg","timestamp":"2026-08-23T02:01:00.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":10,"output_tokens":20,"total_tokens":120}}}}
        """

        let record = try XCTUnwrap(
            CodexJSONLUsageParser().parse(content: jsonl, sourceID: "deepseek-route").only
        )
        XCTAssertEqual(record.costMicrosUSD, 0)
        XCTAssertEqual(record.costMicrosCNY, 393)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
