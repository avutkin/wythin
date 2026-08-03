import XCTest
@testable import Wythin

final class LiveStateClassifierTests: XCTestCase {

    private func reading(_ pairs: [LiveMetric: Float]) -> LiveReading {
        var out: [LiveMetric: MetricReading] = [:]
        for (metric, effective) in pairs {
            out[metric] = MetricReading(metric: metric, level: effective, trend: 0,
                                        meaningful: false, effective: effective)
        }
        return LiveReading(readings: out, coverage: 1.0)
    }

    // MARK: Axes

    func testEnergyAxisRisesWithItsInputs() {
        let low  = LiveStateClassifier.axes(reading([.hr: -1, .rmssd: -1, .rcmse: -1]))
        let high = LiveStateClassifier.axes(reading([.hr: 1, .rmssd: 1, .rcmse: 1]))
        XCTAssertLessThan(low.energy, high.energy)
    }

    func testTensionAxisRisesWithInnerNoiseAndStressBalance() {
        let calm  = LiveStateClassifier.axes(reading([.pip: -1, .stressBalance: -1]))
        let tense = LiveStateClassifier.axes(reading([.pip: 1, .stressBalance: 1]))
        XCTAssertLessThan(calm.tension, tense.tension)
    }

    func testMissingMetricsDoNotSkewAnAxisTowardZero() {
        // Only one of three energy inputs present, strongly high. The axis must
        // reflect that, not be diluted to a third of it by the two absentees.
        let axes = LiveStateClassifier.axes(reading([.rmssd: 2.0]))
        XCTAssertGreaterThan(axes.energy, 1.0)
    }

    // MARK: The nine states

    func testEverythingNearUsualIsStableNeutral() {
        let r = LiveStateClassifier.classify(reading([.hr: 0, .rmssd: 0, .rcmse: 0,
                                                      .pip: 0, .stressBalance: 0,
                                                      .rsa: 0, .dc: 0, .vti: 0]))
        XCTAssertEqual(r.key, .stable_neutral)
        XCTAssertTrue(r.isWeak, "nothing moved — this is a weak call and must say so")
    }

    func testHighEnergyLowTensionGoodRecoveryIsEngagedPerforming() {
        let r = LiveStateClassifier.classify(reading([.hr: 0.8, .rmssd: 1.0, .rcmse: 0.9,
                                                      .pip: -1.0, .stressBalance: -0.8,
                                                      .rsa: 0.8, .dc: 0.9, .vti: 1.0]))
        XCTAssertTrue([.engaged_performing, .calm_alert, .renewed_thriving].contains(r.key),
                      "got \(r.key)")
        XCTAssertFalse(r.isWeak)
    }

    func testHighTensionHighEnergyLowRecoveryIsStressedActivated() {
        let r = LiveStateClassifier.classify(reading([.hr: 1.2, .rmssd: -0.8, .rcmse: 0.5,
                                                      .pip: 1.5, .stressBalance: 1.6,
                                                      .rsa: -1.0, .dc: -1.1, .vti: -1.0]))
        XCTAssertEqual(r.key, .stressed_activated)
    }

    func testHighTensionLowEnergyLowRecoveryIsOverloadedExhausted() {
        let r = LiveStateClassifier.classify(reading([.hr: -1.0, .rmssd: -1.4, .rcmse: -1.2,
                                                      .pip: 1.6, .stressBalance: 1.4,
                                                      .rsa: -1.3, .dc: -1.4, .vti: -1.3]))
        XCTAssertTrue([.overloaded_exhausted, .shutdown_burnout].contains(r.key), "got \(r.key)")
    }

    func testLowEnergyLowTensionImprovingRecoveryIsRecoveringResetting() {
        let r = LiveStateClassifier.classify(reading([.hr: -1.1, .rmssd: 0.4, .rcmse: -0.9,
                                                      .pip: -0.9, .stressBalance: -1.0,
                                                      .rsa: 0.7, .dc: 0.8, .vti: 0.6]))
        XCTAssertTrue([.recovering_resetting, .calm_alert].contains(r.key), "got \(r.key)")
    }

    // MARK: The rule table, driven

    /// One metric per axis, so `LiveStateClassifier.axis`'s renormalisation
    /// makes the axis exactly the value given: energy = `e`, tension = `t`,
    /// recovery = `r`. Lets the rule table be exercised at named coordinates
    /// instead of through a weighted sum that has to be solved backwards.
    private func axes(energy e: Float, tension t: Float, recovery r: Float) -> LiveReading {
        reading([.rmssd: e, .pip: t, .dc: r])
    }

    private func key(energy e: Float, tension t: Float, recovery r: Float) -> LiveStateKey {
        LiveStateClassifier.classify(axes(energy: e, tension: t, recovery: r)).key
    }

    /// The previous version of this test asserted only
    /// `LiveStateKey.allCases.count == 9` and never touched the rule table, so
    /// it would have passed against a table that could not produce four of the
    /// nine. This drives the table itself.
    func testEveryStateKeyIsReachable() {
        var reached: Set<LiveStateKey> = []
        let corners: [(Float, Float, Float)] = [
            ( 0.0,  0.0,  0.0),   // weak            -> stable_neutral
            (-1.5,  1.5, -1.5),   // veryTense/lowE/veryPoorR -> shutdown_burnout
            (-1.0,  0.8, -0.8),   // tense/lowE/poorR         -> overloaded_exhausted
            ( 0.0,  1.0,  0.0),   // tense/!lowE              -> stressed_activated
            (-1.0,  0.0, -1.0),   // lowE/poorR               -> depleted_numb
            (-1.0, -0.5,  0.8),   // lowE/goodR/calm          -> recovering_resetting
            ( 1.0, -0.5,  1.5),   // highE/greatR/calm        -> renewed_thriving
            ( 1.0,  0.0,  0.8),   // highE/goodR              -> engaged_performing
            ( 0.0, -0.8,  0.8),   // calm/goodR               -> calm_alert
        ]
        for (e, t, r) in corners { reached.insert(key(energy: e, tension: t, recovery: r)) }
        XCTAssertEqual(reached.count, 9, "every one of the nine must be reachable; got \(reached)")
        XCTAssertEqual(Set(LiveStateKey.allCases), reached)
    }

    func testTheNamedCornersLandOnTheirNamedStates() {
        XCTAssertEqual(key(energy: -1.5, tension:  1.5, recovery: -1.5), .shutdown_burnout)
        XCTAssertEqual(key(energy: -1.0, tension:  0.8, recovery: -0.8), .overloaded_exhausted)
        XCTAssertEqual(key(energy:  0.0, tension:  1.0, recovery:  0.0), .stressed_activated)
        XCTAssertEqual(key(energy: -1.0, tension:  0.0, recovery: -1.0), .depleted_numb)
        XCTAssertEqual(key(energy: -1.0, tension: -0.5, recovery:  0.8), .recovering_resetting)
        XCTAssertEqual(key(energy:  1.0, tension: -0.5, recovery:  1.5), .renewed_thriving)
        XCTAssertEqual(key(energy:  1.0, tension:  0.0, recovery:  0.8), .engaged_performing)
        XCTAssertEqual(key(energy:  0.0, tension: -0.8, recovery:  0.8), .calm_alert)
        XCTAssertEqual(key(energy:  0.0, tension:  0.0, recovery:  0.0), .stable_neutral)
    }

    // MARK: The fall-through hole

    /// The whole-branch review's worked example. Recovery is 1.4 SD below
    /// usual and nothing else has moved, so no conjunction in the table
    /// matches — and the old table returned `stable_neutral`, whose copy reads
    /// "nothing pulling either way", directly above a WHY list reporting three
    /// metrics well below usual. The header must not contradict its own
    /// explanation.
    func testAStronglyNegativeRecoveryAxisAloneIsNotCalledSteady() {
        let r = LiveStateClassifier.classify(reading([.hr: 0, .rmssd: -0.5, .rcmse: 0,
                                                      .pip: 0.2, .stressBalance: 0.1,
                                                      .rsa: -1.5, .dc: -1.5, .vti: -1.2]))
        XCTAssertEqual(r.axes.energy,   -0.20, accuracy: 0.001)
        XCTAssertEqual(r.axes.tension,   0.155, accuracy: 0.001)
        XCTAssertEqual(r.axes.recovery, -1.395, accuracy: 0.001)
        XCTAssertFalse(r.isWeak, "1.4 SD on an axis is not a weak call")
        XCTAssertNotEqual(r.key, .stable_neutral,
                          "\"nothing pulling either way\" above three metrics well below usual")
        XCTAssertEqual(r.key, .depleted_numb, "recovery moved most and moved down")
    }

    func testALargePositiveEnergyExcursionAloneIsNotCalledSteady() {
        let k = key(energy: 1.4, tension: 0.1, recovery: 0.0)
        XCTAssertNotEqual(k, .stable_neutral)
        XCTAssertEqual(k, .engaged_performing)
    }

    /// `lowE && goodR && !calm` — the third named hole. Low energy with
    /// recovery clearly rebuilding is exactly `recovering_resetting`; the old
    /// table required calm on top and dropped it otherwise.
    func testLowEnergyWithGoodRecoveryAndNeutralTensionIsRecovering() {
        let k = key(energy: -0.9, tension: 0.0, recovery: 0.9)
        XCTAssertNotEqual(k, .stable_neutral)
        XCTAssertEqual(k, .recovering_resetting)
    }

    /// The invariant behind all of the above, swept rather than sampled:
    /// `stable_neutral` means "nothing moved", so it must be returned when and
    /// only when the call is weak. Any other reading has to land on a state
    /// whose copy matches it.
    func testStableNeutralIsReturnedIfAndOnlyIfTheCallIsWeak() {
        let steps: [Float] = [-2.0, -1.3, -0.9, -0.6, -0.4, -0.2, 0, 0.2, 0.4, 0.6, 0.9, 1.3, 2.0]
        for e in steps {
            for t in steps {
                for r in steps {
                    let res = LiveStateClassifier.classify(axes(energy: e, tension: t, recovery: r))
                    XCTAssertEqual(res.key == .stable_neutral, res.isWeak,
                                   "axes (\(e), \(t), \(r)) -> \(res.key), isWeak=\(res.isWeak)")
                }
            }
        }
    }

    // MARK: Metrics that are in no axis

    /// The five `LiveMetric` cases no axis contains. Pinned as a test rather
    /// than only as a comment, because the comment here previously claimed
    /// there were none — and the exclusion logic itself was never exercised.
    private static let unscored: [LiveMetric] = [.sdnn, .coherence, .breathBPM, .cbi, .dfa1]

    func testMetricsInNoAxisMoveNoAxis() {
        for metric in Self.unscored {
            let a = LiveStateClassifier.axes(reading([metric: 3.0]))
            XCTAssertEqual(a.energy,   0, accuracy: 0.0001, "\(metric) moved energy")
            XCTAssertEqual(a.tension,  0, accuracy: 0.0001, "\(metric) moved tension")
            XCTAssertEqual(a.recovery, 0, accuracy: 0.0001, "\(metric) moved recovery")
        }
    }

    /// They are excluded from the WHY ranking too — dropped, not defaulted to
    /// weight 1, which would let an unweighted metric outrank a scored one.
    func testMetricsInNoAxisNeverAppearInTheWhyList() {
        for metric in Self.unscored {
            let r = LiveStateClassifier.classify(reading([metric: 3.0, .pip: 0.5]))
            XCTAssertFalse(r.contributions.contains { $0.metric == metric },
                           "\(metric) pulls on no axis, so it cannot explain the state")
        }
    }

    func testExactlyEightOfThirteenMetricsAreScored() {
        let untouched = LiveAxes(energy: 0, tension: 0, recovery: 0)
        let scored = LiveMetric.allCases.filter {
            LiveStateClassifier.axes(reading([$0: 1.0])) != untouched
        }
        XCTAssertEqual(Set(LiveMetric.allCases).subtracting(scored), Set(Self.unscored))
        XCTAssertEqual(scored.count, 8)
    }

    func testStateKeysMatchTheServerContract() {
        XCTAssertEqual(LiveStateKey.engaged_performing.rawValue, "engaged_performing")
        XCTAssertEqual(LiveStateKey.shutdown_burnout.rawValue, "shutdown_burnout")
    }

    // MARK: Contributions

    func testContributionsAreRankedByAbsolutePull() {
        let r = LiveStateClassifier.classify(reading([.pip: 2.0, .rmssd: 0.4, .dc: -1.2]))
        let ranked = r.contributions.map(\.metric)
        XCTAssertEqual(ranked.first, .pip, "strongest pull must lead")
        let pulls = r.contributions.map { abs($0.value) }
        XCTAssertEqual(pulls, pulls.sorted(by: >), "must be sorted by absolute pull")
    }

    func testContributionsKeepTheirSign() {
        let r = LiveStateClassifier.classify(reading([.pip: 2.0]))
        XCTAssertGreaterThan(r.contributions.first?.value ?? 0, 0)
        let r2 = LiveStateClassifier.classify(reading([.pip: -2.0]))
        XCTAssertLessThan(r2.contributions.first?.value ?? 0, 0)
    }

    func testWeakContributionsAreDropped() {
        let r = LiveStateClassifier.classify(reading([.pip: 2.0, .rmssd: 0.01]))
        XCTAssertFalse(r.contributions.contains { $0.metric == .rmssd })
    }

    func testAtLeastOneContributionSurvivesAFlatWindow() {
        let r = LiveStateClassifier.classify(reading([.pip: 0.01, .rmssd: 0.02]))
        XCTAssertGreaterThanOrEqual(r.contributions.count, 1,
                                    "a flat window still explains itself")
    }

    func testContributionsRankByWeightedPullNotRawZScore() {
        // rcmse's raw z (1.0) is larger than pip's (0.8), but rcmse's axis
        // weight (0.3) is much smaller than pip's (0.55): weighted, pip pulled
        // its axis more (0.55*0.8 = 0.44) than rcmse pulled its own (0.3*1.0 =
        // 0.30). The explanation must lead with what actually moved the state.
        let r = LiveStateClassifier.classify(reading([.rcmse: 1.0, .pip: 0.8]))
        XCTAssertEqual(r.contributions.first?.metric, .pip,
                      "weighted pull, not raw z-score, must decide the order")
    }

    func testTiedContributionsBreakByMetricNameForDeterminism() {
        // hr and rcmse share the same energy weight (0.3); equal effective
        // values give them equal weighted pull. The tie must not depend on
        // Dictionary's per-process hash seeding, or the same reading would
        // explain itself differently between launches.
        let r = LiveStateClassifier.classify(reading([.hr: 1.0, .rcmse: 1.0]))
        XCTAssertEqual(r.contributions.first?.metric, .hr,
                      "tie must break deterministically, not by iteration order")
    }

    // MARK: Hysteresis

    func testHysteresisHoldsThroughASingleNoisyEvaluation() {
        let h = LiveStateHysteresis(required: 3)
        _ = h.settle(.stable_neutral)
        _ = h.settle(.stable_neutral)
        _ = h.settle(.stable_neutral)
        XCTAssertEqual(h.settle(.stressed_activated), .stable_neutral, "one blip must not flip")
    }

    func testHysteresisFlipsAfterASustainedChange() {
        let h = LiveStateHysteresis(required: 3)
        for _ in 0..<3 { _ = h.settle(.stable_neutral) }
        _ = h.settle(.stressed_activated)
        _ = h.settle(.stressed_activated)
        XCTAssertEqual(h.settle(.stressed_activated), .stressed_activated)
    }

    func testHysteresisAdoptsTheFirstStateImmediately() {
        let h = LiveStateHysteresis(required: 3)
        XCTAssertEqual(h.settle(.calm_alert), .calm_alert, "nothing to hold on to yet")
    }

    func testAnInterruptedRunRestarts() {
        let h = LiveStateHysteresis(required: 3)
        _ = h.settle(.stable_neutral)
        _ = h.settle(.stressed_activated)
        _ = h.settle(.stable_neutral)
        _ = h.settle(.stressed_activated)
        _ = h.settle(.stressed_activated)
        XCTAssertEqual(h.settle(.stable_neutral), .stable_neutral,
                       "the candidate run was broken, so nothing changed")
    }
}
