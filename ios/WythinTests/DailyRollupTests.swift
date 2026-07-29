import XCTest
@testable import Wythin

final class DailyRollupTests: XCTestCase {

    private let cal = Calendar.current
    private lazy var day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))

    /// A sample that passes MetricsQualityFilter (sdnn > 5, rmssd > 3, 35 <= bpm <= 210).
    private func good(_ i: Int,
                      dc: Float? = 8,
                      rmssd: Float? = 40,
                      pip: Float? = 55) -> MetricsHistoryPoint {
        MetricsHistoryPoint(
            timestamp: day.addingTimeInterval(Double(i) * 2),
            meanBPM: 60, rmssd: rmssd, rsaMs: 30, sdnn: 50,
            lfHF: 1.2, coherence: 0.5, breathBPM: 12, cbi: 0.5,
            dfa1: 1.0, rcmse: 1.4, pip: pip, dc: dc, motion: 5)
    }

    /// Fails the quality filter: sdnn below 5.
    private func bad(_ i: Int) -> MetricsHistoryPoint {
        MetricsHistoryPoint(
            timestamp: day.addingTimeInterval(Double(i) * 2),
            meanBPM: 60, rmssd: 40, rsaMs: 30, sdnn: 1,
            dfa1: 1.0, rcmse: 1.4, pip: 55, dc: 8)
    }

    func testBelowMinimumTicksProducesNoRollup() {
        let pts = (0..<149).map { good($0) }
        XCTAssertNil(DailyRollupCompute.rollup(day: day, points: pts))
    }

    func testExactlyMinimumTicksProducesARollup() {
        let pts = (0..<150).map { good($0) }
        XCTAssertNotNil(DailyRollupCompute.rollup(day: day, points: pts))
    }

    func testLowQualitySamplesDoNotCountTowardTheGate() {
        // 100 good + 100 bad = 200 total but only 100 valid, below the 150 gate.
        let pts = (0..<100).map { good($0) } + (100..<200).map { bad($0) }
        XCTAssertNil(DailyRollupCompute.rollup(day: day, points: pts))
    }

    func testFieldsAreMeansOfValidSamples() {
        // Half the days at dc 6, half at dc 10 → mean 8.
        let pts = (0..<200).map { good($0, dc: $0 < 100 ? 6 : 10) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        XCTAssertEqual(r.dc!, 8.0, accuracy: 0.001)
        XCTAssertEqual(r.rmssd!, 40.0, accuracy: 0.001)
        XCTAssertEqual(r.sampleCount, 200)
    }

    func testNilFieldsAreIgnoredNotTreatedAsZero() {
        // dc present on 100 of 200 samples; the mean must be over the present ones.
        let pts = (0..<200).map { good($0, dc: $0 < 100 ? 6 : nil) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        XCTAssertEqual(r.dc!, 6.0, accuracy: 0.001)
    }

    func testFieldIsNilWhenNoSampleHasIt() {
        let pts = (0..<200).map { good($0, dc: nil) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        XCTAssertNil(r.dc)
    }

    func testWearSecondsCountsValidSamplesOnly() {
        let pts = (0..<200).map { good($0) } + (200..<300).map { bad($0) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        XCTAssertEqual(r.wearSeconds, 400, accuracy: 0.001)   // 200 × 2 s
    }

    func testStressBalanceIsDerivedAndAveraged() {
        let pts = (0..<200).map { good($0) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        let single = try! XCTUnwrap(DailyRollupCompute.stressBalance(pts[0]))
        XCTAssertEqual(try! XCTUnwrap(r.stressBalance), single, accuracy: 0.001)
        XCTAssertTrue((0...100).contains(single))
    }

    func testRoundTripsThroughCodable() {
        let pts = (0..<200).map { good($0) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        let data = try! JSONEncoder().encode(r)
        XCTAssertEqual(try! JSONDecoder().decode(DailyRollup.self, from: data), r)
    }
}
