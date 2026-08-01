import XCTest
@testable import Wythin

final class ActivityClassTests: XCTestCase {

    func testExerciseIsActivating() {
        XCTAssertEqual(ActivityType.exercise.activityClass, .activating)
    }

    func testWalkIsActivating() {
        // Walk is merged into Exercise but the case still exists for in-flight rows.
        XCTAssertEqual(ActivityType.walk.activityClass, .activating)
    }

    func testEverythingElseIsRestorative() {
        let restorative: [ActivityType] = [.meditation, .breathwork, .meal, .nap,
                                           .thermal, .drinks, .work, .custom]
        for type in restorative {
            XCTAssertEqual(type.activityClass, .restorative,
                           "\(type.rawValue) must keep the existing nine-metric path")
        }
    }

    func testEveryCaseIsClassified() {
        // A new ActivityType must be a deliberate choice, not a silent default.
        XCTAssertEqual(ActivityType.allCases.count, 10)
    }

    func testStoredWalkEntryClassifiesAsActivating() {
        // The row branch reads through activityTypeEnum, so the merge and the
        // class have to agree end to end.
        let entry = ActivityLog(activityType: "Walk", activitySubtype: "Treadmill")
        XCTAssertEqual(entry.activityTypeEnum.activityClass, .activating)
    }
}
