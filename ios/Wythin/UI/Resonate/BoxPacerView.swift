import SwiftUI

// MARK: - Box pacer
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
        }
        .frame(width: side + 96, height: side + 96)
    }

    // MARK: The box

    private var boxTrack: some View {
        ZStack {
            // Unlit track.
            RoundedRectangle(cornerRadius: corner)
                .stroke(Theme.border, lineWidth: 3)

            // One segment per phase. Completed sides stay dim-lit until the cycle
            // resets, so the box fills as the breath goes round.
            ForEach(BreathPhase.allCases) { phase in
                RoundedRectangle(cornerRadius: corner)
                    .trim(from: trimStart(phase), to: trimEnd(phase))
                    .stroke(Theme.breathe.opacity(sideOpacity(phase)),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .animation(.linear(duration: 1), value: state.beatInPhase)
                    .animation(.easeOut(duration: 0.35), value: state.phase)
            }
        }
        .frame(width: side, height: side)
        // SwiftUI trims a rounded rect starting from the top-left corner going
        // clockwise, which is exactly the phase order — no rotation needed.
    }

    /// Fraction of the perimeter where each phase's side begins.
    private func trimStart(_ phase: BreathPhase) -> CGFloat {
        CGFloat(phase.rawValue) / CGFloat(BreathPhase.allCases.count)
    }

    /// A side in the past is fully drawn; the live side is drawn as far as the
    /// beat has got; a side still to come isn't drawn at all.
    private func trimEnd(_ phase: BreathPhase) -> CGFloat {
        let full = trimStart(phase) + 1 / CGFloat(BreathPhase.allCases.count)
        if phase.rawValue < state.phase.rawValue { return full }
        if phase.rawValue > state.phase.rawValue { return trimStart(phase) }
        let fraction = CGFloat(state.beatInPhase) / CGFloat(max(1, pattern.seconds(phase)))
        return trimStart(phase) + fraction / CGFloat(BreathPhase.allCases.count)
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
            .frame(width: side * 0.72, height: side * 0.72)
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
        state.phase.isHold ? 0 : Double(pattern.seconds(state.phase))
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
                Text("/\(pattern.seconds(state.phase))")
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }

            pips
        }
    }

    private var pips: some View {
        HStack(spacing: 7) {
            ForEach(1...max(1, pattern.seconds(state.phase)), id: \.self) { beat in
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
