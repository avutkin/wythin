import SwiftUI

struct CurrentStateCard: View {
    let tick:  MetricsTick?

    /// The user's own centre for RMSSD, from `LiveStateStore.baseline`.
    ///
    /// Passing nil here — as this card did — puts PNS on `AutonomicCompute`'s
    /// absolute saturating curve, where RMSSD 40 ms maps to 0.50 for everybody.
    /// For a user whose resting RMSSD sits near 30 that bar reads
    /// sympathetic-dominant almost always, by construction: spec failure #5,
    /// and the same population-prior problem the state above this card was
    /// rebuilt to remove. With a personal centre, their own usual maps to 0.50
    /// and the bar means "against you" like everything else on the screen.
    ///
    /// Still optional: on a first run there are no rollups yet, and the
    /// absolute curve is the honest fallback until there are.
    let baselineRmssd: Float?

    private var autonomic: AutonomicIndices? {
        guard let t = tick else { return nil }
        return AutonomicCompute.balance(rmssd: t.rmssd, lf: t.lfPower, hf: t.hfPower,
                                        breathBPM: t.breathBPM, meanBPM: t.meanBPM,
                                        baselineRmssd: baselineRmssd)
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
}

private func copy(for s: ANSState) -> StateCopy {
    switch s {
    case .ventralVagal:
        return StateCopy(
            headline: "Resting and recovering",
            feels:    "Breath comes easy and shoulders drop. This is the state your body repairs in.",
            color:    Theme.accent)
    case .sympathetic:
        // Amber, not red: being revved is what effort requires. It is a cost at
        // rest, not a fault. Red is reserved for the dorsal state below.
        return StateCopy(
            headline: "Revved up",
            feels:    "Heart quicker, muscles primed, attention sharp. Great for effort, tiring at rest.",
            color:    Theme.rsa)
    case .dorsalVagal:
        return StateCopy(
            headline: "Running on empty",
            feels:    "Flat and withdrawn. Your system is conserving rather than recovering.",
            color:    Theme.warn)
    case .mixed:
        return StateCopy(
            headline: "Finding balance",
            feels:    "Shifting between rest and readiness. Normal while you settle or warm up.",
            color:    Theme.breathe)
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
            // would park the marker deep in READY, the opposite of the truth.
            // The axis simply does not apply here, so don't pretend to place them.
            //
            // PNS and SNS sit at the ends of the same line as the track —
            // parasympathetic on the left under REST, sympathetic on the
            // right under DRIVE — rather than as a caption underneath it.
            BalanceTrack(pns: indices.pns, sns: indices.sns, color: c.color,
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nervous system: \(c.headline). \(c.feels)")
    }
}

// MARK: - Balance Track
//
// The hero. A marker riding a green-to-red gradient — the colour underneath
// it says which way the balance is leaning without a legend — with the PNS
// and SNS numbers anchored at the track's own ends, so it reads as one row
// instead of a bar plus a separate caption underneath it.
// Deliberately no hard centre divider: the classification threshold moves with
// breathing rate (see AutonomicCompute.classify), so a fixed midpoint would
// contradict the headline whenever slow breathing is doing the work.

private struct BalanceTrack: View {
    let pns:   Float
    let sns:   Float
    let color: Color
    /// False when the rest↔ready axis is meaningless for the current state.
    let placeable: Bool

    private let markerHeight: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            Text(BalanceTrackMath.format(pns))

            GeometryReader { geo in
                let x = BalanceTrackMath.markerOffset(sns: sns, trackWidth: geo.size.width)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: BalanceTrackMath.gradientColors(placeable: placeable),
                            startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)

                    if placeable {
                        Capsule()
                            .fill(Theme.text)
                            .frame(width: 4, height: markerHeight)
                            .shadow(color: color.opacity(0.9), radius: 7)
                            .offset(x: x)
                    }
                }
            }
            .frame(height: markerHeight)
            .frame(maxWidth: .infinity)

            Text(BalanceTrackMath.format(sns))
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Theme.dim.opacity(0.65))
        .animation(.spring(duration: 0.6), value: sns)
    }
}

/// The track's pure geometry and formatting, pulled out of the view so the
/// mapping from a 0–1 balance value to a pixel offset — and the colour and
/// number choices at each end — can be pinned by tests without a SwiftUI
/// host.
enum BalanceTrackMath {
    /// Width reserved for the marker so it doesn't run off either end of
    /// the track at sns 0 or 1.
    static let markerWidth: CGFloat = 24

    static func markerOffset(sns: Float, trackWidth: CGFloat) -> CGFloat {
        let usable = max(0, trackWidth - markerWidth)
        return CGFloat(min(1, max(0, sns))) * usable
    }

    /// Same precision the card has always shown for PNS/SNS.
    static func format(_ v: Float) -> String { String(format: "%.2f", v) }

    /// Green (rest) → red (drive), continuous, so the colour under the
    /// marker reads the lean at a glance. Flat and dim when the axis
    /// doesn't apply (dorsal vagal — see `BalanceSection`).
    static func gradientColors(placeable: Bool) -> [Color] {
        placeable
            ? [Theme.accent, Theme.warn]
            : [Theme.dim.opacity(0.18), Theme.dim.opacity(0.18)]
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

