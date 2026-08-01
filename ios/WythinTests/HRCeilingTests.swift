import XCTest
@testable import Wythin

final class HRCeilingTests: XCTestCase {

    func testCeilingIsThe99thPercentile() {
        // 100 values, 100...199. p99 index = Int(0.99 * 99) = 98 → 198.
        let bpm = (100...199).map { Float($0) }
        XCTAssertEqual(HRCeiling.ceiling(bpm: bpm, restingHR: 55), 198, accuracy: 0.001)
    }

    func testOutlierAboveThe99thPercentileIsIgnored() {
        var bpm = (100...199).map { Float($0) }
        bpm.append(219)   // a single artifact spike must not become the ceiling
        let c = HRCeiling.ceiling(bpm: bpm, restingHR: 55)
        XCTAssertLessThan(c, 219)
    }

    func testFloorAppliesWhenHistoryIsThin() {
        // Never seen above 90, but the ceiling must stay usable as a denominator.
        let bpm: [Float] = [70, 75, 80, 85, 90]
        XCTAssertEqual(HRCeiling.ceiling(bpm: bpm, restingHR: 55), 115, accuracy: 0.001)
    }

    func testEmptyHistoryFallsBackToTheFloor() {
        XCTAssertEqual(HRCeiling.ceiling(bpm: [], restingHR: 50), 110, accuracy: 0.001)
    }

    func testImplausibleValuesAreRejected() {
        // 0 and 20 are strap dropout; 300 and 500 are artifact. Only 150/160/170
        // are real, so the ceiling must come from those and stay above the floor.
        let bpm: [Float] = [0, 20, 300, 500, 150, 160, 170]
        let c = HRCeiling.ceiling(bpm: bpm, restingHR: 55)
        XCTAssertLessThanOrEqual(c, 220)
        XCTAssertGreaterThanOrEqual(c, 115)
    }

    func testCeilingRisesAsHardEffortAccumulates() {
        // The point of learning it: it must track the wearer, not a constant.
        let untrained = (100...150).map { Float($0) }
        let trained   = (100...190).map { Float($0) }
        XCTAssertGreaterThan(HRCeiling.ceiling(bpm: trained, restingHR: 50),
                             HRCeiling.ceiling(bpm: untrained, restingHR: 50))
    }

    func testUnsortedInputGivesTheSameAnswer() {
        let ordered = (100...199).map { Float($0) }
        XCTAssertEqual(HRCeiling.ceiling(bpm: ordered.shuffled(), restingHR: 55),
                       HRCeiling.ceiling(bpm: ordered, restingHR: 55),
                       accuracy: 0.001)
    }
}
