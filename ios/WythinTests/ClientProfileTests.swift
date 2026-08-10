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

    // MARK: Unit conversion

    func testFeetInchesToCentimetres() {
        XCTAssertEqual(BodyUnits.cm(feet: 5, inches: 9),  175)   // US male average
        XCTAssertEqual(BodyUnits.cm(feet: 5, inches: 4),  163)   // US female average
        XCTAssertEqual(BodyUnits.cm(feet: 6, inches: 0),  183)
        XCTAssertEqual(BodyUnits.cm(feet: 4, inches: 11), 150)
    }

    func testCentimetresToFeetInches() {
        let a = BodyUnits.feetInches(fromCm: 175)
        XCTAssertEqual(a.feet, 5); XCTAssertEqual(a.inches, 9)

        let b = BodyUnits.feetInches(fromCm: 183)
        XCTAssertEqual(b.feet, 6); XCTAssertEqual(b.inches, 0)
    }

    /// 12 inches must roll up into a foot — 5'12" is not a height.
    func testInchesNeverRenderAsTwelve() {
        for cm in OnboardingValidation.heightRangeCm {
            let r = BodyUnits.feetInches(fromCm: cm)
            XCTAssertLessThan(r.inches, 12, "\(cm)cm rendered as \(r.feet)'\(r.inches)\"")
            XCTAssertGreaterThanOrEqual(r.inches, 0)
        }
    }

    func testPoundsAndKilogramsConvertBothWays() {
        XCTAssertEqual(BodyUnits.kg(fromPounds: 200), 91)
        XCTAssertEqual(BodyUnits.kg(fromPounds: 171), 78)
        XCTAssertEqual(BodyUnits.pounds(fromKg: 90), 198)
        XCTAssertEqual(BodyUnits.pounds(fromKg: 77), 170)
    }

    /// Switching units repeatedly must not walk a value away from itself. The
    /// UI re-renders from the stored metric each time for exactly this reason;
    /// this pins the property the UI depends on.
    func testUnitRoundTripIsStableAcrossRepeatedConversions() {
        for start in stride(from: 45, through: 160, by: 5) {
            var kg = start
            for _ in 0..<10 { kg = BodyUnits.kg(fromPounds: BodyUnits.pounds(fromKg: kg)) }
            XCTAssertEqual(kg, start, "weight drifted from \(start) to \(kg)")
        }
        for start in stride(from: 140, through: 210, by: 1) {
            var cm = start
            for _ in 0..<10 {
                let r = BodyUnits.feetInches(fromCm: cm)
                cm = BodyUnits.cm(feet: r.feet, inches: r.inches)
            }
            XCTAssertLessThanOrEqual(abs(cm - start), 1, "height drifted from \(start) to \(cm)")
        }
    }

    func testBodyDefaultsAreInsideTheAcceptedRanges() {
        for g in ["Male", "Female", "Non-binary", "Prefer not to say", nil] {
            XCTAssertTrue(OnboardingValidation.heightRangeCm.contains(BodyDefaults.heightCm(gender: g)))
            XCTAssertTrue(OnboardingValidation.weightRangeKg.contains(BodyDefaults.weightKg(gender: g)))
        }
    }

    func testUnitSystemDefaultsToUS() {
        let d = makeDefaults()
        XCTAssertNil(d.string(forKey: UnitSystem.defaultsKey))
        XCTAssertEqual(UnitSystem(rawValue: d.string(forKey: UnitSystem.defaultsKey) ?? "us"), .us)
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
