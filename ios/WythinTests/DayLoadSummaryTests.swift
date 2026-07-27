import XCTest
@testable import Wythin

final class DayLoadSummaryTests: XCTestCase {

    func testNilWhenTooEarly() {
        XCTAssertNil(DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 3.5, hoursElapsed: 0.5))
    }

    func testNilWithoutDayMean() {
        XCTAssertNil(DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: nil, hoursElapsed: 5))
    }

    func testHoldingWhenDayMatchesAnchor() {
        let t = DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 3.58, hoursElapsed: 6)
        XCTAssertTrue(t?.contains("still there") ?? false)
    }

    func testSteadySpendInTheMiddleBand() {
        let t = DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 3.3, hoursElapsed: 6)
        XCTAssertTrue(t?.contains("steadily") ?? false)
    }

    func testHeavySpendWhenWellBelowAnchor() {
        let t = DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 2.6, hoursElapsed: 6)
        XCTAssertTrue(t?.contains("a lot of it") ?? false)
    }

    func testUsesNoTechnicalTerms() {
        let t = DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 3.3, hoursElapsed: 6) ?? ""
        for banned in ["HRV", "RMSSD", "RSA", "SDNN", "DFA", "vagal", "coherence", "entropy"] {
            XCTAssertFalse(t.localizedCaseInsensitiveContains(banned), "leaked \(banned)")
        }
    }
}
