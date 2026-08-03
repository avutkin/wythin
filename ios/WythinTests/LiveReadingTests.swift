import XCTest
@testable import Wythin

final class LiveReadingTests: XCTestCase {

    // MARK: The gain

    func testGainShrinksAtAHighLevel() {
        XCTAssertEqual(LiveReading.gain(1.5), 0.25, accuracy: 0.001)
    }

    func testGainIsOneAtTheCentre() {
        XCTAssertEqual(LiveReading.gain(0), 1.0, accuracy: 0.001)
    }

    func testGainGrowsAtALowLevel() {
        XCTAssertEqual(LiveReading.gain(-1.0), 1.5, accuracy: 0.001)
    }

    func testGainIsClampedAtBothEnds() {
        XCTAssertEqual(LiveReading.gain(99), LiveThresholds.gainClampLow, accuracy: 0.001)
        XCTAssertEqual(LiveReading.gain(-99), LiveThresholds.gainClampHigh, accuracy: 0.001)
    }

    // MARK: The four quadrants from the spec

    func testHighAndEasingBarelyMoves() {
        XCTAssertEqual(LiveReading.effective(level: 1.5, trend: -0.4), 1.45, accuracy: 0.01)
    }

    func testLowAndFallingMovesALot() {
        XCTAssertEqual(LiveReading.effective(level: -1.0, trend: -0.4), -1.30, accuracy: 0.01)
    }

    func testLowButRisingRecoversMeaningfully() {
        XCTAssertEqual(LiveReading.effective(level: -1.0, trend: 0.5), -0.625, accuracy: 0.01)
    }

    func testHighAndRisingSaturates() {
        XCTAssertEqual(LiveReading.effective(level: 1.5, trend: 0.4), 1.55, accuracy: 0.01)
    }

    // MARK: Building from a window

    // The brief's original helper called `MetricsHistoryPoint(timestamp:meanBPM:
    // signalQuality:rrInvalidRate:ecgQualityTier:)`, which does not exist: the
    // "timestamp:" labeled convenience initializer has no `rrInvalidRate`
    // parameter, and it leaves `sdnn`/`rmssd` at their `nil` default — which
    // `MetricsQualityFilter.isValid` rejects outright (it requires `sdnn > 5.0`
    // and `rmssd > 3.0`), so every point would be filtered out regardless.
    // Repaired minimally: drop `rrInvalidRate` (unsupported here) and supply a
    // plausible constant `sdnn`/`rmssd` so points pass the quality filter. No
    // asserted value changes — only `meanBPM` varies per point, which is what
    // every test actually exercises via `.hr`.
    private func window(_ values: [Float], spacingSec: Double, now: Date) -> [MetricsHistoryPoint] {
        let count = values.count
        return values.enumerated().map { idx, v in
            let age = Double(count - 1 - idx) * spacingSec
            return MetricsHistoryPoint(timestamp: now.addingTimeInterval(-age),
                                       meanBPM: v, rmssd: 40, sdnn: 50,
                                       signalQuality: 1.0, ecgQualityTier: 2)
        }
    }

    private func baseline(mean: Double, sd: Double, days: Int = 30) -> LiveBaseline {
        let rollups = (1...days).map { d -> DailyRollup in
            let day = Calendar.current.date(byAdding: .day, value: -d,
                                            to: Calendar.current.startOfDay(for: Date()))!
            return DailyRollup(day: day, dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil,
                               pip: nil, dfa1: nil, stressBalance: nil, vti: nil,
                               meanBPM: mean, sampleCount: 5_000, wearSeconds: 10_000,
                               mean: [LiveMetric.hr.rawValue: mean],
                               sd:   [LiveMetric.hr.rawValue: sd])
        }
        return LiveBaseline.build(rollups: rollups)!
    }

    func testFlatWindowAtBaselineGivesZeroLevelAndFlatTrend() {
        let now = Date()
        let pts = window((0..<300).map { _ in Float(60) }, spacingSec: 2, now: now)
        let r = LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now)
        let hr = r?.readings[.hr]
        XCTAssertEqual(hr?.level ?? 99, 0, accuracy: 0.1)
        XCTAssertFalse(hr?.meaningful ?? true)
        XCTAssertEqual(hr?.trend ?? 99, 0, accuracy: 0.001, "a gated trend is zeroed, not passed through")
    }

    func testASmallSlopeIsGatedByTheSWC() {
        let now = Date()
        // Rises 0.5 bpm across the window — far under one SD of 8.
        let vals = (0..<300).map { Float(60) + Float($0) * 0.5 / 300 }
        let pts = window(vals, spacingSec: 2, now: now)
        let hr = LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now)?.readings[.hr]
        XCTAssertFalse(hr?.meaningful ?? true)
        XCTAssertEqual(hr?.trend ?? 99, 0, accuracy: 0.001)
    }

    func testALargeSlopeClearsTheSWC() {
        let now = Date()
        // Rises 12 bpm across the window — 1.5 SD.
        let vals = (0..<300).map { Float(60) + Float($0) * 12 / 300 }
        let pts = window(vals, spacingSec: 2, now: now)
        let hr = LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now)?.readings[.hr]
        XCTAssertTrue(hr?.meaningful ?? false)
        XCTAssertGreaterThan(hr?.trend ?? 0, 0.5)
    }

    // MARK: The window's location estimator must match the baseline's

    /// A right-skewed window whose MEAN sits exactly on the baseline centre and
    /// whose MEDIAN sits well below it.
    ///
    /// This is the shape RMSSD, LF/HF and PIP actually have within a day. Every
    /// other fixture in this file is constant-valued, where mean == median, so
    /// none of them can see the difference — which is why a mismatched pair
    /// survived the whole branch.
    ///
    /// Ten values repeated 30 times: nine at 52 and one at 132, mean 60, median
    /// 52. Repeating a whole pattern keeps the early and late halves identical,
    /// so the trend is zero and `effective == level` exactly.
    private func skewedWindow(now: Date) -> [MetricsHistoryPoint] {
        let pattern: [Float] = [52, 52, 52, 52, 52, 52, 52, 52, 52, 132]
        let values = (0..<30).flatMap { _ in pattern }
        return window(values, spacingSec: 2, now: now)
    }

    func testTheSkewedFixtureReallyIsSkewed() {
        // Guards the test below from being vacuously true.
        let pattern: [Float] = [52, 52, 52, 52, 52, 52, 52, 52, 52, 132]
        let mean = pattern.reduce(0, +) / Float(pattern.count)
        XCTAssertEqual(mean, 60, accuracy: 0.001)
        XCTAssertEqual(AnchorDetector.median(pattern) ?? 0, 52, accuracy: 0.001)
    }

    /// The baseline centre is a mean of daily MEANS and the trend is computed
    /// from MEANS, so the window's level must be a mean too. Taking the median
    /// against a mean centre subtracts the skew itself: a perfectly typical
    /// window scores a systematically negative z, on every evaluation, on
    /// exactly the metrics that feed most of the Energy and Recovery axes.
    func testATypicalSkewedWindowScoresZeroNotNegative() {
        let now = Date()
        let r = LiveReading.build(window: skewedWindow(now: now),
                                  baseline: baseline(mean: 60, sd: 8), now: now)
        let hr = try? XCTUnwrap(r?.readings[.hr])
        XCTAssertEqual(hr?.level ?? 99, 0, accuracy: 0.15,
                       "a window whose mean is the baseline centre must read as typical")
        XCTAssertFalse(hr?.meaningful ?? true, "the halves are identical — there is no trend")
        XCTAssertEqual(hr?.effective ?? 99, hr?.level ?? -99, accuracy: 0.0001)
    }

    /// Same fixture, stated as the property rather than the number: the level
    /// must agree with the estimator the trend already uses, whatever that is.
    func testLevelUsesTheSameEstimatorAsTheTrend() {
        let now = Date()
        let pts = skewedWindow(now: now)
        let values = pts.compactMap { LiveMetric.hr.value($0) }
        let mean   = values.reduce(0, +) / Float(values.count)
        let median = AnchorDetector.median(values) ?? 0
        XCTAssertNotEqual(mean, median, accuracy: 1.0, "fixture must discriminate the two")

        let b  = baseline(mean: 60, sd: 8)
        let hr = LiveReading.build(window: pts, baseline: b, now: now)?.readings[.hr]
        let zOfMean   = b.z(mean,   for: .hr) ?? 99
        let zOfMedian = b.z(median, for: .hr) ?? 99
        XCTAssertEqual(hr?.level ?? -99, zOfMean, accuracy: 0.0001)
        XCTAssertNotEqual(hr?.level ?? -99, zOfMedian, accuracy: 0.5)
    }

    // MARK: Cadence — the anchor lesson

    func testBuildsAtTheTwoSecondForegroundCadence() {
        let now = Date()
        let pts = window((0..<300).map { _ in Float(60) }, spacingSec: 2, now: now)
        XCTAssertNotNil(LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now))
    }

    func testBuildsAtTheThirtySecondBackgroundCadence() {
        let now = Date()
        // 10 minutes at 30 s is 20 points — the old count-based gate refused this.
        let pts = window((0..<20).map { _ in Float(60) }, spacingSec: 30, now: now)
        XCTAssertNotNil(LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now),
                        "coverage, not raw count, must decide")
    }

    /// `coverage` is the quantity the gate is expressed in, and the gate is
    /// what makes `LiveStateStore` mark a held state stale. Its VALUE was
    /// asserted nowhere — only its consequence (nil vs non-nil) — so a change
    /// that halved it would still pass everything as long as the result stayed
    /// on the same side of `minCoverage`.
    func testCoverageIsReportedAsTheFractionOfTheWindowCarryingSamples() {
        let now = Date()
        let full = window((0..<300).map { _ in Float(60) }, spacingSec: 2, now: now)
        XCTAssertEqual(LiveReading.build(window: full, baseline: baseline(mean: 60, sd: 8),
                                         now: now)?.coverage ?? 0,
                       1.0, accuracy: 0.01, "600 s of 2 s ticks fills a 10-minute window")

        // 14 points at 30 s: 13 gaps + one cadence = 420 s of 600 s = 0.70.
        let partial = window((0..<14).map { _ in Float(60) }, spacingSec: 30, now: now)
        XCTAssertEqual(LiveReading.build(window: partial, baseline: baseline(mean: 60, sd: 8),
                                         now: now)?.coverage ?? 0,
                       0.70, accuracy: 0.01)
    }

    func testRefusesAWindowThatIsMostlyEmpty() {
        let now = Date()
        // Three points at 30 s covers 90 s of a 10-minute window.
        let pts = window((0..<3).map { _ in Float(60) }, spacingSec: 30, now: now)
        XCTAssertNil(LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now))
    }

    func testRefusesAWindowWithDataOnlyAtTheTwoEdges() {
        let now = Date()
        // Two points 600 s apart — one near the window's start, one at "now".
        // A BLE dropout that rejects everything in between looks exactly like
        // this: clean data at both edges, silence in the middle. The gap
        // between them must not be read as one big, perfectly-spaced tick.
        let pts = window([Float(60), Float(60)], spacingSec: 600, now: now)
        XCTAssertNil(LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now),
                    "a single 10-minute gap between two edge samples is silence, not coverage")
    }
}
