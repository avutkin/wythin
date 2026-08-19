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
}
