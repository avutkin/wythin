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

    /// The thumb tracks this, not the stored `Int`.
    ///
    /// Binding straight to the model made the drag feel like it was fighting
    /// the finger: the setter rounded to an integer and the getter read that
    /// rounded value straight back, so on a 0-10 range the thumb could only
    /// occupy eleven positions and kept snapping away mid-gesture. Holding the
    /// continuous position in local state and rounding only on the way out
    /// gives a thumb that follows exactly while still storing 0-10.
    @State private var position: Double = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text)

            // No numeric readout: the position of the thumb between two named
            // ends is the answer, and a 0-10 score invites people to think about
            // the number instead of the feeling. Set-vs-unset is still legible —
            // an untouched slider has no coloured fill behind the thumb.
            //
            // No `step:` either. Stepping quantises the thumb to eleven stops,
            // which is what made the drag feel like it was catching; the stored
            // value is rounded on write instead, so the movement stays smooth
            // and the data stays 0-10.
            Slider(value: $position, in: 0...10)
                .tint(value == nil ? Theme.border : tint)
                .onChange(of: position) { _, new in
                    value = Int(new.rounded())
                }
                .onAppear {
                    // Restore the thumb when stepping back into the screen.
                    if let value { position = Double(value) }
                }

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

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            // Not "right now" — the previous screen already ends on it, and two
            // consecutive questions with the same tail read as one question
            // asked twice.
            question: "How are you feeling today?",
            subtitle: "Drag each one. There are no wrong answers.",
            canContinue: state.isAnswered,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue
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

// MARK: - Body metrics
//
// Height and weight with a unit switch. Entry is imperial or metric; storage is
// always centimetres and kilograms, converted at the boundary, so no value in
// the profile or on the server is ever ambiguous about its unit.
//
// The fields open pre-filled with US adult averages so the interaction is a
// nudge rather than a blank box. That does mean an untouched screen records an
// assumed height and weight as though stated — acceptable for two numbers used
// to normalise metrics, and the step is still skippable.

struct OnboardingBodyMetrics: View {
    let gender: String?
    @Binding var heightCm: Int?
    @Binding var weightKg: Int?

    @State private var units: UnitSystem = UnitSystem.current
    @State private var feet   = ""
    @State private var inches = ""
    @State private var cm     = ""
    @State private var pounds = ""
    @State private var kilos  = ""
    /// Gender-based seeding runs once. Without this, changing gender after
    /// editing your own height would quietly overwrite what you typed.
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HEIGHT & WEIGHT")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Picker("", selection: $units) {
                    ForEach(UnitSystem.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            HStack(spacing: 10) {
                if units == .us {
                    unitField(text: $feet,   suffix: "ft", width: nil)
                    unitField(text: $inches, suffix: "in", width: nil)
                } else {
                    unitField(text: $cm, suffix: "cm", width: nil)
                }
                unitField(text: units == .us ? $pounds : $kilos,
                          suffix: units == .us ? "lb" : "kg", width: nil)
            }
        }
        .onAppear(perform: seedIfNeeded)
        .onChange(of: gender) { _, _ in seedIfNeeded() }
        .onChange(of: units)  { _, new in
            UnitSystem.current = new
            renderFields()          // re-render from stored metric, never from the other field
        }
        .onChange(of: feet)   { _, _ in commitHeight() }
        .onChange(of: inches) { _, _ in commitHeight() }
        .onChange(of: cm)     { _, _ in commitHeight() }
        .onChange(of: pounds) { _, _ in commitWeight() }
        .onChange(of: kilos)  { _, _ in commitWeight() }
    }

    private func unitField(text: Binding<String>, suffix: String, width: CGFloat?) -> some View {
        HStack(spacing: 5) {
            TextField("", text: text, prompt: Text("—").foregroundColor(Theme.dim))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.text)
                .keyboardType(.numberPad)
            Text(suffix)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    // MARK: Seeding and rendering

    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        if heightCm == nil { heightCm = BodyDefaults.heightCm(gender: gender) }
        if weightKg == nil { weightKg = BodyDefaults.weightKg(gender: gender) }
        renderFields()
    }

    /// Text fields are always drawn from the stored metric values, so switching
    /// units can't accumulate rounding by converting a display string back and
    /// forth.
    private func renderFields() {
        if let h = heightCm {
            let ft = BodyUnits.feetInches(fromCm: h)
            feet = String(ft.feet); inches = String(ft.inches); cm = String(h)
        }
        if let w = weightKg {
            pounds = String(BodyUnits.pounds(fromKg: w)); kilos = String(w)
        }
    }

    private func commitHeight() {
        let value: Int?
        if units == .us {
            guard let f = Int(feet.filter(\.isNumber)) else { heightCm = nil; return }
            let i = Int(inches.filter(\.isNumber)) ?? 0
            value = BodyUnits.cm(feet: f, inches: i)
        } else {
            value = Int(cm.filter(\.isNumber))
        }
        heightCm = value.flatMap { OnboardingValidation.heightRangeCm.contains($0) ? $0 : nil }
    }

    private func commitWeight() {
        let value: Int?
        if units == .us {
            value = Int(pounds.filter(\.isNumber)).map(BodyUnits.kg(fromPounds:))
        } else {
            value = Int(kilos.filter(\.isNumber))
        }
        weightKg = value.flatMap { OnboardingValidation.weightRangeKg.contains($0) ? $0 : nil }
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

    private var canContinue: Bool {
        OnboardingValidation.isValidName(firstName)
            && OnboardingValidation.isValidName(lastName)
            && OnboardingValidation.isValidPhone(phone)
            && OnboardingValidation.isValidEmail(email)
    }

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: "Tell us a bit more about you",
            subtitle: "So your coach knows who they're working with.",
            canContinue: canContinue,
            // Last step since the permissions screen was removed, so the button
            // has to say so — "Continue" here promises a screen that no longer
            // exists.
            continueTitle: "Finish",
            onBack: onBack,
            onContinue: onContinue
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
                        title: "Why these aren't optional",
                        body: "Wythin is a coached programme, not a solo tracker. Without your sessions reaching a coach, and without the guidance that's written from them, there is no programme to give you — so we ask you to agree rather than pretend it's a preference.")

                    section(
                        title: "Changing your mind",
                        body: "Both switches stay in Settings. Turning one off stops future sharing immediately, and ask us and we'll delete what was already sent — but it also turns off the coaching those switches pay for.")
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
