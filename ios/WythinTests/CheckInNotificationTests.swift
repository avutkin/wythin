import XCTest
import UserNotifications
@testable import Wythin

/// The moment ask is handed to the OS ahead of time, because the app is
/// usually asleep when it comes due. What matters is the request being
/// recognisable on the way back in, and the timing being what was asked.
final class CheckInNotificationTests: XCTestCase {

    func testTheRequestFiresAtTheAskedTime() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = CheckInNotification.request(fireAt: now.addingTimeInterval(600), now: now)
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 600, accuracy: 0.5)
        XCTAssertFalse(trigger.repeats)
    }

    /// A fire time already in the past (the process was suspended through it)
    /// still schedules — as soon as possible, never a negative interval.
    func testAFireTimeInThePastSchedulesAsSoonAsPossible() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = CheckInNotification.request(fireAt: now.addingTimeInterval(-300), now: now)
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertGreaterThanOrEqual(trigger.timeInterval, 1)
    }

    /// One fixed identifier, so a re-schedule replaces the pending request
    /// instead of stacking a second banner.
    func testTheIdentifierIsFixed() {
        let now = Date()
        let a = CheckInNotification.request(fireAt: now.addingTimeInterval(60), now: now)
        let b = CheckInNotification.request(fireAt: now.addingTimeInterval(120), now: now)
        XCTAssertEqual(a.identifier, b.identifier)
        XCTAssertEqual(a.identifier, CheckInNotification.identifier)
    }

    func testTheTapIsRecognisableAndNeverMistakenForANudge() {
        let request = CheckInNotification.request(fireAt: Date(), now: Date())
        XCTAssertTrue(CheckInNotification.isCheckIn(request.content.userInfo))
        XCTAssertNil(request.content.userInfo[NudgeNotification.triggerKey],
                     "the nudge router keys on this; a check-in must not carry it")
        XCTAssertFalse(CheckInNotification.isCheckIn([:]))
    }

    func testTheCopyAsksTheQuestion() {
        let request = CheckInNotification.request(fireAt: Date(), now: Date())
        XCTAssertEqual(request.content.title, CheckInKind.moment.title)
        XCTAssertFalse(request.content.body.isEmpty)
    }
}
