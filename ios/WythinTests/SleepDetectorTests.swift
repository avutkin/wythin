import XCTest
@testable import Wythin

final class SleepDetectorTests: XCTestCase {

    /// Ticks at the background cadence, which is what an overnight capture
    /// actually records — 30 s, not the 2 s foreground rate.
    private func night(fromHour: Int,
                       fromMinute: Int = 0,
                       hours: Double,
                       day: Int = 20,
                       motion: Float? = 4,
                       hr: Float = 52,
                       spacing: Double = 30) -> [MetricsHistoryPoint] {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: day)
        comps.hour = fromHour
        comps.minute = fromMinute
        let start = cal.date(from: comps)!
        let count = Int((hours * 3600) / spacing)
        return (0..<count).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * spacing),
                                meanBPM: hr, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                                breathBPM: 13, motion: motion,
                                signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
    }

    // MARK: - The window

    func testFindsOvernightWindowSpanningMidnight() {
        // 23:10 → 06:40, the case AnchorDetector deliberately refuses.
        let points = night(fromHour: 23, fromMinute: 10, hours: 7.5)
        let w = SleepDetector.detect(points)

        XCTAssertNotNil(w, "an overnight stretch is exactly what this detector is for")
        XCTAssertEqual(w?.durationSec ?? 0, 7.5 * 3600, accuracy: 60)
    }

    func testPicksTheNightNotTheEveningNap() {
        // A 40-minute nap at 20:00, then a real gap, then the night.
        let nap = night(fromHour: 20, hours: 0.66)
        let sleep = night(fromHour: 23, fromMinute: 10, hours: 7.5)
        let w = SleepDetector.detect(nap + sleep)

        XCTAssertNotNil(w)
        XCTAssertEqual(w?.durationSec ?? 0, 7.5 * 3600, accuracy: 120,
                       "the span from nap-start to wake is 10.7 h — the night is 7.5 h")
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 23)
    }

    func testRejectsNapTooShortToBeANight() {
        // 40 minutes is a nap. A night record built from it would carry a
        // duration score against an 8-hour need and read as catastrophic.
        XCTAssertNil(SleepDetector.detect(night(fromHour: 20, hours: 0.66)))
    }

    func testNightBelongsToTheWakeDate() {
        // 23:10 on the 20th → 06:40 on the 21st. Grouping by the START date
        // files every night under the previous day, which is the bug the
        // research flagged in DailyAnchor and ActivitiesView alike.
        let w = SleepDetector.detect(night(fromHour: 23, fromMinute: 10, hours: 7.5, day: 20))
        let day = Calendar.current.dateComponents([.year, .month, .day], from: w?.day ?? .distantPast)

        XCTAssertEqual(day.day, 21, "the night of the 20th–21st is the 21st's night")
        XCTAssertEqual(day.month, 7)
    }

    func testKeepsNightDespiteMovement() {
        // The anchor rejects anything above `stillnessSD` (20 mg). A sleeper is
        // not a statue, so a detector that inherited that gate would find no
        // nights at all. 25 mg sits above the anchor's gate and inside what a
        // real night measures — asleep is about 4 mg, awake about 13.
        let w = SleepDetector.detect(night(fromHour: 23, hours: 7, motion: 25))
        XCTAssertNotNil(w, "movement is part of sleep, not a disqualifier")
        XCTAssertEqual(w?.durationSec ?? 0, 7 * 3600, accuracy: 120)
    }

    func testSustainedHeavyMovementIsNotANight() {
        // The honest complement: seven hours at 140 mg is someone moving, not
        // someone sleeping. Finding no night is the correct answer, not a
        // failure — and it is what keeps a long restless evening on the sofa
        // out of the record.
        // Relative gates cannot reject this on their own — a uniformly moving
        // recording has no contrast for them to compare against — so this is
        // the absolute sanity floor doing its job.
        XCTAssertNil(SleepDetector.detect(night(fromHour: 23, hours: 7, motion: 140)),
                     "sustained heavy movement is not sleep at any duration")
    }

    // MARK: - Finding where sleep actually starts and ends

    /// Awake ticks: moving, so `SleepStages` reads them as wake.
    private func awakeStretch(fromHour: Int, fromMinute: Int = 0, hours: Double,
                              day: Int = 20) -> [MetricsHistoryPoint] {
        night(fromHour: fromHour, fromMinute: fromMinute, hours: hours,
              day: day, motion: 190, hr: 68)
    }

    func testTrimsWakingHoursOffBothEndsOfContinuousWear() {
        // Strap worn from 21:00 straight through to 09:00 — one unbroken run
        // of 12 h, because nothing was ever disconnected. Splitting on gaps
        // alone would call the whole wear a night.
        let points = awakeStretch(fromHour: 21, hours: 2.1)
            + night(fromHour: 23, fromMinute: 10, hours: 7.5)
            + awakeStretch(fromHour: 6, fromMinute: 45, hours: 2.2, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.durationSec ?? 0, 7.5 * 3600, accuracy: 400,
                       "the night is the asleep part, not the whole wear")
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 23)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.endedAt ?? .distantPast), 6)
    }

    func testBriefWakeInTheNightDoesNotEndIt() {
        // Up for eight minutes at 03:00. A wake bout inside one night, not the
        // end of one night and the start of another.
        let points = night(fromHour: 23, hours: 4)
            + awakeStretch(fromHour: 3, hours: 0.13, day: 21)
            + night(fromHour: 3, fromMinute: 8, hours: 3.5, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertGreaterThan(w?.durationSec ?? 0, 7 * 3600,
                             "one night, briefly interrupted — not two short ones")
    }

    func testAQuietEveningPatchDoesNotAnchorTheNight() {
        // The 17:00 night, exactly as it was recorded.
        //
        // The strap went on at 17:00 and the evening was spent awake, but six
        // quiet minutes on the sofa near the start classified as sleep — long
        // enough to survive `SleepStages.smooth`, which only absorbs runs under
        // three minutes. The trim took the FIRST non-wake tick it saw, so the
        // night anchored to 17:00 and swallowed six hours of evening: a 12 h 37 m
        // "night" reporting 7 h 15 m awake.
        //
        // Sleep onset is a sustained thing. Ten persistent minutes is the
        // actigraphy convention, and six minutes of sitting still is not it.
        let points = quietPatch(fromHour: 17, minutes: 6)
            + awakeStretch(fromHour: 17, fromMinute: 6, hours: 5.9)
            + night(fromHour: 23, hours: 6.6)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 23,
                       "the night starts where sleep is sustained, not at the first quiet tick")
        XCTAssertEqual(w?.durationSec ?? 0, 6.6 * 3600, accuracy: 600,
                       "six hours of evening are not part of the night")
    }

    func testATrueShortDozeStillOpensTheNight() {
        // The complement, so the fix cannot become "ignore the start of sleep".
        // Twelve minutes is past the sustained floor, so it IS onset even
        // though a brief arousal follows it.
        let points = quietPatch(fromHour: 22, minutes: 12)
            + awakeStretch(fromHour: 22, fromMinute: 12, hours: 0.1)
            + night(fromHour: 22, fromMinute: 18, hours: 6.5)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 22)
        XCTAssertEqual(Calendar.current.component(.minute, from: w?.startedAt ?? .distantPast), 0,
                       "onset is the start of the sustained stretch, not after the arousal")
    }

    func testTrimsAQuietPatchOffTheMorningEndToo() {
        // The same defect at the other end: a short still spell after getting
        // up must not extend the night by two hours.
        let points = night(fromHour: 23, hours: 6.5)
            + awakeStretch(fromHour: 5, fromMinute: 30, hours: 1.9, day: 21)
            + quietPatch(fromHour: 7, fromMinute: 24, minutes: 6, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.endedAt ?? .distantPast), 5,
                       "the night ends at the last sustained sleep, not the last still moment")
    }

    /// Still and low-pulsed, but only for a few minutes — sitting quietly,
    /// not sleeping.
    private func quietPatch(fromHour: Int, fromMinute: Int = 0, minutes: Double,
                            day: Int = 20) -> [MetricsHistoryPoint] {
        night(fromHour: fromHour, fromMinute: fromMinute, hours: minutes / 60,
              day: day, motion: 4, hr: 52)
    }

    // MARK: - Where the night actually ends

    func testAMorningDozeDoesNotExtendTheNight() {
        // The recorded night, as photographed: sleep, then hours up, then a
        // doze. The doze is real sustained sleep, so the ten-minute rule
        // accepts it as a boundary — and everything between became "awake",
        // which is where 3 h 31 m of wake in an 8 h 26 m window came from.
        //
        // Sleep after you have been up for the best part of a morning is a
        // separate episode, not the tail of the night.
        let points = night(fromHour: 23, hours: 5)
            + awakeStretch(fromHour: 4, hours: 3.4, day: 21)
            + night(fromHour: 7, fromMinute: 30, hours: 0.25, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        // The last tick of a 5 h run from 23:00 lands at 03:59:30, so compare
        // against the moment rather than the hour component.
        let finalAwakening = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 4))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(finalAwakening) ?? .infinity, 0, accuracy: 60,
                       "the night ends at the final awakening, not at a later doze")
        XCTAssertEqual(w?.durationSec ?? 0, 5 * 3600, accuracy: 600)
    }

    func testAnEveningDozeDoesNotOpenTheNight() {
        // The same rule at the other end. Twenty minutes on the sofa at 21:00,
        // then an hour up, then bed: onset is bed, not the sofa.
        let points = night(fromHour: 21, hours: 0.33)
            + awakeStretch(fromHour: 21, fromMinute: 20, hours: 1.1)
            + night(fromHour: 22, fromMinute: 30, hours: 6.5)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 22)
        XCTAssertEqual(Calendar.current.component(.minute, from: w?.startedAt ?? .distantPast), 30)
    }

    func testAThirtyMinuteWakeBoutStaysInsideTheNight() {
        // The guard on the rule above. Half an hour awake at 03:00 is a wake
        // bout — miserable, but one night. Only a gap past `settleSec` means
        // someone got up for the day, and splitting on anything shorter would
        // turn one broken night into two short ones and wreck continuity.
        let points = night(fromHour: 23, hours: 4)
            + awakeStretch(fromHour: 3, hours: 0.5, day: 21)
            + night(fromHour: 3, fromMinute: 30, hours: 3, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertGreaterThan(w?.durationSec ?? 0, 7 * 3600,
                             "half an hour up is a bout inside the night, not the end of it")
    }
}
