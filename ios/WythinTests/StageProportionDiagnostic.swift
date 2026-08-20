import XCTest
@testable import Wythin

/// The stage breakdown has to describe *this* night.
///
/// It did not. `detailed()` ranked ticks on a depth axis — a real measurement —
/// and then cut the ranking at fixed shares, 21% deep and 23% REM. So every
/// night ever recorded reported 21% deep and 23% REM: the constants, read back
/// out. A textbook 90-minute cycle and a perfectly flat recording came back
/// identical.
///
/// The cut is on the axis itself now, so a night with no depth structure
/// reports undifferentiated light sleep instead of being handed a hypnogram
/// built from nothing but the clock.
final class StageProportionDiagnostic: XCTestCase {

    private func night(coherence: @escaping (Int) -> Float,
                       sdnn: @escaping (Int) -> Float) -> [MetricsHistoryPoint] {
        let start = Date(timeIntervalSince1970: 1_755_000_000)
        return (0..<1200).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                                meanBPM: 52, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2,
                                coherence: coherence(i), sdnn: sdnn(i), lfHF: 1.0)
        }
    }

    private func deepShare(_ pts: [MetricsHistoryPoint]) -> Double {
        let stages = SleepStages.detailed(pts)
        let asleep = stages.filter { $0 != .wake }.count
        guard asleep > 0 else { return 0 }
        return Double(stages.filter { $0 == .n3 }.count) / Double(asleep)
    }

    func testDeepSleepShareReflectsTheNightAndNotAConstant() {
        let structured = night(coherence: { 0.5 + 0.4 * Float(sin(Double($0) / 60)) },
                               sdnn: { 60 - 20 * Float(sin(Double($0) / 60)) })
        let flat = night(coherence: { _ in 0.5 }, sdnn: { _ in 60 })

        // A night with no depth structure at all cannot honestly be reported as
        // having the same deep-sleep share as one with a strong 90-minute cycle.
        XCTAssertNotEqual(deepShare(structured), deepShare(flat), accuracy: 0.02,
                          "both nights report the same deep share — it is the constant, not a measurement")
    }

    func testANightWithNoDepthStructureReportsNoDeepSleep() {
        let flat = night(coherence: { _ in 0.5 }, sdnn: { _ in 60 })
        XCTAssertEqual(deepShare(flat), 0, accuracy: 0.001,
                       "nothing was measured, so nothing should be claimed")
    }

    func testAStructuredNightStillReportsAPlausibleDeepShare() {
        // Responsive must not mean unanchored: a night with real structure
        // should still land inside the typical adult N3 range of 13–23%.
        let structured = night(coherence: { 0.5 + 0.4 * Float(sin(Double($0) / 60)) },
                               sdnn: { i in 60 - 20 * Float(sin(Double(i) / 60)) })
        let share = deepShare(structured)
        XCTAssertGreaterThan(share, 0.05)
        XCTAssertLessThan(share, 0.40)
    }
}
