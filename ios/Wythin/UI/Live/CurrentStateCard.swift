import SwiftUI

struct CurrentStateCard: View {
    let tick:  MetricsTick?
    let state: PolyvagalState

    private var autonomic: AutonomicIndices? {
        guard let t = tick else { return nil }
        return AutonomicCompute.compute(tick: t, baseline: nil)
    }

    var body: some View {
        Group {
            if let idx = autonomic {
                BalanceSection(indices: idx)
                    .padding(18)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.border, lineWidth: 0.5))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: autonomic?.state)
    }

    // MARK: - Causes

    private func causeSection(_ causes: [PolyvagalCause]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why is this happening?")
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)

            ForEach(causes) { cause in
                CauseRow(cause: cause)
            }
        }
    }
}

// MARK: - State copy
//
// Plain language on purpose. "Parasympathetic dominant" tells someone nothing
// they can act on, and when the raw indices read 0.45 / 0.55 it actively reads
// as a contradiction. The headline states the lean, the second line says how
// that lean feels in the body, and the clinical terms are demoted to a footnote.

private struct StateCopy {
    let headline: String
    let feels:    String
    let color:    Color
    /// Seconds per pulse cycle of the needle — slow when rested, quick when roused.
    let pulse:    Double
}

private func copy(for s: ANSState) -> StateCopy {
    switch s {
    case .ventralVagal:
        return StateCopy(
            headline: "Resting and recovering",
            feels:    "Breath comes easy and shoulders drop. This is the state your body repairs in.",
            color:    Theme.accent,
            pulse:    5.0)
    case .sympathetic:
        // Amber, not red: being revved is what effort requires. It is a cost at
        // rest, not a fault. Red is reserved for the dorsal state below.
        return StateCopy(
            headline: "Revved up",
            feels:    "Heart quicker, muscles primed, attention sharp. Great for effort, tiring at rest.",
            color:    Theme.rsa,
            pulse:    1.6)
    case .dorsalVagal:
        return StateCopy(
            headline: "Running on empty",
            feels:    "Flat and withdrawn. Your system is conserving rather than recovering.",
            color:    Theme.warn,
            pulse:    6.5)
    case .mixed:
        return StateCopy(
            headline: "Finding balance",
            feels:    "Shifting between rest and readiness. Normal while you settle or warm up.",
            color:    Theme.breathe,
            pulse:    3.0)
    }
}

// MARK: - Balance Section

private struct BalanceSection: View {
    let indices: AutonomicIndices

    private var c: StateCopy { copy(for: indices.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NERVOUS SYSTEM")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            VStack(alignment: .leading, spacing: 6) {
                Text(c.headline)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(c.color)
                Text(c.feels)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Dorsal vagal is low arousal AND low vagal tone, but `sns = 1 − pns`
            // is pure arithmetic — collapsed variability forces sns toward 1 and
            // would park the needle deep in READY, the opposite of the truth.
            // The axis simply does not apply here, so don't pretend to place them.
            BalanceTrack(sns: indices.sns, color: c.color, pulse: c.pulse,
                         placeable: indices.state != .dorsalVagal)

            if indices.state == .dorsalVagal {
                Text("Too little variation in your heart rate to place you on this scale.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 16) {
                Pole(title: "REST",
                     blurb: "Your brake. Slows the heart to rest, digest, connect.",
                     tint: Theme.accent,
                     edge: .leading)
                Pole(title: "DRIVE",
                     blurb: "Your accelerator. Fight or flight. Effort, focus, stress.",
                     tint: Theme.rsa,
                     edge: .trailing)
            }

            Rectangle()
                .fill(Theme.border)
                .frame(height: 0.5)

            // Each term sits under its own end of the track: parasympathetic
            // under REST on the left, sympathetic under DRIVE on the right.
            HStack(spacing: 8) {
                Text("Parasympathetic (PNS) \(fmt(indices.pns))")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Sympathetic (SNS) \(fmt(indices.sns))")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.dim.opacity(0.65))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nervous system: \(c.headline). \(c.feels)")
    }

    private func fmt(_ v: Float) -> String { String(format: "%.2f", v) }
}

// MARK: - Balance Track
//
// The hero. A needle riding a calm-to-ready gradient, breathing at a rate set by
// the current state, so the balance is something you feel before you read it.
// Deliberately no hard centre divider: the classification threshold moves with
// breathing rate (see AutonomicCompute.classify), so a fixed midpoint would
// contradict the headline whenever slow breathing is doing the work.

private struct BalanceTrack: View {
    let sns:   Float
    let color: Color
    let pulse: Double
    /// False when the rest↔ready axis is meaningless for the current state.
    let placeable: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private let halo: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let usable = max(0, geo.size.width - halo)
            let x = CGFloat(min(1, max(0, sns))) * usable

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: placeable
                            ? [Theme.accent.opacity(0.55),
                               Theme.dim.opacity(0.30),
                               Theme.rsa.opacity(0.55)]
                            : [Theme.dim.opacity(0.18),
                               Theme.dim.opacity(0.18),
                               Theme.dim.opacity(0.18)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 8)

                if placeable {
                    ZStack {
                        Circle()
                            .fill(color)
                            .frame(width: halo, height: halo)
                            .scaleEffect(breathing ? 1.0 : 0.5)
                            .opacity(breathing ? 0.10 : 0.42)
                        Capsule()
                            .fill(Theme.text)
                            .frame(width: 4, height: 22)
                            .shadow(color: color.opacity(0.9), radius: 7)
                    }
                    .frame(width: halo, height: halo)
                    .offset(x: x)
                }
            }
            .frame(height: halo)
        }
        .frame(height: halo)
        .animation(.spring(duration: 0.6), value: sns)
        .onAppear { restartPulse() }
        .onChange(of: pulse) { _, _ in restartPulse() }
    }

    private func restartPulse() {
        guard !reduceMotion else { breathing = false; return }
        withAnimation(nil) { breathing = false }
        withAnimation(.easeInOut(duration: pulse / 2).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}

// MARK: - Pole

private struct Pole: View {
    let title: String
    let blurb: String
    let tint:  Color
    let edge:  HorizontalAlignment

    var body: some View {
        VStack(alignment: edge, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint.opacity(0.9))
            Text(blurb)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim.opacity(0.75))
                .multilineTextAlignment(edge == .leading ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
    }
}

// MARK: - Cause Row

private struct CauseRow: View {
    let cause: PolyvagalCause

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
                    .frame(width: 38, height: 38)
                Image(systemName: cause.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(cause.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(cause.time)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
                Text(cause.description)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
