import XCTest
@testable import Wythin

final class LiveSessionUpdatePolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testUpdatesAreCoalescedToTheInterval() {
        // The strap ticks every two seconds; pushing each one would spend the
        // system's update budget in minutes and get the activity throttled.
        XCTAssertFalse(LiveSessionUpdatePolicy.shouldUpdate(
            last: t0, now: t0.addingTimeInterval(3), strapLost: false))
        XCTAssertTrue(LiveSessionUpdatePolicy.shouldUpdate(
            last: t0, now: t0.addingTimeInterval(10), strapLost: false))
    }

    func testALostStrapGoesThroughImmediately() {
        // A frozen heart rate shown as live is worse than an early update.
        XCTAssertTrue(LiveSessionUpdatePolicy.shouldUpdate(
            last: t0, now: t0.addingTimeInterval(1), strapLost: true))
    }

    func testTheIntervalBoundaryCounts() {
        XCTAssertTrue(LiveSessionUpdatePolicy.shouldUpdate(
            last: t0, now: t0.addingTimeInterval(LiveSessionController.updateInterval),
            strapLost: false))
    }

    func testAFirstUpdateAlwaysPasses() {
        XCTAssertTrue(LiveSessionUpdatePolicy.shouldUpdate(
            last: .distantPast, now: t0, strapLost: false))
    }
}
