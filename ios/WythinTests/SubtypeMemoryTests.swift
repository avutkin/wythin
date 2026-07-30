import XCTest
@testable import Wythin

final class SubtypeMemoryTests: XCTestCase {

    /// Entries newest-first, matching the @Query sort the picker consumes.
    private func entries(_ pairs: [(ActivityType, String?)]) -> [ActivityLog] {
        pairs.map { ActivityLog(activityType: $0.0.rawValue, activitySubtype: $0.1) }
    }

    func testExcludesBuiltInSubtypes() {
        let e = entries([(.exercise, "Yoga"), (.exercise, "Kettlebells")])
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r, ["Kettlebells"])
    }

    func testExcludesOtherActivityTypes() {
        let e = entries([(.walk, "Beach Walk"), (.exercise, "Kettlebells")])
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r, ["Kettlebells"])
    }

    func testDedupesKeepingMostRecentFirst() {
        let e = entries([(.exercise, "Kettlebells"),
                         (.exercise, "Sandbag"),
                         (.exercise, "Kettlebells")])
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r, ["Kettlebells", "Sandbag"])
    }

    func testCapsAtLimit() {
        let e = entries((1...10).map { (.exercise, "Custom \($0)") })
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r.count, 6)
        XCTAssertEqual(r.first, "Custom 1")
    }

    func testIgnoresNilAndBlankSubtypes() {
        let e = entries([(.exercise, nil), (.exercise, "   "), (.exercise, "Sandbag")])
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r, ["Sandbag"])
    }

    func testEmptyWhenNoHistory() {
        XCTAssertTrue(SubtypeMemory.remembered(type: .drinks, entries: [], limit: 6).isEmpty)
    }
}
