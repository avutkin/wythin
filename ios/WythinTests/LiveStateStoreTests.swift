import XCTest
@testable import Wythin

/// `LiveStateStore.recomputeState(env:)` needs a full `AppEnvironment`
/// (`ModelContainer`, `BLEService`, ...) to construct, which is why it isn't
/// exercised directly here — the same reason `DayPotentialStore.refresh(env:)`
/// has no direct test and only its pure `State.derive` does. Everything below
/// drives the `rollups:window:` overload it delegates to, which has no such
/// dependency.
@MainActor
final class LiveStateStoreTests: XCTestCase {

    // MARK: Fixtures

    private func rollup(daysAgo: Int, means: [LiveMetric: Double],
                        sds: [LiveMetric: Double]) -> DailyRollup {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo,
                                        to: Calendar.current.startOfDay(for: Date()))!
        var meanDict: [String: Double] = [:]
        var sdDict:   [String: Double] = [:]
        for (m, v) in means { meanDict[m.rawValue] = v }
        for (m, v) in sds   { sdDict[m.rawValue]   = v }
        return DailyRollup(day: day, dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil, pip: nil,
                           dfa1: nil, stressBalance: nil, vti: nil, meanBPM: means[.hr],
                           sampleCount: 5_000, wearSeconds: 10_000, mean: meanDict, sd: sdDict)
    }

    /// A 30-day baseline covering the five metrics used below (two of the
    /// three energy inputs, both tension inputs) — enough for `tense &&
    /// !lowE` to decide the state on its own, without needing recovery-axis
    /// metrics in the fixture at all. Means/SDs sit at realistic magnitudes
    /// (SDs matching `LivePrior`) so the prior-blend in `BaselineStat.z`
    /// barely moves the z-score at n = 30 — the same assumption
    /// `LiveReadingTests` relies on.
    private func baselineRollups(days: Int = 30) -> [DailyRollup] {
        let means: [LiveMetric: Double] = [.hr: 60, .rmssd: 40, .rcmse: 0.6, .pip: 20, .lfHF: 3]
        let sds:   [LiveMetric: Double] = [.hr: 8, .rmssd: 14, .rcmse: 0.35, .pip: 8, .lfHF: 6]
        return (1...days).map { rollup(daysAgo: $0, means: means, sds: sds) }
    }

    /// A flat (zero-trend) window at the given per-metric values. Flat so
    /// `effective == level` exactly — trend is gated to zero by the SWC gate.
    private func window(hr: Double = 60, rmssd: Double = 40, rcmse: Double = 0.6,
                        pip: Double = 20, lfHF: Double = 3,
                        count: Int = 300, spacingSec: Double = 2, now: Date) -> [MetricsHistoryPoint] {
        (0..<count).map { i in
            let age = Double(count - 1 - i) * spacingSec
            return MetricsHistoryPoint(timestamp: now.addingTimeInterval(-age),
                                       meanBPM: Float(hr), rmssd: Float(rmssd), sdnn: 50,
                                       lfHF: Float(lfHF), rcmse: Float(rcmse), pip: Float(pip),
                                       signalQuality: 1.0, ecgQualityTier: 2)
        }
    }

    /// hr/rmssd/rcmse/pip/lfHF at baseline mean everywhere: every axis reads
    /// as untouched, so this always classifies `.stable_neutral` and weak.
    private func stableWindow(now: Date) -> [MetricsHistoryPoint] { window(now: now) }

    /// z ≈ [hr: 1.2, rmssd: -0.8, rcmse: 0.5, pip: 1.5, lfHF: 1.6] — the same
    /// vector `LiveStateClassifierTests` uses for `stressed_activated`
    /// (tense, not low-energy), reproduced here in raw units against
    /// `baselineRollups()`'s mean/SD instead of pre-built z's.
    private func stressedWindow(now: Date) -> [MetricsHistoryPoint] {
        window(hr: 60 + 1.2 * 8, rmssd: 40 + (-0.8) * 14, rcmse: 0.6 + 0.5 * 0.35,
              pip: 20 + 1.5 * 8, lfHF: 3 + 1.6 * 6, now: now)
    }

    // MARK: Not enough data yet

    func testNoOpWithoutEnoughRollups() {
        let store = LiveStateStore()
        store.recomputeState(rollups: [], window: [])
        XCTAssertNil(store.state)
        XCTAssertNil(store.baseline)
        XCTAssertNil(store.reading)
        XCTAssertNil(store.stateKey)
    }

    func testNoOpWithARollupsButNoCoveredWindow() {
        let store = LiveStateStore()
        let now = Date()
        // Three points at 30 s covers 90 s of the 10-minute window — the
        // same under-coverage shape `LiveReadingTests` uses.
        let sparse = window(count: 3, spacingSec: 30, now: now)
        store.recomputeState(rollups: baselineRollups(), window: sparse, now: now)
        XCTAssertNotNil(store.baseline, "the baseline itself doesn't need a window to build")
        XCTAssertNil(store.reading)
        XCTAssertNil(store.state)
    }

    /// The offline/cold-start fallback lives here, not just at the call
    /// site: a later recompute that fails must not blank out a state the
    /// widget is already showing.
    func testAFailedRecomputeLeavesThePreviousStateInPlace() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(), window: stableWindow(now: now), now: now)
        XCTAssertNotNil(store.state)
        let stateBefore    = store.state
        let baselineBefore = store.baseline
        let readingBefore  = store.reading

        store.recomputeState(rollups: [], window: [], now: now)

        XCTAssertEqual(store.state, stateBefore)
        XCTAssertEqual(store.baseline?.dayCount, baselineBefore?.dayCount)
        XCTAssertEqual(store.reading?.coverage, readingBefore?.coverage)
    }

    // MARK: Building a real state

    func testBuildsBaselineAndReadingFromValidInputs() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(days: 30), window: stableWindow(now: now), now: now)
        XCTAssertEqual(store.baseline?.dayCount, 30)
        XCTAssertNotNil(store.reading)
        XCTAssertEqual(store.reading?.readings[.hr]?.level ?? 99, 0, accuracy: 0.1)
    }

    func testAFlatWindowAtBaselineIsStableAndWeak() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(), window: stableWindow(now: now), now: now)
        XCTAssertEqual(store.stateKey, .stable_neutral)
        XCTAssertTrue(store.state?.isWeak ?? false)
    }

    /// First-ever settle adopts immediately (`LiveStateHysteresis` has no
    /// streak to hold against yet) — this is what lets the very first poll
    /// populate a real name instead of waiting three cycles.
    func testAStrongReadingIsAdoptedImmediatelyOnTheFirstCall() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(), window: stressedWindow(now: now), now: now)
        XCTAssertEqual(store.stateKey, .stressed_activated)
    }

    // MARK: Hysteresis, driven through the store

    func testASingleNoisyPollDoesNotFlipAnAlreadySettledState() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(), window: stableWindow(now: now), now: now)
        XCTAssertEqual(store.stateKey, .stable_neutral)

        store.recomputeState(rollups: baselineRollups(), window: stressedWindow(now: now), now: now)
        XCTAssertEqual(store.stateKey, .stable_neutral, "one differing poll must not flip the name")
    }

    func testTheNameFlipsOnceTheChallengerWinsEnoughInARow() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(), window: stableWindow(now: now), now: now)

        for _ in 0..<(LiveThresholds.hysteresisCount - 1) {
            store.recomputeState(rollups: baselineRollups(), window: stressedWindow(now: now), now: now)
            XCTAssertEqual(store.stateKey, .stable_neutral, "still short of the required streak")
        }
        store.recomputeState(rollups: baselineRollups(), window: stressedWindow(now: now), now: now)
        XCTAssertEqual(store.stateKey, .stressed_activated, "the streak just cleared the requirement")
    }
}

/// Pure text/geometry helpers the WHY row renders from. Both are decoupled
/// from `LiveStateResult`/`LiveReading` so they can be driven with bare
/// numbers instead of building a whole classification.
final class LiveWhyBandAndBarTests: XCTestCase {

    // MARK: LiveWhyBand

    func testWellAboveAtOrOverOne() {
        XCTAssertEqual(LiveWhyBand.text(for: 1.0), "well above your usual")
        XCTAssertEqual(LiveWhyBand.text(for: 2.4), "well above your usual")
    }

    func testAboveBelowOneButOverTheNoiseFloor() {
        XCTAssertEqual(LiveWhyBand.text(for: 0.5), "above your usual")
    }

    func testRightAroundUsualNearZero() {
        XCTAssertEqual(LiveWhyBand.text(for: 0.0), "right around your usual")
        XCTAssertEqual(LiveWhyBand.text(for: -0.34), "right around your usual")
    }

    func testBelowUsualNegativeButNotExtreme() {
        XCTAssertEqual(LiveWhyBand.text(for: -0.5), "below your usual")
    }

    func testWellBelowUnderNegativeOne() {
        // Asymmetric on purpose, matching the brief and `DayPotentialStore
        // .level(_:)`: "well above" is inclusive at +1.0 (`1.0...`), but
        // "well below" only starts strictly past -1.0 (`-1.0..<(-0.35)` still
        // reads "below", not "well below", at exactly -1.0).
        XCTAssertEqual(LiveWhyBand.text(for: -1.0), "below your usual")
        XCTAssertEqual(LiveWhyBand.text(for: -1.001), "well below your usual")
        XCTAssertEqual(LiveWhyBand.text(for: -3.0), "well below your usual")
    }

    /// Pins the boundary itself, in isolation. This does NOT catch a
    /// regression where the wrong quantity is handed to `LiveWhyBand` at the
    /// call site — `LiveWhyBand.text(for:)` has no way to know whether its
    /// caller passed `effective` or `c.value`, so that has to be caught where
    /// the call site's *choice* is itself a tested unit: see
    /// `LiveWhyRowTests.testBandUsesEffectiveNotTheWeightedContribution`
    /// below, which exercises `LiveWhyRow.build` — the one place that choice
    /// is made — with a fixture where the two quantities land in different
    /// bands.
    func testBoundaryIsExactlyAtOnePointZero() {
        XCTAssertEqual(LiveWhyBand.text(for: 0.999), "above your usual")
        XCTAssertEqual(LiveWhyBand.text(for: 1.001), "well above your usual")
    }

    // MARK: LiveWhyBar

    func testStrongestContributionFillsTheFullBar() {
        XCTAssertEqual(LiveWhyBar.width(value: 2.0, strongest: 2.0), LiveWhyBar.maxWidth, accuracy: 0.001)
    }

    func testAWeakerContributionScalesProportionally() {
        let width = LiveWhyBar.width(value: 1.0, strongest: 2.0)
        XCTAssertEqual(width, LiveWhyBar.maxWidth / 2, accuracy: 0.001)
    }

    func testZeroContributionFloorsAtTheMinimumWidth() {
        XCTAssertEqual(LiveWhyBar.width(value: 0, strongest: 2.0), LiveWhyBar.minWidth, accuracy: 0.001)
    }

    func testSignIsIgnoredForBarLength() {
        XCTAssertEqual(LiveWhyBar.width(value: -2.0, strongest: 2.0),
                       LiveWhyBar.width(value: 2.0, strongest: 2.0), accuracy: 0.001)
    }

    /// `strongest` is documented as always being the largest magnitude among
    /// the set `value` is drawn from (the classifier's contributions are
    /// pre-sorted, so the first one's magnitude always qualifies) — a
    /// contribution list of all-zero values is the one real case where
    /// `strongest` is degenerate, and `value` is necessarily degenerate
    /// (zero) right along with it. This must not divide by zero.
    func testADegenerateStrongestValueStillProducesAFiniteWidth() {
        let width = LiveWhyBar.width(value: 0, strongest: 0)
        XCTAssertTrue(width.isFinite)
        XCTAssertEqual(width, LiveWhyBar.minWidth, accuracy: 0.001)
    }
}

/// `LiveWhyRow.build` is the one place that decides which of a
/// `StateContribution`'s two related-but-different numbers feeds which
/// output. Testing `LiveWhyBand`/`LiveWhyBar` alone (above) cannot catch a
/// regression at that decision — both would still pass if the call site fed
/// them the wrong quantity, since neither function can see where its input
/// came from. This class exercises the decision itself.
final class LiveWhyRowTests: XCTestCase {

    private func reading(_ metric: LiveMetric, effective: Float) -> LiveReading {
        let r = MetricReading(metric: metric, level: effective, trend: 0,
                              meaningful: false, effective: effective)
        return LiveReading(readings: [metric: r], coverage: 1.0)
    }

    /// The exact scenario the task's own correction spelled out: a metric at
    /// effective 2.0 (well above usual) sitting on an axis weighted 0.3, so
    /// its ranked pull (`StateContribution.value`) is 0.3 × 2.0 = 0.6 — which
    /// is itself only "above your usual" by the same band table. If
    /// `LiveWhyRow.build` ever regressed to reading `contribution.value`
    /// where `effective` belongs (i.e. reverted to the brief's original,
    /// wrong wiring), this assertion would see "above" instead of "well
    /// above" and fail.
    func testBandUsesEffectiveNotTheWeightedContribution() {
        let contribution = StateContribution(metric: .dfa1, value: 0.3 * 2.0)
        let row = LiveWhyRow.build(for: contribution, reading: reading(.dfa1, effective: 2.0),
                                   strongest: 0.6)
        XCTAssertEqual(row.bandText, "well above your usual",
                       "must describe the metric's own effective reading, not its weighted pull")
        XCTAssertNotEqual(row.bandText, LiveWhyBand.text(for: contribution.value),
                          "banding the weighted pull directly is exactly the bug this guards against")
    }

    /// Sanity check on the same fixture from the other side: swapping the
    /// inputs manually (as a regression would) really does land in a
    /// different band, so the assertion above is not vacuously true.
    func testTheTwoQuantitiesReallyDoLandInDifferentBandsForThisFixture() {
        let contribution = StateContribution(metric: .dfa1, value: 0.3 * 2.0)
        XCTAssertEqual(LiveWhyBand.text(for: contribution.value), "above your usual")
        XCTAssertEqual(LiveWhyBand.text(for: Float(2.0)), "well above your usual")
    }

    /// Bar length and ranking still come from `contribution.value` — that
    /// part of the wiring is correct and must stay that way.
    func testBarWidthUsesTheWeightedContributionNotEffective() {
        let contribution = StateContribution(metric: .dfa1, value: 0.3 * 2.0)
        let row = LiveWhyRow.build(for: contribution, reading: reading(.dfa1, effective: 2.0),
                                   strongest: 0.6)
        XCTAssertEqual(row.barWidth, LiveWhyBar.maxWidth, accuracy: 0.001,
                       "value == strongest, so this must be the full bar")
    }

    func testDisplayNameIsPlainLanguage() {
        let contribution = StateContribution(metric: .dfa1, value: 1.0)
        let row = LiveWhyRow.build(for: contribution, reading: reading(.dfa1, effective: 1.0),
                                   strongest: 1.0)
        XCTAssertEqual(row.displayName, "FOCUS", "never a raw metric name like DFA1")
    }

    /// A metric absent from `reading.readings` (should not happen in
    /// practice — see `LiveStateClassifier.rankedPulls`, which only ever
    /// builds a contribution from a reading that's already present — but the
    /// two types don't enforce that at compile time) must not crash; it
    /// reads as "right around your usual" rather than trapping.
    func testAContributionWithNoMatchingReadingFallsBackSafely() {
        let contribution = StateContribution(metric: .hr, value: 0.5)
        let empty = LiveReading(readings: [:], coverage: 1.0)
        let row = LiveWhyRow.build(for: contribution, reading: empty, strongest: 0.5)
        XCTAssertEqual(row.bandText, "right around your usual")
    }
}
