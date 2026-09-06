import XCTest
@testable import TokenBallCore

final class UsageModelsTests: XCTestCase {
    func testDeepSeekHarnessIdentityUsesDSHDisplayName() {
        for alias in ["deepseek", "deepseek-harness", "dsh"] {
            XCTAssertEqual(AgentIdentity.resolve(alias).displayName, "DSH")
        }
    }

    func testModelDisplayNameShortensDeepSeekV4ModelsWithoutChangingRawID() {
        let cases = [
            ("deepseek-v4-flash-vision-exp", "dsv4-vision-exp"),
            ("deepseek-v4-flash", "dsv4-flash"),
            ("deepseek-v4-pro", "dsv4-pro"),
            ("deepseek-v4-future-preview", "dsv4-future-preview")
        ]

        for (rawID, displayName) in cases {
            let usage = ModelTokenUsage(model: rawID, todayTokens: 1, sevenDayTokens: 1)
            XCTAssertEqual(usage.model, rawID)
            XCTAssertEqual(usage.id, rawID)
            XCTAssertEqual(usage.displayName, displayName)
        }
    }

    func testModelDisplayNameLeavesOtherModelIDsUntouched() {
        XCTAssertEqual(UsageModelDisplayNameFormatter.compact("deepseek-v3"), "deepseek-v3")
        XCTAssertEqual(UsageModelDisplayNameFormatter.compact("DeepSeek-v4-flash"), "DeepSeek-v4-flash")
        XCTAssertEqual(UsageModelDisplayNameFormatter.compact("gpt-5"), "gpt-5")
    }
}
