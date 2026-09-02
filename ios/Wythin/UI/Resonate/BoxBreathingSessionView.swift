import SwiftUI

// MARK: - Guided breath session
//
// Serves any `.pacer` practice. A pattern with holds paces on the box; a hold-free
// one paces on the ring.
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

    // Keyed per practice, so the box and the ring keep their own settings.
    @AppStorage private var minutes: Int
    @AppStorage private var beats:   Int      // box only: beats per phase
    @AppStorage private var bpm:     Int      // box only: metronome tempo
    /// Hold-free breaths are set in seconds instead, in halves — see EvenCadence.
    @AppStorage private var halfSeconds: Int

    @State private var engine:   BoxBreathEngine
    @State private var cue     = MetronomeCue()
    @State private var startedAt = Date.now
    @State private var sessionElapsed: TimeInterval = 0
    @State private var isMuted       = false
    @State private var showSettings  = false
    @State private var didComplete   = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let minuteRange = 1...60
    // Up to 12 so a 5.5-second phase is reachable: 11 beats at 120 BPM.
    private let beatRange   = 2...12
    private let bpmRange    = 40...120
    private let bpmStep     = 5

    init(practice: Practice) {
        self.practice = practice
        let base    = practice.breathPattern ?? .box
        let defaults = practice.id
        let cadence = EvenCadence(beats: base.inhale, bpm: practice.defaultBPM)
        _minutes     = AppStorage(wrappedValue: practice.defaultDurationMins, "pacer.\(defaults).minutes")
        _beats       = AppStorage(wrappedValue: base.inhale,                  "pacer.\(defaults).beats")
        _bpm         = AppStorage(wrappedValue: practice.defaultBPM,          "pacer.\(defaults).bpm")
        _halfSeconds = AppStorage(wrappedValue: cadence.halfSeconds,          "pacer.\(defaults).halfSeconds")
        _engine  = State(initialValue: BoxBreathEngine(pattern: base, bpm: practice.defaultBPM))
    }

    /// The shape of the breath — whether it pauses at the top and bottom. This
    /// decides the pacer (box or ring), never the controls.
    private var hasHolds: Bool { practice.breathPattern?.hasHolds ?? true }

    /// Whether the pace is set in clicks and a tempo rather than in seconds. A
    /// box always is; a hold-free breath is only when it asks to be, which
    /// Coherent Breathing does.
    private var setInBeats: Bool { practice.paceControl == .beatsAndTempo }

    private var cadence: EvenCadence { EvenCadence(halfSeconds: halfSeconds) }

    /// The pattern the controls describe — the practice's own shape, resized to
    /// the chosen pace. A box stays a box; a hold-free breath stays hold-free.
    private var pattern: BreathPattern {
        if hasHolds { return .box(beats: beats) }
        return setInBeats ? .even(beats: beats) : cadence.pattern
    }

    /// The tempo that pattern runs at — chosen when the pace is set in clicks,
    /// derived from the seconds when it is not.
    private var tempo: Int { setInBeats ? bpm : cadence.bpm }

    private var target:    TimeInterval { TimeInterval(minutes) * 60 }
    private var remaining: TimeInterval { max(0, target - sessionElapsed) }
    private var progress:  Double       { target > 0 ? min(sessionElapsed / target, 1) : 0 }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    pacer
                    Spacer(minLength: 0)

                    VStack(spacing: 14) {
                        progressBar
                        readouts
                        settingsPanel
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 18)
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
            if sessionElapsed >= target { didComplete = true; stop() }
        }
        .onChange(of: beats)       { engine.reconfigure(pattern: pattern, bpm: tempo) }
        .onChange(of: bpm)         { engine.reconfigure(pattern: pattern, bpm: tempo) }
        .onChange(of: halfSeconds) { engine.reconfigure(pattern: pattern, bpm: tempo) }
    }

    // MARK: Pacer

    @ViewBuilder
    private var pacer: some View {
        if pattern.hasHolds {
            BoxPacerView(engine: engine)
        } else {
            RingPacerView(engine: engine)
        }
    }

    // MARK: Progress

    /// How far through the session, as a hairline. Precise numbers are in the
    /// readouts; this is here so you can see the end coming without reading.
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule()
                    .fill(Theme.breathe.opacity(0.8))
                    .frame(width: geo.size.width * progress)
                    .animation(.linear(duration: 1), value: progress)
            }
        }
        .frame(height: 3)
    }

    private var readouts: some View {
        HStack(spacing: 0) {
            readout("CYCLE",   "\(engine.state.cycle)")
            divider
            readout("ELAPSED", mmss(sessionElapsed))
            divider
            readout("LEFT",    mmss(remaining))
            divider
            readout("RATE",    String(format: "%.1f", pattern.breathsPerMinute(bpm: tempo)),
                    unit: "br/min")
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 0.5, height: 22)
    }

    private func readout(_ label: String, _ value: String, unit: String? = nil) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .tracking(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Theme.mono(15))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The one line you can read without opening the panel.
    private var summary: String {
        setInBeats ? "\(minutes) MIN · \(pattern.label) · \(bpm) BPM"
                   : "\(minutes) MIN · \(cadence.label) EACH WAY"
    }

    private func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Settings

    /// Collapsed by default so the pacer keeps the screen; the summary line means
    /// you can still read the current setup without opening it.
    private var settingsPanel: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { showSettings.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Text(summary)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.dim)
                        .rotationEffect(.degrees(showSettings ? 180 : 0))
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSettings {
                Divider().background(Theme.border)
                stepperRow(label: "TIME", value: "\(minutes) min",
                           canLower: minutes > minuteRange.lowerBound,
                           canRaise: minutes < minuteRange.upperBound,
                           lower: { minutes -= 1 }, raise: { minutes += 1 })
                Divider().background(Theme.border)
                if setInBeats {
                    stepperRow(label: "PACE", value: pattern.label,
                               canLower: beats > beatRange.lowerBound,
                               canRaise: beats < beatRange.upperBound,
                               lower: { beats -= 1 }, raise: { beats += 1 })
                    Divider().background(Theme.border)
                    stepperRow(label: "TEMPO", value: "\(bpm) BPM",
                               canLower: bpm > bpmRange.lowerBound,
                               canRaise: bpm < bpmRange.upperBound,
                               lower: { bpm = max(bpmRange.lowerBound, bpm - bpmStep) },
                               raise: { bpm = min(bpmRange.upperBound, bpm + bpmStep) })
                } else {
                    // Seconds a side, in halves. No tempo control: it is derived
                    // from the pace, because the tempo is an implementation
                    // detail of keeping the accent on the phase change.
                    stepperRow(label: "PACE", value: "\(cadence.label) each way",
                               canLower: halfSeconds > EvenCadence.range.lowerBound,
                               canRaise: halfSeconds < EvenCadence.range.upperBound,
                               lower: { halfSeconds -= 1 }, raise: { halfSeconds += 1 })
                }
            }
        }
        .padding(.horizontal, 14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private func stepperRow(label: String, value: String,
                            canLower: Bool, canRaise: Bool,
                            lower: @escaping () -> Void,
                            raise: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(width: 52, alignment: .leading)

            Text(value)
                .font(Theme.mono(15))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            stepButton("minus", enabled: canLower, action: lower)
            stepButton("plus",  enabled: canRaise, action: raise)
        }
        .padding(.vertical, 8)
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
        didComplete    = false
        UIApplication.shared.isIdleTimerDisabled = true   // the screen is the pacer
        cue.isMuted = isMuted
        cue.start()
        engine.onBeat = { state in
            cue.play(state.isAccent ? .accent : .plain)
        }
        engine.reconfigure(pattern: pattern, bpm: tempo)
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
