import SwiftUI

/// The two options that need no pacer: silent breath-watching and gentle
/// stretching. A countdown, one line of guidance, and a logged activity on the
/// way out so the impact pipeline can say afterwards whether it helped.
struct NudgeTimerView: View {

    enum Kind {
        case observe
        case stretch

        var intervention: NudgeIntervention {
            NudgeInterventionLibrary.intervention(self == .observe ? .observe : .stretch)
        }

        var heading: String {
            self == .observe ? "WATCH YOUR BREATH" : "GENTLE STRETCHES"
        }

        /// Passive only. Straining under your own effort pushes the system the
        /// other way, so the copy is explicit about staying relaxed.
        var guidance: String {
            switch self {
            case .observe:
                return "Nothing to count and nothing to change. Just notice each breath arriving and leaving."
            case .stretch:
                return "Easy positions you can hold and relax into — supported, never straining. Let the stretch happen rather than forcing it."
            }
        }

        var activity: (type: ActivityType, subtype: String) {
            switch self {
            case .observe: return (.meditation, "Breath Awareness")
            case .stretch: return (.exercise, "Stretching")
            }
        }
    }

    let kind: Kind

    @Environment(\.modelContext) private var ctx
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var startedAt = Date.now
    @State private var remaining: Int = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 28) {
                    Spacer()

                    Text(timeString)
                        .font(.system(size: 64, weight: .light, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())

                    Text(kind.guidance)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Spacer()

                    Text(kind.intervention.why)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle(kind.heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { stop() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.warn)
                }
            }
        }
        .onAppear {
            startedAt = .now
            remaining = kind.intervention.minutes * 60
        }
        .onReceive(tick) { _ in
            guard remaining > 0 else { return }
            remaining -= 1
            if remaining == 0 { stop() }
        }
    }

    private var timeString: String {
        String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private func stop() {
        let activity = kind.activity
        ActivityLogging.logPast(type: activity.type, subtype: activity.subtype, customName: nil,
                                start: startedAt, end: .now,
                                context: ctx, client: env.sync.client)
        dismiss()
    }
}
