import XCTest
@testable import Wythin

final class LocalizationTests: XCTestCase {
    func testSupportedLanguageUsesPhonePreferenceOrder() {
        XCTAssertEqual(AppLanguage.select(from: ["ru-RU", "en-US"]), .russian)
        XCTAssertEqual(AppLanguage.select(from: ["fr-FR", "ru"]), .russian)
        XCTAssertEqual(AppLanguage.select(from: ["en-GB", "ru"]), .english)
        XCTAssertEqual(AppLanguage.select(from: ["de-DE"]), .english)
    }

    func testRussianCatalogIsBundled() {
        guard let path = Bundle.main.path(forResource: "ru", ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return XCTFail("Russian localization is absent from the app bundle")
        }
        XCTAssertEqual(bundle.localizedString(forKey: "LIVE", value: nil, table: "Localizable"),
                       "СЕЙЧАС")
    }

    func testVisibleCopyAndDurationFollowActiveAppLanguage() {
        let russian = AppLanguage.current == .russian
        XCTAssertEqual(LocalizedCopy.text("Settings"), russian ? "Настройки" : "Settings")
        XCTAssertEqual(LocalizedCopy.format("%ds", 5), russian ? "5 с" : "5s")
    }

    func testInsightRequestEncodesActiveLanguageForServer() throws {
        let payload = LiveStateInsightPayload(mode: "live_state", windowMinutes: 10,
                                              metrics: [:])
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["language"] as? String, AppLanguage.current.rawValue)
    }

    func testUserEnteredSubtypeStaysVerbatim() {
        let custom = ActivityLog(activityType: ActivityType.exercise.rawValue,
                                 activitySubtype: "Sleep")
        XCTAssertEqual(custom.displayName, "Sleep")
        let builtIn = ActivityLog(activityType: ActivityType.exercise.rawValue,
                                  activitySubtype: "Yoga")
        XCTAssertEqual(builtIn.displayName,
                       AppLanguage.current == .russian ? "Йога" : "Yoga")
    }
}
