import XCTest
@testable import Wythin

final class HealthAnalysisTests: XCTestCase {
    let origin = Date(timeIntervalSince1970: 10000)
    let source = HealthSourceInfo(bundleIdentifier: "test.watch", name: "Watch")
    var workout: HealthWorkout { HealthWorkout(id: UUID(), activityCode: 37, activityName: "Running", startedAt: origin, endedAt: origin.addingTimeInterval(600), activeDurationSeconds: 600, source: source) }
    func sample(_ seconds: Double, _ value: Double, metric: HealthMetric = .heartRate, duration: Double = 0) -> HealthSample {
        HealthSample(id: UUID(), metric: metric, value: value, startedAt: origin.addingTimeInterval(seconds), endedAt: origin.addingTimeInterval(seconds + duration), source: source)
    }
    func testBoundaryBelongsToExactlyOneWindowAndEmptyIsNotZero() {
        let result = HealthAnalysis.compute(workout: workout, samples: [sample(-300, 60), sample(0, 100), sample(600, 80), sample(1200, 70)], now: origin.addingTimeInterval(2000))
        XCTAssertEqual(result.statistics.first { $0.window == .before }?.mean, 60)
        XCTAssertEqual(result.statistics.first { $0.window == .during }?.mean, 100)
        XCTAssertEqual(result.statistics.first { $0.window == .after }?.mean, 75)
        XCTAssertEqual(HealthAnalysis.compute(workout: workout, samples: [], now: origin.addingTimeInterval(2000)).status, "no_data")
    }
    func testSparseHRRCannotInterpolateAcrossLongGap() {
        let result = HealthAnalysis.compute(workout: workout, samples: [sample(600, 150), sample(610, 140), sample(1100, 80)])
        XCTAssertNil(result.hrr60)
    }
    func testMeasuredHRRAndSeparateSDNN() {
        let result = HealthAnalysis.compute(workout: workout, samples: [sample(600, 150), sample(650, 125), sample(670, 115), sample(0, 35, metric: .sdnn)])
        XCTAssertEqual(result.hrr60, 30)
        XCTAssertEqual(result.statistics.first { $0.metric == .sdnn }?.mean, 35)
    }
    func testCoalescedIntervalsAreWeightedAndClipped() {
        let result = HealthAnalysis.compute(workout: workout, samples: [sample(-20, 60, duration: 30), sample(10, 120, duration: 20)])
        XCTAssertEqual(result.statistics.first { $0.window == .during }?.mean, 100)
        XCTAssertEqual(result.statistics.first { $0.window == .during }?.observedSeconds, 30)
    }
    func testOtherSourcesAreNeverAveragedTogether() {
        var other = sample(10, 200); other.source = HealthSourceInfo(bundleIdentifier: "other", name: "Other")
        let result = HealthAnalysis.compute(workout: workout, samples: [sample(0, 60), other])
        XCTAssertEqual(Set(result.statistics.map { $0.mean! }), Set([60, 200]))
    }
    func testCumulativeCrossingBoundaryIsNotInvented() {
        let result = HealthAnalysis.compute(workout: workout, samples: [sample(-10, 100, metric: .steps, duration: 30)])
        XCTAssertNil(result.statistics.first { $0.window == .during }?.total)
        XCTAssertEqual(result.statistics.first { $0.window == .during }?.boundarySamplesOmitted, 1)
    }
    func testSampleParentAndFractionalTimestampSurviveCoding() throws {
        var s = sample(0.125, 100); s.parentId = UUID(); s.workoutIds = [UUID()]
        XCTAssertEqual(try HealthCoding.decode(HealthSample.self, from: HealthCoding.encode(s)), s)
    }
    func testLongIntervalMeansDoNotInventInstantRecovery() {
        let result = HealthAnalysis.compute(workout: workout, samples: [sample(300, 150, duration: 330), sample(630, 100, duration: 270)])
        XCTAssertNil(result.hrr60)
    }
}
