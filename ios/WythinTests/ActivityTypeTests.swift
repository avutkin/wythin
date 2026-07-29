import XCTest
@testable import Wythin

final class ActivityTypeTests: XCTestCase {

    func testCoffeeAndWorkExist() {
        XCTAssertEqual(ActivityType(rawValue: "Coffee"), .coffee)
        XCTAssertEqual(ActivityType(rawValue: "Work"), .work)
    }

    func testCustomRemainsLastCase() {
        // ActivityTypeCell and the showCustom flow assume Custom is the last
        // tile in the grid.
        XCTAssertEqual(ActivityType.allCases.last, .custom)
    }

    func testNewTypesHaveSubtypesAndIcons() {
        XCTAssertTrue(ActivityType.coffee.subtypes.contains("Espresso"))
        XCTAssertTrue(ActivityType.work.subtypes.contains("Deep Work"))
        XCTAssertFalse(ActivityType.coffee.icon.isEmpty)
        XCTAssertFalse(ActivityType.work.icon.isEmpty)
    }

    func testUnknownRawValueFallsBackToCustom() {
        let entry = ActivityLog(activityType: "Nonsense")
        XCTAssertEqual(entry.activityTypeEnum, .custom)
    }
}
