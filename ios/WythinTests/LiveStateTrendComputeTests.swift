import XCTest
@testable import Wythin

final class LiveStateTrendComputeTests: XCTestCase {

    /// Builds `count` points spaced 2s apart, ending at `now`, with the given
    /// HR values in chronological order (oldest first).
    private func points(count: Int, hrValues: [Float], now: Date = Date()) -> [MetricsHistoryPoint] {
        (0..<count).map { i in
            MetricsHistoryPoint(
                timestamp: now.addingTimeInterval(-Double(count - i) * 2),
                meanBPM: hrValues[i]
            )
        }
    }

    func testReturnsNilBelowMinimumPoints() {
        let history = points(count: 20, hrValues: Array(repeating: 70, count: 20))
        XCTAssertNil(LiveStateTrendCompute.summarize(history, windowMinutes: 10))
    }

    func testComputesStartEndMinMaxMean() {
        let values: [Float] = (0..<60).map { Float(60 + $0) }   // 60...119, ascending
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        let hr = result?["hr"]
        XCTAssertEqual(hr?.start, 60)
        XCTAssertEqual(hr?.end, 119)
        XCTAssertEqual(hr?.min, 60)
        XCTAssertEqual(hr?.max, 119)
        XCTAssertEqual(hr?.mean ?? 0, 89.5, accuracy: 0.01)
    }

    func testDetectsRisingDirection() {
        let values = [Float](repeating: 60, count: 30) + [Float](repeating: 80, count: 30)
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertEqual(result?["hr"]?.direction, "rising")
    }

    func testDetectsFallingDirection() {
        let values = [Float](repeating: 80, count: 30) + [Float](repeating: 60, count: 30)
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertEqual(result?["hr"]?.direction, "falling")
    }

    func testDetectsStableDirection() {
        let values = [Float](repeating: 70, count: 60)
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertEqual(result?["hr"]?.direction, "stable")
    }

    func testOmitsMetricWithNoValuesInWindow() {
        let history = points(count: 60, hrValues: Array(repeating: 70, count: 60))
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertNotNil(result?["hr"])
        XCTAssertNil(result?["rsa"])
    }

    func testExcludesPointsOutsideWindow() {
        let now = Date()
        // 60 points 20 minutes old (outside a 10-min window) + 60 recent points.
        let old = (0..<60).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-1200 - Double(60 - i) * 2), meanBPM: 40)
        }
        let recent = (0..<60).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-Double(60 - i) * 2), meanBPM: 70)
        }
        let result = LiveStateTrendCompute.summarize(old + recent, windowMinutes: 10, now: now)
        XCTAssertEqual(result?["hr"]?.mean, 70)
    }

    func testProducesFiveBucketsAndShape() {
        let values: [Float] = (0..<300).map { 74 - Float($0) * 0.02 }   // steady fall
        let now = Date()
        let history = (0..<300).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-Double(300 - i) * 2),
                                meanBPM: values[i])
        }
        let hr = LiveStateTrendCompute.summarize(history, windowMinutes: 10, now: now)?["hr"]
        XCTAssertEqual(hr?.buckets?.count, 5)
        XCTAssertEqual(hr?.shape, "steady-fall")
        XCTAssertNotNil(hr?.slopePct)
        // A 74 → 68 drift is ~2.8% relative SD — "moderate", not "low".
        XCTAssertEqual(hr?.volatility, "moderate")
    }

    // MARK: - Background cadence (30 s/tick)

    /// Points spaced 30s apart — the background tick cadence.
    private func backgroundPoints(count: Int, hr: Float, now: Date) -> [MetricsHistoryPoint] {
        (0..<count).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-Double(count - i) * 30),
                                meanBPM: hr)
        }
    }

    /// A 10-minute window at the 30s background cadence holds only 20 points,
    /// which is below the 30-point default — so the default correctly refuses.
    func testDefaultMinimumRejectsShortWindowAtBackgroundCadence() {
        let now = Date()
        let history = backgroundPoints(count: 20, hr: 70, now: now)
        XCTAssertNil(LiveStateTrendCompute.summarize(history, windowMinutes: 10, now: now))
    }

    /// ...but a caller that knows the cadence can lower the bar and get a result.
    /// Without this the nudge engine's fast window can never evaluate in background.
    func testSummarizesShortWindowWhenCallerLowersMinimum() {
        let now = Date()
        let history = backgroundPoints(count: 20, hr: 70, now: now)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10,
                                                     minimumPoints: 12, now: now)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["hr"]?.mean, 70)
    }

    func testStillRejectsWhenBelowTheLoweredMinimum() {
        let now = Date()
        let history = backgroundPoints(count: 8, hr: 70, now: now)
        XCTAssertNil(LiveStateTrendCompute.summarize(history, windowMinutes: 10,
                                                     minimumPoints: 12, now: now))
    }

    // MARK: - Derived single series
    //
    // `balance` and `motion` are not in keyPaths (that list is the server payload
    // contract) but the nudge engine needs the same direction/shape/volatility
    // semantics for them.

    func testSeriesTrendComputesDirectionAndShapeForADerivedSeries() {
        let now = Date()
        // Motion climbing steadily across a 30-min window at 30s cadence.
        let history = (0..<60).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: now.addingTimeInterval(-Double(60 - i) * 30),
                                motion: 5 + Float(i) * 0.5)
        }
        let trend = LiveStateTrendCompute.seriesTrend(history, windowMinutes: 30,
                                                      minimumPoints: 36, now: now) { $0.motion }
        XCTAssertEqual(trend?.direction, "rising")
        XCTAssertEqual(trend?.shape, "steady-rise")
        XCTAssertEqual(trend?.buckets?.count, 5)
    }

    func testSeriesTrendReturnsNilBelowMinimumPoints() {
        let now = Date()
        let history = (0..<10).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: now.addingTimeInterval(-Double(10 - i) * 30),
                                motion: 5)
        }
        let trend = LiveStateTrendCompute.seriesTrend(history, windowMinutes: 30,
                                                      minimumPoints: 36, now: now) { $0.motion }
        XCTAssertNil(trend)
    }

    func testSeriesTrendReturnsNilWhenSeriesIsAllNil() {
        let now = Date()
        let history = (0..<60).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: now.addingTimeInterval(-Double(60 - i) * 30),
                                motion: nil)
        }
        let trend = LiveStateTrendCompute.seriesTrend(history, windowMinutes: 30,
                                                      minimumPoints: 36, now: now) { $0.motion }
        XCTAssertNil(trend)
    }

    func testFlatWindowReadsAsLowVolatilityPlateau() {
        let now = Date()
        let history = (0..<300).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-Double(300 - i) * 2),
                                meanBPM: 70 + Float(i % 2) * 0.05)
        }
        let hr = LiveStateTrendCompute.summarize(history, windowMinutes: 10, now: now)?["hr"]
        XCTAssertEqual(hr?.shape, "plateau")
        XCTAssertEqual(hr?.volatility, "low")
    }
}
