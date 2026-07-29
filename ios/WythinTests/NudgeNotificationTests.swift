import XCTest
import UserNotifications
@testable import Wythin

/// The menu is delivered as notification actions, so the user can pick an
/// alternate without opening the app. That makes the identifier round-trip
/// load-bearing: get it wrong and a tap opens the wrong practice.
final class NudgeNotificationTests: XCTestCase {

    private func menu(_ id: NudgeTriggerID) -> [NudgeIntervention] {
        NudgeInterventionLibrary.menu(for: id)
    }

    func testActionIdentifiersRoundTrip() {
        for option in NudgeInterventionLibrary.all {
            let identifier = NudgeNotification.actionIdentifier(option.id)
            XCTAssertEqual(NudgeNotification.intervention(fromAction: identifier), option.id)
        }
    }

    func testAnUnknownActionIdentifierResolvesToNothing() {
        XCTAssertNil(NudgeNotification.intervention(fromAction: "something.else"))
    }

    /// Tapping the notification body means "the one you suggested".
    func testTappingTheBodyResolvesToNoSpecificOption() {
        XCTAssertNil(NudgeNotification.intervention(fromAction: UNNotificationDefaultActionIdentifier))
    }

    func testDismissActionIsRecognised() {
        XCTAssertTrue(NudgeNotification.isDismissal(NudgeNotification.dismissActionIdentifier))
        XCTAssertFalse(NudgeNotification.isDismissal(
            NudgeNotification.actionIdentifier(.walk)))
    }

    // MARK: Categories

    func testACategoryIsBuiltPerTriggerWithItsOwnMenu() {
        let categories = NudgeNotification.categories()
        let ids = Set(categories.map(\.identifier))
        for trigger in NudgeTriggerID.allCases where trigger.isDownshift {
            XCTAssertTrue(ids.contains(trigger.rawValue), "no category for \(trigger.rawValue)")
        }
    }

    /// The focus window never pushes, so it needs no category.
    func testTheFocusWindowHasNoCategory() {
        let ids = Set(NudgeNotification.categories().map(\.identifier))
        XCTAssertFalse(ids.contains(NudgeTriggerID.focusWindow.rawValue))
    }

    func testACategoryCarriesEveryAlternatePlusADismissal() {
        let category = NudgeNotification.category(for: .vagalWithdrawal,
                                                  options: menu(.vagalWithdrawal))
        // The primary is the body tap, so only the alternates become buttons.
        let expected = max(menu(.vagalWithdrawal).count - 1, 0) + 1   // + "not now"
        XCTAssertEqual(category.actions.count, expected)
        XCTAssertEqual(category.actions.last?.identifier,
                       NudgeNotification.dismissActionIdentifier)
    }

    func testCategoryActionsAreLabelledForHumans() {
        let category = NudgeNotification.category(for: .stuckStill, options: menu(.stuckStill))
        for action in category.actions {
            XCTAssertFalse(action.title.isEmpty)
        }
    }
}
