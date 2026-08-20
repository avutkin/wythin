import XCTest
@testable import Wythin

/// The pipeline against one real night. Synthetic fixtures pass because they
/// were built to the thresholds; this one was recorded before the thresholds
/// existed and does not care about them.
final class RealNightTests: XCTestCase {

    private func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    func testFindsTheNightAndNotTheEveningOrTheMorning() {
        // Ground truth from the trace: asleep from about 22:00, up at 07:30
        // where motion jumps to 30 mg and heart rate to 77. The recording runs
        // 21:00–09:00 with no gap, so gap-splitting alone yields all 12 hours.
        guard let w = SleepDetector.detect(RealNight.points()) else {
            return XCTFail("no night found in a night of real data")
        }
        // Bounds, not exact times. There is no polysomnogram here — "22:00"
        // was read off 15-minute medians by eye, and asserting to the minute
        // would be claiming a precision this data cannot support. What the
        // detector must get right is that it finds the NIGHT: not the evening
        // it was still awake for, and not all twelve hours of the recording.
        XCTAssertGreaterThanOrEqual(hhmm(w.startedAt), "21:30", "onset no earlier than settling")
        XCTAssertLessThanOrEqual(hhmm(w.startedAt), "22:15", "onset no later than clearly asleep")
        // 07:00 rather than 07:15: the last clearly-quiet bucket is 07:15, but
        // the boundary is genuinely uncertain to about twenty minutes at
        // five-minute medians, and asserting tighter would be inventing
        // precision.
        XCTAssertGreaterThanOrEqual(hhmm(w.endedAt), "07:00", "wake no earlier than the last quiet stretch")
        XCTAssertLessThanOrEqual(hhmm(w.endedAt), "07:45", "wake no later than the 07:30 rise")
        XCTAssertEqual(w.durationSec / 3600, 9.5, accuracy: 0.8)
    }

    func testFindsBothStatesAcrossTheNight() {
        // Coherence peaks near 23:00, 00:45, 03:15, 04:30 and 06:45 — roughly
        // 90–105 minutes apart — and SDNN runs low exactly where coherence runs
        // high. A classifier that reports one state for the whole night has
        // thrown that structure away.
        guard let w = SleepDetector.detect(RealNight.points()) else { return XCTFail("no night") }
        let inNight = RealNight.points().filter { $0.timestamp >= w.startedAt && $0.timestamp <= w.endedAt }
        let stages = SleepStages.classify(inNight)

        let quiet = stages.filter { $0 == .quiet }.count
        let active = stages.filter { $0 == .active }.count
        XCTAssertGreaterThan(quiet, 0, "no quiet sleep found in a full night")
        XCTAssertGreaterThan(active, 0, "no active sleep found in a full night")

        let quietShare = Double(quiet) / Double(max(1, quiet + active))
        XCTAssertGreaterThan(quietShare, 0.2)
        XCTAssertLessThan(quietShare, 0.8, "one state must not swallow the night")
    }

    func testWakeIsFoundAtTheMorningRiseAndNotDuringTheNight() {
        // Classified over a night-scale window, which is how the pipeline uses
        // it: `detect` narrows an all-day run to the quietest night-length
        // stretch BEFORE classifying, because the gates are relative to the
        // recording's own medians and a 21-hour median is neither day nor
        // night. Handing the whole day straight to `classify` is not a path
        // the detector takes.
        let pts = RealNight.points().filter {
            let h = Calendar.current.component(.hour, from: $0.timestamp)
            let isEvening = h >= 21
            let isMorning = h < 9
            return isEvening || isMorning
        }
        let stages = SleepStages.classify(pts)
        func stage(at hhmmStr: String) -> SleepStage? {
            guard let i = pts.firstIndex(where: { hhmm($0.timestamp) == hhmmStr }) else { return nil }
            return stages[i]
        }
        XCTAssertEqual(stage(at: "07:30"), .wake, "motion 30 mg, HR 77 — up for the day")
        XCTAssertNotEqual(stage(at: "03:00"), .wake, "mid-night must not read as awake")
        XCTAssertNotEqual(stage(at: "05:45"), .wake, "a brief stir is not a wake bout")
    }

    // MARK: - Onset, breathing, and the duration rule

    func testOnsetIsWhereBreathingSettlesNotWhereHeartRateDips() {
        // Heart rate alone put onset at 21:25. The trace says otherwise: at
        // 21:10 motion spikes to 105, at 21:20 heart rate is 118 with breath
        // at 6.7, and breathing does not settle to a steady 17/min until about
        // 22:10. Between those, breath swings from 6.7 to 20.1 — the signature
        // of being awake, which heart rate in the low sixties hides.
        guard let w = SleepDetector.detect(RealNight.points()) else {
            return XCTFail("no night found")
        }
        XCTAssertGreaterThanOrEqual(hhmm(w.startedAt), "21:55",
                                    "onset must not land while breathing is still erratic")
        XCTAssertLessThanOrEqual(hhmm(w.startedAt), "22:30")
    }

    func testBreathingSteadinessIsMeasuredFromBreathRate() {
        // "Not measured" was wrong: breath rate has 97% coverage on this
        // night. What was missing was the derivation, not the signal.
        guard let w = SleepDetector.detect(RealNight.points()) else { return XCTFail("no night") }
        let night = RealNight.points().filter { $0.timestamp >= w.startedAt && $0.timestamp <= w.endedAt }
        let steady = SleepBreathing.steadyFraction(night)

        XCTAssertNotNil(steady, "breath rate is present, so steadiness is computable")
        // 0.6 rather than a guess: a settled night on this hardware measures
        // about 76% steady at the calibrated threshold.
        XCTAssertGreaterThan(steady ?? 0, 0.6, "a settled night is mostly steady")
        XCTAssertLessThanOrEqual(steady ?? 2, 1.0)
    }

    func testLongSleepIsNotPunishedLikeShortSleep() {
        // 10h 05m against a 7h 45m placeholder scored duration 0 — the same as
        // sleeping four hours. The research is explicit that short sleep is
        // causally harmful while long sleep is a marker of illness rather than
        // a cause, and says in terms: do not tell users that sleeping long is
        // harmful.
        var over = SleepScoreInput(regularityIndex: nil, asleepSec: 10.1 * 3600,
                                   needSec: 7.75 * 3600, wakeBouts: 3,
                                   longestUnbrokenSec: 3 * 3600, hrNadirDip: 14,
                                   hrNadirFraction: 0.45, meanRMSSD: 52, steadyFraction: 0.9)
        let long = SleepScore.compute(over).sections[.duration] ?? 0
        over.asleepSec = 4 * 3600
        let short = SleepScore.compute(over).sections[.duration] ?? 100

        XCTAssertGreaterThan(long, 85, "ten hours is not a failure")
        XCTAssertLessThan(short, 40, "four hours is")
        XCTAssertGreaterThan(long, short + 40)
    }

    func testDaytimeQuietIsNotRecordedAsANight() {
        // On days the strap was not worn overnight the search still returns the
        // quietest stretch in the slice. Against the real store that produced
        // entries like 06:45–11:44 and 17:00–21:12 — genuine quiet periods, but
        // a lie-in and an evening on the sofa, not nights.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 8, day: 18)
        comps.hour = 17
        let start = cal.date(from: comps)!
        let evening = (0..<Int(4.5 * 120)).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                                meanBPM: 58, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                                breathBPM: 14, motion: 5,
                                signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        XCTAssertTrue(SleepDetector.detectAll(evening).isEmpty,
                      "17:00–21:30 misses the circadian trough entirely")
    }

    func testTheRealNightStillSurvivesTheTroughGate() {
        let nights = SleepDetector.detectAll(RealNight.points())
        XCTAssertEqual(nights.count, 1)
        XCTAssertGreaterThanOrEqual(hhmm(nights[0].startedAt), "21:55")
        XCTAssertLessThanOrEqual(hhmm(nights[0].startedAt), "22:30")
    }
}
