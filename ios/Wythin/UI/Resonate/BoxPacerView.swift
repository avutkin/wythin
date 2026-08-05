import SwiftUI

// MARK: - Pacers
//
// Two visuals over the same engine. `BoxPacerView` suits a breath with holds —
// four sides, four phases. `RingPacerView` suits a hold-free breath, where a box
// would leave two sides permanently dark; a ring divides its circumference by
// beat share instead, so the whole cycle is one continuous sweep.
//
// Four things move, all read off one BoxBreathEngine:
//
//   the perimeter  — where am I in the cycle (all four phases visible at once)
//   the circle     — what do my lungs do (a dot on an edge can't say inhale vs hold)
//   the count      — how long left
//
// Sides map clockwise to phases: top inhale, right hold, bottom exhale, left hold.

struct BoxPacerView: View {
    let engine: BoxBreathEngine

    private let side:   CGFloat = 260
    private let corner: CGFloat = 28

    private var pattern: BreathPattern { engine.pattern }
    private var state:   BreathState   { engine.state }

    var body: some View {
        ZStack {
            phaseLabels
            boxTrack
            innerCircle
            centreReadout
            // Outside the circle, in the band between its widest point and the
            // box edge — so the circle can breathe through its full range without
            // ever crossing the beat pips.
            pips.offset(y: side * 0.45)
        }
        .frame(width: side + 96, height: side + 96)
    }

    // MARK: The box

    private var boxTrack: some View {
        ZStack {
            // Unlit track.
            RoundedRectangle(cornerRadius: corner)
                .stroke(Theme.border, lineWidth: 3)

            // One segment per phase, each drawn on its own side. Completed sides
            // stay dim-lit until the cycle resets, so the box fills as the breath
            // goes round.
            ForEach(BreathPhase.allCases) { phase in
                BoxSide(phase: phase, corner: corner)
                    .trim(from: 0, to: fill(phase))
                    .stroke(Theme.breathe.opacity(sideOpacity(phase)),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .animation(.linear(duration: engine.beatDuration), value: state.beatInPhase)
                    .animation(.easeOut(duration: 0.35), value: state.phase)
            }
        }
        .frame(width: side, height: side)
    }

    /// How much of a side is drawn: a past side in full, the live side as far as
    /// the beat has got, a side still to come not at all.
    private func fill(_ phase: BreathPhase) -> CGFloat {
        if phase.rawValue < state.phase.rawValue { return 1 }
        if phase.rawValue > state.phase.rawValue { return 0 }
        return CGFloat(state.beatInPhase) / CGFloat(max(1, pattern.beats(phase)))
    }

    private func sideOpacity(_ phase: BreathPhase) -> Double {
        phase == state.phase ? 1.0 : 0.35
    }

    // MARK: The lungs

    /// Grows through the inhale, sits large through the first hold, shrinks
    /// through the exhale, sits small through the second hold.
    private var innerCircle: some View {
        Circle()
            .fill(
                RadialGradient(colors: [Theme.breathe.opacity(0.28), Theme.breathe.opacity(0.05)],
                               center: .center, startRadius: 0, endRadius: side * 0.4)
            )
            .overlay(Circle().stroke(Theme.breathe.opacity(0.45), lineWidth: 1.5))
            // 0.80 of the box: its widest point still leaves a clear band inside
            // the frame for the pips to sit in.
            .frame(width: side * 0.80, height: side * 0.80)
            .scaleEffect(circleScale)
            .animation(.easeInOut(duration: circleAnimationDuration), value: circleScale)
    }

    private var circleScale: CGFloat {
        switch state.phase {
        case .inhale:  return 1.0     // the animation carries it up over the phase
        case .holdIn:  return 1.0
        case .exhale:  return 0.55
        case .holdOut: return 0.55
        }
    }

    /// Holds snap instantly (nothing should appear to move); inhale and exhale
    /// take the whole phase.
    private var circleAnimationDuration: Double {
        state.phase.isHold ? 0 : Double(pattern.beats(state.phase)) * engine.beatDuration
    }

    // MARK: Centre readout

    private var centreReadout: some View {
        VStack(spacing: 6) {
            Text(state.phase.label)
                .font(Theme.display(17))
                .tracking(4)
                .foregroundStyle(Theme.breathe)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(state.beatInPhase)")
                    .font(.system(size: 46, weight: .light, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                Text("/\(pattern.beats(state.phase))")
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    private var pips: some View {
        HStack(spacing: 7) {
            ForEach(1...max(1, pattern.beats(state.phase)), id: \.self) { beat in
                Circle()
                    .fill(beat <= state.beatInPhase ? Theme.breathe : Theme.border)
                    .frame(width: 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.beatInPhase)
    }

    // MARK: Phase names around the box

    /// All four names are always on screen — that's what lets you see the whole
    /// cycle and your place in it, rather than just the current instruction.
    private var phaseLabels: some View {
        ZStack {
            label(.inhale)
                .offset(y: -(side / 2 + 22))
            label(.holdIn)
                .rotationEffect(.degrees(90))
                .offset(x: side / 2 + 24)
            label(.exhale)
                .offset(y: side / 2 + 22)
            label(.holdOut)
                .rotationEffect(.degrees(-90))
                .offset(x: -(side / 2 + 24))
        }
    }

    private func label(_ phase: BreathPhase) -> some View {
        Text(phase.label)
            .font(Theme.monoLabel)
            .tracking(3)
            .foregroundStyle(phase == state.phase ? Theme.breathe : Theme.dim)
            .animation(.easeOut(duration: 0.3), value: state.phase)
    }
}

// MARK: - One side of the box

/// The straight run of a single edge, corners excluded.
///
/// Drawn explicitly rather than by trimming a `RoundedRectangle`, because that
/// shape's path does not begin where you would expect — trimming it from zero
/// starts partway down the right edge, which put the inhale sweep on the wrong
/// side of the box. An explicit path makes the phase-to-edge mapping exact.
private struct BoxSide: Shape {
    let phase:  BreathPhase
    let corner: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = corner
        switch phase {
        case .inhale:   // top, left → right
            path.move(to:    CGPoint(x: rect.minX + c, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        case .holdIn:   // right, top → bottom
            path.move(to:    CGPoint(x: rect.maxX, y: rect.minY + c))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        case .exhale:   // bottom, right → left
            path.move(to:    CGPoint(x: rect.maxX - c, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        case .holdOut:  // left, bottom → top
            path.move(to:    CGPoint(x: rect.minX, y: rect.maxY - c))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        }
        return path
    }
}

// MARK: - Ring pacer

/// For hold-free breaths. The ring's circumference is divided between the phases
/// by their beat share, so the sweep runs continuously round rather than stopping
/// at a corner — which is what an even in-and-out breath actually feels like.
struct RingPacerView: View {
    let engine: BoxBreathEngine

    private let diameter: CGFloat = 260

    private var pattern: BreathPattern { engine.pattern }
    private var state:   BreathState   { engine.state }

    var body: some View {
        ZStack {
            ringTrack
            innerCircle
            centreReadout
            pips.offset(y: diameter * 0.45)
            phaseLabels
        }
        .frame(width: diameter + 96, height: diameter + 96)
    }

    // MARK: The ring

    private var ringTrack: some View {
        ZStack {
            Circle()
                .stroke(Theme.border, lineWidth: 3)

            ForEach(pattern.activePhases) { phase in
                Circle()
                    .trim(from: start(phase), to: end(phase))
                    .stroke(Theme.breathe.opacity(phase == state.phase ? 1.0 : 0.35),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .animation(.linear(duration: engine.beatDuration), value: state.beatInPhase)
                    .animation(.easeOut(duration: 0.35), value: state.phase)
            }
        }
        .rotationEffect(.degrees(-90))   // trim starts at 3 o'clock; begin at 12
        .frame(width: diameter, height: diameter)
    }

    private func start(_ phase: BreathPhase) -> CGFloat {
        CGFloat(pattern.beatsBefore(phase)) / CGFloat(max(1, pattern.cycleBeats))
    }

    /// A past arc in full, the live arc as far as the beat has got, one still to
    /// come not at all.
    private func end(_ phase: BreathPhase) -> CGFloat {
        let span = CGFloat(pattern.beats(phase)) / CGFloat(max(1, pattern.cycleBeats))
        if phase.rawValue < state.phase.rawValue { return start(phase) + span }
        if phase.rawValue > state.phase.rawValue { return start(phase) }
        let done = CGFloat(state.beatInPhase) / CGFloat(max(1, pattern.beats(phase)))
        return start(phase) + span * done
    }

    // MARK: The lungs

    private var innerCircle: some View {
        Circle()
            .fill(
                RadialGradient(colors: [Theme.breathe.opacity(0.28), Theme.breathe.opacity(0.05)],
                               center: .center, startRadius: 0, endRadius: diameter * 0.4)
            )
            .overlay(Circle().stroke(Theme.breathe.opacity(0.45), lineWidth: 1.5))
            .frame(width: diameter * 0.78, height: diameter * 0.78)
            .scaleEffect(state.phase == .inhale ? 1.0 : 0.55)
            .animation(.easeInOut(duration: Double(pattern.beats(state.phase)) * engine.beatDuration),
                       value: state.phase)
    }

    // MARK: Readout

    private var centreReadout: some View {
        VStack(spacing: 6) {
            Text(state.phase.label)
                .font(Theme.display(17))
                .tracking(4)
                .foregroundStyle(Theme.breathe)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(state.beatInPhase)")
                    .font(.system(size: 46, weight: .light, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                Text("/\(pattern.beats(state.phase))")
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    private var pips: some View {
        HStack(spacing: 7) {
            ForEach(1...max(1, pattern.beats(state.phase)), id: \.self) { beat in
                Circle()
                    .fill(beat <= state.beatInPhase ? Theme.breathe : Theme.border)
                    .frame(width: 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.beatInPhase)
    }

    /// Both phase names sit at the arc they own — top for the inhale, bottom for
    /// the exhale — so the whole cycle reads at a glance, as on the box.
    private var phaseLabels: some View {
        ZStack {
            label(.inhale).offset(y: -(diameter / 2 + 22))
            label(.exhale).offset(y:   diameter / 2 + 22)
        }
    }

    private func label(_ phase: BreathPhase) -> some View {
        Text(phase.label)
            .font(Theme.monoLabel)
            .tracking(3)
            .foregroundStyle(phase == state.phase ? Theme.breathe : Theme.dim)
            .animation(.easeOut(duration: 0.3), value: state.phase)
    }
}
