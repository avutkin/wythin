import XCTest
@testable import Wythin

final class TrackMetricSpecTests: XCTestCase {

    private let rollup = DailyRollup(
        day: Date(timeIntervalSince1970: 1_750_000_000),
        dc: 8, rmssd: 40, rsaMs: 30, rcmse: 1.4, pip: 55, dfa1: 1.0,
        stressBalance: 45, vti: 3.7, meanBPM: 60,
        sampleCount: 200, wearSeconds: 400)

    func testHasExactlySevenMetricsInOrder() {
        XCTAssertEqual(TrackMetrics.all.map(\.def.label), [
            "Vagal Tone", "Energy Reserve", "Conscious Breathing",
            "Adaptive Capacity", "Harmony", "Inner Noise", "Stress Balance",
        ])
    }

    func testExcludesPulseAndCalmPower() {
        let labels = Set(TrackMetrics.all.map(\.def.label))
        XCTAssertFalse(labels.contains("Pulse"))
        XCTAssertFalse(labels.contains("Calm Power"))
    }

    func testEveryExtractorReadsItsField() {
        let values = TrackMetrics.all.map { $0.rollup(rollup) }
        XCTAssertEqual(values, [8, 40, 30, 1.4, 1.0, 55, 45])
    }

    func testTrendKeysAreUniqueAndStressBalanceIsNotLfHf() {
        let keys = TrackMetrics.all.map(\.trendKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        // Sending the 0–100 dial under `lf_hf` would have the server's
        // _METRIC_NAMES gloss it as a raw ratio.
        XCTAssertFalse(keys.contains("lf_hf"))
        XCTAssertTrue(keys.contains("stress_balance"))
    }

    func testIndexMetricsAreNotZeroBased() {
        func spec(_ label: String) -> TrackMetricSpec {
            TrackMetrics.all.first { $0.def.label == label }!
        }
        XCTAssertFalse(spec("Adaptive Capacity").zeroBased)
        XCTAssertFalse(spec("Harmony").zeroBased)
        XCTAssertTrue(spec("Energy Reserve").zeroBased)
    }

    func testDirectionsComeFromTheSharedRegistry() {
        func spec(_ label: String) -> TrackMetricSpec {
            TrackMetrics.all.first { $0.def.label == label }!
        }
        // Inner Noise is `.lower` — a drop must read as an improvement.
        XCTAssertGreaterThan(spec("Inner Noise").def.direction.benefit(40),
                             spec("Inner Noise").def.direction.benefit(60))
        // Harmony is `.target(1.0)`.
        XCTAssertGreaterThan(spec("Harmony").def.direction.benefit(1.0),
                             spec("Harmony").def.direction.benefit(1.4))
    }

    func testWhyCopyIsInheritedNotRetyped() {
        for spec in TrackMetrics.all {
            let shared = activityMetricDefs.first { $0.label == spec.def.label }
            XCTAssertEqual(spec.def.why, shared?.why)
            XCTAssertFalse(spec.def.why.isEmpty)
        }
    }

    func testTrendWhyIsNonEmptyForEveryMetric() {
        for spec in TrackMetrics.all {
            XCTAssertFalse(spec.trendWhy.isEmpty, "\(spec.def.label) is missing trendWhy")
        }
    }

    /// Guards against the Activities session-detail copy (`def.why`) being
    /// pasted back into the Track-specific `trendWhy`. Track shows daily
    /// averages across a week/month/6 months, not a single in-progress
    /// session, so language like "expect it to climb as you settle" or
    /// "during" restful practice is incoherent there.
    func testTrendWhyHasNoSessionScopedLanguage() {
        let bannedPhrases = ["session", "as you settle", "as you relax", "during", "expect it to"]
        for spec in TrackMetrics.all {
            let lowered = spec.trendWhy.lowercased()
            for phrase in bannedPhrases {
                XCTAssertFalse(lowered.contains(phrase),
                                "\(spec.def.label) trendWhy contains session-scoped phrase \"\(phrase)\"")
            }
        }
    }

    func testTrendWhyDiffersFromSessionWhy() {
        for spec in TrackMetrics.all {
            XCTAssertNotEqual(spec.trendWhy, spec.def.why, "\(spec.def.label) trendWhy was not rewritten")
        }
    }
}
