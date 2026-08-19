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
        // The anchor rejects anything above stillnessSD. A sleeper turns over,
        // and a detector that inherited that gate would find no nights at all.
        let w = SleepDetector.detect(night(fromHour: 23, hours: 7, motion: 140))
        XCTAssertNotNil(w, "movement is part of sleep, not a disqualifier")
    }
}
