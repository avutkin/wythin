import XCTest
@testable import Wythin

final class StreakComputeTests: XCTestCase {

    private let cal = Calendar.current
    private lazy var today = cal.startOfDay(for: Date())

    private func days(_ offsets: [Int]) -> Set<Date> {
        Set(offsets.map { cal.date(byAdding: .day, value: -$0, to: today)! })
    }

    func testUnbrokenRun() {
        let r = StreakCompute.evaluate(days: days([0, 1, 2, 3]), today: today)
        XCTAssertEqual(r.current, 4)
        XCTAssertFalse(r.graceUsed)
    }

    func testOneMissedDayDoesNotBreakTheRun() {
        // today, -1, (miss -2), -3, -4
        let r = StreakCompute.evaluate(days: days([0, 1, 3, 4]), today: today)
        XCTAssertEqual(r.current, 4)
        XCTAssertTrue(r.graceUsed)
    }

    func testTwoMissesWithinSevenDaysBreakTheRun() {
        // today, -1, (miss -2), -3, (miss -4), -5
        let r = StreakCompute.evaluate(days: days([0, 1, 3, 5]), today: today)
        XCTAssertEqual(r.current, 3)
    }

    func testSecondGraceAllowedOutsideTheSevenDayWindow() {
        // misses at -2 and -9 — more than 7 traversed days apart
        let r = StreakCompute.evaluate(days: days([0, 1, 3, 4, 5, 6, 7, 8, 10, 11]), today: today)
        XCTAssertEqual(r.current, 10)
    }

    func testTodayMissingStillCountsYesterdaysRun() {
        let r = StreakCompute.evaluate(days: days([1, 2, 3]), today: today)
        XCTAssertEqual(r.current, 3)
    }

    func testEmptyHistory() {
        let r = StreakCompute.evaluate(days: [], today: today)
        XCTAssertEqual(r.current, 0)
        XCTAssertEqual(r.best, 0)
        XCTAssertEqual(r.totalAnchors, 0)
    }

    func testBestIsTheLongestRunEver() {
        // a 5-run ending 20 days ago, and a 2-run now
        let old = days([20, 21, 22, 23, 24])
        let recent = days([0, 1])
        let r = StreakCompute.evaluate(days: old.union(recent), today: today)
        XCTAssertEqual(r.current, 2)
        XCTAssertEqual(r.best, 5)
    }
}
