import SwiftUI

// MARK: - Breath-hold session
//
// Unlike the pacers, this one has a setup step and an end. You set the hold
// length and the number of sets, hit Start, and it runs a fixed course:
//
//   per set →  inhale (rising tone) · exhale (falling tone) · beep · HOLD · beep
//
// The hold is on empty lungs, which is a stronger stimulus than the same clock
// time on full, so the defaults are short and the setup screen says so.

struct HoldSessionView: View {
    let practice: Practice

    @Environment(\.modelContext) var ctx
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss

    @AppStorage private var holdSeconds:    Int
    @AppStorage private var sets:           Int
    @AppStorage private var breatheSeconds: Int

    @State private var engine:   BreathHoldEngine
    @State private var cue     = HoldCue()
    @State private var startedAt = Date.now
    @State private var isMuted   = false
    @State private var phase: Screen = .setup

    private enum Screen { case setup, running, done }

    private let holdRange    = 5...300
    private let setRange     = 1...20
    private let breatheRange = 3...10

    init(practice: Practice) {
        self.practice = practice
        let base = practice.holdProtocol ?? .standard
        let key  = practice.id
        _holdSeconds    = AppStorage(wrappedValue: base.holdSeconds,    "hold.\(key).seconds")
        _sets           = AppStorage(wrappedValue: base.sets,           "hold.\(key).sets")
        _breatheSeconds = AppStorage(wrappedValue: base.breatheSeconds, "hold.\(key).breathe")
        _engine = State(initialValue: BreathHoldEngine(plan: base))
    }

    private var plan: HoldProtocol {
        HoldProtocol(breatheSeconds: breatheSeconds, holdSeconds: holdSeconds, sets: sets)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                switch phase {
                case .setup:   setup
                case .running: running
                case .done:    summary
                }
            }
            .navigationTitle(practice.title.uppercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if phase == .running {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isMuted.toggle()
                            cue.isMuted = isMuted
                        } label: {
                            Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                                .foregroundStyle(isMuted ? Theme.dim : Theme.breathe)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(phase == .running ? "Stop" : "Close") {
                        phase == .running ? finish(completed: false) : dismiss()
                    }
                    .font(Theme.monoLabel)
                    .foregroundStyle(phase == .running ? Theme.warn : Theme.dim)
                }
            }
        }
        .onDisappear { teardown() }
    }

    // MARK: Setup

    private var setup: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(plan.label)
                        .font(.system(size: 40, weight: .light, design: .monospaced))
                        .foregroundStyle(Theme.text)
                    Text("\(mmss(plan.totalHoldSeconds)) held · \(mmss(plan.totalSeconds)) in total")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
                .padding(.top, 20)

                VStack(spacing: 0) {
                    stepperRow(label: "HOLD", value: "\(holdSeconds)s",
                               canLower: holdSeconds > holdRange.lowerBound,
                               canRaise: holdSeconds < holdRange.upperBound,
                               lower: { holdSeconds -= 1 }, raise: { holdSeconds += 1 })
                    Divider().background(Theme.border)
                    stepperRow(label: "SETS", value: "\(sets)",
                               canLower: sets > setRange.lowerBound,
                               canRaise: sets < setRange.upperBound,
                               lower: { sets -= 1 }, raise: { sets += 1 })
                    Divider().background(Theme.border)
                    stepperRow(label: "BREATH", value: "\(breatheSeconds)s each way",
                               canLower: breatheSeconds > breatheRange.lowerBound,
                               canRaise: breatheSeconds < breatheRange.upperBound,
                               lower: { breatheSeconds -= 1 }, raise: { breatheSeconds += 1 })
                }
                .padding(.horizontal, 14)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 7) {
                    Label("Before you start", systemImage: "exclamationmark.triangle")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.warn)
                    Text("Sit or lie down, on land, away from water. Holding on empty lungs can make you light-headed or make you faint, and fainting in water drowns people. Breathe whenever you want to — the timer is a suggestion, not an instruction.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Start shorter than you think. A hold on empty is far harder than the same seconds on full.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warn.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.warn.opacity(0.25), lineWidth: 0.5))

                Button { begin() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Start")
                    }
                    .font(Theme.mono(15))
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HoldDialView(state: engine.state, plan: plan)
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                setPips
                HStack(spacing: 0) {
                    readout("SET", "\(engine.state.set) / \(plan.sets)")
                    Rectangle().fill(Theme.border).frame(width: 0.5, height: 22)
                    readout("HOLD", "\(plan.holdSeconds)s")
                    Rectangle().fill(Theme.border).frame(width: 0.5, height: 22)
                    readout("LEFT", mmss(max(0, plan.totalSeconds - engine.elapsed)))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 26)
        }
    }

    /// One pip per set, filled as each hold completes — the only place the whole
    /// course is visible while you are inside it.
    private var setPips: some View {
        HStack(spacing: 6) {
            ForEach(1...max(1, plan.sets), id: \.self) { n in
                Capsule()
                    .fill(n < engine.state.set ? Theme.accent
                          : n == engine.state.set ? Theme.accent.opacity(0.45)
                          : Theme.border)
                    .frame(height: 3)
            }
        }
        .animation(.easeOut(duration: 0.3), value: engine.state.set)
    }

    // MARK: Done

    private var summary: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("\(plan.sets) sets · \(mmss(plan.totalHoldSeconds)) held")
                .font(Theme.mono(17))
                .foregroundStyle(Theme.text)
            Text("Logged to your activities.")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            Spacer()
            Button { dismiss() } label: {
                Text("Done")
                    .font(Theme.mono(15))
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
    }

    // MARK: Bits

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .tracking(1)
            Text(value)
                .font(Theme.mono(15))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func stepperRow(label: String, value: String,
                            canLower: Bool, canRaise: Bool,
                            lower: @escaping () -> Void,
                            raise: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(width: 58, alignment: .leading)
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

    private func mmss(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Lifecycle

    private func begin() {
        startedAt = .now
        engine.configure(plan)
        cue.prepare(breatheSeconds: breatheSeconds)
        cue.isMuted = isMuted
        cue.start()
        UIApplication.shared.isIdleTimerDisabled = true

        engine.onPhaseChange = { state in
            // The hold is bracketed: the beep that opens it, and the beep that
            // ends it — which arrives as the next set's inhale, or as the finish.
            switch state.phase {
            case .hold:   cue.play(.beep)
            case .inhale: cue.play(.beep); cue.play(.inhale)
            case .exhale: cue.play(.exhale)
            }
        }
        engine.onFinish = { finish(completed: true) }

        phase = .running
        engine.start()
    }

    private func teardown() {
        engine.onPhaseChange = nil
        engine.onFinish = nil
        engine.stop()
        cue.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Logs whatever was actually done, complete or not — a session cut short is
    /// still a session, and silently dropping it would lose real practice.
    private func finish(completed: Bool) {
        guard phase == .running else { return }
        teardown()
        ActivityLogging.logPast(type: practice.activityType,
                                subtype: practice.subtype,
                                customName: nil,
                                start: startedAt, end: .now,
                                context: ctx, client: env.sync.client)
        if completed {
            phase = .done
        } else {
            dismiss()
        }
    }
}

// MARK: - Hold dial

/// One dial for all three phases: the ring fills through each breath and drains
/// through the hold, and the circle swells and empties with the lungs.
///
/// The dial owns its animation rather than reading a per-second progress value.
/// Driving it off the tick had two faults. The ring was computed as
/// `secondsIntoPhase / length`, which for a five-second phase runs 0/5…4/5 — it
/// stopped at four fifths and jumped, so a breath never visibly finished. And
/// the circle's target for the inhale was its resting value, so on the very
/// first breath nothing moved at all: SwiftUI only animates a change, and there
/// was none. Setting the target once per phase and animating over the phase's
/// own duration fixes both, and makes the motion continuous instead of stepping
/// once a second.
struct HoldDialView: View {
    let state: HoldState
    let plan:  HoldProtocol

    private let size: CGFloat = 268
    private let empty: CGFloat = 0.45
    private let full:  CGFloat = 1.0

    @State private var ring: Double  = 0
    @State private var lung: CGFloat = 0.45

    private var tint: Color {
        state.phase == .hold ? Theme.warn : Theme.breathe
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.border, lineWidth: 3)

            Circle()
                .trim(from: 0, to: ring)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.26), tint.opacity(0.04)],
                                     center: .center, startRadius: 0, endRadius: size * 0.4))
                .frame(width: size * 0.78, height: size * 0.78)
                .scaleEffect(lung)

            VStack(spacing: 6) {
                Text(state.phase.label)
                    .font(Theme.display(17))
                    .tracking(4)
                    .foregroundStyle(tint)
                Text(state.countdown)
                    .font(.system(size: 46, weight: .light, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .frame(width: size, height: size)
        .onAppear { run(state.phase) }
        .onChange(of: state.phase) { _, phase in run(phase) }
    }

    /// Snap to the phase's starting pose without animating, then travel to its
    /// end over exactly the phase's length. The snap has to be in a transaction
    /// with animations disabled or SwiftUI coalesces it with the travel and the
    /// dial appears to start from wherever the last phase left it.
    private func run(_ phase: HoldPhase) {
        let seconds = Double(plan.seconds(phase))
        var snap = Transaction()
        snap.disablesAnimations = true

        switch phase {
        case .inhale:
            withTransaction(snap) { ring = 0; lung = empty }
            withAnimation(.linear(duration: seconds))    { ring = 1 }
            withAnimation(.easeInOut(duration: seconds)) { lung = full }
        case .exhale:
            withTransaction(snap) { ring = 0; lung = full }
            withAnimation(.linear(duration: seconds))    { ring = 1 }
            withAnimation(.easeInOut(duration: seconds)) { lung = empty }
        case .hold:
            // Lungs stay where the exhale left them — empty is the whole point.
            withTransaction(snap) { ring = 1; lung = empty }
            withAnimation(.linear(duration: seconds))    { ring = 0 }
        }
    }
}
