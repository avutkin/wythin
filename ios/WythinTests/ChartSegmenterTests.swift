import XCTest
@testable import Wythin

/// Regression cover for the chart line-break rule.
///
/// The 24h window is the only one that can expose an off-by-one here: its
/// bucket is 720 s, well over the 300 s gap threshold, so treating the index
/// distance between two ADJACENT buckets as an empty span makes every point its
/// own segment and the line renders as isolated dots. The 30m (15 s) and 2h
/// (60 s) buckets are both under the threshold and stay joined either way.
final class ChartSegmenterTests: XCTestCase {

    private let gapBreak: TimeInterval = 300     // MetricChartCard.gapBreakSeconds

    // TimeWindow bucket widths: seconds / 120
    private let bucket30m: TimeInterval = 15
    private let bucket2h:  TimeInterval = 60
    private let bucket24h: TimeInterval = 720

    private func segments(_ keys: [Int],
                          present: Set<Int>? = nil,
                          bucket: TimeInterval) -> [Int] {
        ChartSegmenter.segments(valueKeys: keys,
                                presentKeys: present ?? Set(keys),
                                bucketSeconds: bucket,
                                gapBreakSeconds: gapBreak)
    }

    // MARK: The regression

    /// Adjacent 24h buckets must form ONE continuous run. This is the exact
    /// case that shipped broken: every point landed in its own segment, so
    /// Swift Charts drew no line between them.
    func testAdjacentBucketsStayJoinedAt24h() {
        let segs = segments([100, 101, 102, 103, 104], bucket: bucket24h)
        XCTAssertEqual(segs, [0, 0, 0, 0, 0])
    }

    func testAdjacentBucketsStayJoinedAt2hAnd30m() {
        XCTAssertEqual(segments([7, 8, 9], bucket: bucket2h),  [0, 0, 0])
        XCTAssertEqual(segments([7, 8, 9], bucket: bucket30m), [0, 0, 0])
    }

    // MARK: Genuine gaps still break

    /// One missing 24h bucket is a 720 s hole — past the 300 s threshold — so
    /// with no sensor data in between the line must break.
    func testSensorOffGapBreaksTheLineAt24h() {
        let segs = segments([100, 102], present: [100, 102], bucket: bucket24h)
        XCTAssertEqual(segs, [0, 1])
    }

    /// A long gap at 2h: 10 missing 60 s buckets = 600 s > 300 s.
    func testSensorOffGapBreaksTheLineAt2h() {
        let segs = segments([10, 21], present: [10, 21], bucket: bucket2h)
        XCTAssertEqual(segs, [0, 1])
    }

    /// A gap shorter than the threshold stays joined: 3 missing 60 s buckets
    /// = 180 s < 300 s.
    func testShortGapStaysJoined() {
        XCTAssertEqual(segments([10, 14], present: [10, 14], bucket: bucket2h), [0, 0])
    }

    // MARK: Sensor-on bridging

    /// The sensor was on across the hole — this metric was merely uncomputable
    /// for a stretch (e.g. DC warming up). The line must stay connected, so
    /// gaps line up across every chart rather than following each metric's own
    /// nil pattern.
    func testMetricGapBridgedWhenSensorWasOn() {
        let segs = segments([100, 104], present: [100, 101, 102, 103, 104], bucket: bucket24h)
        XCTAssertEqual(segs, [0, 0])
    }

    /// Mixed: bridged where the sensor ran, broken where it didn't.
    func testBridgesAndBreaksInOneSeries() {
        // 100 → 104 bridged (sensor on at 102); 104 → 108 broken (nothing between).
        let segs = segments([100, 104, 108],
                            present: [100, 102, 104, 108],
                            bucket: bucket24h)
        XCTAssertEqual(segs, [0, 0, 1])
    }

    // MARK: Degenerate input

    func testEmptyInput() {
        XCTAssertEqual(segments([], bucket: bucket24h), [])
    }

    func testSinglePoint() {
        XCTAssertEqual(segments([42], bucket: bucket24h), [0])
    }

    /// One segment id per input key, always — `points` indexes them in parallel.
    func testOutputCountMatchesInput() {
        let keys = [1, 2, 3, 9, 10, 40]
        XCTAssertEqual(segments(keys, bucket: bucket24h).count, keys.count)
    }
}
