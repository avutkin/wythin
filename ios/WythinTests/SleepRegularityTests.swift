import XCTest
@testable import Wythin

final class SleepRegularityTests: XCTestCase {

    /// A night starting at `hour:minute` on `day`, lasting `hours`.
    private func window(day: Int, hour: Int, minute: Int = 0, hours: Double) -> SleepWindow {
        var comps = DateComponents(year: 2026, month: 7, day: day)
        comps.hour = hour
        comps.minute = minute
        let start = Calendar.current.date(from: comps)!
        return SleepWindow(startedAt: start, endedAt: start.addingTimeInterval(hours * 3600))
    }

    /// Seven identical nights, 23:00 → 07:00.
    private func perfectWeek() -> [SleepWindow] {
        (14...20).map { window(day: $0, hour: 23, hours: 8) }
    }

    func testIdenticalNightsScoreOneHundred() {
        let sri = SleepRegularity.index(of: perfectWeek())
        XCTAssertNotNil(sri)
        XCTAssertEqual(sri ?? 0, 100, accuracy: 1,
                       "same times every night is the definition of perfect regularity")
    }

    func testShiftedNightsScoreLower() {
        // Alternating 23:00 and 03:00 starts — a four-hour swing every night.
        let swinging = (14...20).map { d in
            window(day: d, hour: d % 2 == 0 ? 23 : 3, hours: 8)
        }
        let sri = SleepRegularity.index(of: swinging)
        XCTAssertNotNil(sri)
        XCTAssertLessThan(sri ?? 100, 60,
                          "a four-hour swing every night is severe irregularity")
    }

    func testNeedsAtLeastTwoNights() {
        XCTAssertNil(SleepRegularity.index(of: [window(day: 14, hour: 23, hours: 8)]),
                     "regularity is a comparison — one night cannot have it")
    }

    func testModestShiftScoresBetweenTheExtremes() {
        // A consistent one-hour drift is real but mild.
        let drifting = (14...20).map { d in
            window(day: d, hour: 23, minute: (d - 14) * 10, hours: 8)
        }
        let sri = SleepRegularity.index(of: drifting) ?? 0
        XCTAssertGreaterThan(sri, 80)
        XCTAssertLessThan(sri, 100)
    }
}
