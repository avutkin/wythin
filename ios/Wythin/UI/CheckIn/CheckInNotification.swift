import Foundation
import UserNotifications

/// The moment ask as a local notification, scheduled ahead of time because
/// the app is usually asleep when it comes due. No category and no action
/// buttons: the tap opens the app, and the coordinator reads the ledger.
enum CheckInNotification {
    /// One fixed identifier, so a re-schedule replaces the pending request.
    static let identifier = "wythin.checkin.moment"
    /// userInfo key the app delegate recognises a check-in by. Deliberately
    /// not `NudgeNotification.triggerKey`, which the nudge router keys on.
    static let kindKey = "checkin"

    static func isCheckIn(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[kindKey] != nil
    }

    static func request(fireAt: Date, now: Date = .now) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = CheckInKind.moment.title
        content.body = "A few seconds, five sliders. Tap to answer."
        content.userInfo = [kindKey: CheckInKind.moment.wireValue]
        content.sound = .default
        content.interruptionLevel = .active
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(fireAt.timeIntervalSince(now), 1),
                                                        repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }
}

/// What the coordinator needs from the notification centre, narrow enough
/// to fake in tests.
protocol CheckInNotifying: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func schedule(fireAt: Date, now: Date) async
    func cancelPending()
    func clearDelivered()
}

final class CheckInNotificationService: CheckInNotifying {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(fireAt: Date, now: Date) async {
        try? await center.add(CheckInNotification.request(fireAt: fireAt, now: now))
    }

    func cancelPending() {
        center.removePendingNotificationRequests(withIdentifiers: [CheckInNotification.identifier])
    }

    func clearDelivered() {
        center.removeDeliveredNotifications(withIdentifiers: [CheckInNotification.identifier])
    }
}
