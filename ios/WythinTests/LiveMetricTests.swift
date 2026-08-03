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

    /// One point carrying a DISTINCT value for every field, so a mis-wired
    /// extractor reads a number that belongs to another metric and the
    /// assertion fails. The previous version of this test covered 3 of 13,
    /// which is how `stressBalance` sat wired to the raw `lfHF` ratio through
    /// eight reviewed tasks: nothing asserted what it returned.
    private var allFieldsPoint: MetricsHistoryPoint {
        MetricsHistoryPoint(timestamp: Date(),
                            meanBPM: 61, rmssd: 33, rsaMs: 27, sdnn: 52,
                            lfHF: 1.7, coherence: 0.62, breathBPM: 14, cbi: 0.41,
                            dfa1: 1.08, rcmse: 1.35, pip: 44, dc: 7.5)
    }

    func testEveryExtractorReadsItsOwnField() {
        let p = allFieldsPoint
        XCTAssertEqual(LiveMetric.hr.value(p), 61)
        XCTAssertEqual(LiveMetric.rmssd.value(p), 33)
        XCTAssertEqual(LiveMetric.rsa.value(p), 27)
        XCTAssertEqual(LiveMetric.sdnn.value(p), 52)
        XCTAssertEqual(LiveMetric.coherence.value(p), 0.62)
        XCTAssertEqual(LiveMetric.breathBPM.value(p), 14)
        XCTAssertEqual(LiveMetric.cbi.value(p), 0.41)
        XCTAssertEqual(LiveMetric.pip.value(p), 44)
        XCTAssertEqual(LiveMetric.dfa1.value(p), 1.08)
        XCTAssertEqual(LiveMetric.dc.value(p), 7.5)
        XCTAssertEqual(LiveMetric.rcmse.value(p), 1.35)
        // vti is ln(RMSSD); the convenience initializer derives it that way.
        XCTAssertEqual(try XCTUnwrap(LiveMetric.vti.value(p)), log(Float(33)), accuracy: 0.0001)
        // Derived, not a stored field — see below.
        XCTAssertEqual(try XCTUnwrap(LiveMetric.stressBalance.value(p)), 54.7945, accuracy: 0.001)
    }

    /// The whole table at once: every case must be covered by the fixture
    /// above, so adding a `LiveMetric` case without wiring an extractor is
    /// caught here rather than by a metric that silently never scores.
    func testNoCaseIsLeftUnwiredOnAFullyPopulatedPoint() {
        let p = allFieldsPoint
        for metric in LiveMetric.allCases {
            XCTAssertNotNil(metric.value(p), "\(metric) read nil from a fully populated point")
        }
    }

    func testMissingFieldsReadAsNilRatherThanZero() {
        let empty = MetricsHistoryPoint(timestamp: Date(), meanBPM: 61)
        XCTAssertNil(LiveMetric.dfa1.value(empty))
        XCTAssertNil(LiveMetric.rmssd.value(empty))
        // No RMSSD and no LF/HF powers — the balance has nothing to work from.
        XCTAssertNil(LiveMetric.stressBalance.value(empty))
    }

    /// The load-bearing property of I1: the Tension axis's second input is the
    /// breathing-robust SNS share, NOT the raw LF/HF ratio. During resonance
    /// breathing the vagal peak moves into LF and the ratio spikes, while the
    /// RMSSD-driven dial is unmoved — so scoring the ratio would call the most
    /// vagally-activating breathing there is "stressed".
    func testStressBalanceIsTheBreathingRobustDialNotTheRawRatio() {
        // Same RMSSD, same heart rate; only the breathing rate and the
        // (consequently inverted) LF/HF ratio differ.
        let normal = MetricsHistoryPoint(timestamp: Date(), meanBPM: 60, rmssd: 45,
                                         sdnn: 50, lfHF: 0.8, breathBPM: 14)
        let paced  = MetricsHistoryPoint(timestamp: Date(), meanBPM: 60, rmssd: 45,
                                         sdnn: 50, lfHF: 9.0, breathBPM: 6)
        XCTAssertEqual(try XCTUnwrap(LiveMetric.stressBalance.value(normal)),
                       try XCTUnwrap(LiveMetric.stressBalance.value(paced)), accuracy: 0.0001,
                       "slow breathing must not move the stress dial when RMSSD has not moved")
        XCTAssertNotEqual(normal.lfHF, paced.lfHF, "the fixture's raw ratio really does differ")
    }

    /// Matches the value `DailyRollupCompute` stores in the typed
    /// `stressBalance` field — the two must be the same number, since the live
    /// path scores the dictionary entry and the charts plot the typed field.
    func testExtractorAgreesWithTheRollupsStoredStressBalance() {
        let p = allFieldsPoint
        XCTAssertEqual(try XCTUnwrap(DailyRollupCompute.stressBalance(p)),
                       Double(try XCTUnwrap(LiveMetric.stressBalance.value(p))), accuracy: 0.0001)
    }

    func testRawValuesAreStableWireKeys() {
        XCTAssertEqual(LiveMetric.hr.rawValue, "hr")
        XCTAssertEqual(LiveMetric.breathBPM.rawValue, "breath_bpm")
        // "stress_balance", never "lf_hf": the same distinction
        // `TrackMetricSpecTests.testTrendKeysAreUniqueAndStressBalanceIsNotLfHf`
        // already enforces for the Track payload. A 0–100 dial stored under
        // the ratio's key would be read back as a ratio.
        XCTAssertEqual(LiveMetric.stressBalance.rawValue, "stress_balance")
        XCTAssertFalse(LiveMetric.allCases.map(\.rawValue).contains("lf_hf"))
    }

    func testRawValuesAreUnique() {
        let keys = LiveMetric.allCases.map(\.rawValue)
        XCTAssertEqual(Set(keys).count, keys.count, "rawValue is a persisted dictionary key")
    }
}
