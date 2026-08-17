import XCTest
@testable import Wythin

final class MindBodyResponseTests: XCTestCase {

    // MARK: Classification

    func testYinClassifiesRestorative() {
        // Near-rest: almost no elevated time.
        XCTAssertEqual(MindBodyResponse.classify(elevatedSeconds: 120, durationSeconds: 3600,
                                                 vagalRose: false, deltaRMSSDPct: 10), .restorative)
    }

    func testPowerVinyasaClassifiesWorkout() {
        XCTAssertEqual(MindBodyResponse.classify(elevatedSeconds: 2400, durationSeconds: 3600,
                                                 vagalRose: false, deltaRMSSDPct: -15), .workout)
    }

    func testVagalRiseAnchorsRestorativeEvenWithSomeElevatedTime() {
        // DC rising while moving is the strongest single vote.
        XCTAssertEqual(MindBodyResponse.classify(elevatedSeconds: 1200, durationSeconds: 3600,
                                                 vagalRose: true, deltaRMSSDPct: nil), .restorative)
    }

    func testVagalRiseDoesNotOverrideAClearWorkout() {
        XCTAssertEqual(MindBodyResponse.classify(elevatedSeconds: 2400, durationSeconds: 3600,
                                                 vagalRose: true, deltaRMSSDPct: nil), .workout)
    }

    func testTheMiddleBandTiebreaksOnThePostReboundSign() {
        // Immediate rebound up = restorative signature; suppression = mixed.
        XCTAssertEqual(MindBodyResponse.classify(elevatedSeconds: 1200, durationSeconds: 3600,
                                                 vagalRose: false, deltaRMSSDPct: 12), .restorative)
        XCTAssertEqual(MindBodyResponse.classify(elevatedSeconds: 1200, durationSeconds: 3600,
                                                 vagalRose: false, deltaRMSSDPct: -12), .mixed)
    }

    // MARK: Regulation credit

    func testAFullReboundTopsOut() {
        XCTAssertEqual(MindBodyResponse.regulationScore(beforeRMSSD: 30, afterRMSSD: 42), 100)
    }

    func testSuppressionAfterStoppingScoresLow() {
        XCTAssertEqual(MindBodyResponse.regulationScore(beforeRMSSD: 30, afterRMSSD: 24), 0)
    }

    func testNoAfterWindowMeansNoScoreNotZero() {
        XCTAssertNil(MindBodyResponse.regulationScore(beforeRMSSD: 30, afterRMSSD: nil))
    }

    func testTheIndexCarriesTheDeltaItWasScoredFrom() {
        let idx = MindBodyResponse.index(beforeRMSSD: 30, afterRMSSD: 36)
        XCTAssertEqual(idx?.detail, "+20% calm after")
        XCTAssertEqual(idx?.name, "Regulation")
    }

    // MARK: Model plumbing

    func testOnlyMindBodySubtypesGetTheRead() {
        let lift = ActivityLog(activityType: "Exercise", activitySubtype: "Powerlifting")
        XCTAssertFalse(lift.isMindBody)
        XCTAssertNil(lift.regulationIndex)
        let yoga = ActivityLog(activityType: "Exercise", activitySubtype: "Yoga")
        XCTAssertTrue(yoga.isMindBody)
    }

    func testAYinSessionEndToEnd() {
        let yoga = ActivityLog(activityType: "Exercise", activitySubtype: "Yoga")
        yoga.startedAt = Date(timeIntervalSince1970: 0)
        yoga.endedAt   = Date(timeIntervalSince1970: 3600)
        yoga.zone2Sec = 60
        yoga.vagalRoseDuring = true
        yoga.beforeRMSSD = 30; yoga.afterRMSSD = 39
        XCTAssertEqual(yoga.mindBodyClass, .restorative)
        // +30%% on the −20…+40 ramp: (30−(−20))/60 = 83.
        XCTAssertEqual(yoga.regulationIndex?.value, 83)
    }
}
