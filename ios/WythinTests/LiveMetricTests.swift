import XCTest
@testable import Wythin

final class LiveMetricTests: XCTestCase {

    func testEveryCaseHasAPlainLanguageName() {
        let banned = ["HRV", "RMSSD", "RSA", "SDNN", "DFA", "LF/HF", "vagal", "entropy"]
        for metric in LiveMetric.allCases {
            XCTAssertFalse(metric.displayName.isEmpty, "\(metric) has no display name")
            for term in banned {
                XCTAssertFalse(metric.displayName.localizedCaseInsensitiveContains(term),
                               "\(metric) leaks the technical term \(term)")
            }
        }
    }

    func testExtractorsReadTheRightField() {
        let p = MetricsHistoryPoint(timestamp: Date(), meanBPM: 61, rmssd: 33, pip: 44)
        XCTAssertEqual(LiveMetric.hr.value(p), 61)
        XCTAssertEqual(LiveMetric.rmssd.value(p), 33)
        XCTAssertEqual(LiveMetric.pip.value(p), 44)
        XCTAssertNil(LiveMetric.dfa1.value(p))
    }

    func testRawValuesAreStableWireKeys() {
        XCTAssertEqual(LiveMetric.hr.rawValue, "hr")
        XCTAssertEqual(LiveMetric.breathBPM.rawValue, "breath_bpm")
        XCTAssertEqual(LiveMetric.lfHF.rawValue, "lf_hf")
    }
}
