import XCTest
@testable import Wythin

final class ReserveSpanTests: XCTestCase {

    func testAnchorRestingHRIsPreferredOverThePercentile() {
        // Straps are worn mostly during exercise, so the 5th percentile of all
        // samples sits well above true rest. An anchor-derived resting rate is
        // the whole point of preferring this source.
        let exerciseHeavy = (110...170).map { Float($0) }
        let span = ReserveSpan.build(anchorRestingHRs: [52, 54, 53],
                                     bpm: exerciseHeavy,
                                     motion: exerciseHeavy.map { _ in Float(40) })
        XCTAssertEqual(span.restingHR, 53, accuracy: 0.001)
    }

    func testWithoutAnchorsItUsesHeartRateWhileStill() {
        var bpm: [Float] = [], motion: [Float?] = []
        for _ in 0..<400 { bpm.append(55); motion.append(1.0) }      // still
        for _ in 0..<400 { bpm.append(150); motion.append(40.0) }    // working
        let span = ReserveSpan.build(anchorRestingHRs: [], bpm: bpm, motion: motion)
        XCTAssertEqual(span.restingHR, 55, accuracy: 0.001,
                       "the working samples must not raise resting")
    }

    func testTooFewStillSamplesFallsBackToTheOverallPercentile() {
        var bpm: [Float] = [], motion: [Float?] = []
        for _ in 0..<10 { bpm.append(55); motion.append(1.0) }
        for _ in 0..<400 { bpm.append(150); motion.append(40.0) }
        let span = ReserveSpan.build(anchorRestingHRs: [], bpm: bpm, motion: motion)
        XCTAssertGreaterThan(span.restingHR, 55)
    }

    func testNoHistoryAtAllStillGivesAUsableSpan() {
        let span = ReserveSpan.build(anchorRestingHRs: [], bpm: [], motion: [])
        XCTAssertEqual(span.restingHR, 60, accuracy: 0.001)
        XCTAssertGreaterThan(span.ceiling, span.restingHR)
    }

    func testImplausibleAnchorsAreIgnored() {
        let span = ReserveSpan.build(anchorRestingHRs: [0, 300, 54],
                                     bpm: (100...160).map { Float($0) },
                                     motion: (100...160).map { _ in Float(40) })
        XCTAssertEqual(span.restingHR, 54, accuracy: 0.001)
    }

    func testTheSpanNeverCollapses() {
        // A low ceiling with a high resting rate would make every %HRR read 100 %.
        let span = ReserveSpan.build(anchorRestingHRs: [70],
                                     bpm: [72, 74, 75], motion: [nil, nil, nil])
        XCTAssertGreaterThanOrEqual(span.ceiling - span.restingHR, HRCeiling.minimumSpan)
    }

    func testMismatchedMotionArrayIsRejectedRatherThanZipped() {
        // Zipping arrays of different lengths silently truncates, which would
        // pair heart rates with the wrong motion values.
        let span = ReserveSpan.build(anchorRestingHRs: [],
                                     bpm: (100...200).map { Float($0) },
                                     motion: [1.0, 1.0])
        // Falls through to the overall 5th percentile of 100...200, which is 105 —
        // the point is that the two-element motion array was not zipped against it.
        XCTAssertEqual(span.restingHR, 105, accuracy: 0.001)
    }
}
