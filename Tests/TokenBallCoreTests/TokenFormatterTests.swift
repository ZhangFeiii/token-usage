import XCTest
@testable import TokenBallCore

final class TokenFormatterTests: XCTestCase {
    func testCompactFormatting() {
        XCTAssertEqual(TokenFormatter.compact(999), "999")
        XCTAssertEqual(TokenFormatter.compact(1_200), "1.2K")
        XCTAssertEqual(TokenFormatter.compact(28_000_000), "28M")
        XCTAssertEqual(TokenFormatter.compact(1_250_000_000), "1.2B")
    }
}
