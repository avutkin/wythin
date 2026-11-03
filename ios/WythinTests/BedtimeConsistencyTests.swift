import XCTest
@testable import Wythin

final class BedtimeConsistencyTests: XCTestCase {

    /// A night starting at `hour:minute` on `day`, lasting `hours`.
    private func window(day: Int, hour: Int, minute: Int = 0,
                        hours: Double = 8) -> SleepWindow {
        var comps = DateComponents(year: 2026, month: 7, day: day)
        comps.hour = hour
        comps.minute = minute
        let start = Calendar.current.date(from: comps)!
        return SleepWindow(startedAt: start, endedAt: start.addingTimeInterval(hours * 3600))
    }

    // MARK: - The measurement

    func testIdenticalBedtimesHaveNoSpread() {
        let nights = [window(day: 10, hour: 23), window(day: 11, hour: 23),
                      window(day: 12, hour: 23)]
        XCTAssertEqual(BedtimeConsistency.onsetSDMinutes(of: nights) ?? -1, 0, accuracy: 0.5)
    }

    /// The reason this replaced SRI: gaps must cost nothing. Three nights taken
    /// three weeks apart, all at the same hour, describe a person with a fixed
    /// bedtime — not an irregular one, and not an unmeasurable one.
    func testNightsWeeksApartAreAsMeasurableAsConsecutiveOnes() {
        let spread = [window(day: 1, hour: 23), window(day: 11, hour: 23),
                      window(day: 25, hour: 23)]
        let together = [window(day: 1, hour: 23), window(day: 2, hour: 23),
                        window(day: 3, hour: 23)]
        XCTAssertEqual(BedtimeConsistency.onsetSDMinutes(of: spread) ?? -1,
                       BedtimeConsistency.onsetSDMinutes(of: together) ?? -2,
                       accuracy: 0.5,
                       "a gap between nights says nothing about the bedtime on either side")
    }

    /// Clock times wrap. A sleeper who goes to bed either side of midnight is
    /// one of the steadiest there is, and any measure that reads 23:50 and
    /// 00:10 as twenty-three hours apart is broken for most people.
    func testBedtimesEitherSideOfMidnightAreClose() {
        let nights = [window(day: 10, hour: 23, minute: 50),
                      window(day: 12, hour: 0, minute: 10),
                      window(day: 14, hour: 0, minute: 0)]
        guard let sd = BedtimeConsistency.onsetSDMinutes(of: nights) else {
            return XCTFail("three nights is enough to measure")
        }
        XCTAssertLessThan(sd, 20, "these are minutes apart, not most of a day")
    }

    func testAWideningSpreadRaisesTheNumber() {
        let tight = [window(day: 10, hour: 23), window(day: 11, hour: 23, minute: 15),
                     window(day: 12, hour: 22, minute: 45)]
        let loose = [window(day: 10, hour: 21), window(day: 11, hour: 1),
                     window(day: 12, hour: 23)]
        let a = BedtimeConsistency.onsetSDMinutes(of: tight) ?? 0
        let b = BedtimeConsistency.onsetSDMinutes(of: loose) ?? 0
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(a, 30, "a quarter of an hour either way is a steady bedtime")
        XCTAssertGreaterThan(b, 60, "hours apart is not a bedtime, it is three of them")
    }

    // MARK: - What it refuses to answer

    func testTwoNightsIsNotASpread() {
        XCTAssertNil(BedtimeConsistency.onsetSDMinutes(of: [window(day: 10, hour: 23),
                                                            window(day: 11, hour: 23)]),
                     "with two points the spread is half the gap, and one late night reads as a habit")
    }

    func testOneNightIsNotASpread() {
        XCTAssertNil(BedtimeConsistency.onsetSDMinutes(of: [window(day: 10, hour: 23)]))
    }

    func testNoNightsIsNotASpread() {
        XCTAssertNil(BedtimeConsistency.onsetSDMinutes(of: []))
    }

    // MARK: - Where the night sits on the clock

    private func onset(_ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents(year: 2026, month: 7, day: 10)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    func testInsideTheWindowCostsNothing() {
        XCTAssertEqual(BedtimePlacement.minutesOutside(onset(22, 0)), 0)
        XCTAssertEqual(BedtimePlacement.minutesOutside(onset(22, 30)), 0)
        XCTAssertEqual(BedtimePlacement.minutesOutside(onset(23, 0)), 0)
    }

    /// The measured relationship is a U, not a ramp: nights beginning well
    /// before the window carry raised risk much as late ones do. Scoring it as
    /// "earlier is always better" would be choosing a shape we liked over the
    /// one that was observed.
    func testVeryEarlyIsAsFarOutAsVeryLate() {
        XCTAssertEqual(BedtimePlacement.minutesOutside(onset(20, 0)), 120, accuracy: 0.1)
        XCTAssertEqual(BedtimePlacement.minutesOutside(onset(1, 0)), 120, accuracy: 0.1)
    }

    /// Clock times wrap. An onset half an hour after midnight is ninety minutes
    /// past the window, not twenty-two and a half hours.
    func testPastMidnightIsMeasuredTheShortWayRound() {
        XCTAssertEqual(BedtimePlacement.minutesOutside(onset(0, 30)), 90, accuracy: 0.1)
    }

    // MARK: - How it scores

    private func timing(sdMin: Double?, outsideMin: Double? = 0) -> Int? {
        var input = SleepScoreInput(bedtimeSDMin: sdMin, asleepSec: 7 * 3600,
                                    needSec: 8 * 3600)
        input.bedtimeSDMin = sdMin
        input.bedtimeOutsideMin = outsideMin
        return SleepScore.compute(input).sections[.timing]
    }

    /// The point of adding placement: somebody who has worn the strap once or
    /// twice has no spread to measure, and used to see nothing at all. The hour
    /// they went to sleep is measurable from the first night.
    func testTimingIsScoredFromOneNightBeforeThereIsASpread() {
        let firstNight = timing(sdMin: nil, outsideMin: 0)
        XCTAssertEqual(firstNight, 100, "asleep inside the window, and that much is known tonight")
        XCTAssertNotNil(timing(sdMin: nil, outsideMin: 150))
    }

    func testAGoodHourLiftsAnInconsistentSchedule() {
        let scattered = timing(sdMin: 105, outsideMin: 150)
        let scatteredButWellTimed = timing(sdMin: 105, outsideMin: 0)
        guard let scattered, let scatteredButWellTimed else { return XCTFail("scoreable") }
        XCTAssertGreaterThan(scatteredButWellTimed, scattered)
        XCTAssertLessThan(scatteredButWellTimed, 60,
                          "one well-placed night does not make an irregular schedule regular")
    }

    /// Consistency is the better-evidenced half and must stay the larger one.
    func testConsistencyOutweighsTheHour() {
        let steadyButLate = timing(sdMin: 15, outsideMin: 180)
        let scatteredButOnTime = timing(sdMin: 110, outsideMin: 0)
        guard let steadyButLate, let scatteredButOnTime else { return XCTFail("scoreable") }
        XCTAssertGreaterThan(steadyButLate, scatteredButOnTime)
    }

    func testATightBedtimeAtAGoodHourScoresFull() {
        XCTAssertEqual(timing(sdMin: 12, outsideMin: 0), 100)
    }

    /// Nothing to commend it on either half.
    func testAScatteredBedtimeAtABadHourScoresNothing() {
        XCTAssertEqual(timing(sdMin: 140, outsideMin: 200), 0)
    }

    /// A scattered schedule still earns the part of the section it deserves.
    /// Zeroing it because the spread is wide would throw away a real fact about
    /// the night — that it started at a sensible hour.
    func testAScatteredBedtimeAtAGoodHourIsNotZero() {
        guard let score = timing(sdMin: 140, outsideMin: 0) else { return XCTFail("scoreable") }
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThan(score, 45, "and it is still mostly a verdict on the spread")
    }

    /// The middle has to be usable, or the section is a pass/fail badge. An
    /// hour of spread is common and ordinary and should read as neither.
    /// Measured on its own, with no hour to lift it.
    func testAnHourOfSpreadLandsInTheMiddle() {
        guard let score = timing(sdMin: 60, outsideMin: nil) else { return XCTFail("scoreable") }
        XCTAssertGreaterThan(score, 35)
        XCTAssertLessThan(score, 70)
    }

    func testWithNeitherHalfTimingIsAbsentRatherThanZero() {
        XCTAssertNil(timing(sdMin: nil, outsideMin: nil),
                     "a section with no input is absent — scoring it zero would blame the sleeper "
                     + "for what was never measured")
    }
}
