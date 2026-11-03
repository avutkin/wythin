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

    /// A night with live sessions either side of it, at the cadences the app
    /// actually records at.
    ///
    /// This is the shape that lost a real night. The app ticks every few
    /// seconds while a session is running and every 30 s in the background, so
    /// 88 minutes of meditation either side of eight hours of sleep supplied
    /// 61.5% of the run's samples. Every gate in the detector is relative to
    /// "this recording's own median", and a median over samples is a median
    /// over whatever produced the most ticks — the meditation, not the sleep.
    private func nightBetweenSessions(sleepMotion: Float = 4,
                                      awakeMotion: Float = 50,
                                      day: Int = 20) -> [MetricsHistoryPoint] {
        // 21:40 evening session, 23:00 asleep, 07:00 morning session, 08:30 off.
        evening(day: day, motion: awakeMotion)
            + night(fromHour: 23, hours: 8, day: day, motion: sleepMotion, hr: 57)
            + morning(day: day + 1, motion: awakeMotion)
    }

    private func evening(day: Int, motion: Float) -> [MetricsHistoryPoint] {
        night(fromHour: 21, fromMinute: 40, hours: 1.33, day: day,
              motion: motion, hr: 85, spacing: 5)
    }

    private func morning(day: Int, motion: Float) -> [MetricsHistoryPoint] {
        night(fromHour: 7, hours: 1.5, day: day, motion: motion, hr: 70, spacing: 5)
    }

    // MARK: - Baselines are per minute, not per sample

    /// The regression this whole section exists for: a real night that scored
    /// nothing because the awake blocks around it out-voted it on sample count.
    ///
    /// With the median taken over samples, the run's median motion IS the
    /// meditation's motion, which is over `impossibleSleepMotion`, and
    /// `trimmedToSleep` discards the entire run — no night, no boundaries,
    /// nothing shown to the sleeper.
    func testNightSurvivesDenseAwakeSessionsEitherSideOfIt() {
        let points = nightBetweenSessions()
        let w = SleepDetector.detect(points)

        XCTAssertNotNil(w, "eight hours of quiet sleep is a night whatever surrounds it")
        XCTAssertEqual(w?.durationSec ?? 0, 8 * 3600, accuracy: 20 * 60,
                       "the night is the sleep, not the sleep plus the sessions")
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.hour, from: w?.startedAt ?? .distantPast), 23,
                       "onset is where the sleep starts, not where the strap went on")
        // The sleep block's last tick is 06:59:30, so the night ends there and
        // not at 08:30 where the recording does.
        let expectedEnd = cal.date(from: DateComponents(year: 2026, month: 7, day: 21, hour: 7))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(expectedEnd) ?? .infinity, 0, accuracy: 15 * 60,
                       "the night ends at the final awakening, not at the end of the recording")
    }

    /// The veto has to keep working for what it is actually for — a run that is
    /// genuinely thrashing throughout is not sleep, however long it is.
    func testAGenuinelyRestlessRunIsStillRejected() {
        XCTAssertNil(SleepDetector.detect(night(fromHour: 23, hours: 8, motion: 90)),
                     "40 mg is a floor on the sleeping level, and this run has no quiet in it")
    }

    /// Sampling density must not move the answer. The same night, recorded at a
    /// steady background cadence, is the same night.
    func testTheAnswerDoesNotDependOnSamplingDensity() {
        let dense = SleepDetector.detect(nightBetweenSessions())
        let even = SleepDetector.detect(
            night(fromHour: 21, fromMinute: 40, hours: 1.33, motion: 50, hr: 85)
                + night(fromHour: 23, hours: 8, motion: 4, hr: 57)
                + night(fromHour: 7, hours: 1.5, day: 21, motion: 50, hr: 70))
        XCTAssertNotNil(dense)
        XCTAssertNotNil(even)
        XCTAssertEqual(dense?.durationSec ?? 0, even?.durationSec ?? -1, accuracy: 15 * 60,
                       "the same night sampled two ways must not be two different nights")
    }

    // MARK: - Wake bouts belong to the night they interrupt

    /// A wake in the middle of the night is part of that night. Ending the
    /// record at it reports the first half and throws the rest away.
    func testAnInteriorWakeStaysInsideTheNight() {
        let points = night(fromHour: 23, hours: 3, motion: 4, hr: 57)
            + night(fromHour: 2, hours: 0.33, day: 21, motion: 20, hr: 74)   // 20 min awake
            + night(fromHour: 2, fromMinute: 20, hours: 4.6, day: 21, motion: 4, hr: 57)
        let w = SleepDetector.detect(points)

        XCTAssertNotNil(w)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 23)
        XCTAssertEqual(w?.durationSec ?? 0, 8 * 3600, accuracy: 20 * 60,
                       "23:00 to 07:00 including the bout, not 23:00 to 02:00")
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

    func testSubstantialSleepAfterGettingUpIsStillTheNight() {
        // The recorded night of 10–11 September, in shape: asleep, up and
        // about for a while, then back to bed for real sleep before the
        // morning. The rule used to call the hour on your feet a final
        // awakening and file the later sleep as a morning nap — which this
        // app has no record for, so it was simply gone: the night read
        // 3 h 51 m against a morning that plainly held more.
        //
        // A substantial return to sleep inside `maxInBedWakeSec` is the tail
        // of the night, with the time up counted as awake inside it. The
        // sleep is what is being measured; where the person spent the gap
        // decides how the gap is scored, not whether the sleep counts.
        let points = night(fromHour: 20, fromMinute: 56, hours: 8.2)
            + onYourFeet(fromHour: 5, fromMinute: 8, hours: 1.03, day: 21)
            + night(fromHour: 6, fromMinute: 10, hours: 2.33, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        let rose = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 8, minute: 30))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(rose) ?? .infinity, 0, accuracy: 120,
                       "two hours of sleep after an hour up is the night's tail, not a nap")
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 20)
    }

    func testEvenAShortDozeAfterGettingUpIsStillTheNight() {
        // Sleep after waking is sleep. Fifteen minutes of it after an hour on
        // your feet extends the night to the doze, and the hour is scored
        // awake inside it — which is what happened.
        let points = night(fromHour: 20, fromMinute: 56, hours: 8.2)
            + onYourFeet(fromHour: 5, fromMinute: 8, hours: 1.03, day: 21)
            + night(fromHour: 6, fromMinute: 10, hours: 0.25, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        let dozeEnd = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 6, minute: 25))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(dozeEnd) ?? .infinity, 0, accuracy: 120,
                       "the night ends at the last sleep of the morning")
    }

    func testAnEveningNapBeforeALongGapDoesNotOpenTheNightEvenIfSubstantial() {
        // The rejoin runs forward only. Forty minutes on the sofa at 20:00,
        // then two and a half hours up with the strap on, then bed: onset is
        // bed. A return to sleep in the morning is the night continuing; a
        // nap before the night is a different thing that happened earlier.
        let points = night(fromHour: 20, hours: 0.66)
            + awakeStretch(fromHour: 20, fromMinute: 40, hours: 2.5)
            + night(fromHour: 23, fromMinute: 10, hours: 7.5)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 23)
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

    func testHoursAwakeInBedThenSleepIsStillTheSameNight() {
        // People wake for a couple of hours in the night and sleep again. Three
        // and a half hours awake at 03:00, then two hours of sleep: one night
        // of 10 h 30 m with a long awake stretch inside it — not a five-hour
        // night with the second sleep thrown away. There is no cap on how
        // long the awake stretch may be; the next sleep of the day is the
        // night continuing.
        let points = night(fromHour: 22, hours: 5)
            + awakeInBed(fromHour: 3, hours: 3.5, day: 21)
            + night(fromHour: 6, fromMinute: 30, hours: 2, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.durationSec ?? 0, 10.5 * 3600, accuracy: 600)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.endedAt ?? .distantPast), 8)
    }

    func testADozeAfterHoursUpIsTheNightsTail() {
        // Sleep, then hours up, then a doze at 07:30. The doze is sleep seen
        // later in the same morning, so it belongs to the night; the hours up
        // are awake inside it. The night ends at the doze.
        let points = night(fromHour: 23, hours: 5)
            + awakeStretch(fromHour: 4, hours: 3.4, day: 21)
            + night(fromHour: 7, fromMinute: 30, hours: 0.25, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        let dozeEnd = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 7, minute: 45))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(dozeEnd) ?? .infinity, 0, accuracy: 120)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 23)
    }

    func testTheNightEndsAtTheLastSleepOfTheMorning() {
        // Several returns to sleep across a morning of trying: each one joins,
        // and the night ends at the last of them, not the first wake.
        let points = night(fromHour: 23, hours: 6)                              // → 05:00
            + awakeInBed(fromHour: 5, hours: 2, day: 21)                        // → 07:00
            + night(fromHour: 7, hours: 0.5, day: 21)                            // → 07:30
            + awakeStretch(fromHour: 7, fromMinute: 30, hours: 2.5, day: 21)     // → 10:00
            + night(fromHour: 10, hours: 0.66, day: 21)                          // → 10:40
            + awakeStretch(fromHour: 10, fromMinute: 40, hours: 0.8, day: 21)    // → 11:28

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        let lastSleep = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 10, minute: 40))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(lastSleep) ?? .infinity, 0, accuracy: 120)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 23)
    }

    func testSleepAfterAStrapOffGapIsStillTheNight() {
        // Up at 05:00, strap off for the shower and breakfast, strap back on
        // and asleep again at 06:30. A recording hole is not a reason to
        // throw the second sleep away; the hole is simply unmeasured time
        // inside the night.
        let points = night(fromHour: 23, hours: 6)                              // → 05:00
            + night(fromHour: 6, fromMinute: 30, hours: 1.5, day: 21)           // → 08:00
            + awakeStretch(fromHour: 8, hours: 1, day: 21)                       // → 09:00

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(Calendar.current.component(.hour, from: w?.startedAt ?? .distantPast), 23)
        let secondSleepEnd = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 8))!
        XCTAssertEqual(w?.endedAt.timeIntervalSince(secondSleepEnd) ?? .infinity, 0, accuracy: 120)
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

    func testALongWakeIsScoredAwakeNotSteppedOver() {
        // And the bound on that leniency: stepping over brief arousals must not
        // become calling three hours awake "sleep". The window now runs to the
        // later doze — the night continues through the wake — but the hours
        // inside it are awake, and the time asleep says so.
        let points = night(fromHour: 23, hours: 5)
            + awakeStretch(fromHour: 4, hours: 3.4, day: 21)
            + night(fromHour: 7, fromMinute: 30, hours: 0.25, day: 21)

        let w = SleepDetector.detect(points)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.durationSec ?? 0, 8.75 * 3600, accuracy: 600,
                       "the window spans the wake to the doze")
        let inside = points.filter { $0.timestamp >= w!.startedAt && $0.timestamp <= w!.endedAt }
        let asleep = SleepRecorder.seconds(where: SleepStages.withinSleep(inside).map { $0 != .wake },
                                           points: inside)
        XCTAssertEqual(asleep, 5.25 * 3600, accuracy: 900,
                       "three hours awake inside the window are awake, not sleep")
    }
}
