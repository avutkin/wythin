import XCTest
@testable import Wythin

final class AnchorDetectorTests: XCTestCase {

    /// Builds `minutes` of still, clean 2s ticks starting at `hour` on a fixed day.
    private func stillPoints(minutes: Double,
                             hour: Int,
                             motion: Float? = 5,
                             hr: Float = 60,
                             vti: Float = 3.6) -> [MetricsHistoryPoint] {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20)
        comps.hour = hour
        let start = cal.date(from: comps)!
        let count = Int(minutes * 30)   // 30 ticks per minute at 2 s
        return (0..<count).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 2),
                                meanBPM: hr, vti: vti, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: motion,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
    }

    func testFindsCleanMorningWindow() {
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 7))
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.lnRMSSD ?? 0, 3.6, accuracy: 0.001)
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001)
        XCTAssertNotNil(a?.dc)
        XCTAssertFalse(a?.late ?? true)
        XCTAssertEqual(a?.confidence, .high)
    }

    func testRejectsWindowShorterThanMinimum() {
        XCTAssertNil(AnchorDetector.detect(stillPoints(minutes: 2, hour: 7)))
    }

    func testDropsDCOnShortWindow() {
        let a = AnchorDetector.detect(stillPoints(minutes: 4, hour: 7))
        XCTAssertNotNil(a)
        XCTAssertNil(a?.dc, "DC needs a 5-minute window")
        XCTAssertEqual(a?.confidence, .medium)
    }

    func testRejectsMotion() {
        XCTAssertNil(AnchorDetector.detect(stillPoints(minutes: 6, hour: 7, motion: 120)))
    }

    func testFallsBackToHRStabilityWhenMotionUnknown() {
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 7, motion: nil))
        XCTAssertNotNil(a)
        XCTAssertFalse(a?.motionKnown ?? true)
        XCTAssertEqual(a?.confidence, .low)
    }

    func testAfternoonOnlyWindowIsLate() {
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 15))
        XCTAssertNotNil(a)
        XCTAssertTrue(a?.late ?? false)
        XCTAssertEqual(a?.confidence, .medium)
    }

    func testPrefersMorningWindowOverLaterOne() {
        let points = stillPoints(minutes: 6, hour: 8) + stillPoints(minutes: 20, hour: 16)
        let a = AnchorDetector.detect(points)
        XCTAssertEqual(Calendar.current.component(.hour, from: a?.startedAt ?? .distantPast), 8)
    }

    func testRejectsImplausibleBreathingRate() {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let points = (0..<180).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 2),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 30, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        XCTAssertNil(AnchorDetector.detect(points))
    }
}
