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

    // MARK: - Naps

    /// An ordinary waking stretch: moving about, pulse where a day sits.
    private func daytime(fromHour: Int, fromMinute: Int = 0, hours: Double,
                         day: Int = 20) -> [MetricsHistoryPoint] {
        night(fromHour: fromHour, fromMinute: fromMinute, hours: hours,
              day: day, motion: 30, hr: 70)
    }

    /// Asleep during the day: still, and — the part that matters — a pulse
    /// several beats below the day around it.
    private func napping(fromHour: Int, fromMinute: Int = 0, hours: Double,
                         day: Int = 20) -> [MetricsHistoryPoint] {
        night(fromHour: fromHour, fromMinute: fromMinute, hours: hours,
              day: day, motion: 5, hr: 58)
    }

    func testFindsAnAfternoonNap() {
        // The case that has never been visible to this app at all. The night
        // detector searches for the quietest night-length stretch and discards
        // anything under three hours, so a real half hour of afternoon sleep
        // was not merely mis-scored — it was never looked for.
        let points = daytime(fromHour: 9, hours: 5)
            + napping(fromHour: 14, hours: 0.5)
            + daytime(fromHour: 14, fromMinute: 30, hours: 4)

        let naps = NapDetector.detect(points, excluding: [])
        XCTAssertEqual(naps.count, 1)
        XCTAssertEqual(Calendar.current.component(.hour, from: naps.first?.startedAt ?? .distantPast), 14)
        XCTAssertEqual(naps.first?.durationSec ?? 0, 30 * 60, accuracy: 120)
    }

    func testSittingStillIsNotANap() {
        // The false positive this detector exists in spite of. Reading in a
        // chair is exactly as motionless as sleeping, so a rule built on
        // stillness reports an afternoon with a book as an afternoon asleep.
        // The pulse is what separates them, and here it never drops.
        let stillButAwake = night(fromHour: 14, hours: 1, motion: 5, hr: 70)
        let points = daytime(fromHour: 9, hours: 5) + stillButAwake
            + daytime(fromHour: 15, hours: 4)

        XCTAssertTrue(NapDetector.detect(points, excluding: []).isEmpty,
                      "stillness without a fall in pulse is rest, not sleep")
    }

    func testAnHourAtADeskIsNotANap() {
        // The bug as shipped, and the reason the baseline changed. A day's
        // median heart rate is lifted by every minute spent walking about, so
        // simply sitting down puts a person well under it. Compared against the
        // day, this desk hour reads as sleep; compared against rest — which is
        // the state a nap actually has to be distinguished from — it is
        // indistinguishable from the rest of the sitting, because that is what
        // it is.
        let walking = night(fromHour: 9, hours: 3, motion: 60, hr: 85)
        let desk = night(fromHour: 12, hours: 1, motion: 5, hr: 68)
        let more = night(fromHour: 13, hours: 3, motion: 5, hr: 68)
        let walkingAgain = night(fromHour: 16, hours: 2, motion: 60, hr: 85)

        XCTAssertTrue(NapDetector.detect(walking + desk + more + walkingAgain,
                                         excluding: []).isEmpty,
                      "sitting is not sleeping, however far below a walking average it sits")
    }

    func testAStretchTooShortIsNotANap() {
        let points = daytime(fromHour: 9, hours: 5)
            + napping(fromHour: 14, hours: 0.1)      // six minutes
            + daytime(fromHour: 14, fromMinute: 6, hours: 4)

        XCTAssertTrue(NapDetector.detect(points, excluding: []).isEmpty,
                      "six minutes is a lull, not a nap")
    }

    func testAStretchTooLongBelongsToTheNightDetector() {
        // Above `maxNapSec` this must stay silent, whatever it sees. Two
        // detectors both claiming one stretch is how an afternoon becomes two
        // entries in the same list.
        let points = daytime(fromHour: 9, hours: 4)
            + napping(fromHour: 13, hours: 4)
            + daytime(fromHour: 17, hours: 4)

        XCTAssertTrue(NapDetector.detect(points, excluding: []).isEmpty,
                      "past three hours it is not this detector's to report")
    }

    func testSleepInsideAKnownNightIsNotANap() {
        // The night is handed in, not guessed at. Without the exclusion the
        // first run over a week of history reports a nap inside every night.
        let nightPoints = night(fromHour: 23, hours: 6, day: 20)
        let points = daytime(fromHour: 15, hours: 6, day: 20) + nightPoints
            + daytime(fromHour: 6, hours: 5, day: 21)
        let window = SleepWindow(startedAt: nightPoints.first!.timestamp,
                                 endedAt: nightPoints.last!.timestamp)

        XCTAssertTrue(NapDetector.detect(points, excluding: [window]).isEmpty,
                      "the night is the night detector's, and it is excluded whole")
    }

    func testEachDayIsJudgedAgainstItsOwnBaseline() {
        // The recorder hands this detector three weeks of history in one array.
        // Pooled, the baseline stops being "the surrounding day" and becomes a
        // median of the whole span — and `minWakingSpanSec`, which compares the
        // first tick to the last, always passes.
        //
        // Here that difference is the whole answer. The 20th holds only two and
        // a half hours of quiet recording — too little to know what that day
        // looked like, so it must yield nothing. Pooled with the 21st, its
        // pulse sits below the combined median and the whole stretch reports as
        // a nap that never happened.
        let thin = night(fromHour: 13, hours: 2.5, day: 20, motion: 5, hr: 62)
        let full = daytime(fromHour: 9, hours: 5, day: 21)
            + napping(fromHour: 14, hours: 0.5, day: 21)
            + daytime(fromHour: 14, fromMinute: 30, hours: 3, day: 21)

        let naps = NapDetector.detect(thin + full, excluding: [])
        XCTAssertEqual(naps.count, 1, "a day too thin to have a baseline yields no naps")
        XCTAssertEqual(Calendar.current.component(.day, from: naps.first?.startedAt ?? .distantPast), 21)
    }

    func testABriefStirDoesNotSplitANap() {
        // One restless minute in the middle of forty is a turn, and splitting
        // there would leave two nineteen-minute pieces where there was one nap.
        let points = daytime(fromHour: 9, hours: 5)
            + napping(fromHour: 14, hours: 0.32)
            + daytime(fromHour: 14, fromMinute: 19, hours: 0.017)   // ~1 min
            + napping(fromHour: 14, fromMinute: 20, hours: 0.33)
            + daytime(fromHour: 14, fromMinute: 40, hours: 4)

        let naps = NapDetector.detect(points, excluding: [])
        XCTAssertEqual(naps.count, 1, "a one-minute stir is inside the nap, not the end of it")
        XCTAssertEqual(naps.first?.durationSec ?? 0, 40 * 60, accuracy: 180)
    }

    // MARK: - Where the night actually ends

    /// Awake, but still in bed: pulse and movement up enough to be scored
    /// wake, nowhere near enough to be scored *upright*.
    private func awakeInBed(fromHour: Int, fromMinute: Int = 0, hours: Double,
                            day: Int = 20) -> [MetricsHistoryPoint] {
        night(fromHour: fromHour, fromMinute: fromMinute, hours: hours,
              day: day, motion: 14, hr: 60)
    }

    /// Out of bed and on your feet: the gravity vector says upright, and the
    /// accelerometer agrees.
    private func onYourFeet(fromHour: Int, fromMinute: Int = 0, hours: Double,
                            day: Int = 20) -> [MetricsHistoryPoint] {
        let base = night(fromHour: fromHour, fromMinute: fromMinute, hours: hours,
                         day: day, motion: 40, hr: 72)
        return base.map {
            MetricsHistoryPoint(anchorTestTimestamp: $0.timestamp,
                                meanBPM: $0.meanBPM, vti: $0.vti, dc: $0.dc,
                                pip: $0.pip, dfa1: $0.dfa1, breathBPM: $0.breathBPM,
                                motion: $0.motion, bodyPosition: .upright,
                                signalQuality: $0.signalQuality,
                                rrInvalidRate: $0.rrInvalidRate,
                                ecgQualityTier: $0.ecgQualityTier)
        }
    }

    func testAMorningReturnToSleepStaysInsideTheSameNight() {
        // The photographed night, as reported: 20:56 → 05:08, 8 h 11 m in bed.
        // What actually happened is that the sleeper woke around five, stayed
        // in bed for an hour, slept again, and got up at 08:30 — one night of
        // 11 h 34 m with a long wake bout in the middle of it.
        //
        // The old rule split on the hour alone and kept the larger half, so
        // three and a half hours of night, and every awakening inside them,
        // were discarded before the score ever saw them.
        let points = night(fromHour: 20, fromMinute: 56, hours: 8.2)
            + awakeInBed(fromHour: 5, fromMinute: 8, hours: 1.03, day: 21)
            + night(fromHour: 6, fromMinute: 10, hours: 2.33, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        let rose = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 8, minute: 30))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(rose) ?? .infinity, 0, accuracy: 120,
                       "an hour awake in bed is a wake bout, not the end of the night")
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 20)
    }

    func testGettingUpForTheDayStillEndsTheNight() {
        // The guard on the test above, and the reason the evidence has to be
        // read rather than the clock. Same shape, same gap, same later sleep —
        // but this hour was spent upright and moving, so the night ended at
        // 05:08 and the later sleep is a morning nap.
        let points = night(fromHour: 20, fromMinute: 56, hours: 8.2)
            + onYourFeet(fromHour: 5, fromMinute: 8, hours: 1.03, day: 21)
            + night(fromHour: 6, fromMinute: 10, hours: 2.33, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        let got = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 5, minute: 8))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(got) ?? .infinity, 0, accuracy: 120,
                       "upright and moving for an hour is getting up, and it ends the night")
    }

    func testGettingUpBrieflyAndComingBackToBedKeepsTheNight() {
        // The case a five-minute bar got wrong, and the reason the bar is
        // twenty. Ten minutes upright in the middle of an hour awake is a trip
        // to the kitchen, not a morning — and a chest strap reads sitting up in
        // bed and standing at the counter exactly the same way, so the only
        // thing separating them is how long it lasts.
        let points = night(fromHour: 20, fromMinute: 56, hours: 8.2)
            + awakeInBed(fromHour: 5, fromMinute: 8, hours: 0.33, day: 21)
            + onYourFeet(fromHour: 5, fromMinute: 28, hours: 0.17, day: 21)
            + awakeInBed(fromHour: 5, fromMinute: 38, hours: 0.53, day: 21)
            + night(fromHour: 6, fromMinute: 10, hours: 2.33, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        let rose = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 8, minute: 30))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(rose) ?? .infinity, 0, accuracy: 120,
                       "a ten-minute trip out of bed does not end the night")
    }

    func testWithoutAPositionChannelALongWakeStillSplitsTheNight() {
        // Every night recorded before `bodyPosition` existed has no out-of-bed
        // evidence available at all, so the evidence test can only ever return
        // false. `maxInBedWakeSec` is the backstop that keeps those nights from
        // swallowing the following morning whole.
        let points = night(fromHour: 22, hours: 5)
            + awakeInBed(fromHour: 3, hours: 3.5, day: 21)
            + night(fromHour: 6, fromMinute: 30, hours: 2, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.durationSec ?? 0, 5 * 3600, accuracy: 600,
                       "past three hours awake, the next sleep is a separate episode")
    }

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

    // MARK: - Brief awakenings

    func testAShortAwakeningSurvivesIntoTheHypnogram() {
        // "I woke up several times last night and I don't see those awake."
        // One threshold governed every stage run, so any wake under three
        // minutes was absorbed into the sleep around it and erased — from the
        // chart, from the awake total, and from the bout count continuity is
        // scored on. Ninety seconds is a real awakening.
        let points = night(fromHour: 23, hours: 2)
            + awakeStretch(fromHour: 1, hours: 0.025, day: 21)   // 90 s
            + night(fromHour: 1, fromMinute: 2, hours: 5, day: 21)

        let stages = SleepStages.classify(points)
        XCTAssertTrue(stages.contains(.wake),
                      "a 90-second awakening must survive smoothing")
    }

    func testAStageFlickerIsStillAbsorbed() {
        // The other half of the same rule: wake gets a low floor BECAUSE it is
        // a different kind of event. Stage runs keep the three-minute floor, or
        // the hypnogram goes back to being confetti.
        XCTAssertEqual(SleepThresholds.minStageRunSec, 180)
        XCTAssertLessThan(SleepThresholds.minWakeRunSec, SleepThresholds.minStageRunSec)
    }

    func testABriefArousalDoesNotMoveSleepOnset() {
        // The regression the fix could have caused. Once 60-second wakes are
        // visible they also start breaking the runs that define persistent
        // sleep, so a stretch that was twelve unbroken minutes becomes two
        // six-minute pieces and onset slides later — or nothing clears the bar
        // and the night is never found. An arousal is an event inside sleep.
        let points = night(fromHour: 23, hours: 0.1)                       // 23:00–23:06
            + awakeStretch(fromHour: 23, fromMinute: 6, hours: 0.017)      // ~60 s
            + night(fromHour: 23, fromMinute: 7, hours: 7, day: 20)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w, "a night with an early arousal is still a night")
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 23)
        XCTAssertEqual(Calendar.current.component(.minute, from: w?.startedAt ?? .distantPast), 0,
                       "onset is where sleep began, not after the arousal")
    }

    func testALongWakeStillBreaksPersistentSleep() {
        // And the bound on that leniency: stepping over brief arousals must not
        // become stepping over the night's actual end.
        let points = night(fromHour: 23, hours: 5)
            + awakeStretch(fromHour: 4, hours: 3.4, day: 21)
            + night(fromHour: 7, fromMinute: 30, hours: 0.25, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.durationSec ?? 0, 5 * 3600, accuracy: 600,
                       "three hours awake is still the end of the night")
    }
}
