import XCTest
@testable import Wythin

final class DayPotentialInsightTests: XCTestCase {

    func testParsesFullReply() {
        let raw = """
        Good Reserves
        • Your first still reading came in **at the top of your usual range**.
        • Your mornings are **settling into a steady rhythm**.
        → Room for one hard block and a full session.
        """
        let i = DayPotentialInsight(raw: raw)
        XCTAssertEqual(i.title, "Good Reserves")
        XCTAssertEqual(i.bullets.count, 2)
        XCTAssertTrue(i.bullets[0].hasPrefix("Your first still reading"))
        XCTAssertEqual(i.recommendation, "Room for one hard block and a full session.")
    }

    func testHandlesHyphenBullets() {
        let i = DayPotentialInsight(raw: "Steady\n- one\n- two\n-> go easy")
        XCTAssertEqual(i.bullets, ["one", "two"])
        XCTAssertEqual(i.recommendation, "go easy")
    }

    func testMissingRecommendation() {
        let i = DayPotentialInsight(raw: "Steady\n• only bullet")
        XCTAssertNil(i.recommendation)
        XCTAssertEqual(i.bullets.count, 1)
    }

    func testEmptyReply() {
        let i = DayPotentialInsight(raw: "   ")
        XCTAssertEqual(i.title, "")
        XCTAssertTrue(i.bullets.isEmpty)
    }
}
