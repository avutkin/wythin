import XCTest
@testable import Wythin

final class ActivityLogIndicesTests: XCTestCase {

    private func lift() -> ActivityLog {
        ActivityLog(activityType: "Exercise", activitySubtype: "Powerlifting")
    }

    // MARK: - Absence is absence

    func testASessionWithNothingStoredOffersNoIndices() {
        // The row this replaces printed three dashes and a "1 of 7". An index
        // with no data is left out, not shown empty.
        XCTAssertTrue(lift().scoredIndices.isEmpty)
    }

    func testAnIndexAppearsOnlyWhenItsInputIsThere() {
        let entry = lift()
        XCTAssertNil(entry.bounceBackIndex)
        entry.hrr60Bpm = 34
        XCTAssertNotNil(entry.bounceBackIndex)
    }

    func testEfficiencyStaysOutWithoutAnExternalWorkSignal() {
        // Chest motion does not measure barbell work. Borrowing heart rate here
        // would print Brake release's number twice under a second name.
        let entry = lift()
        entry.efficiencySlope = -0.4
        entry.efficiencyScore = 72
        entry.hasExternalWorkSignal = false
        XCTAssertNil(entry.efficiencyIndex)
        entry.hasExternalWorkSignal = true
        XCTAssertNotNil(entry.efficiencyIndex)
    }

    // MARK: - What the cells say

    func testEveryIndexCarriesAVerdictSoTheNumberIsNeverAlone() {
        let entry = lift()
        entry.hrr60Bpm = 34
        entry.halfRecoveryMinutes = 9
        let index = entry.bounceBackIndex!
        XCTAssertFalse(index.verdict.isEmpty)
        XCTAssertEqual(index.name, BounceBackIndex.displayName)
    }

    func testTheDetailLineQuotesTheMeasurement() {
        let entry = lift()
        entry.hrr60Bpm = 34
        entry.halfRecoveryMinutes = 9
        XCTAssertTrue(entry.bounceBackIndex!.detail.contains("9"))
    }

    // MARK: - Doses

    func testLoadAndPeakAreNeverScored() {
        // Scoring them would say a heavier session beat a lighter one, which
        // the measurement does not support.
        let entry = lift()
        entry.exerciseLoad = 94
        entry.duringHRPeak = 148
        let doseNames = entry.ungradedDoses.map(\.name)
        XCTAssertEqual(doseNames, ["Load", "Peak"])
        XCTAssertFalse(entry.scoredIndices.contains { $0.name == "Load" })
        XCTAssertFalse(entry.scoredIndices.contains { $0.name == "Peak" })
    }

    func testEveryDoseCarriesItsUnit() {
        let entry = lift()
        entry.duringHRPeak = 148
        XCTAssertTrue(entry.ungradedDoses.first { $0.name == "Peak" }!.value.contains("bpm"))
    }

    // MARK: - The row's advice

    func testAdviceNeedsEnoughIndicesToHaveAWeakestOne() {
        let entry = lift()
        entry.hrr60Bpm = 34
        XCTAssertNil(SessionRecommendation.advice(for: entry.scoredIndices))
    }

    func testTheAdviceNamesAnIndexThatIsActuallyOnTheRow() {
        let entry = lift()
        entry.hrr60Bpm = 34
        entry.halfRecoveryMinutes = 9
        entry.efficiencySlope = -0.4
        entry.efficiencyScore = 55
        entry.hasExternalWorkSignal = true
        // Brake release is derived from the DC/HR pair, not from the stored
        // score alone — the score only supplies the word.
        entry.beforeDC = 16.0; entry.duringDC = 3.2
        entry.beforeHR = 62;   entry.duringHR = 148
        entry.duringDCTrough = 3.2

        let indices = entry.scoredIndices
        guard let advice = SessionRecommendation.advice(for: indices) else {
            return XCTFail("three indices should be enough for advice")
        }
        XCTAssertTrue(indices.contains { advice.because.contains($0.name) },
                      "advice must speak about a metric the reader can see")
    }
}
