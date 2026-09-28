import XCTest
@testable import Wythin

/// The question this answers is not "what was the night" — `SleepDetector` does
/// that — but "when may the app write it down". Sealing a night too early
/// truncates it; sealing it twice duplicates it; never sealing it loses it.
final class SleepSessionizerTests: XCTestCase {

    private func points(fromHour: Int, fromMinute: Int = 0, hours: Double,
                        day: Int = 20, motion: Float = 6,
                        spacing: Double = 30) -> [MetricsHistoryPoint] {
        var comps = DateComponents(year: 2026, month: 7, day: day)
        comps.hour = fromHour
        comps.minute = fromMinute
        let start = Calendar.current.date(from: comps)!
        let count = Int((hours * 3600) / spacing)
        return (0..<count).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * spacing),
                                meanBPM: 52, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                                breathBPM: 13, motion: motion,
                                signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents(year: 2026, month: 7, day: day)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    /// 23:10 on the 20th → 06:40 on the 21st.
    private func lastNight() -> [MetricsHistoryPoint] {
        points(fromHour: 23, fromMinute: 10, hours: 7.5, day: 20)
    }

    // MARK: - When to write it down

    func testRecordsLastNightOnceAwake() {
        // 08:00, two hours after waking. The night is over and unrecorded.
        let w = SleepSessionizer.nightToRecord(from: lastNight(),
                                               now: at(21, 8),
                                               recordedDays: [])
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.durationSec ?? 0, 7.5 * 3600, accuracy: 120)
    }

    func testDoesNotSealANightStillInProgress() {
        // 03:00, mid-night. The last sample is seconds old — this person is
        // still asleep, and writing the record now would truncate the night to
        // whatever has happened so far.
        let sofar = points(fromHour: 23, fromMinute: 10, hours: 3.8, day: 20)
        let w = SleepSessionizer.nightToRecord(from: sofar,
                                               now: at(21, 3),
                                               recordedDays: [])
        XCTAssertNil(w, "a night in progress is not a night yet")
    }

    func testDoesNotRecordTheSameNightTwice() {
        // The poll runs every few minutes all day. It must write once.
        let night = SleepSessionizer.nightToRecord(from: lastNight(),
                                                    now: at(21, 8),
                                                    recordedDays: [])
        XCTAssertNotNil(night)

        let again = SleepSessionizer.nightToRecord(from: lastNight(),
                                                    now: at(21, 8, 5),
                                                    recordedDays: [night!.day])
        XCTAssertNil(again, "already written — the poll must be idempotent")
    }

    func testRecordsNightsInsideTheLookbackSoRegularityHasHistory() {
        // Backfill is deliberate. Regularity is a comparison between days and
        // needs at least two, so recording only the most recent night leaves
        // Timing permanently absent on a fresh install while weeks of samples
        // sit unused. A night from eleven days ago is inside the window and
        // should be recorded.
        let old = points(fromHour: 23, fromMinute: 10, hours: 7.5, day: 10)
        XCTAssertNotNil(SleepSessionizer.nightToRecord(from: old,
                                                       now: at(21, 8),
                                                       recordedDays: []))
    }

    func testIgnoresNightsBeyondTheLookback() {
        // There is still a horizon: a night from months back is not history
        // worth surfacing, and it would drag the regularity window with it.
        var comps = DateComponents(year: 2026, month: 4, day: 3)
        comps.hour = 23
        let start = Calendar.current.date(from: comps)!
        let ancient = (0..<Int(7.5 * 120)).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                                meanBPM: 52, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                                breathBPM: 13, motion: 6,
                                signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        XCTAssertNil(SleepSessionizer.nightToRecord(from: ancient,
                                                    now: at(21, 8),
                                                    recordedDays: []))
    }

    func testWaitsOutABriefWakeBeforeSealing() {
        // Awake at 06:00 to use the bathroom, back to sleep at 06:12. A poll
        // landing in that window must not seal the night — the person is not
        // up for the day yet.
        let night = points(fromHour: 23, fromMinute: 10, hours: 6.83, day: 20)
        let w = SleepSessionizer.nightToRecord(from: night,
                                                now: at(21, 6, 5),
                                                recordedDays: [])
        XCTAssertNil(w, "five minutes of quiet is not proof the night ended")
    }

    // MARK: - The race that cut a night short

    /// Ticks that read as wake: moving, pulse up.
    private func up(fromHour: Int, fromMinute: Int = 0, minutes: Double,
                    day: Int = 21) -> [MetricsHistoryPoint] {
        var comps = DateComponents(year: 2026, month: 7, day: day)
        comps.hour = fromHour
        comps.minute = fromMinute
        let start = Calendar.current.date(from: comps)!
        let count = Int((minutes * 60) / 30)
        return (0..<count).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                                meanBPM: 66, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                                breathBPM: 15, motion: 60,
                                signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
    }

    func testHoldsTheNightWhileSleepIsResuming() {
        // The recorded night of 10–11 September. Asleep until 04:24, up for
        // fifteen minutes, awake in bed, then asleep again from 05:02. The
        // poll landed at 05:10: 46 minutes past the last SUSTAINED sleep, so
        // the old rule sealed the night — but the sleeper had been back
        // asleep for eight minutes, two short of "sustained", and that sleep
        // was invisible to it. The night was written ending at 04:24 and, once
        // written, was never revisited. An hour and a quarter of sleep was
        // lost.
        //
        // Elapsed time since the last sustained sleep is not proof that the
        // night is over. Sleep-like ticks after the detected end, however few,
        // mean the person may be going back under, and the night waits.
        let night = points(fromHour: 23, fromMinute: 10, hours: 5.23, day: 20)   // → 04:24
        let upAndAbout = up(fromHour: 4, fromMinute: 24, minutes: 38)             // → 05:02
        let resumed = points(fromHour: 5, fromMinute: 2, hours: 8.0 / 60, day: 21) // → 05:10
        let w = SleepSessionizer.nightToRecord(from: night + upAndAbout + resumed,
                                               now: at(21, 5, 10),
                                               recordedDays: [])
        XCTAssertNil(w, "eight minutes of resumed sleep must hold the night open")
    }

    func testSealsOnceTheTailHasBeenAwakeForTheSettleTime() {
        // Same night, but the sleeper stayed up. Forty-six minutes of wake
        // after the last sleep, with no sleep-like tick in it, is a morning.
        let night = points(fromHour: 23, fromMinute: 10, hours: 5.23, day: 20)
        let upAndAbout = up(fromHour: 4, fromMinute: 24, minutes: 46)
        let w = SleepSessionizer.nightToRecord(from: night + upAndAbout,
                                               now: at(21, 5, 10),
                                               recordedDays: [])
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.endedAt.timeIntervalSince(at(21, 4, 24)) ?? .infinity, 0, accuracy: 60)
    }

    func testAResumedSleepIsSealedOnlyAfterItsOwnSettleTime() {
        // The sleeper went back under at 05:02 and got up at 06:20. At 06:40
        // the night is still not settled — twenty minutes up is not a morning
        // — and at 07:10 it is, ending at 06:20 rather than 04:24.
        let night = points(fromHour: 23, fromMinute: 10, hours: 5.23, day: 20)
        let upAndAbout = up(fromHour: 4, fromMinute: 24, minutes: 38)
        let resumed = points(fromHour: 5, fromMinute: 2, hours: 1.3, day: 21)      // → 06:20
        let morning = up(fromHour: 6, fromMinute: 20, minutes: 50)                 // → 07:10
        let all = night + upAndAbout + resumed + morning

        XCTAssertNil(SleepSessionizer.nightToRecord(from: all, now: at(21, 6, 40), recordedDays: []))
        let w = SleepSessionizer.nightToRecord(from: all, now: at(21, 7, 10), recordedDays: [])
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.endedAt.timeIntervalSince(at(21, 6, 20)) ?? .infinity, 0, accuracy: 60,
                       "the night runs to the final awakening, and the resumed sleep is inside it")
    }
}
