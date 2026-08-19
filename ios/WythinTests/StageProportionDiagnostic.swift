import XCTest
@testable import Wythin

/// **A known defect, recorded rather than hidden.**
///
/// `detailed()` ranks every asleep tick on a depth axis and then cuts the
/// ranking at `deepShare` (21%) and `remShare` (23%). Ranking is a measurement;
/// cutting at a fixed share is not. The consequence is that the deep and REM
/// percentages are the same on every night that was ever recorded — they are
/// the constants, read back out.
///
/// The doc comment on `detailed()` is honest about this ("the proportions are
/// imposed, not discovered"), but the UI prints exact minutes and percentages,
/// which reads as measurement. This test asserts what the numbers *should* do
/// and is expected to fail until the cut points come from the night instead of
/// from a constant.
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
        XCTExpectFailure("known: deepShare/remShare impose the proportions — see doc above")

        let structured = night(coherence: { 0.5 + 0.4 * Float(sin(Double($0) / 60)) },
                               sdnn: { 60 - 20 * Float(sin(Double($0) / 60)) })
        let flat = night(coherence: { _ in 0.5 }, sdnn: { _ in 60 })

        // A night with no depth structure at all cannot honestly be reported as
        // having the same deep-sleep share as one with a strong 90-minute cycle.
        XCTAssertNotEqual(deepShare(structured), deepShare(flat), accuracy: 0.02,
                          "both nights report the same deep share — it is the constant, not a measurement")
    }
}
