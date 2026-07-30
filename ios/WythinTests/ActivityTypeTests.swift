import XCTest
@testable import Wythin

final class ActivityTypeTests: XCTestCase {

    // MARK: - Grid shape

    func testPickerHasExactlyNineTiles() {
        XCTAssertEqual(ActivityType.pickerCases.count, 9)
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
        for type in ActivityType.allCases {
            XCTAssertEqual(ActivityType.fromStored(type.rawValue), type)
        }
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
