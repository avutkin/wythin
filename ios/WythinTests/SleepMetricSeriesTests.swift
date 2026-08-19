import XCTest
@testable import Wythin

/// Each of the nine metrics gets its own line across the night, so a number
/// like "Vagal Tone 14.5 ms" stops being a single flat average and becomes
/// something you can actually track — where it rose, where it collapsed, and
/// whether that lines up with the wake bouts.
final class SleepMetricSeriesTests: XCTestCase {

    private var night: [MetricsHistoryPoint] { RealNight.points() }

    func testEveryMeasuredMetricGetsASeries() {
        let prepared = PreparedNight(points: night)
        for def in activityMetricDefs where night.contains(where: { def.extract($0) != nil }) {
            XCTAssertFalse(prepared.series[def.id]?.isEmpty ?? true,
                           "\(def.label) has samples but no line to draw")
        }
    }

    func testASeriesIsBucketedSoTheChartDoesNotDrawEveryTick() {
        // A ten-hour night at the foreground cadence is ~18,000 samples and the
        // chart is a few hundred points wide. Drawing every one is wasted work
        // and an unreadable line.
        let prepared = PreparedNight(points: night)
        for (id, series) in prepared.series {
            XCTAssertLessThanOrEqual(series.count, PreparedNight.seriesBuckets,
                                     "\(id) was not bucketed")
        }
    }

    func testASeriesIsInChronologicalOrder() {
        let prepared = PreparedNight(points: night)
        for (id, series) in prepared.series {
            let dates = series.map(\.date)
            XCTAssertEqual(dates, dates.sorted(), "\(id) is out of order")
        }
    }

    func testABucketAveragesTheSamplesInsideIt() {
        // Two samples in one bucket average; the mean of the whole series must
        // still land on the metric's night average, which the header prints.
        let prepared = PreparedNight(points: night)
        guard let hr = activityMetricDefs.first(where: { $0.techLabel == "HR" }),
              let series = prepared.series[hr.id], !series.isEmpty,
              let average = prepared.averages[hr.id] else {
            return XCTFail("heart rate should be present in a real night")
        }
        let seriesMean = series.map(\.value).reduce(0, +) / Double(series.count)
        XCTAssertEqual(seriesMean, average, accuracy: max(1, abs(average) * 0.1),
                       "the line and the printed average describe the same night")
    }

    func testWakeBandsMarkTheStretchesSpentAwake() {
        let prepared = PreparedNight(points: night)
        let stages = SleepStages.detailed(night)
        guard stages.contains(.wake) else { return XCTFail("fixture has no wake") }

        XCTAssertFalse(prepared.wakeBands.isEmpty,
                       "the night has wake ticks, so it has wake bands")
        // Every band must sit inside the night and be non-empty.
        for band in prepared.wakeBands {
            XCTAssertLessThan(band.start, band.end)
            XCTAssertGreaterThanOrEqual(band.start, night.first!.timestamp)
            XCTAssertLessThanOrEqual(band.end, night.last!.timestamp)
        }
        // Bands must not overlap — they are contiguous runs, merged.
        for (a, b) in zip(prepared.wakeBands, prepared.wakeBands.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "wake bands overlap")
        }
    }

    func testAnEmptyNightHasNoSeriesAndNoBands() {
        let prepared = PreparedNight(points: [])
        XCTAssertTrue(prepared.series.isEmpty)
        XCTAssertTrue(prepared.wakeBands.isEmpty)
    }
}
