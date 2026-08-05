import SwiftUI

// MARK: - Box Breathing session
//
// A guided pacer. Time, pace and tempo are set from the panel at the bottom and
// persist between sessions.
//
// Pace is counted in beats per phase, not seconds, so however the tempo is set a
// phase is always a whole number of beats — which keeps the accented beat that
// opens each phase landing exactly on the phase change.
//
// On Stop it logs a breathwork ActivityLog for the elapsed time, the same path
// ResonanceSessionView takes.

struct BoxBreathingSessionView: View {
    let practice: Practice

    @Environment(\.modelContext) var ctx
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss

    @AppStorage("boxBreathMinutes") private var minutes = 6
    @AppStorage("boxBreathBeats")   private var beats   = 6
    @AppStorage("boxBreathBPM")     private var bpm     = 60

    @State private var engine:    BoxBreathEngine
    @State private var cue      = MetronomeCue()
    @State private var startedAt = Date.now
    @State private var sessionElapsed: TimeInterval = 0
    @State private var isMuted = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let minuteRange = 1...60
    private let beatRange   = 2...10
    private let bpmRange    = 40...120
    private let bpmStep     = 5

    init(practice: Practice) {
        self.practice = practice
        _engine = State(initialValue: BoxBreathEngine(pattern: practice.breathPattern ?? .box))
    }

    private var pattern: BreathPattern { .box(beats: beats) }
    private var target:  TimeInterval  { TimeInterval(minutes) * 60 }
    private var remaining: TimeInterval { max(0, target - sessionElapsed) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 4)
                    BoxPacerView(engine: engine)
                    Spacer(minLength: 4)
                    readouts
                        .padding(.bottom, 14)
                    controls
                        .padding(.horizontal)
                        .padding(.bottom, 20)
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
        .onAppear    { start() }
        .onDisappear { teardown() }
        .onReceive(ticker) { _ in
            guard engine.isRunning else { return }
            sessionElapsed = Date.now.timeIntervalSince(startedAt)
            if sessionElapsed >= target { stop() }
        }
        .onChange(of: beats) { engine.reconfigure(pattern: pattern, bpm: bpm) }
        .onChange(of: bpm)   { engine.reconfigure(pattern: pattern, bpm: bpm) }
    }

    // MARK: Readouts

    private var readouts: some View {
        HStack(spacing: 18) {
            readout("CYCLE", "\(engine.state.cycle)")
            readout("ELAPSED", mmss(sessionElapsed))
            readout("LEFT", mmss(remaining))
            readout("RATE", String(format: "%.1f br/min", pattern.breathsPerMinute(bpm: bpm)))
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            Text(value)
                .font(Theme.mono(15))
                .foregroundStyle(Theme.text)
        }
        .frame(minWidth: 68)
    }

    private func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            stepperRow(label: "TIME", value: "\(minutes) min",
                       canLower: minutes > minuteRange.lowerBound,
                       canRaise: minutes < minuteRange.upperBound,
                       lower: { minutes -= 1 }, raise: { minutes += 1 })
            Divider().background(Theme.border)
            stepperRow(label: "PACE", value: "\(beats)-\(beats)-\(beats)-\(beats)",
                       canLower: beats > beatRange.lowerBound,
                       canRaise: beats < beatRange.upperBound,
                       lower: { beats -= 1 }, raise: { beats += 1 })
            Divider().background(Theme.border)
            stepperRow(label: "TEMPO", value: "\(bpm) BPM",
                       canLower: bpm > bpmRange.lowerBound,
                       canRaise: bpm < bpmRange.upperBound,
                       lower: { bpm = max(bpmRange.lowerBound, bpm - bpmStep) },
                       raise: { bpm = min(bpmRange.upperBound, bpm + bpmStep) })
        }
        .cardStyle()
    }

    private func stepperRow(label: String, value: String,
                            canLower: Bool, canRaise: Bool,
                            lower: @escaping () -> Void,
                            raise: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(width: 54, alignment: .leading)

            Text(value)
                .font(Theme.mono(15))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            stepButton("minus", enabled: canLower, action: lower)
            stepButton("plus",  enabled: canRaise, action: raise)
        }
        .padding(.vertical, 9)
    }

    private func stepButton(_ symbol: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Theme.accent : Theme.dim.opacity(0.4))
                .frame(width: 34, height: 30)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Lifecycle

    private func start() {
        startedAt      = .now
        sessionElapsed = 0
        UIApplication.shared.isIdleTimerDisabled = true   // the screen is the pacer
        cue.isMuted = isMuted
        cue.start()
        engine.onBeat = { state in
            cue.play(state.isAccent ? .accent : .plain)
        }
        engine.reconfigure(pattern: pattern, bpm: bpm)
        engine.start()
    }

    private func teardown() {
        engine.onBeat = nil
        engine.stop()
        cue.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func stop() {
        guard engine.isRunning else { return }
        teardown()
        ActivityLogging.logPast(type: practice.activityType,
                                subtype: practice.subtype,
                                customName: nil,
                                start: startedAt, end: .now,
                                context: ctx, client: env.sync.client)
        dismiss()
    }
}
