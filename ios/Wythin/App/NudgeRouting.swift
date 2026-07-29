import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// What the user asked for by tapping a notification.
struct NudgeAction: Equatable {
    let trigger: NudgeTriggerID
    /// Which option they picked. Tapping the body means "the one you
    /// suggested", which resolves to the menu's primary.
    let intervention: NudgeInterventionID
}

/// A nudge shown as a card because the app is already open.
struct InAppNudge: Equatable, Identifiable {
    let trigger: NudgeTriggerID
    let content: NudgeContent
    var id: String { trigger.rawValue }
}

/// Carries a notification tap from the app delegate to the UI.
///
/// A tap can arrive before any view is listening — iOS may relaunch the app to
/// deliver it — so an action with nowhere to go is buffered rather than lost.
@MainActor
final class NudgeRouter {

    static let shared = NudgeRouter()

    var handler: ((NudgeAction) -> Void)? {
        didSet { drain() }
    }
    /// Recorded when the user chooses "Not now", so dismissals can be counted.
    var onDismiss: ((NudgeTriggerID) -> Void)?

    private var pending: NudgeAction?

    func route(_ action: NudgeAction) {
        pending = action
        drain()
    }

    func dismissed(_ trigger: NudgeTriggerID) {
        onDismiss?(trigger)
    }

    private func drain() {
        guard let action = pending, let handler else { return }
        pending = nil
        handler(action)
    }
}

/// The app has no delegate of its own — it is a pure SwiftUI `@main` — but
/// `UNUserNotificationCenterDelegate` needs one, so this exists solely to give
/// notification taps somewhere to land.
final class WythinAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Foreground: deliberately no banner.
    ///
    /// The in-app card carries the same nudge instead. A banner over the screen
    /// already showing that state is noise.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[NudgeNotification.triggerKey] as? String,
              let trigger = NudgeTriggerID(rawValue: raw) else { return }

        let identifier = response.actionIdentifier

        if NudgeNotification.isDismissal(identifier) {
            await MainActor.run { NudgeRouter.shared.dismissed(trigger) }
            return
        }

        // A body tap carries no option: honour the suggestion that was made.
        let picked = NudgeNotification.intervention(fromAction: identifier)
            ?? NudgeInterventionLibrary.menu(for: trigger).first?.id

        guard let picked else { return }
        await MainActor.run {
            NudgeRouter.shared.route(NudgeAction(trigger: trigger, intervention: picked))
        }
    }
}
