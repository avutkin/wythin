import XCTest
@testable import Wythin

final class TrackMetricSpecTests: XCTestCase {

    private let rollup = DailyRollup(
        day: Date(timeIntervalSince1970: 1_750_000_000),
        dc: 8, rmssd: 40, rsaMs: 30, rcmse: 1.4, pip: 55, dfa1: 1.0,
        stressBalance: 45, vti: 3.7, meanBPM: 60,
        sampleCount: 200, wearSeconds: 400, mean: [:], sd: [:])

    func testHasExactlyEightMetricsInOrder() {
        // Matches `LiveMetric`'s declaration order for the cases the two
        // screens share (dc, rcmse, pip, dfa1, stressBalance, rsa, rmssd) —
        // see `testOrderMatchesLiveMetricDeclarationOrder` below, which pins
        // that relationship directly rather than duplicating it as a literal
        // label list that could drift out of sync with `LiveMetric` unnoticed.
        XCTAssertEqual(TrackMetrics.all.map(\.def.label), [
            "Vagal Tone", "Adaptive Capacity", "Inner Noise", "Harmony",
            "Stress Balance", "Conscious Breathing", "Calm Power",
            "Overall Variability",
        ])
    }

    /// Track's `rollup` closures are keyed to `DailyRollup` fields, but the
    /// two screens' orderings are meant to agree metric-by-metric — this maps
    /// each Track spec to the `LiveMetric` case reading the *same*
    /// underlying quantity, and checks that the sequence of those cases is
    /// non-decreasing against `LiveMetric.allCases`' own index order. A
    /// `TrackMetrics.all` reorder that drifts from `LiveMetric` (e.g. two
    /// specs swapped, or a new one inserted at the wrong spot) fails this
    /// even though `testHasExactlySevenMetricsInOrder` above is a fine
    /// regression pin for the current, already-correct order — that test
    /// alone would not catch a *plausible-looking* wrong order being typed in
    /// fresh, since it doesn't derive its expectation from `LiveMetric` at all.
    func testOrderMatchesLiveMetricDeclarationOrder() {
        let liveCase: [String: LiveMetric] = [
            "Vagal Tone": .dc, "Calm Power": .rmssd, "Conscious Breathing": .rsa,
            "Adaptive Capacity": .rcmse, "Harmony": .dfa1, "Inner Noise": .pip,
            "Stress Balance": .stressBalance, "Overall Variability": .sdnn,
        ]
        let liveOrder = LiveMetric.allCases
        let trackIndicesInLiveOrder = TrackMetrics.all.map { spec -> Int in
            let live = liveCase[spec.def.label]!
            return liveOrder.firstIndex(of: live)!
        }
        XCTAssertEqual(trackIndicesInLiveOrder, trackIndicesInLiveOrder.sorted(),
                       "TrackMetrics.all has drifted from LiveMetric's declaration order")
        // Sanity check the fixture itself covers every Track metric exactly
        // once, so a typo in `liveCase` can't silently pass the assertion above.
        XCTAssertEqual(Set(liveCase.keys), Set(TrackMetrics.all.map(\.def.label)))
    }

    func testExcludesPulse() {
        let labels = Set(TrackMetrics.all.map(\.def.label))
        XCTAssertFalse(labels.contains("Pulse"))
    }

    func testEveryExtractorReadsItsField() {
        // dc, rcmse, pip, dfa1, stressBalance, rsaMs, rmssd — the fixture's
        // fields read in display order.
        let values = TrackMetrics.all.map { $0.rollup(rollup) }
        // SDNN reads the keyed mean dictionary, which the fixture leaves empty.
        XCTAssertEqual(values, [8, 1.4, 55, 1.0, 45, 30, 40, nil])
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
        XCTAssertTrue(spec("Calm Power").zeroBased)
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
            guard let shared = activityMetricDefs.first(where: { $0.label == spec.def.label }) else {
                // Track-only metrics (Overall Variability) have no Activities
                // surface, so they own their copy instead of inheriting it.
                XCTAssertFalse(spec.def.why.isEmpty)
                continue
            }
            XCTAssertEqual(spec.def.why, shared.why)
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

    /// Names the measure, not a family or a stale alias. Each of these was
    /// wrong on screen at some point: the RMSSD card said "HRV" (a family, not
    /// a measure), the name "Calm Power" sat on the log of the measure beside
    /// it, and Stress Balance said "LF/HF" — which it has never plotted.
    func testTechLabelsNameTheActualMeasure() {
        func def(_ label: String) -> ActivityMetricDef {
            activityMetricDefs.first { $0.label == label }!
        }
        XCTAssertEqual(def("Calm Power").techLabel, "RMSSD")
        XCTAssertNotEqual(def("Stress Balance").techLabel, "LF/HF")

        // And every metric spells its measure out somewhere, so an
        // abbreviation is never the only thing naming it.
        for d in activityMetricDefs {
            XCTAssertFalse(d.techFull.isEmpty, "\(d.label) has no spelled-out technical name")
            XCTAssertTrue(d.techFull.contains("("), "\(d.label) techFull should carry (abbreviation)")
        }
        for spec in TrackMetrics.all {
            XCTAssertFalse(spec.def.techFull.isEmpty, "\(spec.def.label) has no spelled-out name")
        }
    }

}
