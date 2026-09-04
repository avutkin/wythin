import SwiftUI
import UIKit

// MARK: - Scripted breath session
//
// Serves any `.scripted` practice: a short sequence of named moves rather than a
// repeating pattern.
//
// Three things carry the practice, and none of them is a sweeping line. A
// perimeter that fills and then unwinds to reset pulls the eye at exactly the
// moment the next breath starts, so the cycle is shown as discrete segments that
// light and go dark instead.
//
//   the circle       — what the lungs are doing, including the two moves that go
//                      past where a breath would have stopped on its own
//   the word + count — which move this is, and how much of it is left. A surge
//                      shows no number: it is one effort, not a duration
//   the next line    — what is coming, because a scripted breath cannot be
//                      guessed ahead the way an even one can
//
// Natural steps are the reason this screen exists rather than another pacer.
// They show no countdown, they are walked through by a breath sound rather than
// counted at, and a tap ends one early — the guide waits on the breath rather
// than the breath chasing the guide.

struct ScriptedBreathSessionView: View {
    let practice: Practice

    @Environment(\.modelContext) var ctx
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss

    @AppStorage private var minutes:       Int
    @AppStorage private var holdSeconds:   Int
    @AppStorage private var breathSeconds: Int

    @State private var engine:    ScriptedBreathEngine
    @State private var cue      = ScriptedCue()
    @State private var startedAt = Date.now
    @State private var sessionElapsed: TimeInterval = 0
    @State private var isMuted      = false
    @State private var showSettings = false
    @State private var fill:  Double = 0.26
    @State private var pump:  Bool   = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let diameter:    CGFloat = 250
    private let minuteRange  = 1...60
    private let holdRange    = 5...60
    private let holdStep     = 5
    private let breathRange  = 2...12

    init(practice: Practice) {
        self.practice = practice
        let base = practice.breathScript ?? .stacking
        let keys = practice.id
        let hold = base.steps.first(where: { $0.move.isLongHold })?.pace.seconds ?? 15
        let natural = base.steps.first(where: { $0.pace.isNatural })?.pace.seconds ?? 4
        _minutes       = AppStorage(wrappedValue: practice.defaultDurationMins, "script.\(keys).minutes")
        _holdSeconds   = AppStorage(wrappedValue: hold,    "script.\(keys).hold")
        _breathSeconds = AppStorage(wrappedValue: natural, "script.\(keys).breath")
        _engine = State(initialValue: ScriptedBreathEngine(script: base))
    }

    // MARK: Derived

    private var baseScript: BreathScript { practice.breathScript ?? .stacking }
    private var script:     BreathScript {
        baseScript.resized(hold: holdSeconds, natural: breathSeconds)
    }

    private var step: BreathStep {
        let steps = script.steps
        guard steps.indices.contains(engine.state.stepIndex) else {
            return BreathStep(move: .inhale, pace: .natural(breathSeconds))
        }
        return steps[engine.state.stepIndex]
    }

    private var nextStep: BreathStep {
        let steps = script.steps
        guard !steps.isEmpty else { return step }
        return steps[(engine.state.stepIndex + 1) % steps.count]
    }

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
            if sessionElapsed >= target { stop() }
        }
        .onChange(of: holdSeconds)   { engine.reconfigure(script: script) }
        .onChange(of: breathSeconds) {
            cue.prepareBreath(seconds: breathSeconds)
            engine.reconfigure(script: script)
        }
    }

    // MARK: The pacer

    private var pacer: some View {
        VStack(spacing: 22) {
            stepRail

            ZStack {
                lungs
                centreReadout
            }
            .frame(width: diameter + 40, height: diameter + 40)

            VStack(spacing: 8) {
                Text(step.move.instruction)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    // Two lines reserved, so a longer instruction doesn't shift
                    // the circle up when the step changes.
                    .frame(height: 34, alignment: .top)

                if step.pace.isNatural {
                    Text("TAP WHEN YOU ARE READY")
                        .font(Theme.monoLabel)
                        .tracking(2)
                        .foregroundStyle(Theme.breathe.opacity(0.55))
                } else {
                    Text("NEXT · \(nextStep.move.label)")
                        .font(Theme.monoLabel)
                        .tracking(2)
                        .foregroundStyle(Theme.dim.opacity(0.7))
                }
            }
        }
        .contentShape(Rectangle())
        // Only a natural step can be tapped through. A counted hold that could be
        // tapped away is not a hold.
        .onTapGesture { if step.pace.isNatural { engine.advance() } }
    }

    /// One segment per step in the cycle. They light in order and all go dark at
    /// the wrap — a discrete reset rather than a line retreating backwards.
    private var stepRail: some View {
        HStack(spacing: 5) {
            ForEach(Array(script.steps.enumerated()), id: \.offset) { index, item in
                Capsule()
                    .fill(railTint(index))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .top) {
                        if index == engine.state.stepIndex {
                            Text(item.move.label)
                                .font(.system(size: 9, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(Theme.breathe)
                                .fixedSize()
                                .offset(y: -14)
                        }
                    }
            }
        }
        .frame(width: diameter + 40)
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.25), value: engine.state.stepIndex)
    }

    private func railTint(_ index: Int) -> Color {
        if index == engine.state.stepIndex { return Theme.breathe }
        if index <  engine.state.stepIndex { return Theme.breathe.opacity(0.3) }
        return Theme.border
    }

    // MARK: The lungs

    /// 0.42 at empty, 1.0 at full — the circle never collapses to nothing, so
    /// "empty" still reads as a body rather than a disappearance.
    private var scale: CGFloat { 0.42 + 0.58 * CGFloat(fill) }

    /// A breath moves across its whole step. A surge is driven: it reaches the
    /// end of its travel in the first third and sits there, so the movement on
    /// screen looks like the effort it is asking for.
    private var fillAnimation: Animation {
        step.move.isSurge
            ? .easeOut(duration: Double(step.pace.seconds) * 0.35)
            : .easeInOut(duration: Double(step.pace.seconds))
    }

    private var lungs: some View {
        Circle()
            .fill(RadialGradient(colors: [Theme.breathe.opacity(0.28), Theme.breathe.opacity(0.05)],
                                 center: .center, startRadius: 0, endRadius: diameter * 0.4))
            .overlay(Circle().stroke(Theme.breathe.opacity(0.45), lineWidth: 1.5))
            .frame(width: diameter, height: diameter)
            .scaleEffect(scale)
            .animation(fillAnimation, value: fill)
            // The pump is the one move with no volume change to show, so it is
            // shown as movement instead: the chest working against held air.
            .scaleEffect(pump ? 1.022 : 1.0)
            .animation(pump ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                       value: pump)
    }

    private var centreReadout: some View {
        VStack(spacing: 6) {
            Text(step.move.label)
                .font(Theme.display(17))
                .tracking(4)
                .foregroundStyle(Theme.breathe)

            if step.pace.isNatural {
                // No number: a breath at your own speed has nothing to count
                // down, and showing one would make it a deadline.
                Text("YOUR PACE")
                    .font(Theme.monoLabel)
                    .tracking(3)
                    .foregroundStyle(Theme.dim)
            } else if step.move.isSurge {
                // Nor here, for the opposite reason. One strong effort is not
                // two seconds of anything; a countdown turns a push into a wait.
                Text(step.move == .topUp ? "ALL THE WAY IN" : "ALL THE WAY OUT")
                    .font(Theme.monoLabel)
                    .tracking(3)
                    .foregroundStyle(Theme.breathe.opacity(0.8))
            } else {
                Text(engine.state.countdown)
                    .font(.system(size: 46, weight: .light, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
            }

            if !step.pace.isNatural, !step.move.isSurge, step.pace.seconds <= 6 {
                pips
            }
        }
    }

    /// Only for the short moves. Fifteen pips is a bar chart, not a count — a
    /// long hold gets the numeral instead.
    private var pips: some View {
        HStack(spacing: 6) {
            ForEach(1...max(1, step.pace.seconds), id: \.self) { second in
                Circle()
                    .fill(second <= engine.state.secondsIntoStep + 1 ? Theme.breathe : Theme.border)
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.15), value: engine.state.secondsIntoStep)
    }

    // MARK: Progress and readouts

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
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 0.5, height: 26)
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
        .frame(maxWidth: .infinity)
    }

    private func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Settings

    private var summary: String {
        var parts = ["\(minutes) MIN"]
        if baseScript.hasLongHolds { parts.append("HOLD \(holdSeconds)s") }
        parts.append("BREATH \(breathSeconds)s")
        return parts.joined(separator: " · ")
    }

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
                if baseScript.hasLongHolds {
                    Divider().background(Theme.border)
                    stepperRow(label: "HOLD", value: "\(holdSeconds)s",
                               canLower: holdSeconds > holdRange.lowerBound,
                               canRaise: holdSeconds < holdRange.upperBound,
                               lower: { holdSeconds = max(holdRange.lowerBound, holdSeconds - holdStep) },
                               raise: { holdSeconds = min(holdRange.upperBound, holdSeconds + holdStep) })
                }
                Divider().background(Theme.border)
                // How long the guide waits on a natural breath before moving on
                // by itself. A tap still ends one sooner.
                stepperRow(label: "BREATH", value: "\(breathSeconds)s",
                           canLower: breathSeconds > breathRange.lowerBound,
                           canRaise: breathSeconds < breathRange.upperBound,
                           lower: { breathSeconds -= 1 }, raise: { breathSeconds += 1 })
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
                .frame(width: 58, alignment: .leading)
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

    // MARK: Transport

    private func start() {
        startedAt      = .now
        sessionElapsed = 0
        UIApplication.shared.isIdleTimerDisabled = true   // the screen is the guide
        cue.isMuted = isMuted
        cue.prepareBreath(seconds: breathSeconds)
        cue.start()
        engine.onTick = { state, event in
            cue.play(event)
            apply(state)
        }
        engine.reconfigure(script: script)
        engine.start()
    }

    /// The visual follows the engine rather than a timer of its own, so the
    /// circle, the count and the tone cannot disagree about which move this is.
    private func apply(_ state: ScriptedBreathState) {
        let steps = script.steps
        guard steps.indices.contains(state.stepIndex) else { return }
        let move = steps[state.stepIndex].move
        if state.secondsIntoStep == 0 {
            if let target = move.fill { fill = target }   // a hold keeps what it was given
            pump = (move == .pump)
        }
    }

    private func teardown() {
        engine.onTick = nil
        engine.stop()
        cue.stop()
        pump = false
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
