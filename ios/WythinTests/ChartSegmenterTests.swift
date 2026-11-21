import XCTest
import SwiftUI
@testable import Wythin

/// Exercise the plotted data, including the averaging that used to hide gaps.
final class ChartSegmenterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_795_046_400)

    private func sample(_ seconds: Double, value: Float = 10) -> MetricsHistoryPoint {
        MetricsHistoryPoint(timestamp: start.addingTimeInterval(seconds),
                            meanBPM: 61, rmssd: 33, rsaMs: 27, sdnn: 52,
                            lfHF: 1.7, coherence: 0.62, breathBPM: 14, cbi: 0.41,
                            dfa1: 1.08, rcmse: 1.35, pip: 44, dc: value)
    }

    private func card(_ history: [MetricsHistoryPoint], window: TimeWindow = .h24,
                      night: ClosedRange<Date>? = nil, smooth: Bool = false,
                      transform: ((Double) -> Double)? = nil,
                      extract: @escaping (MetricsHistoryPoint) -> Double? = { $0.dc.map(Double.init) }) -> MetricChartCard {
        MetricChartCard(title: "Vagal Tone", subtitle: "", yLabel: "ms", color: .blue,
                        windows: TimeWindow.allCases, refs: [], yDomain: 0...100, win: window,
                        night: night, selectedX: .constant(nil), panOffset: .constant(0), smooth: smooth,
                        isEstimated: { $0.breathSource == .heart }, history: history,
                        date: start,
                        liveDay: LiveChartDay(bounds: start..<start.addingTimeInterval(86400),
                                              timeZone: TimeZone(secondsFromGMT: 0)!, isToday: false),
                        bucketTransform: transform, extract: extract)
    }

    func testContinuousRecordingStaysConnectedAtEveryZoom() {
        let history = stride(from: 0.0, through: 3600.0, by: 10).map { sample($0) }
        for window in TimeWindow.allCases {
            let points = card(history, window: window).points
            XCTAssertGreaterThan(points.count, 1)
            XCTAssertEqual(Set(points.map(\.segment)).count, 1, "\(window): averaging must not turn continuous data into dots")
            XCTAssertTrue(points.allSatisfy { $0.val == 10 })
        }
    }

    func testIsolatedIntermediateRecordingCannotBridgeHoursOfMissingData() {
        let history = [10.0, 20, 14_410, 14_420, 28_810, 28_820].map { sample($0) }
        for window in TimeWindow.allCases {
            let points = card(history, window: window).points
            XCTAssertEqual(Set(points.map(\.segment)).count, 3, "\(window): three separate recording runs")
            for (a, b) in zip(points, points.dropFirst()) where b.date.timeIntervalSince(a.date) >= 300 {
                XCTAssertNotEqual(a.segment, b.segment)
            }
        }
    }

    func testGapWithinOne24HourBucketDoesNotMergeRecordings() {
        let points = card([sample(10, value: 10), sample(20, value: 20),
                           sample(620, value: 80), sample(630, value: 100)]).points
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map(\.val), [15, 90])
        XCTAssertEqual(points.map(\.segment), [0, 1])
        XCTAssertEqual(Set(points.map(\.id)).count, points.count)
        XCTAssertTrue(points.first!.date <= start.addingTimeInterval(20))
        XCTAssertTrue(points.last!.date >= start.addingTimeInterval(620))
    }

    func testGapBetweenAdjacent24HourBucketsStillBreaks() {
        let points = card([sample(710), sample(1320)]).points
        XCTAssertEqual(points.map(\.segment), [0, 1])
    }

    func testExactFiveMinuteGapBreaksButShorterGapStaysConnected() {
        let points = card([sample(10), sample(309), sample(609)], window: .m30).points
        XCTAssertEqual(points.map(\.segment), [0, 0, 1])
    }

    func testOtherMetricsCannotFillMissingValuesForThisMetric() {
        let history = stride(from: 0.0, through: 1200.0, by: 30).map { seconds in
            MetricsHistoryPoint(timestamp: start.addingTimeInterval(seconds), meanBPM: 61,
                                dc: seconds == 0 || seconds == 1200 ? 10 : nil)
        }
        for window in TimeWindow.allCases {
            XCTAssertEqual(card(history, window: window).points.map(\.segment), [0, 1])
            let hr = card(history, window: window, extract: { $0.meanBPM.map(Double.init) }).points
            XCTAssertEqual(Set(hr.map(\.segment)).count, 1)
        }
    }

    func testCommonRecordingOutageBreaksEveryLiveMetric() {
        let history = [10.0, 20, 14_410, 14_420, 28_810, 28_820].map { sample($0) }
        for metric in LiveMetric.allCases {
            let points = card(history, extract: { metric.value($0).map(Double.init) }).points
            XCTAssertEqual(points.map(\.segment), [0, 1, 2], "\(metric)")
        }
    }

    func testIsolatedReadingKeepsActualTimestamp() {
        let points = card([sample(37)]).points
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.date, start.addingTimeInterval(37))
    }

    func testUnorderedAndDuplicateReadingsHaveChronologicalUniquePoints() {
        let history = [sample(910), sample(20, value: 30), sample(10), sample(20, value: 20)]
        let points = card(history).points
        XCTAssertEqual(points.map(\.val), [20, 10])
        XCTAssertEqual(points.map(\.segment), [0, 1])
        XCTAssertEqual(points.map(\.date), points.map(\.date).sorted())
        XCTAssertEqual(Set(points.map(\.id)).count, points.count)
    }

    func testPinnedNightAndDayBoundsExcludeOutsideSamples() {
        let night = start.addingTimeInterval(3600)...start.addingTimeInterval(3600 + 8 * 3600)
        let history = [sample(-1), sample(3610), sample(3970), sample(40_000), sample(86400)]
        let points = card(history, night: night).points
        XCTAssertEqual(points.map(\.segment), [0, 1])
        XCTAssertTrue(points.allSatisfy { night.contains($0.date) })
        XCTAssertEqual(card(history).points.count, 3)
    }

    func testBucketPreservesQualitySourceAndTransformAfterAverage() throws {
        var first = sample(10, value: 10)
        first.breathSource = .heart
        var second = MetricsHistoryPoint(timestamp: start.addingTimeInterval(20), dc: 30, signalQuality: 0.8)
        second.breathSource = .accelerometer
        let points = card([first, second], transform: { log($0) }).points
        let point = try XCTUnwrap(points.first)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(point.val, log(20), accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(point.quality), 0.8, accuracy: 0.00001)
        XCTAssertFalse(point.estimated, "an even split is measured")
        XCTAssertTrue(card([first]).points.first!.estimated)
    }

    func testSmoothingPreservesEstimatedReadingsAndValuesAcrossGaps() {
        let history = [(10.0, Float(10)), (310.0, Float(20)), (610.0, Float(100))].map { seconds, value in
            var point = sample(seconds, value: value)
            point.breathSource = .heart
            return point
        }
        let chart = card(history, smooth: true)
        let points = chart.displayedPoints
        XCTAssertEqual(points.map(\.segment), [0, 1, 2])
        XCTAssertEqual(points.map(\.val), [10, 20, 100], "smoothing cannot blend separate runs")
        XCTAssertEqual(points.map(\.date), chart.points.map(\.date))
        XCTAssertTrue(points.allSatisfy(\.estimated), "isolated EDR readings must still be labelled estimated")
    }

    func testMissingAndNonfiniteValuesDoNotCreateCoverage() {
        XCTAssertTrue(card([]).points.isEmpty)
        let history = [sample(10), sample(200, value: .nan), sample(400, value: .infinity), sample(620)]
        let points = card(history).points
        XCTAssertEqual(points.map(\.segment), [0, 1])
        XCTAssertTrue(points.allSatisfy { $0.val.isFinite })
    }
}
