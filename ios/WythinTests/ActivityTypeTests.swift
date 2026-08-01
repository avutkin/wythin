import XCTest
@testable import Wythin

final class ActivityTypeTests: XCTestCase {

    // MARK: - Grid shape

    func testPickerHasExactlyEightTiles() {
        XCTAssertEqual(ActivityType.pickerCases.count, 8)
        XCTAssertFalse(ActivityType.pickerCases.contains(.custom),
                       "Custom is offered below the grid, not as a tile")
    }

    func testCustomRemainsLastCase() {
        // ActivityTypeCell and the showCustom flow assume Custom is last.
        XCTAssertEqual(ActivityType.allCases.last, .custom)
    }

    // MARK: - Legacy types

    func testMergedLegacyTypesResolveToTheirNewTile() {
        XCTAssertEqual(ActivityType.fromStored("Run"), .exercise)
        XCTAssertEqual(ActivityType.fromStored("Cold Exposure"), .thermal)
        XCTAssertEqual(ActivityType.fromStored("Sauna"), .thermal)
        XCTAssertEqual(ActivityType.fromStored("Coffee"), .drinks)
        XCTAssertEqual(ActivityType.fromStored("Alcohol"), .drinks)
    }

    func testCurrentTypesStillResolve() {
        // Walk is excluded: its raw value now deliberately resolves to Exercise,
        // which is the merge (see testStoredWalkResolvesToExercise).
        for type in ActivityType.allCases where type != .walk {
            XCTAssertEqual(ActivityType.fromStored(type.rawValue), type)
        }
    }

    // MARK: - Walk merge

    func testWalkIsNoLongerAPickerTile() {
        XCTAssertFalse(ActivityType.pickerCases.contains(.walk),
                       "Walk folded into Exercise; it must not spend a tile")
        XCTAssertEqual(ActivityType.pickerCases.count, 8)
    }

    func testStoredWalkResolvesToExercise() {
        XCTAssertEqual(ActivityType.fromStored("Walk"), .exercise)
    }

    func testWalkSubtypesMovedOntoExercise() {
        let ex = ActivityType.exercise.subtypes
        for sub in ["Nature Walk", "City Walk", "Hiking", "Treadmill"] {
            XCTAssertTrue(ex.contains(sub), "\(sub) must be reachable under Exercise")
        }
    }

    func testLegacyWalkEntryKeepsItsSubtypeButShowsAsExercise() {
        let entry = ActivityLog(activityType: "Walk", activitySubtype: "Hiking")
        XCTAssertEqual(entry.activityTypeEnum, .exercise)
        XCTAssertEqual(entry.displayName, "Hiking", "history must not lose its label")
    }

    func testUnknownRawValueFallsBackToCustom() {
        let entry = ActivityLog(activityType: "Nonsense")
        XCTAssertEqual(entry.activityTypeEnum, .custom)
    }

    func testLegacyEntryKeepsItsSubtypeAndTile() {
        let entry = ActivityLog(activityType: "Run", activitySubtype: "Tempo Run",
                                startedAt: Date(), endedAt: Date().addingTimeInterval(1800))
        XCTAssertEqual(entry.activityTypeEnum, .exercise)
        XCTAssertEqual(entry.displayName, "Tempo Run")
    }

    // MARK: - Subtypes and icons

    func testMergedSubtypesSurviveOnTheNewTile() {
        XCTAssertTrue(ActivityType.exercise.subtypes.contains("Tempo Run"))
        XCTAssertTrue(ActivityType.thermal.subtypes.contains("Ice Bath"))
        XCTAssertTrue(ActivityType.thermal.subtypes.contains("Sauna"))
        XCTAssertTrue(ActivityType.drinks.subtypes.contains("Espresso"))
        XCTAssertTrue(ActivityType.drinks.subtypes.contains("Wine"))
        XCTAssertTrue(ActivityType.work.subtypes.contains("Deep Work"))
    }

    func testEveryTileHasAnIcon() {
        for type in ActivityType.allCases {
            XCTAssertFalse(type.icon.isEmpty, "\(type.rawValue) has no icon")
        }
    }
}
