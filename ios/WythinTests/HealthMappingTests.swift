import XCTest
import HealthKit
@testable import Wythin

final class HealthMappingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testRunningAndWalkingDoNotInferIntensityOrSetting() {
        XCTAssertEqual(HealthWorkoutMapping.activityName(for: 37), "Running")
        XCTAssertEqual(HealthWorkoutMapping.activityName(for: 52), "Walking")
    }

    func testUnknownWorkoutCodeIsKeptInNeutralLabel() {
        XCTAssertEqual(HealthWorkoutMapping.activityName(for: 65000), "Workout (65000)")
    }

    func testLongPausedWorkoutKeepsElapsedAndActiveDurationsSeparate() throws {
        let pause = HKWorkoutEvent(type: .pause,
            dateInterval: DateInterval(start: start.addingTimeInterval(3600), duration: 0), metadata: nil)
        let resume = HKWorkoutEvent(type: .resume,
            dateInterval: DateInterval(start: start.addingTimeInterval(4200), duration: 0), metadata: nil)
        let raw = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(14400),
            workoutEvents: [pause, resume], totalEnergyBurned: HKQuantity(unit: .kilocalorie(), doubleValue: 840),
            totalDistance: HKQuantity(unit: .meter(), doubleValue: 24000),
            metadata: [HKMetadataKeyWasUserEntered: true, HKMetadataKeyTimeZone: "America/Los_Angeles",
                       "private_note": "DO_NOT_EXPORT_PRIVATE_METADATA"])
        let mapped = HealthWorkoutMapping.workout(raw)
        XCTAssertEqual(mapped.id, raw.uuid)
        XCTAssertEqual(mapped.activityCode, 37)
        XCTAssertEqual(mapped.endedAt.timeIntervalSince(mapped.startedAt), 14400)
        XCTAssertEqual(mapped.activeDurationSeconds, 13800)
        XCTAssertEqual(mapped.events.map(\.kind), ["pause", "resume"])
        XCTAssertEqual(mapped.events.first?.startedAt, start.addingTimeInterval(3600))
        XCTAssertEqual(mapped.energyKcal, 840)
        XCTAssertEqual(mapped.distanceMeters, 24000)
        XCTAssertEqual(mapped.timezone, "America/Los_Angeles")
        XCTAssertTrue(mapped.userEntered)
        let json = String(decoding: try HealthCoding.encode(mapped), as: UTF8.self)
        XCTAssertFalse(json.contains("DO_NOT_EXPORT_PRIVATE_METADATA"))
    }

    func testMultisportSegmentPreservesItsOwnActivityAndInterval() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        let raw = HKWorkoutActivity(workoutConfiguration: configuration, start: start,
            end: start.addingTimeInterval(900), metadata: ["private_note": "do not export"])
        let mapped = HealthWorkoutMapping.segment(raw, workoutEnd: start.addingTimeInterval(3600))
        XCTAssertEqual(mapped.activityCode, 13)
        XCTAssertEqual(mapped.startedAt, start)
        XCTAssertEqual(mapped.endedAt, start.addingTimeInterval(900))
    }

    func testSDNNNormalizesSecondsToMillisecondsWithoutChangingMetric() {
        let raw = HKQuantitySample(type: HKQuantityType(.heartRateVariabilitySDNN),
            quantity: HKQuantity(unit: .second(), doubleValue: 0.042), start: start, end: start)
        let mapped = HealthWorkoutMapping.sample(raw, metric: .sdnn)
        XCTAssertEqual(mapped.metric, .sdnn)
        XCTAssertEqual(mapped.value, 42, accuracy: 0.000001)
        XCTAssertEqual(mapped.representation, .point)
        XCTAssertEqual(mapped.id, raw.uuid)
        XCTAssertEqual(mapped.parent, raw.uuid)
    }

    func testCoalescedIntervalIsNotTurnedIntoAnInstantaneousPoint() {
        let raw = HKQuantitySample(type: HKQuantityType(.heartRate),
            quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 83),
            start: start, end: start.addingTimeInterval(60))
        let mapped = HealthWorkoutMapping.sample(raw, metric: .heartRate)
        XCTAssertEqual(mapped.representation, .interval)
        XCTAssertEqual(mapped.startedAt, start)
        XCTAssertEqual(mapped.endedAt, start.addingTimeInterval(60))
        XCTAssertEqual(mapped.value, 83)
    }

    func testSeriesChildrenHaveStableDistinctIdentityAndParentDeletionKey() {
        let parent = HKQuantitySample(type: HKQuantityType(.heartRate),
            quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 90),
            start: start, end: start.addingTimeInterval(60))
        let quantity = HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 92)
        let interval = DateInterval(start: start.addingTimeInterval(10), duration: 2)
        let first = HealthWorkoutMapping.seriesPoint(parent: parent, metric: .heartRate,
            index: 0, quantity: quantity, interval: interval)
        let retry = HealthWorkoutMapping.seriesPoint(parent: parent, metric: .heartRate,
            index: 0, quantity: quantity, interval: interval)
        let second = HealthWorkoutMapping.seriesPoint(parent: parent, metric: .heartRate,
            index: 1, quantity: quantity, interval: interval)
        XCTAssertEqual(first.id, retry.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, parent.uuid)
        XCTAssertEqual(first.parentId, parent.uuid)
        XCTAssertEqual(first.representation, .series)
        XCTAssertEqual(first.startedAt, start.addingTimeInterval(10))
        XCTAssertEqual(first.endedAt, start.addingTimeInterval(12))
        XCTAssertEqual(first.value, 92)
    }

    func testEnergyDistanceAndCountUseDocumentedWireUnits() {
        let fixtures: [(HealthMetric, HKQuantityTypeIdentifier, HKUnit, Double, Double)] = [
            (.activeEnergy, .activeEnergyBurned, .joule(), 4184, 1),
            (.walkingRunningDistance, .distanceWalkingRunning, .meterUnit(with: .kilo), 2, 2000),
            (.cyclingDistance, .distanceCycling, .meterUnit(with: .kilo), 3, 3000),
            (.swimmingDistance, .distanceSwimming, .meter(), 25, 25),
            (.steps, .stepCount, .count(), 123, 123)
        ]
        for (metric, type, unit, value, expected) in fixtures {
            let raw = HKQuantitySample(type: HKQuantityType(type), quantity: HKQuantity(unit: unit, doubleValue: value),
                start: start, end: start.addingTimeInterval(10))
            XCTAssertEqual(HealthWorkoutMapping.sample(raw, metric: metric).value, expected, accuracy: 0.000001)
        }
    }

    func testSourcePageCountsDeletionsTowardLimit() {
        let raw = HKQuantitySample(type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 123), start: start, end: start)
        let page = HealthAnchoredPage(objects: [raw], deletedIDs: [UUID()],
            anchor: HKQueryAnchor(fromValue: 1), limit: 2)
        XCTAssertTrue(page.hasMore)
        let last = HealthAnchoredPage(objects: [raw], deletedIDs: [],
            anchor: HKQueryAnchor(fromValue: 2), limit: 2)
        XCTAssertFalse(last.hasMore)
    }

    func testSecureAnchorRoundTripAndCorruptAnchorFailure() throws {
        let original = HKQueryAnchor(fromValue: 456)
        let encoded = try HealthKitSource.encodeAnchor(original)
        XCTAssertEqual(try HealthKitSource.decodeAnchor(encoded), original)
        XCTAssertNil(try HealthKitSource.decodeAnchor(nil))
        XCTAssertThrowsError(try HealthKitSource.decodeAnchor(Data("corrupt".utf8)))
    }

    func testSeriesDoesNotPublishPartialValuesOrLoseFinalCallbackQuantity() throws {
        let quantity = HKQuantity(unit: .count(), doubleValue: 42)
        let parent = HKQuantitySample(type: HKQuantityType(.stepCount), quantity: quantity, start: start, end: start)
        let collector = HealthSeriesCollector(parent: parent, metric: .steps)
        XCTAssertNil(collector.receive(quantity: nil, interval: nil, done: false, error: nil))
        let result = try XCTUnwrap(collector.receive(quantity: quantity,
            interval: DateInterval(start: start, duration: 0), done: true, error: nil)).get()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.value, 42)
        XCTAssertEqual(result.first?.parentId, parent.uuid)
        XCTAssertNil(collector.receive(quantity: quantity,
            interval: DateInterval(start: start, duration: 0), done: true, error: nil))
    }

    func testSeriesFailureDoesNotPublishPartialContainer() throws {
        let quantity = HKQuantity(unit: .count(), doubleValue: 42)
        let parent = HKQuantitySample(type: HKQuantityType(.stepCount), quantity: quantity, start: start, end: start)
        let collector = HealthSeriesCollector(parent: parent, metric: .steps)
        XCTAssertNil(collector.receive(quantity: quantity,
            interval: DateInterval(start: start, duration: 0), done: false, error: nil))
        let failure = try XCTUnwrap(collector.receive(quantity: nil, interval: nil,
            done: true, error: NSError(domain: "SyntheticHealthError", code: 1)))
        XCTAssertThrowsError(try failure.get())
        XCTAssertNil(collector.receive(quantity: nil, interval: nil, done: true, error: nil))
        let empty = HealthSeriesCollector(parent: parent, metric: .steps)
        XCTAssertThrowsError(try XCTUnwrap(empty.receive(quantity: nil, interval: nil, done: true, error: nil)).get())
    }

    func testObserverCompletionIsCalledExactlyOnceAcrossRacingFinishes() {
        let completion = expectation(description: "HealthKit delivery completed")
        completion.assertForOverFulfill = true
        let delivery = HealthObserverCompletion { completion.fulfill() }
        DispatchQueue.concurrentPerform(iterations: 20) { _ in delivery.finish() }
        wait(for: [completion], timeout: 1)
    }
}
