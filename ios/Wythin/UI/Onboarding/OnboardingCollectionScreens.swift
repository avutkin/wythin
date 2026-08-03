import SwiftUI

// MARK: - Current state
//
// Five self-report sliders on one screen. Each starts *unset*: the track is
// empty and the value reads "—" until the user touches it, so an untouched
// slider can't be mistaken for a deliberate mid-scale answer. That distinction
// is the whole point of the screen — it becomes the subjective baseline the
// first objective readings are compared against.

struct OnboardingStateSlider: View {
    let title:    String
    let lowLabel: String
    let highLabel: String
    let tint:     Color
    @Binding var value: Int?

    /// Sliders bind to Double; this mirrors the optional into one, defaulting to
    /// the midpoint so an untouched thumb sits centre while still reading as unset.
    private var proxy: Binding<Double> {
        Binding(get: { Double(value ?? 5) },
                set: { value = Int($0.rounded()) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(value.map(String.init) ?? "—")
                    .font(Theme.monoBody)
                    .foregroundStyle(value == nil ? Theme.dim : tint)
                    .monospacedDigit()
            }

            Slider(value: proxy, in: 0...10, step: 1)
                .tint(value == nil ? Theme.border : tint)

            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.dim)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0) out of 10" } ?? "not set")
    }
}

struct OnboardingCurrentStateScreen: View {
    let progress: Double
    @Binding var state: CurrentState
    let onBack:     () -> Void
    let onContinue: () -> Void
    var onSkip:     (() -> Void)? = nil

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: "How are you right now?",
            subtitle: "Drag each one. There are no wrong answers.",
            canContinue: state.isAnswered,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue,
            onSkip: onSkip
        ) {
            VStack(spacing: 22) {
                OnboardingStateSlider(title: "Focus", lowLabel: "SCATTERED", highLabel: "SHARP",
                                      tint: Theme.ulf, value: $state.focus)
                OnboardingStateSlider(title: "Anxiety", lowLabel: "CALM", highLabel: "ON EDGE",
                                      tint: Theme.hrv, value: $state.anxiety)
                OnboardingStateSlider(title: "Energy", lowLabel: "DEPLETED", highLabel: "CHARGED",
                                      tint: Theme.rsa, value: $state.energy)
                OnboardingStateSlider(title: "Sleep quality", lowLabel: "BROKEN", highLabel: "DEEP",
                                      tint: Theme.breathe, value: $state.sleepQuality)
                OnboardingStateSlider(title: "Stress", lowLabel: "EASY", highLabel: "UNDER LOAD",
                                      tint: Theme.warn, value: $state.stress)
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Contact
//
// Name, phone and email on one screen. Splitting these across four steps put
// them at the very end of the flow, one tap apart, which is the worst place to
// spend taps — so they share a screen and Continue gates on all four.

struct OnboardingContactScreen: View {
    let progress: Double
    @Binding var firstName: String
    @Binding var lastName:  String
    @Binding var phone:     String
    @Binding var email:     String
    let onBack:     () -> Void
    let onContinue: () -> Void
    var onSkip:     (() -> Void)? = nil

    private var canContinue: Bool {
        OnboardingValidation.isValidName(firstName)
            && OnboardingValidation.isValidName(lastName)
            && OnboardingValidation.isValidPhone(phone)
            && OnboardingValidation.isValidEmail(email)
    }

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: "How can we reach you?",
            subtitle: "So your coach can follow up.",
            canContinue: canContinue,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue,
            onSkip: onSkip
        ) {
            VStack(spacing: 10) {
                OnboardingTextField(placeholder: "First name", keyboard: .default,
                                    contentType: .givenName, capitalization: .words, text: $firstName)
                OnboardingTextField(placeholder: "Last name", keyboard: .default,
                                    contentType: .familyName, capitalization: .words, text: $lastName)
                OnboardingTextField(placeholder: "(555) 123-4567", keyboard: .phonePad,
                                    contentType: .telephoneNumber, capitalization: .never, text: $phone)
                OnboardingTextField(placeholder: "you@example.com", keyboard: .emailAddress,
                                    contentType: .emailAddress, capitalization: .never, text: $email)
            }
            .padding(.top, 4)
        }
    }
}

/// The text field used by every collection screen, extracted so the four on the
/// contact screen can't drift from each other.
struct OnboardingTextField: View {
    let placeholder:    String
    let keyboard:       UIKeyboardType
    let contentType:    UITextContentType?
    let capitalization: TextInputAutocapitalization
    @Binding var text:  String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.dim))
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Theme.text)
            .keyboardType(keyboard)
            .textContentType(contentType)
            .textInputAutocapitalization(capitalization)
            .autocorrectionDisabled()
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - Permissions
//
// Two switches, both reversible in Settings. Bluetooth is deliberately absent:
// iOS prompts for it at the moment of connection, and a second in-app switch
// claiming to control it would be a lie. HealthKit is absent because the app
// does not read HealthKit at all.
//
// Their defaults differ on purpose. Sync is on because losing a phone should
// not mean losing the history. Nudges are off because they interrupt, and
// AppEnvironment already treats that as something a user opts into rather than
// something that starts happening to them; onboarding is not a licence to
// reverse that.

struct OnboardingPermissionsScreen: View {
    let progress: Double
    @Binding var cloudSync:     Bool
    @Binding var notifications: Bool
    let onBack:   () -> Void
    let onFinish: () -> Void

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: "Two last choices.",
            subtitle: "Both can be changed any time in Settings.",
            canContinue: true,
            continueTitle: "Finish",
            onBack: onBack,
            onContinue: onFinish
        ) {
            VStack(spacing: 10) {
                OnboardingToggleCard(
                    icon: "icloud",
                    title: "Sync to your account",
                    detail: "Keeps your history if you lose the phone, and lets your coach see it. Off means everything stays on this device.",
                    isOn: $cloudSync)

                OnboardingToggleCard(
                    icon: "bell",
                    title: "Nudges",
                    detail: "A quiet notification when your state shifts and a short practice would help.",
                    isOn: $notifications)

                Text("We never sell your data, and we don't share it with anyone you haven't chosen.")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Consent row
//
// The compact sibling of OnboardingToggleCard, sized to sit under the live
// waveforms without pushing the footer off screen.
//
// One line, one switch. The row names Claude outright rather than saying "our
// AI partner" — consent to send health data to a third party means nothing if
// the user can't tell who the third party is, and a named processor is what the
// App Store privacy questionnaire and GDPR Article 13 both expect.
//
// The detail that used to sit here now lives behind the "What's shared?" sheet
// under the rows. Moving it is fine; deleting it is not, because informed
// consent has to have somewhere to be informed from.

struct OnboardingConsentRow: View {
    let icon:  String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
                .scaleEffect(0.85)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 50)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - What's shared
//
// The disclosure the rows no longer carry inline. Reachable in one tap from the
// consent block, and deliberately specific about what is *not* sent.

struct DataSharingDetailSheet: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's shared")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 28)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        title: "With the Wythin team",
                        body: "Your sessions and the metrics computed from them, so a coach can review your progress and adjust your guidance. They see your name and email because they may contact you.")

                    section(
                        title: "With \(AIProvider.name)",
                        body: "\(AIProvider.name) runs the AI model that writes your guidance. Your metrics — heart-rate variability, breathing rate, session times — are sent to it so the wording can be specific to you.")

                    section(
                        title: "What is never sent to \(AIProvider.name)",
                        body: "Your name, phone number and email address. Your raw ECG. Anything from a session you deleted.")

                    section(
                        title: "Changing your mind",
                        body: "Both switches live in Settings and take effect immediately. Turning one off stops future sharing; ask us and we'll delete what was already sent.")
                }
                .padding(.top, 22)
                .padding(.bottom, 24)
            }

            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(LinearGradient.onboardingPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg.ignoresSafeArea())
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(body)
                .font(Theme.monoBody)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OnboardingToggleCard: View {
    let icon:   String
    let title:  String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(Theme.text)
                .frame(width: 26)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}
