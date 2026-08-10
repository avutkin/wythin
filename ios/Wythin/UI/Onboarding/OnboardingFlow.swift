import SwiftUI

// MARK: - OnboardingFlow
//
// First-launch, reels-style onboarding. Drives an ordered sequence of full-screen
// steps, persisting answers to the ClientProfileStore as it goes, and calls
// `onComplete` when the user finishes.
//
// This pass is data collection only. The insight/research reels that sit between
// the questions in the design are deliberately not built yet — the step machine
// below is ordered so they drop in between existing cases without renumbering
// anything, since `progress` is derived from the case list rather than hardcoded.

struct OnboardingFlow: View {
    @Environment(AppEnvironment.self) private var env
    let onComplete: () -> Void

    private let store = ClientProfileStore()
    @State private var profile = ClientProfileStore().load()
    @State private var step: Step = .welcome
    @State private var showBLE = false

    // Onboarding no longer asks about sharing, sync or nudges — those live in
    // Settings. This flag is still set on finish so the separate post-onboarding
    // cloud-sync sheet stays suppressed: "don't ask proactively" has to mean the
    // old prompt too, not just the screen that replaced it.
    @AppStorage("didShowCloudSyncNotice") private var didShowCloudSyncNotice = false

    enum Step: Int, CaseIterable {
        // Current state sits directly after goals: having just named what they
        // want to change, rating where they are now reads as the second half of
        // the same question rather than a survey item three screens later.
        case welcome, goals, currentState, practices, devices, aboutYou, connect, contact

        /// Interactive steps after welcome, for the progress bar.
        static var progressTotal: Double { Double(Step.allCases.count - 1) }
        var progress: Double {
            guard rawValue >= Step.goals.rawValue else { return 0 }
            return Double(rawValue) / Step.progressTotal
        }
    }

    // MARK: Option catalogs

    private let goalOptions: [OnboardingOption] = [
        .init("Improve sleep",            icon: "moon.stars"),
        .init("Be more present",          icon: "leaf"),
        .init("More resilient to stress", icon: "shield"),
        .init("Reduce anxiety",           icon: "heart"),
        .init("Sharpen focus",            icon: "scope"),
        .init("Boost energy",             icon: "bolt"),
    ]
    private let practiceOptions: [OnboardingOption] = [
        .init("Meditation",    icon: "brain.head.profile"),
        .init("Breathwork",    icon: "wind"),
        .init("Yoga",          icon: "figure.yoga"),
        .init("Gym",           icon: "dumbbell"),
        .init("Running",       icon: "figure.run"),
        .init("Cold exposure", icon: "snowflake"),
        .init("Walking",       icon: "figure.walk"),
    ]
    private let deviceOptions: [OnboardingOption] = [
        .init("Oura Ring",      icon: "circle.circle"),
        .init("Whoop",          icon: "applewatch.side.right"),
        .init("Apple Watch",    icon: "applewatch"),
        .init("Garmin",         icon: "location.circle"),
        .init("Fitbit",         icon: "square.circle"),
        // No "Just this app" option: at this point in the flow the strap isn't
        // connected and the app measures nothing, so it read as a claim about
        // the future rather than an answer. Someone tracking with nothing just
        // continues — `requiresSelection: false` keeps that a valid answer
        // rather than a dead end.
    ]

    var body: some View {
        ZStack {
            content
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
                .id(step)   // drive the transition on step change
        }
        .animation(.easeInOut(duration: 0.28), value: step)
        .sheet(isPresented: $showBLE) {
            BLEConnectionSheet(ble: env.ble)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeScreen(onStart: { go(.goals) })

        case .goals:
            OnboardingMultiSelectScreen(
                progress: step.progress,
                question: "What matters most to you right now?",
                // Not "pick all that apply" here, unlike the two steps after
                // it. A priorities question answered with everything isn't a
                // priorities question, and the goal reels key their cards to
                // the top three.
                subtitle: "Your top three.",
                options: goalOptions,
                selection: $profile.goals,
                onBack: { go(.welcome) },
                onContinue: { persist(); go(.currentState) }
            )

        case .currentState:
            OnboardingCurrentStateScreen(
                progress: step.progress,
                state: $profile.state,
                onBack: { go(.goals) },
                onContinue: { persist(); go(.practices) }
            )

        case .practices:
            OnboardingMultiSelectScreen(
                progress: step.progress,
                question: "What practices do you do regularly?",
                subtitle: "Pick all that apply.",
                options: practiceOptions,
                selection: $profile.practices,
                requiresSelection: false,
                onBack: { go(.currentState) },
                onContinue: { persist(); go(.devices) }
            )

        case .devices:
            OnboardingMultiSelectScreen(
                progress: step.progress,
                question: "What do you measure yourself with?",
                subtitle: "Anything you use to track performance or state.",
                options: deviceOptions,
                selection: $profile.devices,
                requiresSelection: false,
                onBack: { go(.practices) },
                onContinue: { persist(); go(.aboutYou) }
            )

        case .aboutYou:
            OnboardingAboutYouScreen(
                progress: step.progress,
                ageRange: $profile.ageRange,
                gender: $profile.gender,
                heightCm: $profile.heightCm,
                weightKg: $profile.weightKg,
                onBack: { go(.devices) },
                onContinue: { persist(); go(.connect) }
            )

        case .connect:
            OnboardingConnectScreen(
                progress: step.progress,
                state: env.ble.state,
                batteryLevel: env.ble.batteryLevel,
                ecg: env.waveform.ecg,
                acc: env.waveform.acc,
                onOpenBLE: { showBLE = true },
                onBack: { go(.aboutYou) },
                onContinue: { go(.contact) }
            )

        case .contact:
            OnboardingContactScreen(
                progress: step.progress,
                firstName: $profile.firstName,
                lastName: $profile.lastName,
                phone: $profile.phone,
                email: $profile.email,
                onBack: { go(.connect) },
                onContinue: { finish() }
            )
        }
    }

    // MARK: Navigation & persistence

    private func go(_ next: Step) {
        withAnimation { step = next }
    }

    /// Advance without answering. `clear` runs first for steps where a partial
    /// answer is worse than none, because the skip path bypasses validation.
    /// The multi-selects need no clearing — empty already means "not answered".
    private func skip(to next: Step, clearing clear: (() -> Void)? = nil) {
        clear?()
        persist()
        go(next)
    }

    private func persist() {
        store.save(profile)
    }

    /// Suppresses the old post-onboarding cloud-sync sheet on the way out.
    /// Sharing and sync are Settings decisions now, and a prompt that fires the
    /// moment onboarding ends would put the question straight back.
    private func finish() {
        persist()
        didShowCloudSyncNotice = true
        onComplete()
    }
}
