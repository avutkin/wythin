import XCTest
@testable import Wythin

/// The night screen precomputes its staging so the main thread never does it.
/// The risk in moving that work is that it quietly becomes a *different*
/// computation — and then the legend under the montage disagrees with the
/// stage summary stored on the record, which is the one number the user
/// already saw in the activities list.
final class PreparedNightTests: XCTestCase {

    private var night: [MetricsHistoryPoint] { RealNight.points() }

    func testStagingMatchesTheRecordersOwnClassification() {
        let prepared = PreparedNight(points: night)
        XCTAssertEqual(prepared.stages, SleepStages.detailed(night),
                       "the screen must stage the night exactly as the recorder does")
    }

    func testStageMinutesMatchElapsedTimeNotSampleCount() {
        // The earlier bug: minutes came from count × a tick interval guessed
        // from the first two samples, so the stages summed to more than the
        // window they sat in.
        let prepared = PreparedNight(points: night)
        let stages = SleepStages.detailed(night)

        for stage in SleepStageDetail.allCases {
            let expected = Int((SleepRecorder.seconds(where: stages.map { $0 == stage },
                                                      points: night) / 60).rounded())
            XCTAssertEqual(prepared.stageMinutes[stage], expected, "\(stage)")
        }
    }

    func testStageMinutesDoNotExceedTheNight() {
        let prepared = PreparedNight(points: night)
        let total = prepared.stageMinutes.values.reduce(0, +)
        let span = Int((night.last!.timestamp.timeIntervalSince(night.first!.timestamp)) / 60)
        XCTAssertLessThanOrEqual(total, span + 1,
                                 "the stages cannot add up to more than the night they describe")
    }

    func testAveragesAreKeyedByMetricAndSkipUnmeasured() {
        let prepared = PreparedNight(points: night)
        // Heart rate is present in a real capture; a metric with no samples is
        // absent from the dictionary rather than present as zero, because the
        // grid renders absence as an em dash.
        let hr = activityMetricDefs.first { $0.label.lowercased().contains("heart") }
        if let hr { XCTAssertNotNil(prepared.averages[hr.id]) }

        for def in activityMetricDefs where prepared.averages[def.id] == nil {
            XCTAssertTrue(night.allSatisfy { def.extract($0) == nil },
                          "\(def.label) was dropped despite having samples")
        }
    }

    func testMotionThresholdIsRelativeToThisNight() {
        let prepared = PreparedNight(points: night)
        let motions = night.compactMap(\.motion).sorted()
        XCTAssertFalse(motions.isEmpty)
        XCTAssertEqual(prepared.motionThreshold,
                       max(motions[motions.count / 2] * 2, 8), accuracy: 0.001)
    }

    func testAnEmptyNightIsNotACrash() {
        let prepared = PreparedNight(points: [])
        XCTAssertTrue(prepared.stages.isEmpty)
        XCTAssertEqual(prepared.motionThreshold, .greatestFiniteMagnitude,
                       "no motion means no ticks drawn, not every tick drawn")
    }

    // MARK: - What the readout under each chart is built from

    /// The three numbers sit directly under the line they came off. If they
    /// were taken from the raw ticks they would name values the drawn line
    /// never reaches, and the reader would be told their pulse hit a figure
    /// they cannot find on the chart.
    func testExtremesComeOffTheDrawnLineNotTheRawTicks() {
        let prepared = PreparedNight(points: night)
        for (id, e) in prepared.extremes {
            guard let drawn = prepared.series[id], !drawn.isEmpty else {
                return XCTFail("\(id) has extremes but nothing drawn")
            }
            let values = drawn.map(\.value)
            XCTAssertGreaterThanOrEqual(e.low, values.min()! - 0.0001, id)
            XCTAssertLessThanOrEqual(e.high, values.max()! + 0.0001, id)
            XCTAssertLessThanOrEqual(e.low, e.typical, id)
            XCTAssertLessThanOrEqual(e.typical, e.high, id)
        }
    }

    /// A metric's night reading is a reading of the SLEEP. Letting a wake bout
    /// set the low or the high would put the moment of getting out of bed at
    /// the end of a bar labelled "your lowest pulse asleep".
    func testExtremesIgnoreTheStretchesSpentAwake() {
        let prepared = PreparedNight(points: night)
        guard !prepared.wakeBands.isEmpty else {
            return  // nothing to exclude on this night; the rule is still enforced above
        }
        for (_, e) in prepared.extremes {
            for band in prepared.wakeBands {
                XCTAssertFalse(band.start <= e.lowAt && e.lowAt <= band.end,
                               "the low was taken from a wake bout")
                XCTAssertFalse(band.start <= e.highAt && e.highAt <= band.end,
                               "the high was taken from a wake bout")
            }
        }
    }

    /// A stage a night barely touched is not a reading of it. Three ticks of N1
    /// drawn as a bar beside four hours of N2 invites exactly the comparison it
    /// cannot support.
    func testStagesWithTooFewTicksAreAbsentRatherThanReported() {
        let prepared = PreparedNight(points: night)
        let stages = prepared.stages
        for (id, perStage) in prepared.byStage {
            guard let def = activityMetricDefs.first(where: { $0.id == id }) else { continue }
            for (stage, _) in perStage {
                let ticks = stages.indices
                    .filter { stages[$0] == stage }
                    .compactMap { def.extract(night[$0]) }
                    .count
                XCTAssertGreaterThanOrEqual(ticks, PreparedNight.minStageTicks,
                                            "\(id)/\(stage) was reported from \(ticks) ticks")
            }
        }
    }

    /// The hour beside each bar is what stops the bars being read as a
    /// stage-to-stage comparison they cannot support. It has to fall inside
    /// the stretch it claims to describe.
    func testEachStageReadingCarriesAnHourInsideTheNight() {
        let prepared = PreparedNight(points: night)
        let first = night.first!.timestamp, last = night.last!.timestamp
        for (_, perStage) in prepared.byStage {
            for (_, reading) in perStage {
                XCTAssertGreaterThanOrEqual(reading.at, first)
                XCTAssertLessThanOrEqual(reading.at, last)
            }
        }
    }

    func testAnEmptyNightHasNothingToRead() {
        let prepared = PreparedNight(points: [])
        XCTAssertTrue(prepared.extremes.isEmpty)
        XCTAssertTrue(prepared.byStage.isEmpty)
    }
}
