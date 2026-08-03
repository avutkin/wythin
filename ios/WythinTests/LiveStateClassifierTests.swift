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
        let calm  = LiveStateClassifier.axes(reading([.pip: -1, .lfHF: -1]))
        let tense = LiveStateClassifier.axes(reading([.pip: 1, .lfHF: 1]))
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
                                                      .pip: 0, .lfHF: 0,
                                                      .rsa: 0, .dc: 0, .vti: 0]))
        XCTAssertEqual(r.key, .stable_neutral)
        XCTAssertTrue(r.isWeak, "nothing moved — this is a weak call and must say so")
    }

    func testHighEnergyLowTensionGoodRecoveryIsEngagedPerforming() {
        let r = LiveStateClassifier.classify(reading([.hr: 0.8, .rmssd: 1.0, .rcmse: 0.9,
                                                      .pip: -1.0, .lfHF: -0.8,
                                                      .rsa: 0.8, .dc: 0.9, .vti: 1.0]))
        XCTAssertTrue([.engaged_performing, .calm_alert, .renewed_thriving].contains(r.key),
                      "got \(r.key)")
        XCTAssertFalse(r.isWeak)
    }

    func testHighTensionHighEnergyLowRecoveryIsStressedActivated() {
        let r = LiveStateClassifier.classify(reading([.hr: 1.2, .rmssd: -0.8, .rcmse: 0.5,
                                                      .pip: 1.5, .lfHF: 1.6,
                                                      .rsa: -1.0, .dc: -1.1, .vti: -1.0]))
        XCTAssertEqual(r.key, .stressed_activated)
    }

    func testHighTensionLowEnergyLowRecoveryIsOverloadedExhausted() {
        let r = LiveStateClassifier.classify(reading([.hr: -1.0, .rmssd: -1.4, .rcmse: -1.2,
                                                      .pip: 1.6, .lfHF: 1.4,
                                                      .rsa: -1.3, .dc: -1.4, .vti: -1.3]))
        XCTAssertTrue([.overloaded_exhausted, .shutdown_burnout].contains(r.key), "got \(r.key)")
    }

    func testLowEnergyLowTensionImprovingRecoveryIsRecoveringResetting() {
        let r = LiveStateClassifier.classify(reading([.hr: -1.1, .rmssd: 0.4, .rcmse: -0.9,
                                                      .pip: -0.9, .lfHF: -1.0,
                                                      .rsa: 0.7, .dc: 0.8, .vti: 0.6]))
        XCTAssertTrue([.recovering_resetting, .calm_alert].contains(r.key), "got \(r.key)")
    }

    func testEveryStateKeyIsReachable() {
        // Guards against a rule table with an unreachable branch.
        XCTAssertEqual(LiveStateKey.allCases.count, 9)
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
