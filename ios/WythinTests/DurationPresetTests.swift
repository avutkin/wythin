import XCTest
@testable import Wythin

final class DurationPresetTests: XCTestCase {

    func testPresetsAreTheSpecifiedFive() {
        XCTAssertEqual(DurationPresetRow.presets, [5, 10, 15, 20, 30])
    }

    func testExactValueSelectsThatPreset() {
        XCTAssertTrue(DurationPresetRow.isSelected(15, minutes: 15))
        XCTAssertFalse(DurationPresetRow.isSelected(20, minutes: 15))
    }

    func testNonPresetValueSelectsNothing() {
        // Dragging the slider off a preset must clear the highlight without
        // any extra state to track.
        for p in DurationPresetRow.presets {
            XCTAssertFalse(DurationPresetRow.isSelected(p, minutes: 17))
        }
    }

    func testNilValueSelectsNothing() {
        for p in DurationPresetRow.presets {
            XCTAssertFalse(DurationPresetRow.isSelected(p, minutes: nil))
        }
    }

    func testFractionalValueDoesNotSelect() {
        XCTAssertFalse(DurationPresetRow.isSelected(15, minutes: 15.4))
    }
}
