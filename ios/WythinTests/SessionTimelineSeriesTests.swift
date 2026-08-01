import XCTest
@testable import Wythin

final class SessionTimelineSeriesTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 100_000)
    private func t(_ o: TimeInterval) -> Date { start.addingTimeInterval(o) }

    /// resting 50, ceiling 150 → span 100, so hr 100 is exactly 50 %HRR.
    private let resting: Float = 50
    private let ceiling: Float = 150

    private func build(_ s: [(date: Date, hr: Float?, dc: Float?)],
                       minutes: Double = 20,
                       dcPre: Float? = 10) -> [TimelinePoint] {
        SessionTimelineSeries.build(samples: s, startedAt: start,
                                    endedAt: t(minutes * 60),
                                    restingHR: resting, ceiling: ceiling, dcPre: dcPre)
    }

    // MARK: - The arithmetic

    func testHRRIsAPercentageOfReserve() {
        let pts = build((0..<40).map { (t(Double($0) * 30), Float(100), Float(10)) })
        XCTAssertFalse(pts.isEmpty)
        for p in pts { XCTAssertEqual(p.hrr, 50, accuracy: 0.001) }
    }

    func testWithdrawnIsTheFractionOfPreSessionDCGone() {
        // dc 4 against dcPre 10 → 60 % withdrawn.
        let pts = build((0..<40).map { (t(Double($0) * 30), Float(100), Float(4)) })
        for p in pts { XCTAssertEqual(p.withdrawn!, 60, accuracy: 0.001) }
    }

    func testWithdrawnClampsWhenDCExceedsBaseline() {
        // Recovery above baseline is zero withdrawal, never negative.
        let pts = build((0..<40).map { (t(Double($0) * 30), Float(100), Float(14)) })
        for p in pts { XCTAssertEqual(p.withdrawn!, 0, accuracy: 0.001) }
    }

    func testSamplesAreAveragedWithinABucket() {
        // 20 min over 120 buckets = 10 s each. Two samples in one bucket,
        // 100 and 150 bpm → 50 % and 100 % → mean 75 %.
        let pts = build([(t(1), Float(100), nil), (t(2), Float(150), nil)])
        XCTAssertEqual(pts.count, 1)
        XCTAssertEqual(pts[0].hrr, 75, accuracy: 0.001)
    }

    // MARK: - Windowing

    func testSamplesOutsideTheSessionAreIgnored() {
        let pts = build([(t(-60), Float(150), Float(1)),   // before
                         (t(300), Float(100), Float(10)),  // inside
                         (t(9999), Float(150), Float(1))]) // after
        XCTAssertEqual(pts.count, 1)
        XCTAssertEqual(pts[0].hrr, 50, accuracy: 0.001)
    }

    func testTheEndBoundaryIsExclusive() {
        // Matches computeHRVWindows' half-open [startedAt, end) partition, so
        // the chart and the stored numbers agree on which sample is in.
        let pts = build([(t(20 * 60), Float(150), Float(1))])
        XCTAssertTrue(pts.isEmpty)
    }

    func testZeroLengthSessionYieldsNothing() {
        XCTAssertTrue(SessionTimelineSeries.build(
            samples: [(t(0), Float(100), Float(10))],
            startedAt: start, endedAt: start,
            restingHR: resting, ceiling: ceiling, dcPre: 10).isEmpty)
    }

    // MARK: - Gaps must break the line, not be drawn through

    func testALongDropoutBreaksTheLine() {
        // Ten minutes of silence in the middle. Without a break the chart draws
        // a confident stroke across data it never had.
        var s: [(date: Date, hr: Float?, dc: Float?)] = []
        for i in 0..<10 { s.append((t(Double(i) * 30), Float(100), Float(5))) }
        for i in 0..<10 { s.append((t(600 + Double(i) * 30), Float(120), Float(5))) }

        let pts = build(s, minutes: 20)
        XCTAssertGreaterThan(Set(pts.map(\.segment)).count, 1,
                             "a dropout must split the run so the line breaks")
    }

    func testContinuousCoverageHasNoBreaks() {
        let s = (0..<40).map { (t(Double($0) * 30), Float(100), Float(5)) }
        let pts = build(s, minutes: 20)
        XCTAssertEqual(Set(pts.map(\.segment)).count, 1,
                       "unbroken coverage must stay one segment")
    }

    func testSegmentsAreMonotonicAndStartAtZero() {
        var s: [(date: Date, hr: Float?, dc: Float?)] = []
        for i in 0..<10 { s.append((t(Double(i) * 30), Float(100), Float(5))) }
        for i in 0..<10 { s.append((t(600 + Double(i) * 30), Float(120), Float(5))) }
        let segs = build(s, minutes: 20).map(\.segment)
        XCTAssertEqual(segs.first, 0)
        XCTAssertEqual(segs, segs.sorted(), "segments must never go backwards")
    }

    // MARK: - Missing DC

    func testNoBaselineMeansNoVagalTrace() {
        let pts = build((0..<40).map { (t(Double($0) * 30), Float(100), Float(5)) }, dcPre: nil)
        XCTAssertFalse(pts.isEmpty)
        XCTAssertTrue(pts.allSatisfy { $0.withdrawn == nil },
                      "without a baseline there is nothing to be withdrawn from")
    }

    func testZeroBaselineIsRejectedRatherThanDividedBy() {
        let pts = build((0..<40).map { (t(Double($0) * 30), Float(100), Float(5)) }, dcPre: 0)
        XCTAssertTrue(pts.allSatisfy { $0.withdrawn == nil })
    }

    func testHRPlotsEvenWhereDCIsAbsent() {
        let pts = build((0..<40).map { (t(Double($0) * 30), Float(100), nil) })
        XCTAssertFalse(pts.isEmpty)
        XCTAssertTrue(pts.allSatisfy { $0.withdrawn == nil })
    }

    func testBucketsWithNoHeartRateAreNotPlotted() {
        // DC alone cannot anchor a point on a chart whose x-axis is driven by HR.
        let pts = build((0..<40).map { (t(Double($0) * 30), nil, Float(5)) })
        XCTAssertTrue(pts.isEmpty)
    }

    // MARK: - Ordering

    func testOutputIsChronologicalRegardlessOfInputOrder() {
        let s = (0..<40).map { (t(Double($0) * 30), Float(100 + $0), Float(5)) }
        let pts = build(s.shuffled(), minutes: 20)
        XCTAssertEqual(pts.map(\.date), pts.map(\.date).sorted())
    }
}
