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

    func testIgnoresNightsOlderThanTheLookback() {
        // Stale history from a week ago must not suddenly appear as "last
        // night" the first time the detector runs.
        let old = points(fromHour: 23, fromMinute: 10, hours: 7.5, day: 10)
        XCTAssertNil(SleepSessionizer.nightToRecord(from: old,
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
}
