import SwiftUI

// MARK: - Box Breathing session
//
// A guided pacer on a fixed pattern. Nothing here is configurable: 60 BPM, six
// beats a phase, four phases. Because a phase is exactly six beats, the accented
// beat that opens it *is* the phase change, so the cycle stays followable with
// your eyes shut.
//
// On Stop it logs a breathwork ActivityLog for the elapsed time, the same path
// ResonanceSessionView takes.

struct BoxBreathingSessionView: View {
    let practice: Practice

    @Environment(\.modelContext) var ctx
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss

    @State private var engine:    BoxBreathEngine
    @State private var cue     =  MetronomeCue()
    @State private var startedAt = Date.now
    @State private var isMuted   = false

    init(practice: Practice) {
        self.practice = practice
        _engine = State(initialValue: BoxBreathEngine(pattern: practice.breathPattern ?? .box))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 8)
                    BoxPacerView(engine: engine)
                    Spacer(minLength: 8)
                    footer
                        .padding(.bottom, 28)
                }
            }
            .navigationTitle(practice.title.uppercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isMuted.toggle()
                        cue.isMuted = isMuted
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                            .foregroundStyle(isMuted ? Theme.dim : Theme.breathe)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop") { stop() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.warn)
                }
            }
        }
        .onAppear  { start() }
        .onDisappear { teardown() }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                readout("CYCLE", "\(engine.state.cycle)")
                readout("ELAPSED", elapsedString)
                readout("PACE", "\(engine.pattern.label)")
            }
            Text("60 BPM · one beat a second")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim.opacity(0.7))
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            Text(value)
                .font(Theme.mono(16))
                .foregroundStyle(Theme.text)
        }
        .frame(minWidth: 76)
    }

    private var elapsedString: String {
        let total = Int(engine.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Lifecycle

    private func start() {
        startedAt = .now
        UIApplication.shared.isIdleTimerDisabled = true   // the screen is the pacer
        cue.isMuted = isMuted
        cue.start()
        engine.onBeat = { state in
            cue.play(state.isAccent ? .accent : .plain)
        }
        engine.start()
    }

    private func teardown() {
        engine.onBeat = nil
        engine.stop()
        cue.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func stop() {
        teardown()
        ActivityLogging.logPast(type: practice.activityType,
                                subtype: practice.subtype,
                                customName: nil,
                                start: startedAt, end: .now,
                                context: ctx, client: env.sync.client)
        dismiss()
    }
}
