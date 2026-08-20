import XCTest
@testable import Wythin

/// The one clock every channel of the montage is drawn against.
///
/// These are the tests the old axis could never have passed: it was an
/// `HStack` of labels separated by equal `Spacer()`s, so 17:00→18:00 and
/// 18:00→20:00 were given the same width. Every hour label on the night chart
/// was in the wrong place, and the traces above it — which used Swift Charts'
/// own axis — disagreed with it.
final class SleepMontageRulerTests: XCTestCase {

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        var c = DateComponents(year: 2026, month: 8, day: day)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    private func ruler(_ from: Date, _ to: Date) -> MontageRuler {
        MontageRuler(startedAt: from, endedAt: to)
    }

    // MARK: - Position

    func testEndsMapToTheEdges() {
        let r = ruler(at(23, 4), at(6, 4, day: 21))
        XCTAssertEqual(r.x(at(23, 4), width: 300), 0, accuracy: 0.001)
        XCTAssertEqual(r.x(at(6, 4, day: 21), width: 300), 300, accuracy: 0.001)
    }

    func testAnHourIsTheSameWidthWhereverItFalls() {
        // The defect, stated as a property: equal durations must occupy equal
        // width. Under the old Spacer axis this was false by construction.
        let r = ruler(at(17), at(6, day: 21))   // 13 h
        let early = r.x(at(18), width: 650) - r.x(at(17), width: 650)
        let late  = r.x(at(5, day: 21), width: 650) - r.x(at(4, day: 21), width: 650)
        XCTAssertEqual(early, late, accuracy: 0.001)
        XCTAssertEqual(early, 50, accuracy: 0.001, "13 h across 650 pt is 50 pt an hour")
    }

    func testMidpointSitsHalfway() {
        let r = ruler(at(23), at(7, day: 21))   // 8 h
        XCTAssertEqual(r.x(at(3, day: 21), width: 400), 200, accuracy: 0.001)
    }

    func testTimesOutsideTheWindowAreClamped() {
        let r = ruler(at(23), at(7, day: 21))
        XCTAssertEqual(r.x(at(20), width: 400), 0, accuracy: 0.001)
        XCTAssertEqual(r.x(at(11, day: 21), width: 400), 400, accuracy: 0.001)
    }

    func testAZeroLengthWindowDoesNotDivideByZero() {
        let r = ruler(at(23), at(23))
        XCTAssertEqual(r.x(at(23), width: 400), 0, accuracy: 0.001)
        XCTAssertTrue(r.ticks.isEmpty)
    }

    // MARK: - Ticks

    func testTicksAreWholeHoursAtTheirRealTime() {
        let r = ruler(at(23, 4), at(6, 4, day: 21))   // 7 h → 2-hourly
        XCTAssertEqual(r.tickStepHours, 2)
        let hours = r.ticks.map { Calendar.current.component(.hour, from: $0) }
        XCTAssertEqual(hours, [0, 2, 4])
        XCTAssertTrue(r.ticks.allSatisfy { Calendar.current.component(.minute, from: $0) == 0 })
    }

    func testAShortNightGetsHourlyTicks() {
        let r = ruler(at(1), at(5, 30))   // 4.5 h
        XCTAssertEqual(r.tickStepHours, 1)
        XCTAssertEqual(r.ticks.map { Calendar.current.component(.hour, from: $0) }, [2, 3, 4])
    }

    func testALongRecordingThinsToThreeHourly() {
        let r = ruler(at(17), at(9, day: 21))   // 16 h
        XCTAssertEqual(r.tickStepHours, 3)
        XCTAssertEqual(r.ticks.map { Calendar.current.component(.hour, from: $0) },
                       [18, 21, 0, 3, 6])
    }

    func testTicksKeepClearOfTheStartAndEndLabels() {
        // 23:50 → 06:10. Midnight is ten minutes from the start marker and
        // 06:00 is ten minutes from the end one; both would collide with the
        // ASLEEP / WOKE labels, so neither is drawn.
        let r = ruler(at(23, 50), at(6, 10, day: 21))
        let hours = r.ticks.map { Calendar.current.component(.hour, from: $0) }
        XCTAssertFalse(hours.contains(0), "midnight collides with the ASLEEP marker")
        XCTAssertFalse(hours.contains(6), "06:00 collides with the WOKE marker")
        XCTAssertEqual(hours, [2, 4])
    }

    func testEveryTickIsStrictlyInsideTheWindow() {
        let r = ruler(at(22, 13), at(7, 41, day: 21))
        XCTAssertTrue(r.ticks.allSatisfy { $0 > r.startedAt && $0 < r.endedAt })
    }

    // MARK: - Scrubbing back from a finger position

    func testXAndDateAreInverses() {
        let r = ruler(at(22, 13), at(7, 41, day: 21))
        for x in stride(from: 0.0, through: 360.0, by: 36.0) {
            let back = r.x(r.date(atX: x, width: 360), width: 360)
            XCTAssertEqual(back, x, accuracy: 0.001)
        }
    }

    func testScrubbingOffEitherEdgeClampsToTheNight() {
        let r = ruler(at(23), at(7, day: 21))
        XCTAssertEqual(r.date(atX: -80, width: 300), r.startedAt)
        XCTAssertEqual(r.date(atX: 900, width: 300), r.endedAt)
    }

    func testAZeroWidthPlotDoesNotDivideByZero() {
        let r = ruler(at(23), at(7, day: 21))
        XCTAssertEqual(r.date(atX: 42, width: 0), r.startedAt)
    }
}
