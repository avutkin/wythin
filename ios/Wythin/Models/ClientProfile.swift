import Foundation

// MARK: - CurrentState

/// Self-reported baseline captured on one screen during onboarding. Each value
/// is 0…10, or nil when the user skipped that slider. Stored alongside the
/// profile so the first objective readings have something subjective to sit
/// against.
struct CurrentState: Codable, Equatable {
    var focus:        Int? = nil
    var anxiety:      Int? = nil
    var energy:       Int? = nil
    var sleepQuality: Int? = nil
    var stress:       Int? = nil

    /// True once the user has moved at least one slider.
    var isAnswered: Bool {
        [focus, anxiety, energy, sleepQuality, stress].contains { $0 != nil }
    }
}

// MARK: - ClientProfile

/// Profile collected during first-launch onboarding. Stored locally as JSON in
/// UserDefaults (not SwiftData) so it never touches the model schema — the app
/// deletes its SwiftData store on schema mismatch, which would risk HRV data.
struct ClientProfile: Codable, Equatable {
    var firstName: String   = ""
    var lastName:  String   = ""
    var phone:     String   = ""
    var email:     String   = ""
    var ageRange:  String?  = nil
    var gender:    String?  = nil
    var heightCm:  Int?     = nil
    var weightKg:  Int?     = nil
    var goals:     [String] = []
    var practices: [String] = []
    var devices:   [String] = []
    var state:     CurrentState = CurrentState()

    init() {}

    /// Decoded field by field with `decodeIfPresent`, never all-or-nothing.
    ///
    /// The synthesized initializer throws when any non-optional key is absent,
    /// and `ClientProfileStore.load` turns a throw into a blank profile — so a
    /// release that adds one field would silently wipe every existing user's
    /// answers. Tolerating missing keys makes that failure impossible, and it
    /// costs one initializer.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstName = try c.decodeIfPresent(String.self,       forKey: .firstName) ?? ""
        lastName  = try c.decodeIfPresent(String.self,       forKey: .lastName)  ?? ""
        phone     = try c.decodeIfPresent(String.self,       forKey: .phone)     ?? ""
        email     = try c.decodeIfPresent(String.self,       forKey: .email)     ?? ""
        ageRange  = try c.decodeIfPresent(String.self,       forKey: .ageRange)
        gender    = try c.decodeIfPresent(String.self,       forKey: .gender)
        heightCm  = try c.decodeIfPresent(Int.self,          forKey: .heightCm)
        weightKg  = try c.decodeIfPresent(Int.self,          forKey: .weightKg)
        goals     = try c.decodeIfPresent([String].self,     forKey: .goals)     ?? []
        practices = try c.decodeIfPresent([String].self,     forKey: .practices) ?? []
        devices   = try c.decodeIfPresent([String].self,     forKey: .devices)   ?? []
        state     = try c.decodeIfPresent(CurrentState.self, forKey: .state)     ?? CurrentState()
    }
}

// MARK: - Consent
//
// Single source of truth for the two data-sharing switches. Both the SwiftUI
// screens and the sync layer read their defaults from here, because they cannot
// read them from the same mechanism: `@AppStorage` applies its default without
// writing the key, while `UserDefaults.bool(forKey:)` returns `false` for a key
// that was never written. Left to drift, a user who saw both switches ON and
// never touched them would have synced consent as `false` — the UI and the
// server disagreeing about what was agreed to, which is the one thing a consent
// flag must never do.

/// Who actually receives the metrics when AI guidance is on.
///
/// A single constant because the consent screen must name the real processor,
/// and the real processor is whatever `/insights` calls — today `AsyncOpenAI`
/// with `gpt-4o-mini`, in `server/routers/insights.py`. Naming a different
/// company on the consent screen than the one receiving the data is not a copy
/// nit; it makes the disclosure false. When the backend moves to Anthropic,
/// change `name` here and the row, the sheet and any future surface all follow.
enum AIProvider {
    static let name    = "OpenAI"
    static let company = "OpenAI"
}

enum OnboardingConsent {
    static let shareWithTeamKey = "shareWithTeam"
    static let aiInsightsKey    = "aiInsightsEnabled"

    /// Change these to flip what a fresh install starts with. Nothing else.
    static let shareWithTeamDefault = true
    static let aiInsightsDefault    = true

    static func value(forKey key: String, default fallback: Bool,
                      in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    static func shareWithTeam(in defaults: UserDefaults = .standard) -> Bool {
        value(forKey: shareWithTeamKey, default: shareWithTeamDefault, in: defaults)
    }

    static func aiInsights(in defaults: UserDefaults = .standard) -> Bool {
        value(forKey: aiInsightsKey, default: aiInsightsDefault, in: defaults)
    }

    // MARK: Mandatory consent
    //
    // Data sharing is a condition of finishing onboarding: decline and the flow
    // stops. Kept here as plain predicates rather than inline `&&` in a view so
    // the rule is stated once, testable, and greppable when it changes.
    //
    // Worth knowing what this costs, because it is not only a product choice:
    // GDPR Art. 7(4) says consent isn't freely given where a service is
    // conditional on processing not necessary to deliver it, and App Review
    // 5.1.1(ii) rejects apps that gate core functionality on unrelated data
    // sharing. Team sharing is defensible on those terms — coaching genuinely
    // requires a coach to see the data. Third-party model processing is the
    // weaker of the two, since reading the strap needs no such thing.
    // Making either optional again is one `false` below.
    static let shareWithTeamIsMandatory = true
    static let aiInsightsIsMandatory    = true
    static let cloudSyncIsMandatory     = true

    /// Gate for the connect step's two sharing switches.
    static func canProceedFromSharing(shareWithTeam: Bool, aiInsights: Bool) -> Bool {
        (!shareWithTeamIsMandatory || shareWithTeam)
            && (!aiInsightsIsMandatory || aiInsights)
    }

    /// Gate for the final permissions step. Nudges are deliberately absent:
    /// notification delivery is granted by iOS, not by us, so requiring it would
    /// be a promise we can't keep — a user who denies the system prompt would be
    /// locked out by a switch that says yes.
    static func canFinishOnboarding(cloudSync: Bool) -> Bool {
        !cloudSyncIsMandatory || cloudSync
    }
}

// MARK: - Validation helpers

enum OnboardingValidation {
    /// Light phone check: at least 7 digits after stripping non-digits.
    static func isValidPhone(_ raw: String) -> Bool {
        raw.filter(\.isNumber).count >= 7
    }

    /// Basic email shape check — good enough to gate a Continue button.
    static func isValidEmail(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pattern = #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#
        return trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A name is anything non-blank; we are not in the business of telling
    /// people their name is wrong.
    static func isValidName(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Plausible adult range, wide enough not to reject real people.
    static let heightRangeCm = 120...220
    static let weightRangeKg = 30...250
}

// MARK: - ClientProfileStore

/// Loads/saves the ClientProfile as JSON under a single UserDefaults key.
struct ClientProfileStore {
    static let key = "clientProfile"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ClientProfile {
        guard let data = defaults.data(forKey: Self.key),
              let profile = try? JSONDecoder().decode(ClientProfile.self, from: data)
        else { return ClientProfile() }
        return profile
    }

    func save(_ profile: ClientProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
