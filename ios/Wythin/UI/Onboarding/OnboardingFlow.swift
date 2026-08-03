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
    @State private var showDataDetail = false

    // Consent lives outside the profile: these switches must be readable by the
    // sync layer and by Settings without loading the profile, and
    // `cloudSyncEnabled` already exists and is honoured by SyncCoordinator.
    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = true
    @AppStorage("didShowCloudSyncNotice") private var didShowCloudSyncNotice = false

    // Data-sharing consents, surfaced on the connect step once data is flowing.
    //
    // Both default ON as specified. Flagging the trade-off in one place rather
    // than arguing with it: GDPR treats health data as special category and
    // requires opt-in that is unambiguous, and a switch already on is the
    // textbook example of consent that is not. Flipping either default is the
    // single word `false` below — no other code changes.
    @AppStorage(OnboardingConsent.shareWithTeamKey)
    private var shareWithTeam = OnboardingConsent.shareWithTeamDefault
    @AppStorage(OnboardingConsent.aiInsightsKey)
    private var aiInsightsEnabled = OnboardingConsent.aiInsightsDefault

    /// Nudges route through AppEnvironment rather than @AppStorage so this
    /// screen and Settings read the same value, and so switching it on here
    /// triggers the same authorization request Settings does. It stays **off by
    /// default** on purpose — see the note on `AppEnvironment.nudgesEnabled`:
    /// the thresholds are still first guesses, so being interrupted has to be
    /// chosen rather than something that starts happening.
    private var nudgesBinding: Binding<Bool> {
        Binding(get: { env.nudgesEnabled },
                set: { on in
                    env.nudgesEnabled = on
                    if on {
                        Task { _ = await env.notifications.requestAuthorization() }
                    }
                })
    }

    enum Step: Int, CaseIterable {
        case welcome, goals, practices, devices, currentState, aboutYou, connect, contact, permissions

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
        .init("Just this app",  icon: "iphone"),
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
        .sheet(isPresented: $showDataDetail) {
            DataSharingDetailSheet(onDone: { showDataDetail = false })
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
                question: "What do you want to work on?",
                subtitle: "Pick all that apply.",
                options: goalOptions,
                selection: $profile.goals,
                onBack: { go(.welcome) },
                onContinue: { persist(); go(.practices) },
                onSkip: { skip(to: .practices) }
            )

        case .practices:
            OnboardingMultiSelectScreen(
                progress: step.progress,
                question: "What practices do you do regularly?",
                subtitle: "Pick all that apply.",
                options: practiceOptions,
                selection: $profile.practices,
                onBack: { go(.goals) },
                onContinue: { persist(); go(.devices) },
                onSkip: { skip(to: .devices) }
            )

        case .devices:
            OnboardingMultiSelectScreen(
                progress: step.progress,
                question: "What tools do you use now?",
                subtitle: "Pick all that apply.",
                options: deviceOptions,
                selection: $profile.devices,
                onBack: { go(.practices) },
                onContinue: { persist(); go(.currentState) },
                onSkip: { skip(to: .currentState) }
            )

        case .currentState:
            OnboardingCurrentStateScreen(
                progress: step.progress,
                state: $profile.state,
                onBack: { go(.devices) },
                onContinue: { persist(); go(.aboutYou) },
                onSkip: { skip(to: .aboutYou) { profile.state = CurrentState() } }
            )

        case .aboutYou:
            OnboardingAboutYouScreen(
                progress: step.progress,
                ageRange: $profile.ageRange,
                gender: $profile.gender,
                heightCm: $profile.heightCm,
                weightKg: $profile.weightKg,
                onBack: { go(.currentState) },
                onContinue: { persist(); go(.connect) },
                onSkip: { skip(to: .connect) }
            )

        case .connect:
            OnboardingConnectScreen(
                progress: step.progress,
                state: env.ble.state,
                batteryLevel: env.ble.batteryLevel,
                ecg: env.waveform.ecg,
                acc: env.waveform.acc,
                shareWithTeam: $shareWithTeam,
                aiInsights: $aiInsightsEnabled,
                onShowDataDetail: { showDataDetail = true },
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
                onContinue: { persist(); go(.permissions) },
                // Half-typed contact details are worse than none, since skip
                // bypasses validation and the result would sync as if real.
                onSkip: {
                    skip(to: .permissions) {
                        profile.firstName = ""; profile.lastName = ""
                        profile.phone = "";     profile.email = ""
                    }
                }
            )

        case .permissions:
            OnboardingPermissionsScreen(
                progress: step.progress,
                cloudSync: $cloudSyncEnabled,
                notifications: nudgesBinding,
                onBack: { go(.contact) },
                onFinish: { finish() }
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

    /// The permissions screen is now the explicit, informed choice the separate
    /// post-onboarding sheet used to provide, so mark that notice as shown and
    /// let it stay suppressed.
    private func finish() {
        persist()
        didShowCloudSyncNotice = true
        onComplete()
    }
}
