import SwiftUI

// MARK: - Premium graphite accent gradient
//
// A refined diagonal graphite/gunmetal gradient — light grey easing into deep
// charcoal — used for every accented surface in onboarding (primary buttons,
// selected options/chips, progress bar, strap highlight) for an understated,
// premium feel. White text stays legible across the range.

extension LinearGradient {
    static let onboardingPrimary = LinearGradient(
        colors: [Color(hex: "#6E6E76"), Color(hex: "#3A3A40"), Color(hex: "#1E1E22")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - Shared chrome
//
// Every non-welcome step renders inside `OnboardingScaffold`: progress bar on
// top, a big bold question, optional subtitle, the step's content, and a
// Back / Continue footer. Keeps the whole flow feeling like one system.

struct OnboardingScaffold<Content: View>: View {
    let progress:      Double          // 0…1
    let question:      String
    let subtitle:      String?
    let canContinue:   Bool
    let continueTitle: String
    let onBack:        (() -> Void)?
    let onContinue:    () -> Void
    /// Optional escape hatch for steps that ask for personal detail. Steps that
    /// leave this nil render no skip affordance at all.
    var onSkip:        (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("WythinLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

            OnboardingProgressBar(progress: progress)
                .padding(.top, 10)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(question)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)

            ScrollView { content.padding(.horizontal, 24) }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg.ignoresSafeArea())
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.dim)
                            .frame(width: 52, height: 52)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button(action: onContinue) {
                    Text(continueTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(canContinue ? Theme.text : Theme.dim)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(canContinue
                                    ? AnyShapeStyle(LinearGradient.onboardingPrimary)
                                    : AnyShapeStyle(Theme.surface))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canContinue)
            }

            // Deliberately quiet: a plain text button, no fill, so it reads as
            // available without competing with Continue.
            if let onSkip {
                Button(action: onSkip) {
                    Text("Skip for now")
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }
}

struct OnboardingProgressBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule()
                    .fill(LinearGradient.onboardingPrimary)
                    .frame(width: max(6, geo.size.width * min(max(progress, 0), 1)))
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Option card (reels question choices)

struct OnboardingOption: Identifiable, Equatable {
    let id:    String    // stored value + identity
    let icon:  String    // SF Symbol
    var label: String { id }
    init(_ id: String, icon: String) { self.id = id; self.icon = icon }
}

struct OptionCard: View {
    let option:   OnboardingOption
    let selected: Bool
    let action:   () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: option.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.text)
                    .frame(width: 26)
                Text(option.label)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected
                        ? AnyShapeStyle(LinearGradient.onboardingPrimary)
                        : AnyShapeStyle(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Color.clear : Theme.border, lineWidth: 0.5)
            )
            .scaleEffect(selected ? 1.0 : 0.99)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Welcome

struct OnboardingWelcomeScreen: View {
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("WythinLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .foregroundStyle(Theme.text)
            Text("WYTHIN")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .tracking(4)
                .padding(.top, 18)
            Text("Understand your nervous system,\none breath at a time.")
                .font(Theme.monoBody)
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
            Spacer()
            Button(action: onStart) {
                Text("Get Started")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(LinearGradient.onboardingPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }
}

// MARK: - Contact field step (phone / email)

struct OnboardingFieldScreen: View {
    let progress:     Double
    let question:     String
    let subtitle:     String?
    let placeholder:  String
    let keyboard:     UIKeyboardType
    let contentType:  UITextContentType?
    @Binding var text: String
    let isValid:      Bool
    let onBack:       (() -> Void)?
    let onContinue:   () -> Void
    var onSkip:       (() -> Void)? = nil

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: question,
            subtitle: subtitle,
            canContinue: isValid,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue,
            onSkip: onSkip
        ) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.dim))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.text)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
                .padding(.top, 4)
        }
    }
}

// MARK: - Reels multi-select question

struct OnboardingMultiSelectScreen: View {
    let progress:  Double
    let question:  String
    let subtitle:  String?
    let options:   [OnboardingOption]
    @Binding var selection: [String]
    let onBack:     () -> Void
    let onContinue: () -> Void
    var onSkip:     (() -> Void)? = nil

    // "Other" free-text: any selection value that isn't a preset option id is
    // treated as the custom entry, so it survives back-navigation.
    @State private var otherActive = false
    @State private var otherText   = ""
    @FocusState private var otherFocused: Bool

    private var presetIDs: Set<String> { Set(options.map(\.id)) }

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: question,
            subtitle: subtitle,
            canContinue: !selection.isEmpty,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue,
            onSkip: onSkip
        ) {
            VStack(spacing: 10) {
                ForEach(options) { opt in
                    OptionCard(option: opt, selected: selection.contains(opt.id)) {
                        toggle(opt.id)
                    }
                }

                OptionCard(option: OnboardingOption("Other", icon: "plus.circle"),
                           selected: otherActive) {
                    otherActive.toggle()
                    if otherActive {
                        otherFocused = true
                    } else {
                        otherText = ""
                        commitOther("")
                    }
                }

                if otherActive {
                    TextField("", text: $otherText,
                              prompt: Text("Type your own…").foregroundColor(Theme.dim))
                        .focused($otherFocused)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
                        .onChange(of: otherText) { _, new in commitOther(new) }
                }
            }
            .padding(.top, 4)
            .animation(.easeInOut(duration: 0.2), value: otherActive)
        }
        .onAppear(perform: hydrate)
    }

    private func toggle(_ id: String) {
        if let idx = selection.firstIndex(of: id) {
            selection.remove(at: idx)
        } else {
            selection.append(id)
        }
    }

    /// Restore "Other" state from any custom (non-preset) value already selected.
    private func hydrate() {
        if let custom = selection.first(where: { !presetIDs.contains($0) }) {
            otherActive = true
            otherText   = custom
        }
    }

    /// Keep at most one custom (non-preset) entry in `selection`, mirroring the
    /// text field. Removing then re-adding avoids stale duplicates.
    private func commitOther(_ text: String) {
        selection.removeAll { !presetIDs.contains($0) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if otherActive, !trimmed.isEmpty {
            selection.append(trimmed)
        }
    }
}

// MARK: - About you (age + gender, one screen)

struct OnboardingAboutYouScreen: View {
    let progress: Double
    @Binding var ageRange: String?
    @Binding var gender:   String?
    @Binding var heightCm: Int?
    @Binding var weightKg: Int?
    let onBack:     () -> Void
    let onContinue: () -> Void
    var onSkip:     (() -> Void)? = nil

    private let ages    = ["18–24", "25–34", "35–44", "45–54", "55+"]
    private let genders = ["Female", "Male", "Non-binary", "Prefer not to say"]

    /// Age and gender are required; height and weight are not. They feed
    /// normalisation later rather than anything on screen today, so blocking
    /// Continue on them would cost more than they are currently worth.
    private var canContinue: Bool { ageRange != nil && gender != nil }

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: "A bit about you",
            subtitle: "This tailors your guidance.",
            canContinue: canContinue,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue,
            onSkip: onSkip
        ) {
            VStack(alignment: .leading, spacing: 18) {
                pickerGroup(title: "AGE", options: ages, selection: $ageRange)
                pickerGroup(title: "GENDER", options: genders, selection: $gender)

                OnboardingBodyMetrics(gender: gender, heightCm: $heightCm, weightKg: $weightKg)
            }
            .padding(.top, 4)
        }
    }

    private func pickerGroup(title: String, options: [String], selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            FlowChips(options: options, selection: selection)
        }
    }
}

/// Numeric entry with a unit suffix, used for height and weight.
///
/// Binds to `Int?` so an empty field stays nil rather than becoming 0 — a
/// weight of zero would otherwise sync to the server as a real answer.
/// Out-of-range input is kept in the field but not committed, so the user sees
/// what they typed and the profile never holds an implausible value.
struct OnboardingNumberField: View {
    let title: String
    let unit:  String
    let range: ClosedRange<Int>
    @Binding var value: Int?

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            HStack(spacing: 6) {
                TextField("", text: $text, prompt: Text("—").foregroundColor(Theme.dim))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .keyboardType(.numberPad)
                    .onChange(of: text) { _, new in commit(new) }
                Text(unit)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
        }
        .onAppear { if let value { text = String(value) } }
    }

    private func commit(_ new: String) {
        guard let n = Int(new.filter(\.isNumber)), range.contains(n) else {
            value = nil
            return
        }
        value = n
    }
}

/// Simple wrapping chip row for single-select pickers.
struct FlowChips: View {
    let options: [String]
    @Binding var selection: String?

    var body: some View {
        FlexibleWrap(options, spacing: 8) { opt in
            let sel = selection == opt
            Button {
                selection = opt
            } label: {
                Text(opt)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(sel
                                ? AnyShapeStyle(LinearGradient.onboardingPrimary)
                                : AnyShapeStyle(Theme.surface))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(sel ? Color.clear : Theme.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Minimal flow layout that wraps its children onto multiple lines.
struct FlexibleWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data:    Data
    let spacing: CGFloat
    @ViewBuilder let content: (Data.Element) -> Content

    init(_ data: Data, spacing: CGFloat = 8, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        WrapLayout(spacing: spacing) {
            ForEach(Array(data), id: \.self) { content($0) }
        }
    }
}

/// iOS 16+ Layout that flows subviews left-to-right, wrapping to new rows.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Chest-strap placement diagram
//
// A simple vector illustration (no image asset needed) of a torso with the
// Polar H10 strap band highlighted across the chest, so the user sees where it
// goes.

struct ChestStrapDiagram: View {
    var body: some View {
        VStack(spacing: 0) {
            // Head
            Circle()
                .fill(Theme.surface)
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))

            // Torso with the strap band across the chest
            ZStack {
                RoundedRectangle(cornerRadius: 26)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Theme.border, lineWidth: 1))
                    .frame(width: 100, height: 128)

                // Strap band
                Capsule()
                    .fill(LinearGradient.onboardingPrimary)
                    .frame(width: 112, height: 16)
                    .shadow(color: Color.black.opacity(0.5), radius: 8)
                    .overlay(
                        // Sensor pod centered on the strap
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.bg)
                            .frame(width: 18, height: 10)
                    )
                    .offset(y: -20)
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Connect device step

struct OnboardingConnectScreen: View {
    let progress:    Double
    let state:       BLEState
    let batteryLevel: Int?
    /// Live display buffers, straight off `AppEnvironment.waveform`. The point
    /// of showing them here is that the user sees their own heartbeat seconds
    /// after pairing — the strap stops being a setup step and starts being the
    /// thing the app is about.
    let ecg:         [Float]
    let acc:         [Float]
    /// Data-sharing consents, shown only once a strap is streaming — there is
    /// nothing to consent to before that. See `OnboardingConsentRow` for why
    /// the copy names Claude rather than saying "our AI partner".
    @Binding var shareWithTeam: Bool
    @Binding var aiInsights:    Bool
    let onShowDataDetail: () -> Void
    let onOpenBLE:   () -> Void
    let onBack:      () -> Void
    let onContinue:  () -> Void

    /// Once the strap is paired the screen stops selling and starts confirming.
    private var connectedName: String? {
        switch state {
        case .connected(let name), .standby(let name): return name
        default: return nil
        }
    }

    /// The consent rows only exist once a strap is paired, so before that there
    /// is nothing to gate on and Continue must not be blocked by switches the
    /// user cannot yet see.
    private var sharingGranted: Bool {
        OnboardingConsent.canProceedFromSharing(shareWithTeam: shareWithTeam,
                                                aiInsights: aiInsights)
    }

    private var isBusy: Bool {
        switch state {
        case .scanning, .connecting: return true
        default: return false
        }
    }

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: connectedName == nil ? "Connect your Polar H10" : "You're connected.",
            subtitle: connectedName == nil
                ? "Your chest strap streams the heart data behind every reading."
                : "That's the hard part done.",
            // Gated only once paired, because that is when the consent rows
            // appear. Blocking earlier would stop a user on a switch that isn't
            // on screen yet.
            canContinue: connectedName == nil || sharingGranted,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(spacing: 14) {
                if let name = connectedName {
                    connectedCard(name: name)
                } else {
                    ChestStrapDiagram()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)

                    Text("Wear the strap around your chest, just below the chest muscles, snug against the skin.")
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)

                    Button(action: onOpenBLE) {
                        HStack(spacing: 8) {
                            if isBusy {
                                ProgressView().tint(Theme.text)
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                            Text(isBusy ? "Searching…" : "Connect device")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(LinearGradient.onboardingPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Text("You can also do this later from the Live tab.")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.top, 4)
            .animation(.easeInOut(duration: 0.25), value: connectedName)
        }
    }

    @ViewBuilder
    private func connectedCard(name: String) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 13) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(batteryLevel.map { "CONNECTED · \($0)% BATTERY" } ?? "CONNECTED")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))

            liveStrip(title: "LIVE ECG", detail: "130 Hz", tint: Theme.accent) {
                ECGWaveformView(buffer: ecg)
            }

            liveStrip(title: "BREATHING", detail: "200 Hz · ACC Z", tint: Theme.breathe) {
                ACCWaveformView(buffer: acc)
            }

            Text("That's your own heartbeat, live.")
                .font(Theme.monoBody)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            consentBlock
        }
        .padding(.top, 8)
    }

    private var consentBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MAKE IT YOURS")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .padding(.top, 6)

            OnboardingConsentRow(
                icon: "person.2",
                title: "Share with the Wythin team",
                isRequired: OnboardingConsent.shareWithTeamIsMandatory,
                isOn: $shareWithTeam)

            OnboardingConsentRow(
                icon: "sparkles",
                title: "Share securely with \(AIProvider.name)",
                isRequired: OnboardingConsent.aiInsightsIsMandatory,
                isOn: $aiInsights)

            if !sharingGranted {
                OnboardingConsentBlockedNote(
                    message: "Wythin is a coached programme — without these we can't read your sessions or support you, so there's no app to give you.")
            }

            Button(action: onShowDataDetail) {
                HStack(spacing: 4) {
                    Text("What's shared?")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.breathe)
            }
            .padding(.top, 2)
        }
    }

    /// Waveform with its own caption row, so each strip says what it is and at
    /// what rate — the numbers are the evidence that this is a real stream.
    private func liveStrip<Content: View>(
        title: String, detail: String, tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(Theme.monoLabel)
                    .foregroundStyle(tint)
                Spacer()
                Text(detail)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            content()
        }
    }
}
