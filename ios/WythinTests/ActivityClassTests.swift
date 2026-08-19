import XCTest
@testable import Wythin

final class ActivityClassTests: XCTestCase {

    func testExerciseIsActivating() {
        XCTAssertEqual(ActivityType.exercise.activityClass, .activating)
    }

    func testWalkIsActivating() {
        // Walk is merged into Exercise but the case still exists for in-flight rows.
        XCTAssertEqual(ActivityType.walk.activityClass, .activating)
    }

    func testEverythingElseIsRestorative() {
        let restorative: [ActivityType] = [.meditation, .breathwork, .meal, .nap,
                                           .thermal, .drinks, .work, .custom]
        for type in restorative {
            XCTAssertEqual(type.activityClass, .restorative,
                           "\(type.rawValue) must keep the existing nine-metric path")
        }
    }

    func testEveryCaseIsClassified() {
        // A new ActivityType must be a deliberate choice, not a silent default.
        XCTAssertEqual(ActivityType.allCases.count, 11,
                       "Sleep joined the enum; it is measured, not picked")
    }

    func testStoredWalkEntryClassifiesAsActivating() {
        // The row branch reads through activityTypeEnum, so the merge and the
        // class have to agree end to end.
        let entry = ActivityLog(activityType: "Walk", activitySubtype: "Treadmill")
        XCTAssertEqual(entry.activityTypeEnum.activityClass, .activating)
    }
}

// MARK: - Classification follows the measurement, not the label

extension ActivityClassTests {

    func testARealHeartRateRiseMakesItActivating() {
        // A brisk vinyasa logged as Yoga is an activating session and deserves
        // the recovery analysis, whatever tile it was logged under.
        XCTAssertEqual(ActivityClass.measured(beforeHR: 62, duringHR: 95,
                                              fallback: .restorative), .activating)
    }

    func testNoMeaningfulRiseMakesItRestorative() {
        // A session logged as Exercise that never lifted the pulse is not one.
        XCTAssertEqual(ActivityClass.measured(beforeHR: 62, duringHR: 68,
                                              fallback: .activating), .restorative)
    }

    func testTheThresholdItselfCounts() {
        let base = 60.0
        XCTAssertEqual(ActivityClass.measured(beforeHR: base,
                                              duringHR: base + ActivityClass.activatingHRRise,
                                              fallback: .restorative), .activating)
        XCTAssertEqual(ActivityClass.measured(beforeHR: base,
                                              duringHR: base + ActivityClass.activatingHRRise - 0.1,
                                              fallback: .activating), .restorative)
    }

    func testAFallingHeartRateIsNeverActivating() {
        XCTAssertEqual(ActivityClass.measured(beforeHR: 70, duringHR: 58,
                                              fallback: .activating), .restorative)
    }

    func testWithoutMeasurementTheLabelStandsIn() {
        // An entry with no strap data has only its type as evidence.
        XCTAssertEqual(ActivityClass.measured(beforeHR: nil, duringHR: 120,
                                              fallback: .activating), .activating)
        XCTAssertEqual(ActivityClass.measured(beforeHR: 60, duringHR: nil,
                                              fallback: .restorative), .restorative)
    }

    func testTheThresholdClearsOrdinaryVariation() {
        // Posture, a deep breath or a warm room move the pulse a few beats; the
        // bar has to sit clear of that without reaching toward exercise.
        XCTAssertGreaterThanOrEqual(ActivityClass.activatingHRRise, 10)
        XCTAssertLessThanOrEqual(ActivityClass.activatingHRRise, 25)
    }
}

// MARK: - The measurement decides only within the exercise family

extension ActivityClassTests {

    func testAMeditationThatRaisedThePulseIsStillAMeditation() {
        // Promoting it to the load-and-recovery model told people their
        // breathing practice was a workout. The measurement classifies
        // exercises; it never reclassifies a restorative practice.
        let entry = ActivityLog(activityType: "Meditation")
        entry.beforeHR = 60; entry.duringHR = 95   // a 35 bpm rise
        XCTAssertEqual(entry.measuredClass, .restorative)
    }

    func testBreathworkStaysRestorativeWhateverThePulseDid() {
        let entry = ActivityLog(activityType: "Breathwork", activitySubtype: "Pranayama")
        entry.beforeHR = 58; entry.duringHR = 110
        XCTAssertEqual(entry.measuredClass, .restorative)
    }

    func testEveryExerciseIsThePulseRoseCategory() {
        // By type, both ways: even a gentle exercise keeps the
        // load-and-recovery read — the chip states the measured rise, the
        // label decides the model.
        let lifted = ActivityLog(activityType: "Exercise", activitySubtype: "Yoga")
        lifted.beforeHR = 62; lifted.duringHR = 98
        XCTAssertEqual(lifted.measuredClass, .activating)

        let gentle = ActivityLog(activityType: "Exercise", activitySubtype: "Yoga")
        gentle.beforeHR = 62; gentle.duringHR = 66
        XCTAssertEqual(gentle.measuredClass, .activating)
    }

    func testAnExerciseWithNoMeasurementDefaultsToItsLabel() {
        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Powerlifting")
        XCTAssertEqual(entry.measuredClass, .activating)
    }
}
