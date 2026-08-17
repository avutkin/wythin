import XCTest
@testable import Wythin

final class BreathRateTrackerTests: XCTestCase {

    private func est(_ bpm: Float, _ confidence: Float = 6) -> BreathRateTracker.Estimate {
        .init(bpm: bpm, confidence: confidence)
    }

    // MARK: Fusion (within one tick)

    /// Two channels agreeing is stronger evidence than either alone, so their
    /// rates are averaged by confidence.
    func testAgreeingSourcesAreAveragedByConfidence() {
        let fused = BreathRateTracker.fuse([est(14, 4), est(15, 8)])
        XCTAssertEqual(fused?.bpm ?? 0, 14.67, accuracy: 0.05)
        XCTAssertEqual(fused?.confidence ?? 0, 12, accuracy: 0.01)
    }

    /// Disagreeing sources cannot both be right — averaging would invent a
    /// rate neither measured, so the more prominent peak wins outright.
    func testDisagreeingSourcesTakeTheStrongerPeak() {
        let fused = BreathRateTracker.fuse([est(7, 3), est(18, 9)])
        XCTAssertEqual(fused?.bpm ?? 0, 18, accuracy: 0.01)
    }

    func testNoCandidatesFuseToNil() {
        XCTAssertNil(BreathRateTracker.fuse([]))
        XCTAssertNil(BreathRateTracker.fuse([est(15, 0)]))   // zero confidence
    }

    // MARK: Tracking (across ticks)

    func testFirstReadingSeedsTheFilter() {
        var t = BreathRateTracker()
        XCTAssertEqual(t.update([est(15)], dt: 2) ?? 0, 15, accuracy: 0.001)
    }

    /// The headline behaviour: a lone spike between two steady readings must
    /// barely move the tracked rate — this is the 6→22→9 jitter the chart was
    /// plotting as if it were breathing.
    func testIsolatedSpikeIsRejected() {
        var t = BreathRateTracker()
        for _ in 0..<8 { _ = t.update([est(14)], dt: 2) }
        let before = t.bpm!
        let after  = t.update([est(28, 3)], dt: 2)!
        XCTAssertEqual(after, before, accuracy: 0.5, "a single spike moved the tracked rate")
    }

    /// …but a real, sustained change is followed: deliberately dropping from
    /// 14 to 6 br/min converges within a handful of ticks rather than being
    /// suppressed forever.
    func testSustainedChangeIsFollowed() {
        var t = BreathRateTracker()
        for _ in 0..<8 { _ = t.update([est(14)], dt: 2) }
        for _ in 0..<10 { _ = t.update([est(6)], dt: 2) }
        XCTAssertEqual(t.bpm ?? 0, 6, accuracy: 1.5)
    }

    /// A momentarily unreadable spectrum is not evidence that breathing
    /// stopped — hold the last value rather than blanking the chart.
    func testEmptyTickHoldsTheLastValue() {
        var t = BreathRateTracker()
        _ = t.update([est(12)], dt: 2)
        XCTAssertEqual(t.update([], dt: 2) ?? 0, 12, accuracy: 0.001)
    }

    /// High-confidence readings move the estimate faster than low-confidence
    /// ones — the whole point of carrying prominence through.
    func testConfidenceControlsHowFastTheEstimateMoves() {
        var strong = BreathRateTracker(), weak = BreathRateTracker()
        for _ in 0..<5 {
            _ = strong.update([est(12)], dt: 2)
            _ = weak.update([est(12)], dt: 2)
        }
        _ = strong.update([est(16, 20)], dt: 2)
        _ = weak.update([est(16, 3)], dt: 2)
        XCTAssertGreaterThan(strong.bpm!, weak.bpm!)
    }

    func testResetForgetsState() {
        var t = BreathRateTracker()
        _ = t.update([est(15)], dt: 2)
        t.reset()
        XCTAssertNil(t.bpm)
        XCTAssertEqual(t.update([est(8)], dt: 2) ?? 0, 8, accuracy: 0.001)
    }
}
