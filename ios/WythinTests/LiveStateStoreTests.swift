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
    ///
    /// `stressBalance` is not a field on the window's points: it is derived
    /// per tick from RMSSD (`LiveMetric.stressBalance.value`), so its centre
    /// here is the dial's value at the baseline RMSSD of 40 — `1 − 40/(40+40)`
    /// = 0.5 → 50 — and the window moves it only by moving RMSSD.
    private func baselineRollups(days: Int = 30) -> [DailyRollup] {
        let means: [LiveMetric: Double] = [.hr: 60, .rmssd: 40, .rcmse: 0.6, .pip: 20,
                                           .stressBalance: 50]
        let sds:   [LiveMetric: Double] = [.hr: 8, .rmssd: 14, .rcmse: 0.35, .pip: 8,
                                           .stressBalance: 10]
        return (1...days).map { rollup(daysAgo: $0, means: means, sds: sds) }
    }

    /// A flat (zero-trend) window at the given per-metric values. Flat so
    /// `effective == level` exactly — trend is gated to zero by the SWC gate.
    private func window(hr: Double = 60, rmssd: Double = 40, rcmse: Double = 0.6,
                        pip: Double = 20,
                        count: Int = 300, spacingSec: Double = 2, now: Date) -> [MetricsHistoryPoint] {
        (0..<count).map { i in
            let age = Double(count - 1 - i) * spacingSec
            return MetricsHistoryPoint(timestamp: now.addingTimeInterval(-age),
                                       meanBPM: Float(hr), rmssd: Float(rmssd), sdnn: 50,
                                       breathBPM: 14, rcmse: Float(rcmse), pip: Float(pip),
                                       signalQuality: 1.0, ecgQualityTier: 2)
        }
    }

    /// hr/rmssd/rcmse/pip at baseline mean everywhere — and therefore stress
    /// balance at its baseline too, since it is derived from RMSSD. Every axis
    /// reads as untouched, so this always classifies `.stable_neutral` and weak.
    private func stableWindow(now: Date) -> [MetricsHistoryPoint] { window(now: now) }

    /// z ≈ [hr: 1.2, rmssd: -0.8, rcmse: 0.5, pip: 1.5] — the same vector
    /// `LiveStateClassifierTests` uses for `stressed_activated` (tense, not
    /// low-energy), reproduced here in raw units against `baselineRollups()`'s
    /// mean/SD instead of pre-built z's. RMSSD 28.8 puts the derived stress
    /// dial at 1 − 28.8/68.8 = 0.5814 → 58.1, i.e. z ≈ +0.81 against the
    /// 50 ± 10 baseline, so the Tension axis reads ≈ 0.55·1.5 + 0.45·0.81 =
    /// 1.19 — comfortably `tense`.
    private func stressedWindow(now: Date) -> [MetricsHistoryPoint] {
        window(hr: 60 + 1.2 * 8, rmssd: 40 + (-0.8) * 14, rcmse: 0.6 + 0.5 * 0.35,
              pip: 20 + 1.5 * 8, now: now)
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

    // MARK: Staleness — the spec's "hold the last state; mark it stale"

    func testNothingIsStaleBeforeThereIsAStateToHold() {
        let store = LiveStateStore()
        store.recomputeState(rollups: [], window: [])
        XCTAssertFalse(store.isStale, "there is nothing on screen to be stale")
    }

    func testAFreshReadingIsNotStale() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(), window: stableWindow(now: now), now: now)
        XCTAssertFalse(store.isStale)
    }

    /// The window stops covering (the strap dropped out, the app went quiet),
    /// so the widget keeps showing the last state it knew — which is right,
    /// but it must not keep presenting it as current.
    func testAHeldStateIsMarkedStale() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(), window: stableWindow(now: now), now: now)
        let held = store.stateKey

        store.recomputeState(rollups: baselineRollups(),
                             window: window(count: 3, spacingSec: 30, now: now), now: now)
        XCTAssertEqual(store.stateKey, held, "the state is held, not blanked")
        XCTAssertTrue(store.isStale, "…but it is no longer current, and must say so")
    }

    /// BLE disconnect stops the poll loop entirely, so no recompute will ever
    /// run to notice — the view has to say so directly.
    func testDisconnectingMarksTheHeldStateStale() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(), window: stableWindow(now: now), now: now)
        store.markStale()
        XCTAssertTrue(store.isStale)
    }

    func testStalenessClearsOnceAFreshReadingArrives() {
        let store = LiveStateStore()
        let now = Date()
        store.recomputeState(rollups: baselineRollups(), window: stableWindow(now: now), now: now)
        store.markStale()
        XCTAssertTrue(store.isStale)

        store.recomputeState(rollups: baselineRollups(), window: stableWindow(now: now), now: now)
        XCTAssertFalse(store.isStale)
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
    /// caller passed `level` or `c.value`, so that has to be caught where
    /// the call site's *choice* is itself a tested unit: see
    /// `LiveWhyRowTests.testBandUsesLevelNotTheWeightedContribution`
    /// below, which exercises `LiveWhyRow.build` — the one place that choice
    /// is made — with a fixture where the two quantities land in different
    /// bands.
    func testBoundaryIsExactlyAtOnePointZero() {
        XCTAssertEqual(LiveWhyBand.text(for: 0.999), "above your usual")
        XCTAssertEqual(LiveWhyBand.text(for: 1.001), "well above your usual")
    }

    // MARK: LiveWhyBar

    func testAFullSDOfPullFillsTheBar() {
        XCTAssertEqual(LiveWhyBar.width(value: LiveWhyBar.fullScale),
                       LiveWhyBar.maxWidth, accuracy: 0.001)
    }

    func testHalfAsMuchPullIsHalfTheDrawableLength() {
        let midpoint = LiveWhyBar.minWidth + (LiveWhyBar.maxWidth - LiveWhyBar.minWidth) / 2
        XCTAssertEqual(LiveWhyBar.width(value: LiveWhyBar.fullScale / 2), midpoint, accuracy: 0.001)
    }

    func testZeroContributionFloorsAtTheMinimumWidth() {
        XCTAssertEqual(LiveWhyBar.width(value: 0), LiveWhyBar.minWidth, accuracy: 0.001)
    }

    func testSignIsIgnoredForBarLength() {
        XCTAssertEqual(LiveWhyBar.width(value: -0.7), LiveWhyBar.width(value: 0.7), accuracy: 0.001)
    }

    func testAnExtremePullIsClampedRatherThanOverflowing() {
        XCTAssertEqual(LiveWhyBar.width(value: 20), LiveWhyBar.maxWidth, accuracy: 0.001)
    }

    /// The spec's weak-call design: "the impact bars are all short. This is
    /// honest and visible." Normalising by the top contribution's own
    /// magnitude made the leading bar full-width ALWAYS — including on a
    /// maximally flat window, where the single fallback contribution rendered
    /// as one confident full-width bar. The bar has to encode absolute
    /// magnitude, not only rank.
    func testAFlatWindowsOnlyContributionDrawsAShortBar() {
        let flat = LiveWhyBar.width(value: 0.02)
        XCTAssertLessThan(flat, LiveWhyBar.minWidth + 3, "nothing moved — the bar must say so")
        XCTAssertNotEqual(flat, LiveWhyBar.maxWidth, accuracy: 0.001)
    }

    /// Two readings where one metric leads by the same ratio but at completely
    /// different absolute strengths must NOT draw the same pair of bars.
    func testRankIsNotEnoughTheAbsoluteSizeShows() {
        XCTAssertGreaterThan(LiveWhyBar.width(value: 1.0), LiveWhyBar.width(value: 0.1) + 20,
                             "a strong pull and a faint one cannot render alike")
    }

    /// Pins the relationship the view relies on to keep every row's name — and
    /// the explanation line beneath it — starting at the same x: the text
    /// indent is the bar's fixed column width plus the HStack's own spacing
    /// between the bar and the name. If the view ever went back to sizing the
    /// bar's own HStack to `row.barWidth` directly (the ragged-left-edge bug),
    /// this constant alone wouldn't catch it — but a drift between this value
    /// and whatever the view hardcodes for the explanation's leading padding
    /// would no longer be silent, because both now read from here.
    func testTextIndentIsTheBarColumnPlusItsOwnSpacing() {
        XCTAssertEqual(LiveWhyBar.textIndent, LiveWhyBar.maxWidth + LiveWhyBar.rowSpacing, accuracy: 0.001)
        XCTAssertEqual(LiveWhyBar.textIndent, 53, accuracy: 0.001,
                       "pins the actual on-screen indent, not just the formula")
    }
}

/// `LiveWhyBarTone` — which colour family a WHY bar should read as. Before
/// this, a strong bar always drew `Theme.accent` regardless of sign, so a
/// metric dragging the state DOWN rendered in the app's positive-state green.
final class LiveWhyBarToneTests: XCTestCase {

    func testAStrongPositivePullIsPositive() {
        XCTAssertEqual(LiveWhyBarTone.of(value: 0.8, isStrong: true), .positive)
    }

    /// The exact bug: a strong NEGATIVE pull must never come back `.positive`
    /// (which the view maps to the app's positive-state green).
    func testAStrongNegativePullIsNegativeNotPositive() {
        XCTAssertEqual(LiveWhyBarTone.of(value: -0.8, isStrong: true), .negative)
        XCTAssertNotEqual(LiveWhyBarTone.of(value: -0.8, isStrong: true), .positive)
    }

    func testAWeakPullIsWeakRegardlessOfSign() {
        XCTAssertEqual(LiveWhyBarTone.of(value: 0.8, isStrong: false), .weak)
        XCTAssertEqual(LiveWhyBarTone.of(value: -0.8, isStrong: false), .weak)
    }

    /// Exactly zero counts as positive (the `>= 0` boundary) — an arbitrary
    /// but harmless choice since a strong pull of exactly zero can't happen in
    /// practice (`isStrong` requires `abs(value) > 0.6`); pinned so the
    /// boundary can't silently flip.
    func testZeroIsPositiveByConvention() {
        XCTAssertEqual(LiveWhyBarTone.of(value: 0, isStrong: true), .positive)
    }
}

/// `LiveWhyBand.text(level:windowValue:baselineCentre:)` — the percentage
/// half of the WHY row: "38% below your usual" rather than only "well below
/// your usual". Each case below is chosen so a regression to the OLD
/// (band-only) behaviour, or to a naive percent-always formula, would flip
/// the assertion rather than merely producing a differently-worded string
/// that still happens to pass.
final class LiveWhyBandPercentTests: XCTestCase {

    /// The mockup's own example, reproduced: a window sitting 38% under its
    /// baseline centre, comfortably outside the neutral band. If this ever
    /// regressed to the qualitative-only `text(for:)`, the assertion would
    /// see "well below your usual" instead and fail — it is not merely
    /// checking that a string is non-empty.
    func testFellThirtyEightPercentBelowUsual() {
        let text = LiveWhyBand.text(level: -1.6, windowValue: 62, baselineCentre: 100)
        XCTAssertEqual(text, "38% below your usual")
    }

    func testTwelvePercentAboveUsual() {
        let text = LiveWhyBand.text(level: 1.2, windowValue: 112, baselineCentre: 100)
        XCTAssertEqual(text, "12% above your usual")
    }

    /// No dash, no qualitative phrase alongside the number — the user's
    /// chosen shape is the number ALONE followed by the plain meaning.
    func testNoDashConstructionInThePercentSentence() {
        let text = LiveWhyBand.text(level: -1.6, windowValue: 62, baselineCentre: 100)
        XCTAssertFalse(text.contains("—"), "no dash clause — value then plain meaning only")
        XCTAssertFalse(text.contains("well"), "the qualitative band phrase must not also appear")
    }

    /// The neutral band never prints a number, even when the raw values would
    /// yield a clean, computable percentage — a small `level` means the
    /// reading isn't sure enough of a direction to put a figure on it. This
    /// is the RECOVERY row from the approved mockup: "right around your
    /// usual", not "4% above your usual".
    func testNeutralBandSuppressesTheNumberEvenWhenOneIsComputable() {
        let text = LiveWhyBand.text(level: 0.1, windowValue: 104, baselineCentre: 100)
        XCTAssertEqual(text, "right around your usual")
    }

    /// Pins the exact neutral boundary this function shares with `text(for:)`
    /// — asserted by calling both, so a change to one that isn't mirrored in
    /// the other (the exact defect this indirection is meant to prevent)
    /// shows up here as a mismatch rather than passing silently.
    func testNeutralBoundaryMatchesTheQualitativeBandExactly() {
        for level: Float in [-0.35, -0.1, 0, 0.1, 0.34] {
            XCTAssertEqual(LiveWhyBand.text(level: level, windowValue: 999, baselineCentre: 100),
                           LiveWhyBand.text(for: level),
                           "level \(level) must be neutral in both, or in neither")
        }
    }

    /// A baseline centre of exactly zero cannot be divided by — this must
    /// fall back to the qualitative band, not crash or print `inf`/`nan`.
    func testDegenerateCentreOfExactlyZeroFallsBackToTheBand() {
        let text = LiveWhyBand.text(level: -1.6, windowValue: -5, baselineCentre: 0)
        XCTAssertEqual(text, "well below your usual")
        XCTAssertFalse(text.contains("%"), "no number can come out of a zero centre")
    }

    /// Not just literal zero — a centre close enough to zero still swings
    /// wildly for a tiny absolute change, so it must fall back too.
    func testNearZeroCentreAlsoFallsBackToTheBand() {
        let text = LiveWhyBand.text(level: -1.6, windowValue: -5, baselineCentre: 0.0001)
        XCTAssertFalse(text.contains("%"), "a near-zero centre must not produce a wild percentage")
        XCTAssertEqual(text, LiveWhyBand.text(for: -1.6))
    }

    /// A percentage that itself rounds to 0% would read as a contradiction
    /// next to a non-neutral effective ("0% below your usual") — this must
    /// fall back to the qualitative phrase instead of printing a hollow number.
    func testAPercentageThatRoundsToZeroFallsBackToTheBand() {
        // (999.6 - 1000) / 1000 * 100 == -0.04%, which rounds to 0.
        let text = LiveWhyBand.text(level: -0.5, windowValue: 999.6, baselineCentre: 1000)
        XCTAssertEqual(text, "below your usual")
        XCTAssertFalse(text.contains("%"))
    }

    /// Rounds to the nearest whole percent rather than truncating — 37.6%
    /// must read as 38%, not 37%.
    func testPercentageRoundsRatherThanTruncates() {
        let text = LiveWhyBand.text(level: -1.6, windowValue: 62.4, baselineCentre: 100)
        XCTAssertEqual(text, "38% below your usual")
    }
}

/// The honesty suffixes on the card's own label. Pure, so the three flags can
/// be driven directly instead of through a rendered view.
final class LiveStateHeadlineTests: XCTestCase {

    func testAConfidentCurrentReadingHasNoSuffix() {
        XCTAssertEqual(LiveStateHeadline.text(isWeak: false, provisional: false, isStale: false),
                       "CURRENT STATE")
    }

    func testAWeakCallSaysSo() {
        XCTAssertEqual(LiveStateHeadline.text(isWeak: true, provisional: false, isStale: false),
                       "CURRENT STATE · WEAK SIGNAL")
    }

    /// Mirrors `DayPotentialStore.State.headline`'s existing "· EARLY DAYS",
    /// so the same words mean the same thing on both cards.
    func testAProvisionalBaselineSaysTheRangeIsStillForming() {
        XCTAssertEqual(LiveStateHeadline.text(isWeak: false, provisional: true, isStale: false),
                       "CURRENT STATE · EARLY DAYS")
    }

    func testAHeldStateSaysItIsNotUpdating() {
        XCTAssertEqual(LiveStateHeadline.text(isWeak: false, provisional: false, isStale: true),
                       "CURRENT STATE · NOT UPDATING")
    }

    /// Staleness leads: a held reading may have been a strong call when it was
    /// taken, and how old it is matters more than how firm it was.
    func testAllThreeStackWithStalenessFirst() {
        XCTAssertEqual(LiveStateHeadline.text(isWeak: true, provisional: true, isStale: true),
                       "CURRENT STATE · NOT UPDATING · WEAK SIGNAL · EARLY DAYS")
    }
}

/// `LiveEmptyStateCopy` — the card's fully-empty state (no local reading, no
/// narration yet). The old fixed "Gathering data… pull down to refresh" was
/// false whenever the strap was off: pulling down could not produce a fresh
/// window regardless of how it was triggered. Each case below is chosen so a
/// regression back to a single fixed string, or to a string that doesn't
/// distinguish "no baseline yet" from "no reading right now", would flip the
/// assertion.
final class LiveEmptyStateCopyTests: XCTestCase {

    func testNoBaselineYetNamesTheBaselineRegardlessOfConnection() {
        XCTAssertEqual(LiveEmptyStateCopy.text(hasBaseline: false, isConnected: true),
                       "Building your baseline — check back in a few days.")
        XCTAssertEqual(LiveEmptyStateCopy.text(hasBaseline: false, isConnected: false),
                       "Building your baseline — check back in a few days.",
                       "no baseline is the same story whether or not the strap is on")
    }

    func testBaselineExistsAndConnectedIsWaitingOnTheFirstWindow() {
        let text = LiveEmptyStateCopy.text(hasBaseline: true, isConnected: true)
        XCTAssertEqual(text, "Reading your first window…")
        XCTAssertFalse(text.contains("pull down"),
                       "must not tell the user to do something that isn't the actual blocker")
    }

    /// The scenario the fix exists for: baseline is fine, but there's no
    /// current reading because the strap is off — pulling down cannot help,
    /// so the text must say the true blocker (connect the strap) instead.
    func testBaselineExistsButDisconnectedNamesTheStrapAsTheBlocker() {
        let text = LiveEmptyStateCopy.text(hasBaseline: true, isConnected: false)
        XCTAssertEqual(text, "No recent reading — connect your strap to see your current state.")
        XCTAssertFalse(text.contains("pull down"),
                       "pulling down does nothing when the strap itself is off")
    }
}

/// `LiveWhyRow.build` is the one place that decides which of a
/// `StateContribution`'s two related-but-different numbers feeds which
/// output. Testing `LiveWhyBand`/`LiveWhyBar` alone (above) cannot catch a
/// regression at that decision — both would still pass if the call site fed
/// them the wrong quantity, since neither function can see where its input
/// came from. This class exercises the decision itself.
final class LiveWhyRowTests: XCTestCase {

    /// `windowValue`/`baselineCentre` both 0 here deliberately: a degenerate
    /// centre falls back to the qualitative band (see `LiveWhyBand`'s doc),
    /// which is what every test in this class below is asserting against —
    /// they are about *which quantity* (`level` vs `contribution.value`)
    /// feeds the band, not about the percentage formatter. That formatter
    /// gets its own fixtures in `LiveWhyBandPercentTests`. `level` and
    /// `effective` are set to the same value here — this fixture is about
    /// discriminating `level` from `contribution.value`, not from
    /// `effective`; see `testBandFollowsLevelEvenWhenEffectiveDisagreesInSign`
    /// below for the case where `level` and `effective` themselves diverge.
    private func reading(_ metric: LiveMetric, effective: Float) -> LiveReading {
        let r = MetricReading(metric: metric, level: effective, trend: 0,
                              meaningful: false, effective: effective,
                              windowValue: 0, baselineCentre: 0)
        return LiveReading(readings: [metric: r], coverage: 1.0)
    }

    /// The exact scenario the task's own correction spelled out: a metric at
    /// level 2.0 (well above usual) sitting on an axis weighted 0.3, so its
    /// ranked pull (`StateContribution.value`) is 0.3 × 2.0 = 0.6 — which is
    /// itself only "above your usual" by the same band table. If
    /// `LiveWhyRow.build` ever regressed to reading `contribution.value`
    /// where `level` belongs, this assertion would see "above" instead of
    /// "well above" and fail.
    func testBandUsesLevelNotTheWeightedContribution() {
        let contribution = StateContribution(metric: .dfa1, value: 0.3 * 2.0)
        let row = LiveWhyRow.build(for: contribution, reading: reading(.dfa1, effective: 2.0))
        XCTAssertEqual(row.bandText, "well above your usual",
                       "must describe the metric's own current level, not its weighted pull")
        XCTAssertNotEqual(row.bandText, LiveWhyBand.text(for: contribution.value),
                          "banding the weighted pull directly is exactly the bug this guards against")
    }

    /// The audit's own worked example: inner noise sitting at level +0.05
    /// (right around usual) with a falling trend of −1.5 SD/window. With
    /// gain(0.05) ≈ 0.975, `effective` = 0.05 + 0.5·0.975·(−1.5) ≈ −0.68 —
    /// "below your usual" — even though the metric's own current position is
    /// neutral. Ranking (`contribution.value`, here negative — a downward
    /// driver) is correctly derived from `effective`, but the row's TEXT must
    /// describe `level`, or the row prints a direction ("above"/"below") that
    /// contradicts the very quantity that put it in the WHY list. Before the
    /// fix, `LiveWhyRow.build` fed `effective` to the band function, which
    /// skipped the neutral short-circuit (since -0.68 isn't neutral) and
    /// printed "2% above your usual" from the raw window/baseline values —
    /// directionally backwards from a row ranked as a downward pull.
    func testBandFollowsLevelEvenWhenEffectiveDisagreesInSign() {
        let r = MetricReading(metric: .pip, level: 0.05, trend: -1.5, meaningful: true,
                              effective: -0.68, windowValue: 20.4, baselineCentre: 20)
        let reading = LiveReading(readings: [.pip: r], coverage: 1.0)
        let contribution = StateContribution(metric: .pip, value: -0.4)   // ranked as a downward driver
        let row = LiveWhyRow.build(for: contribution, reading: reading)
        XCTAssertEqual(row.bandText, "right around your usual",
                       "the text must describe where the metric actually sits (level), not the trend-adjusted effective")
        XCTAssertFalse(row.bandText.contains("above"),
                       "a row ranked as a downward driver must never print as moving upward")
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
    /// part of the wiring is correct and must stay that way. The same fixture
    /// now discriminates on width too: the pull (0.6) and the metric's own
    /// effective reading (2.0) draw visibly different bars.
    func testBarWidthUsesTheWeightedContributionNotEffective() {
        let contribution = StateContribution(metric: .dfa1, value: 0.3 * 2.0)
        let row = LiveWhyRow.build(for: contribution, reading: reading(.dfa1, effective: 2.0))
        XCTAssertEqual(row.barWidth, LiveWhyBar.width(value: 0.6), accuracy: 0.001)
        XCTAssertNotEqual(row.barWidth, LiveWhyBar.width(value: 2.0), accuracy: 0.001,
                          "banding is the metric's own reading; the bar is its pull on the state")
    }

    func testDisplayNameIsPlainLanguage() {
        let contribution = StateContribution(metric: .dfa1, value: 1.0)
        let row = LiveWhyRow.build(for: contribution, reading: reading(.dfa1, effective: 1.0))
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
        let row = LiveWhyRow.build(for: contribution, reading: empty)
        XCTAssertEqual(row.bandText, "right around your usual")
    }

    /// End-to-end wiring check with a REAL (non-degenerate) `windowValue`/
    /// `baselineCentre` pair — every other test in this class uses the 0/0
    /// fixture, which only ever exercises `LiveWhyBand`'s fallback path. This
    /// is the one place that confirms `LiveWhyRow.build` actually forwards
    /// `MetricReading`'s native-unit fields to the percentage formatter
    /// rather than silently keeping the old fallback behaviour it happens to
    /// share a return type with.
    func testBuildProducesARealPercentageWhenTheReadingHasOne() {
        let r = MetricReading(metric: .pip, level: -1.6, trend: 0, meaningful: false,
                              effective: -1.6, windowValue: 62, baselineCentre: 100)
        let reading = LiveReading(readings: [.pip: r], coverage: 1.0)
        let contribution = StateContribution(metric: .pip, value: -0.4)
        let row = LiveWhyRow.build(for: contribution, reading: reading)
        XCTAssertEqual(row.bandText, "38% below your usual")
    }
}

/// The card's own persisted drop-down key. A rename here — the key literal
/// itself, not just the `expanded` property — would silently reset every
/// user's WHY-expanded/collapsed preference on their next launch, with
/// nothing in the other 780+ tests able to notice: `@AppStorage` reads
/// through whatever string it's given, so a renamed key is functionally
/// identical to the old one from every test's point of view except this one.
final class LiveStateWidgetKeyTests: XCTestCase {
    func testExpansionStorageKeyIsPinned() {
        XCTAssertEqual(LiveStateWidget.expansionStorageKey, "currentStateExpanded")
    }
}

/// `LiveCollapsedRowSpec.build` is the pure decision behind the collapsed
/// row, unifying what were two separate code paths (a settled local state,
/// and the narration-only fallback before enough data exists). Its
/// `isExpandable` field is what `LiveCollapsedRowSpec.revealsDropDown` ANDs
/// with `expanded` before `LiveStateWidget.currentStateSection` ever calls
/// `whyList` — these tests pin the half of that invariant reachable without
/// a view host: that `isExpandable` is true only when there is a local
/// `reading` to build a WHY list from, and false in every other case.
/// `LiveCollapsedRowSpecRevealsDropDownTests` below pins the other half — the
/// AND itself — which used to be inexpressible without a SwiftUI
/// view-hosting harness this project doesn't have (no ViewInspector or
/// similar); extracting it into `revealsDropDown` closes that gap. See the
/// audit report (`ui-fix-report.md`, finding 8) for the history.
final class LiveCollapsedRowSpecTests: XCTestCase {

    private func state(key: LiveStateKey = .calm_alert, isWeak: Bool = false) -> LiveStateResult {
        LiveStateResult(key: key, axes: LiveAxes(energy: 0, tension: 0, recovery: 0),
                        contributions: [], isWeak: isWeak)
    }

    private let readingFixture = LiveReading(readings: [:], coverage: 1.0)

    func testNilStateNilTextReturnsNil() {
        let spec = LiveCollapsedRowSpec.build(state: nil, reading: nil, text: nil,
                                              provisional: false, isStale: false)
        XCTAssertNil(spec, "nothing to show yet — the view falls back to LiveEmptyStateCopy")
    }

    /// A state without a matching reading (shouldn't happen via
    /// `LiveStateStore.recomputeState`, which always sets both together —
    /// but the two are independent optionals at the type level, so the
    /// decision must handle it correctly rather than by accident) falls
    /// through to the narration-only fallback, exactly like a nil state
    /// would — and that fallback is never expandable.
    func testAStateWithoutAMatchingReadingIsNotExpandable() {
        let text = "calm_alert | Settled"
        let spec = LiveCollapsedRowSpec.build(state: state(), reading: nil, text: text,
                                              provisional: false, isStale: false)
        XCTAssertEqual(spec?.isExpandable, false)
        XCTAssertEqual(spec?.title, "Settled",
                       "falls through to the narration fallback's own title, not the local state's")
    }

    func testAStateWithAMatchingReadingIsExpandable() {
        let spec = LiveCollapsedRowSpec.build(state: state(), reading: readingFixture, text: nil,
                                              provisional: false, isStale: false)
        XCTAssertEqual(spec?.isExpandable, true)
    }

    /// The dead-chevron scenario itself: narration has arrived but there is
    /// still no local reading (very first session). This must never be
    /// expandable — there is nothing a drop-down could reveal.
    func testNarrationOnlyFallbackIsNeverExpandable() {
        let spec = LiveCollapsedRowSpec.build(state: nil, reading: nil, text: "calm_alert | Settled",
                                              provisional: false, isStale: false)
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.isExpandable, false)
    }

    func testLocalStateRowUsesLiveStateCopyAndHeadline() {
        let spec = LiveCollapsedRowSpec.build(state: state(key: .calm_alert), reading: readingFixture,
                                              text: nil, provisional: false, isStale: false)
        XCTAssertEqual(spec?.title,   LiveStateCopy.title(for: .calm_alert))
        XCTAssertEqual(spec?.feeling, LiveStateCopy.feeling(for: .calm_alert))
        XCTAssertEqual(spec?.label,
                       LiveStateHeadline.text(isWeak: false, provisional: false, isStale: false))
    }

    func testNarrationOnlyFallbackHasNoFeelingLine() {
        let spec = LiveCollapsedRowSpec.build(state: nil, reading: nil, text: "calm_alert | Settled",
                                              provisional: false, isStale: false)
        XCTAssertNil(spec?.feeling, "no local reading means no feeling phrase to build from")
    }
}

/// `LiveCollapsedRowSpec.revealsDropDown` — the two-condition gate that used
/// to be an inline `spec.isExpandable, expanded` expression written directly
/// in `LiveStateWidget.currentStateSection`'s body. That inline form is
/// exactly what the previous audit (`ui-fix-report.md`, finding 8) flagged as
/// untestable without a SwiftUI view-hosting harness: it could pin
/// `isExpandable`'s own truth table (above), but nothing could pin that the
/// view kept ANDing it with `expanded` rather than silently weakening the
/// gate to just one condition or the other — a class of regression this
/// feature has now shipped twice (once as the "dead chevron", see
/// `testAStateWithoutAMatchingReadingIsNotExpandable`'s doc; once as this
/// exact gate). Naming the decision as its own function makes it directly
/// callable from a test, closing the gap.
final class LiveCollapsedRowSpecRevealsDropDownTests: XCTestCase {

    func testHiddenWhenNotExpandableEvenIfOpen() {
        XCTAssertFalse(LiveCollapsedRowSpec.revealsDropDown(isExpandable: false, expanded: true),
                       "a row with nothing to reveal must never reveal anything")
    }

    func testHiddenWhenExpandableButCollapsed() {
        XCTAssertFalse(LiveCollapsedRowSpec.revealsDropDown(isExpandable: true, expanded: false),
                       "the user hasn't asked to see it yet")
    }

    func testRevealedOnlyWhenBothHold() {
        XCTAssertTrue(LiveCollapsedRowSpec.revealsDropDown(isExpandable: true, expanded: true))
    }

    /// Sweeps all four combinations against the literal `&&` truth table —
    /// chosen specifically so a regression that swaps the operator for `||`
    /// (which would agree with the three tests above on three of the four
    /// rows) still fails here on the one row where the two operators
    /// disagree: `isExpandable: false, expanded: true`.
    func testAllFourCombinationsMatchLogicalAnd() {
        for isExpandable in [true, false] {
            for expanded in [true, false] {
                XCTAssertEqual(LiveCollapsedRowSpec.revealsDropDown(isExpandable: isExpandable, expanded: expanded),
                               isExpandable && expanded,
                               "isExpandable=\(isExpandable) expanded=\(expanded)")
            }
        }
    }
}

/// `FeltStateDraft` — the in-progress check-in. `nil` IS the touched flag the
/// design calls for; these tests exist because a regression here (e.g.
/// initialising a scale to 50 "so the knob starts somewhere") would be
/// invisible in the UI on first glance but would poison every saved row.
final class FeltStateDraftTests: XCTestCase {

    func testAFreshDraftHasNoAnswersAtAll() {
        let draft = FeltStateDraft.empty
        XCTAssertNil(draft.focus)
        XCTAssertNil(draft.energy)
        XCTAssertNil(draft.stress)
        XCTAssertNil(draft.mood)
        XCTAssertFalse(draft.hasAnyAnswer)
    }

    /// The exact regression this guards against: a scale that was never
    /// dragged must persist as `nil`, not as 50 (or any other in-range
    /// value) — see `FeltStateLog`'s own doc for why a default here is worse
    /// than no data.
    func testAnUntouchedScalePersistsAsNilNeverAsTheMidpoint() {
        var draft = FeltStateDraft.empty
        draft.focus = 80   // touch one scale only
        let log = draft.makeLog(stateKey: .calm_alert)
        XCTAssertEqual(log.focus, 80)
        XCTAssertNil(log.energy, "never touched — must not become 50")
        XCTAssertNil(log.stress, "never touched — must not become 50")
        XCTAssertNil(log.mood,   "never touched — must not become 50")
    }

    /// A partially-filled check-in saves the answered scales and leaves the
    /// rest nil — "Skip any you like" only means something if this is true.
    func testAPartiallyFilledCheckInSavesAnsweredScalesAndLeavesRestNil() {
        var draft = FeltStateDraft.empty
        draft.energy = 65
        draft.mood   = 40
        let log = draft.makeLog(stateKey: .stressed_activated)
        XCTAssertEqual(log.energy, 65)
        XCTAssertEqual(log.mood,   40)
        XCTAssertNil(log.focus)
        XCTAssertNil(log.stress)
        XCTAssertTrue(draft.hasAnyAnswer)
    }

    /// The field that turns a row into a labelled example rather than a mood
    /// diary entry (accuracy design §6) — captured on the row regardless of
    /// which scales were answered.
    func testTheDisplayedStateKeyIsCapturedOnTheSavedRow() {
        let draft = FeltStateDraft.empty
        let log = draft.makeLog(stateKey: .renewed_thriving)
        XCTAssertEqual(log.stateKey, "renewed_thriving")
    }

    /// A check-in can be saved before the classifier has ever produced a
    /// reading (the first few days) — the row is still kept, just without a
    /// key to calibrate against later.
    func testANilStateKeyIsStoredAsNilNotAPlaceholderString() {
        let draft = FeltStateDraft.empty
        let log = draft.makeLog(stateKey: nil)
        XCTAssertNil(log.stateKey)
    }

    func testSubscriptReadsAndWritesTheMatchingScale() {
        var draft = FeltStateDraft.empty
        draft[.stress] = 72
        XCTAssertEqual(draft[.stress], 72)
        XCTAssertEqual(draft.stress, 72)
        XCTAssertNil(draft[.focus], "writing one scale must not touch the others")
    }
}

/// `FeltStateKnobSpec` — "untouched is not the middle." A scale that was
/// never dragged must render with a centred grey knob and NO fill; these
/// tests would fail if a regression rendered `nil` as though it were the
/// value 50 (which would also happen to centre the knob, but WOULD draw a
/// half-filled track — the fill assertion is what actually distinguishes the
/// two cases).
final class FeltStateKnobSpecTests: XCTestCase {

    func testUntouchedRendersCenteredWithNoFillAndIsNotTouched() {
        let spec = FeltStateKnobSpec.build(value: nil)
        XCTAssertEqual(spec.knobFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(spec.fillFraction, 0, accuracy: 0.001,
                       "no fill — a filled half-track would look identical to a real answer of 50")
        XCTAssertFalse(spec.isTouched)
    }

    func testAnActualMidpointAnswerIsDistinctFromUntouched() {
        let spec = FeltStateKnobSpec.build(value: 50)
        XCTAssertEqual(spec.knobFraction, 0.5, accuracy: 0.001,
                       "coincidentally the same position as untouched...")
        XCTAssertEqual(spec.fillFraction, 0.5, accuracy: 0.001,
                       "...but WITH a fill, and touched — the two must not be confusable in the model")
        XCTAssertTrue(spec.isTouched)
    }

    func testExtremeValuesMapToTheirEnds() {
        XCTAssertEqual(FeltStateKnobSpec.build(value: 0).knobFraction, 0, accuracy: 0.001)
        XCTAssertEqual(FeltStateKnobSpec.build(value: 100).knobFraction, 1, accuracy: 0.001)
    }

    func testOutOfRangeValuesClampRatherThanOverflow() {
        XCTAssertEqual(FeltStateKnobSpec.build(value: -20).knobFraction, 0, accuracy: 0.001)
        XCTAssertEqual(FeltStateKnobSpec.build(value: 140).knobFraction, 1, accuracy: 0.001)
    }
}

/// `FeltStateDragMapping` — the drag gesture's raw position to a stored
/// 0–100 value. Pure so the clamping at both track edges is tested without a
/// SwiftUI view host.
final class FeltStateDragMappingTests: XCTestCase {

    func testMidTrackMapsToFifty() {
        XCTAssertEqual(FeltStateDragMapping.value(x: 50, trackWidth: 100), 50, accuracy: 0.001)
    }

    func testLeftEdgeMapsToZero() {
        XCTAssertEqual(FeltStateDragMapping.value(x: 0, trackWidth: 100), 0, accuracy: 0.001)
    }

    func testRightEdgeMapsToOneHundred() {
        XCTAssertEqual(FeltStateDragMapping.value(x: 100, trackWidth: 100), 100, accuracy: 0.001)
    }

    func testADragPastTheLeftEdgeClampsToZeroRatherThanGoingNegative() {
        XCTAssertEqual(FeltStateDragMapping.value(x: -40, trackWidth: 100), 0, accuracy: 0.001)
    }

    func testADragPastTheRightEdgeClampsToOneHundredRatherThanOverflowing() {
        XCTAssertEqual(FeltStateDragMapping.value(x: 260, trackWidth: 100), 100, accuracy: 0.001)
    }

    func testAZeroWidthTrackReturnsZeroRatherThanDividingByZero() {
        XCTAssertEqual(FeltStateDragMapping.value(x: 50, trackWidth: 0), 0, accuracy: 0.001)
    }
}

/// The two check-in scales' fixed order and copy. `FeltStateScaleKey`'s
/// `CaseIterable` order is what the form renders in, so this pins it against
/// an accidental reorder in a future edit.
final class FeltStateScaleKeyTests: XCTestCase {
    func testScalesRenderInTheSpecifiedOrder() {
        XCTAssertEqual(FeltStateScaleKey.allCases, [.focus, .energy, .stress, .mood])
    }

    func testEveryScaleHasBothAnchorWordsAndNeitherIsEmpty() {
        for key in FeltStateScaleKey.allCases {
            XCTAssertFalse(key.leftAnchor.isEmpty, "\(key)")
            XCTAssertFalse(key.rightAnchor.isEmpty, "\(key)")
            XCTAssertNotEqual(key.leftAnchor, key.rightAnchor, "\(key)")
        }
    }

    /// No numbers displayed anywhere is the design's explicit rule — the
    /// anchor words themselves must never smuggle a digit in.
    func testAnchorWordsContainNoDigits() {
        let digits = CharacterSet.decimalDigits
        for key in FeltStateScaleKey.allCases {
            XCTAssertNil(key.leftAnchor.rangeOfCharacter(from: digits), "\(key)")
            XCTAssertNil(key.rightAnchor.rangeOfCharacter(from: digits), "\(key)")
        }
    }
}

/// The check-in's own persisted drop-down key, and its independence from the
/// state drop-down's key — the two sections are specified as independent
/// (accuracy design §5), and `@AppStorage` enforces that only if the two
/// literal strings actually differ. A regression that reused
/// `expansionStorageKey` for both would compile fine and pass every other
/// test in this file, since nothing else reads either literal directly.
final class FeltStateCheckInStorageKeyTests: XCTestCase {
    func testCheckInStorageKeyIsPinned() {
        XCTAssertEqual(LiveStateWidget.checkInStorageKey, "checkInExpanded")
    }

    func testTheTwoDropDownsUseDistinctStorageKeys() {
        XCTAssertNotEqual(LiveStateWidget.checkInStorageKey, LiveStateWidget.expansionStorageKey,
                          "one drop-down toggling must never be able to toggle the other")
    }
}

/// `FeltStateCheckInCopy` — the check-in's own fixed strings. `helper` in
/// particular: the user asked for "no dash constructions in this card", and
/// for a line short enough to never wrap, so these pin both properties
/// directly rather than trusting a future edit to preserve them by habit.
final class FeltStateCheckInCopyTests: XCTestCase {

    func testHelperHasNoDashConstruction() {
        XCTAssertFalse(FeltStateCheckInCopy.helper.contains("—"),
                       "one short clause, not two joined by a dash")
        XCTAssertFalse(FeltStateCheckInCopy.helper.contains("-"),
                       "no dash of any kind, not just the em-dash")
    }

    /// A rough proxy for "fits on one line at default dynamic type on a
    /// standard phone width" — the row's own font is 11pt system, and this
    /// codebase's narrowest supported phone (see `DayPotentialStrip`'s own
    /// 1-line headline treatment) comfortably fits ~45 characters of an
    /// 11pt system font inside its horizontal padding. The old two-clause
    /// helper ("A few seconds — helps your numbers mean something", 52
    /// characters) wrapped; this pins the replacement staying well under
    /// that, not just "shorter than before".
    func testHelperIsShortEnoughToFitOnOneLine() {
        XCTAssertLessThanOrEqual(FeltStateCheckInCopy.helper.count, 45)
    }

    func testQuestionIsUnchanged() {
        XCTAssertEqual(FeltStateCheckInCopy.question, "How do you feel right now?")
    }
}
