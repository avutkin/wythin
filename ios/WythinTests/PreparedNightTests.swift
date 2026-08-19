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
}
