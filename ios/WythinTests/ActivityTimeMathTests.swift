import XCTest
@testable import Wythin

final class ActivityTimeMathTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testEndIsStartPlusDuration() {
        XCTAssertEqual(ActivityTimeMath.end(start: start, minutes: 30),
                       start.addingTimeInterval(1800))
    }

    func testDurationIsTheGapBetweenStartAndEnd() {
        XCTAssertEqual(ActivityTimeMath.minutes(start: start,
                                                end: start.addingTimeInterval(2700)),
                       45, accuracy: 0.001)
    }

    func testTheTwoAreInverses() {
        for m in [1.0, 7.0, 20.0, 90.0, 180.0] {
            let e = ActivityTimeMath.end(start: start, minutes: m)
            XCTAssertEqual(ActivityTimeMath.minutes(start: start, end: e), m, accuracy: 0.001)
        }
    }

    func testAnEndBeforeTheStartCannotProduceANegativeDuration() {
        // Otherwise the session finishes before it begins.
        XCTAssertEqual(ActivityTimeMath.minutes(start: start,
                                                end: start.addingTimeInterval(-3600)),
                       ActivityTimeMath.minimumMinutes, accuracy: 0.001)
    }

    func testAnImplausiblyLongSpanIsClamped() {
        // Six hours is a forgotten stop, not a practice.
        XCTAssertEqual(ActivityTimeMath.minutes(start: start,
                                                end: start.addingTimeInterval(6 * 3600)),
                       ActivityTimeMath.maximumMinutes, accuracy: 0.001)
    }

    func testRangeCheckMatchesTheClamp() {
        XCTAssertTrue(ActivityTimeMath.isWithinRange(start: start,
                                                     end: start.addingTimeInterval(1800)))
        XCTAssertFalse(ActivityTimeMath.isWithinRange(start: start,
                                                      end: start.addingTimeInterval(-60)))
        XCTAssertFalse(ActivityTimeMath.isWithinRange(start: start,
                                                      end: start.addingTimeInterval(6 * 3600)))
    }

    func testEndLabelIsAbsentWithoutATarget() {
        XCTAssertNil(ActivityTimeMath.endLabel(start: start, minutes: nil))
        XCTAssertNotNil(ActivityTimeMath.endLabel(start: start, minutes: 20))
    }
}
