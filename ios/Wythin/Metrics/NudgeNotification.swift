import Foundation
import UserNotifications

/// Turns a nudge into a local notification, and a tap back into an intention.
///
/// Delivery is a local notification posted from a process that is already
/// awake: `bluetooth-central` keeps the app running on the strap's stream, so
/// the engine can post with `trigger: nil` the moment a rule fires. No push
/// server, no APNs. The corollary is that no strap means no nudge at all.
enum NudgeNotification {

    static let actionPrefix = "wythin.nudge.option."
    static let dismissActionIdentifier = "wythin.nudge.dismiss"
    static let triggerKey = "trigger"

    // MARK: Identifiers

    static func actionIdentifier(_ id: NudgeInterventionID) -> String {
        actionPrefix + id.rawValue
    }

    /// Which option the user picked, or nil when they tapped the body — which
    /// means "the one you suggested" — or dismissed.
    static func intervention(fromAction identifier: String) -> NudgeInterventionID? {
        guard identifier.hasPrefix(actionPrefix) else { return nil }
        return NudgeInterventionID(rawValue: String(identifier.dropFirst(actionPrefix.count)))
    }

    static func isDismissal(_ identifier: String) -> Bool {
        identifier == dismissActionIdentifier || identifier == UNNotificationDismissActionIdentifier
    }

    // MARK: Categories

    /// One category per downshift trigger, since each has a different menu.
    /// The focus window never pushes, so it has none.
    static func categories(disabled: Set<NudgeInterventionID> = [],
                           pacerHoldsAvailable: Bool = false) -> [UNNotificationCategory] {
        NudgeTriggerID.allCases.filter(\.isDownshift).map { trigger in
            category(for: trigger,
                     options: NudgeInterventionLibrary.menu(for: trigger,
                                                            disabled: disabled,
                                                            pacerHoldsAvailable: pacerHoldsAvailable))
        }
    }

    /// The primary is the notification body itself, so only the alternates
    /// become buttons — opening the app to choose how to calm down is friction
    /// the menu exists to remove.
    static func category(for trigger: NudgeTriggerID,
                         options: [NudgeIntervention]) -> UNNotificationCategory {
        var actions = options.dropFirst().map { option in
            UNNotificationAction(identifier: actionIdentifier(option.id),
                                 title: option.title,
                                 options: [.foreground])
        }
        actions.append(UNNotificationAction(identifier: dismissActionIdentifier,
                                            title: "Not now",
                                            options: []))
        return UNNotificationCategory(identifier: trigger.rawValue,
                                      actions: Array(actions),
                                      intentIdentifiers: [],
                                      options: [])
    }

    // MARK: Content

    static func request(for trigger: NudgeTriggerID, content: NudgeContent) -> UNNotificationRequest {
        let payload = UNMutableNotificationContent()
        payload.title = content.title
        payload.body = content.body
        payload.categoryIdentifier = trigger.rawValue
        payload.userInfo = [triggerKey: trigger.rawValue]
        payload.sound = .default
        payload.interruptionLevel = .active
        // nil trigger: deliver now, from live code, with the state that caused
        // it still in memory.
        return UNNotificationRequest(identifier: "wythin.nudge.\(trigger.rawValue)",
                                     content: payload,
                                     trigger: nil)
    }
}

// MARK: - Delivery

protocol NudgeDelivering: AnyObject {
    func refreshCategories(disabled: Set<NudgeInterventionID>, pacerHoldsAvailable: Bool)
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func deliver(_ content: NudgeContent, trigger: NudgeTriggerID) async
}

final class NudgeNotificationService: NudgeDelivering {

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func refreshCategories(disabled: Set<NudgeInterventionID>, pacerHoldsAvailable: Bool) {
        center.setNotificationCategories(
            Set(NudgeNotification.categories(disabled: disabled,
                                             pacerHoldsAvailable: pacerHoldsAvailable)))
    }

    /// Asked with evidence at the end of shadow mode, never on first launch —
    /// a cold permission prompt gets denied by reflex.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func deliver(_ content: NudgeContent, trigger: NudgeTriggerID) async {
        try? await center.add(NudgeNotification.request(for: trigger, content: content))
    }
}
