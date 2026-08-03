import XCTest
@testable import Wythin

final class ClientProfileTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "ClientProfileTests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "ClientProfileTests")
        return d
    }

    // MARK: Store round-trip

    func testStoreLoadReturnsEmptyProfileWhenNothingSaved() {
        let store = ClientProfileStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), ClientProfile())
    }

    func testStoreSaveThenLoadRoundTrips() {
        let defaults = makeDefaults()
        let store = ClientProfileStore(defaults: defaults)
        var profile = ClientProfile()
        profile.firstName = "Ada"
        profile.lastName = "Lovelace"
        profile.phone = "5551234567"
        profile.email = "a@b.com"
        profile.ageRange = "25–34"
        profile.gender = "Female"
        profile.heightCm = 168
        profile.weightKg = 61
        profile.goals = ["Improve sleep", "Reduce anxiety"]
        profile.practices = ["Breathwork"]
        profile.devices = ["Oura Ring", "Just this app"]
        profile.state = CurrentState(focus: 6, anxiety: 7, energy: 4, sleepQuality: 5, stress: 8)

        store.save(profile)
        XCTAssertEqual(ClientProfileStore(defaults: defaults).load(), profile)
    }

    // MARK: Forward/backward compatibility
    //
    // The whole reason ClientProfile has a hand-written init(from:). A profile
    // written by an older build has none of the newer keys; decoding must keep
    // what is there instead of throwing, because a throw is indistinguishable
    // from "nothing saved" and would wipe the user's answers.

    func testDecodesLegacyProfileMissingNewKeys() throws {
        let legacy = """
        {"phone":"5551234567","email":"a@b.com","ageRange":"25–34","gender":"Female",
         "goals":["Improve sleep"],"practices":["Yoga"],"devices":["Whoop"]}
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(ClientProfile.self, from: legacy)

        XCTAssertEqual(profile.phone, "5551234567")
        XCTAssertEqual(profile.goals, ["Improve sleep"])
        XCTAssertEqual(profile.practices, ["Yoga"])
        XCTAssertEqual(profile.devices, ["Whoop"])
        // New fields fall back to their empty values rather than failing the decode.
        XCTAssertEqual(profile.firstName, "")
        XCTAssertNil(profile.heightCm)
        XCTAssertEqual(profile.state, CurrentState())
    }

    func testLoadKeepsLegacyProfileInsteadOfBlankingIt() {
        let defaults = makeDefaults()
        let legacy = #"{"phone":"5551234567","email":"a@b.com","goals":["Boost energy"]}"#
            .data(using: .utf8)!
        defaults.set(legacy, forKey: ClientProfileStore.key)

        let loaded = ClientProfileStore(defaults: defaults).load()

        XCTAssertEqual(loaded.phone, "5551234567")
        XCTAssertEqual(loaded.goals, ["Boost energy"])
        XCTAssertNotEqual(loaded, ClientProfile(), "legacy profile must not decode to a blank one")
    }

    func testDecodesEmptyObject() throws {
        let profile = try JSONDecoder().decode(ClientProfile.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(profile, ClientProfile())
    }

    // MARK: CurrentState

    func testCurrentStateIsAnsweredOnlyWhenSomethingIsSet() {
        XCTAssertFalse(CurrentState().isAnswered)
        XCTAssertTrue(CurrentState(stress: 0).isAnswered, "zero is an answer, not an absence")
        XCTAssertTrue(CurrentState(focus: 5).isAnswered)
    }

    func testCurrentStateRoundTripsThroughJSON() throws {
        let state = CurrentState(focus: 0, anxiety: 10, energy: nil, sleepQuality: 3, stress: 7)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(CurrentState.self, from: data), state)
    }

    // MARK: Consent defaults
    //
    // Guards the divergence bug: @AppStorage applies its default without writing
    // the key, so a plain UserDefaults.bool read returns false for a switch the
    // user saw as on. The UI and the sync payload must agree.

    func testConsentReadsDefaultWhenKeyWasNeverWritten() {
        let defaults = makeDefaults()
        XCTAssertNil(defaults.object(forKey: OnboardingConsent.shareWithTeamKey))
        XCTAssertEqual(OnboardingConsent.shareWithTeam(in: defaults),
                       OnboardingConsent.shareWithTeamDefault)
        XCTAssertEqual(OnboardingConsent.aiInsights(in: defaults),
                       OnboardingConsent.aiInsightsDefault)
    }

    func testConsentHonoursAnExplicitFalse() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: OnboardingConsent.aiInsightsKey)
        XCTAssertFalse(OnboardingConsent.aiInsights(in: defaults),
                       "an explicit opt-out must never be overridden by the default")
    }

    func testConsentHonoursAnExplicitTrue() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: OnboardingConsent.shareWithTeamKey)
        XCTAssertTrue(OnboardingConsent.shareWithTeam(in: defaults))
    }

    // MARK: Phone validation

    func testPhoneValidation() {
        XCTAssertFalse(OnboardingValidation.isValidPhone(""))
        XCTAssertFalse(OnboardingValidation.isValidPhone("12345"))       // 5 digits
        XCTAssertTrue(OnboardingValidation.isValidPhone("5551234"))       // 7 digits
        XCTAssertTrue(OnboardingValidation.isValidPhone("(555) 123-4567")) // digits ≥ 7 after stripping
    }

    // MARK: Email validation

    func testEmailValidation() {
        XCTAssertFalse(OnboardingValidation.isValidEmail(""))
        XCTAssertFalse(OnboardingValidation.isValidEmail("nope"))
        XCTAssertFalse(OnboardingValidation.isValidEmail("a@b"))
        XCTAssertFalse(OnboardingValidation.isValidEmail("a@b."))
        XCTAssertTrue(OnboardingValidation.isValidEmail("a@b.com"))
        XCTAssertTrue(OnboardingValidation.isValidEmail("First.Last@Example.co.uk"))
    }

    // MARK: Name validation

    func testNameValidation() {
        XCTAssertFalse(OnboardingValidation.isValidName(""))
        XCTAssertFalse(OnboardingValidation.isValidName("   "))
        XCTAssertTrue(OnboardingValidation.isValidName("Ada"))
        XCTAssertTrue(OnboardingValidation.isValidName("Ó"))
    }
}
