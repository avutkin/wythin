import XCTest
@testable import Wythin

final class AnchorBaselineTests: XCTestCase {

    private func reading(daysAgo: Int, lnRMSSD: Float, hr: Float = 60, hour: Double = 7) -> AnchorReading {
        let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return AnchorReading(startedAt: start, durationSec: 300, hour: hour,
                             lnRMSSD: lnRMSSD, dc: 7.5, restingHR: hr, pip: 40, dfa1: 1.0,
                             breathBPM: 13, late: false, motionKnown: true, confidence: .high)
    }

    func testNilBelowMinimumAnchors() {
        let history = (1...6).map { reading(daysAgo: $0, lnRMSSD: 3.6) }
        XCTAssertNil(AnchorBaseline.build(history: history, todayHour: 7))
    }

    func testComputesMeanAndSD() {
        let values: [Float] = [3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 4.0]
        let history = values.enumerated().map { reading(daysAgo: $0.offset + 1, lnRMSSD: $0.element) }
        let b = AnchorBaseline.build(history: history, todayHour: 7)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 3.7, accuracy: 0.001)
        XCTAssertEqual(b?.lnRMSSD.n, 7)
        XCTAssertGreaterThan(b?.lnRMSSD.sd ?? 0, 0)
    }

    func testExcludesAnchorsOlderThanWindow() {
        var history = (1...7).map { reading(daysAgo: $0, lnRMSSD: 3.6) }
        history.append(reading(daysAgo: 90, lnRMSSD: 99))
        let b = AnchorBaseline.build(history: history, todayHour: 7)
        XCTAssertEqual(b?.lnRMSSD.n, 7)
    }

    func testPrefersAnchorsNearTodaysHour() {
        let morning = (1...7).map { reading(daysAgo: $0, lnRMSSD: 3.6, hour: 7) }
        let evening = (8...14).map { reading(daysAgo: $0, lnRMSSD: 9.0, hour: 21) }
        let b = AnchorBaseline.build(history: morning + evening, todayHour: 7)
        XCTAssertTrue(b?.hourMatched ?? false)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 3.6, accuracy: 0.001)
    }

    func testFallsBackToAllAnchorsWhenHourMatchTooSmall() {
        let evening = (1...8).map { reading(daysAgo: $0, lnRMSSD: 9.0, hour: 21) }
        let b = AnchorBaseline.build(history: evening, todayHour: 7)
        XCTAssertFalse(b?.hourMatched ?? true)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 9.0, accuracy: 0.001)
    }

    func testComputesRecentCV() {
        let values: [Float] = [3.0, 4.0, 3.0, 4.0, 3.0, 4.0, 3.0]
        let history = values.enumerated().map { reading(daysAgo: $0.offset + 1, lnRMSSD: $0.element) }
        let b = AnchorBaseline.build(history: history, todayHour: 7)
        XCTAssertGreaterThan(b?.cv7 ?? 0, 0.1)
    }
}
