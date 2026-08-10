import XCTest
@testable import Wythin

final class SessionIndicesTests: XCTestCase {

    // MARK: - The ramp

    func testTheAnchorsAreTheEnds() {
        XCTAssertEqual(SessionIndices.ramp(10, best: 10, worst: 50), 100)
        XCTAssertEqual(SessionIndices.ramp(50, best: 10, worst: 50), 0)
        XCTAssertEqual(SessionIndices.ramp(30, best: 10, worst: 50), 50)
    }

    func testTheRampClampsRatherThanRunningPastTheEnds() {
        // A session better than the anchor is not 130 out of 100.
        XCTAssertEqual(SessionIndices.ramp(2, best: 10, worst: 50), 100)
        XCTAssertEqual(SessionIndices.ramp(90, best: 10, worst: 50), 0)
    }

    func testDirectionComesFromTheArgumentsNotAFlag() {
        // Higher-is-better reads the same way with the anchors swapped.
        XCTAssertEqual(SessionIndices.ramp(40, best: 50, worst: 10), 75)
    }

    func testEqualAnchorsCannotDivideByZero() {
        XCTAssertEqual(SessionIndices.ramp(7, best: 7, worst: 7), 50)
    }

    // MARK: - Bands

    func testTheBandBoundariesAreInclusiveWhereTheLegendSaysTheyAre() {
        XCTAssertEqual(IndexBand.of(44), .act)
        XCTAssertEqual(IndexBand.of(45), .improve)
        XCTAssertEqual(IndexBand.of(69), .improve)
        XCTAssertEqual(IndexBand.of(70), .keep)
    }

    func testTheLegendQuotesTheRealThresholds() {
        // The legend is generated from the constants so the two cannot drift.
        XCTAssertTrue(IndexBand.act.legend.contains("\(IndexBand.actBelow)"))
        XCTAssertTrue(IndexBand.keep.legend.contains("\(IndexBand.keepAbove)"))
    }

    // MARK: - Warm-up speed

    func testTheMockupNumbersReproduce() {
        // 41 s against 25 s → 100 and 90 s → 0 is the 75 shown in the proposal.
        XCTAssertEqual(MobilisationIndex.score(secondsToHalfRange: 41), 75)
    }

    func testAFasterWarmUpScoresHigher() {
        let quick = MobilisationIndex.score(secondsToHalfRange: 30)!
        let slow  = MobilisationIndex.score(secondsToHalfRange: 70)!
        XCTAssertGreaterThan(quick, slow)
    }

    func testWithoutAMeasurementThereIsNoScore() {
        XCTAssertNil(MobilisationIndex.score(secondsToHalfRange: nil))
        XCTAssertNil(MobilisationIndex.score(secondsToHalfRange: 0))
    }

    func testTheDetailLineCarriesTheMeasurementItCameFrom() {
        let index = MobilisationIndex.index(secondsToHalfRange: 41)
        XCTAssertEqual(index?.detail, "41 s")
        XCTAssertEqual(index?.verdict, "switched on fast")
    }

    // MARK: - Steadiness

    func testLessDriftScoresHigher() {
        let steady   = SteadinessIndex.score(driftPercent: 2)!
        let drifting = SteadinessIndex.score(driftPercent: 9)!
        XCTAssertGreaterThan(steady, drifting)
    }

    func testTheProposalsDriftLandsInTheMiddleBand() {
        let value = SteadinessIndex.score(driftPercent: 4.2)!
        XCTAssertEqual(IndexBand.of(value), .improve)
    }

    func testTheConventionalDecouplingThresholdSitsNearTheMiddle() {
        // 5% is the endurance literature's line between holding a session and
        // outrunning it, so it must not land in either outer band.
        XCTAssertEqual(IndexBand.of(SteadinessIndex.score(driftPercent: 5)!), .improve)
    }

    // MARK: - Bounce-back

    func testTheThreePartsAreScoredBeforeTheyAreAveraged() {
        // Minutes and beats cannot be averaged raw; if they were, the 34 bpm
        // would swamp the 9 minutes and the result would track heart rate alone.
        let both = BounceBackIndex.score(hrr60Bpm: 34, halfRecoveryMinutes: 9,
                                         decoupling: nil, decouplingMean: nil,
                                         decouplingHistoryCount: 0)!
        let hrOnly = HeartRateRecovery.score(hrr60: 34)!
        XCTAssertNotEqual(both, hrOnly)
        XCTAssertLessThan(both, hrOnly)   // the slower half-recovery pulls it down
    }

    func testDecouplingStaysOutUntilThereIsHistoryForIt() {
        let withoutHistory = BounceBackIndex.score(
            hrr60Bpm: 34, halfRecoveryMinutes: 9, decoupling: 2.1,
            decouplingMean: 2.8,
            decouplingHistoryCount: BounceBackIndex.minimumHistoryForDecoupling - 1)
        let withHistory = BounceBackIndex.score(
            hrr60Bpm: 34, halfRecoveryMinutes: 9, decoupling: 2.1,
            decouplingMean: 2.8,
            decouplingHistoryCount: BounceBackIndex.minimumHistoryForDecoupling)
        XCTAssertNotEqual(withoutHistory, withHistory)
    }

    func testTighterDecouplingThanUsualScoresAboveTheMiddle() {
        let tighter = BounceBackIndex.decouplingScore(2.1, personalMean: 2.8)!
        let looser  = BounceBackIndex.decouplingScore(3.6, personalMean: 2.8)!
        XCTAssertGreaterThan(tighter, 50)
        XCTAssertLessThan(looser, 50)
    }

    func testDecouplingNeedsAPersonalBaselineBecauseItHasNoPublishedNorm() {
        XCTAssertNil(BounceBackIndex.decouplingScore(2.1, personalMean: nil))
    }

    func testNoInputsMeansNoScoreRatherThanZero() {
        // Zero would read as "you did not recover", which is a claim about the
        // owner rather than about the data.
        XCTAssertNil(BounceBackIndex.score(hrr60Bpm: nil, halfRecoveryMinutes: nil,
                                           decoupling: nil, decouplingMean: nil,
                                           decouplingHistoryCount: 0))
    }

    // MARK: - The recommendation

    private func idx(_ name: String, _ value: Int) -> ScoredIndex {
        ScoredIndex(name: name, value: value, verdict: "came off deeper", detail: "")
    }

    func testTheAdviceSpeaksToTheWeakestIndex() {
        let advice = SessionRecommendation.advice(for: [
            idx("Readiness", 71),
            idx(BrakeReleaseIndex.displayName, 61),
            idx(BounceBackIndex.displayName, 74),
        ])
        XCTAssertEqual(advice?.action,
                       SessionRecommendation.action(for: BrakeReleaseIndex.displayName))
        XCTAssertTrue(advice?.because.contains("61") == true)
    }

    func testEveryIndexHasItsOwnAction() {
        // A single generic line would be true of every weak read and therefore
        // useful on none of them.
        let names = [BrakeReleaseIndex.displayName, MobilisationIndex.displayName,
                     BounceBackIndex.displayName, SteadinessIndex.displayName,
                     "Efficiency", "Readiness"]
        let actions = Set(names.map { SessionRecommendation.action(for: $0) })
        XCTAssertEqual(actions.count, names.count)
    }

    func testAllStrongGetsDifferentWordsFromAWeakRead() {
        let advice = SessionRecommendation.advice(for: [
            idx("Readiness", 82), idx("Efficiency", 78), idx("Steadiness", 91),
        ])
        XCTAssertEqual(advice?.action, "Repeat this session as it was.")
    }

    func testOneIndexIsNotAWeakestOne() {
        XCTAssertNil(SessionRecommendation.advice(for: [idx("Readiness", 30)]))
        XCTAssertNil(SessionRecommendation.advice(for: [idx("Readiness", 30),
                                                       idx("Efficiency", 40)]))
    }

    func testTheRecommendationNeverContradictsTheGrid() {
        // The card the coach replaced could praise a session the score called
        // poor. This one is a pure function of the numbers beside it.
        let indices = [idx("Readiness", 40), idx("Efficiency", 88), idx("Steadiness", 66)]
        let advice = SessionRecommendation.advice(for: indices)
        XCTAssertTrue(advice?.because.contains("Readiness") == true)
        XCTAssertFalse(advice?.because.contains("Efficiency") == true)
    }
}

// MARK: - Readiness

final class ReadinessScoreTests: XCTestCase {

    private func peers(_ values: [Double]) -> [Double] { values }

    func testAPercentileNeedsPeersBeforeItMeansAnything() {
        let c = ReadinessScore.Component(today: 50, peers: [40, 45, 50, 55],
                                         higherIsBetter: true)
        XCTAssertNil(ReadinessScore.componentScore(c),
                     "four peers is noise pretending to be a measurement")
    }

    func testTodayAtTheTopOfYourOwnRangeScoresHigh() {
        let c = ReadinessScore.Component(today: 62, peers: [30, 35, 40, 45, 50, 55, 60],
                                         higherIsBetter: true)
        XCTAssertEqual(ReadinessScore.componentScore(c), 100)
    }

    func testDirectionIsPerComponent() {
        // A low resting pulse is a good morning; a low RMSSD is not.
        let history: [Double] = [50, 54, 58, 62, 66, 70, 74]
        let lowIsGood  = ReadinessScore.Component(today: 52, peers: history, higherIsBetter: false)
        let highIsGood = ReadinessScore.Component(today: 52, peers: history, higherIsBetter: true)
        XCTAssertGreaterThan(ReadinessScore.componentScore(lowIsGood)!,
                             ReadinessScore.componentScore(highIsGood)!)
    }

    func testOneUnusuallyBadDayDoesNotRedefineTheBottomOfTheScale() {
        // Bounded by the 10th/90th percentile, not min/max, so an outlier
        // cannot permanently flatten every later score.
        let withOutlier: [Double] = [2, 40, 42, 44, 46, 48, 50, 52, 54, 56]
        let c = ReadinessScore.Component(today: 41, peers: withOutlier, higherIsBetter: true)
        XCTAssertLessThan(ReadinessScore.componentScore(c)!, 40,
                          "41 is near the bottom of the real spread, outlier aside")
    }

    func testAFlatHistoryIsMidScaleRatherThanADivideByZero() {
        let c = ReadinessScore.Component(today: 50, peers: Array(repeating: 50, count: 8),
                                         higherIsBetter: true)
        XCTAssertEqual(ReadinessScore.componentScore(c), 50)
    }

    func testComponentsWithoutEnoughHistoryAreDroppedNotZeroed() {
        let good = ReadinessScore.Component(today: 60, peers: [30, 35, 40, 45, 50, 55],
                                            higherIsBetter: true)
        let thin = ReadinessScore.Component(today: 60, peers: [50], higherIsBetter: true)
        XCTAssertEqual(ReadinessScore.score([good, thin]),
                       ReadinessScore.componentScore(good),
                       "a component with no history must not drag the mean toward zero")
    }

    func testNoComponentsMeansNoScore() {
        XCTAssertNil(ReadinessScore.score([]))
    }
}
