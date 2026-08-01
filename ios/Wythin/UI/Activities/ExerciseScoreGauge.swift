import SwiftUI

/// The 0–100 session score for an exercise session.
///
/// Deliberately the same dial as `PracticeImpactGauge`: the identical 240°
/// track, segmented dashed fill and knob-at-the-fill-end. A meditation and a
/// workout are different physiologies but they are the same product, and two
/// unrelated score dials made the app look like two apps.
///
/// What changes above the crown threshold is the palette and the knob glyph —
/// green check becomes gold crown — so the reward reads as the familiar dial
/// doing something special, not as a different component.
struct ExerciseScoreGauge: View {
    let score:   Int
    let caption: String
    let crowned: Bool
    /// Optional inner ring — the session's Load, as a share of the heaviest
    /// session in recent history. Size, drawn inside quality.
    var loadFraction: Double? = nil

    @State private var sweep:      CGFloat = 0
    @State private var crownScale: CGFloat = 1
    @State private var crownGlow:  Double  = 0
    @State private var rayBloom:   CGFloat = 0

    private let lineWidth:   CGFloat = 14
    private let subLineWidth: CGFloat = 5
    private let knobRadius:  CGFloat = 13
    private let arcFraction: CGFloat = 240.0 / 360.0
    private let rotation = Angle.degrees(150)

    private var scoreFrac: CGFloat { CGFloat(min(max(score, 0), 100)) / 100 }
    private var gold: Color { Color(hex: "#FFC01F") }

    private var fillColors: [Color] {
        crowned
            ? [Color(hex: "#FFE79A"), gold, Color(hex: "#FF9E2C")]
            : [Color(hex: "#8BE86B"), Theme.accent, Color(hex: "#2FCF9A")]
    }
    private var accent: Color { crowned ? gold : Theme.accent }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    var body: some View {
        GeometryReader { geo in
            let inset  = knobRadius + lineWidth / 2 + 4
            let d      = min(geo.size.width, geo.size.height) - inset * 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r      = d / 2
            let theta  = (150.0 + 240.0 * Double(scoreFrac * sweep)) * .pi / 180
            let knob   = CGPoint(x: center.x + r * CGFloat(cos(theta)),
                                 y: center.y + r * CGFloat(sin(theta)))

            ZStack {
                if crowned {
                    ForEach(0..<12, id: \.self) { i in
                        Capsule()
                            .fill(gold.opacity(0.5 * (1 - rayBloom)))
                            .frame(width: 3, height: 13)
                            .offset(y: -(r + 16 + rayBloom * 16))
                            .rotationEffect(.degrees(Double(i) / 12 * 360))
                    }
                    .position(center)
                }

                Circle()
                    .trim(from: 0, to: arcFraction)
                    .stroke(Theme.surface,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(rotation)
                    .frame(width: d, height: d)
                    .position(center)

                Circle()
                    .trim(from: 0, to: arcFraction * scoreFrac * sweep)
                    .stroke(
                        LinearGradient(colors: fillColors,
                                       startPoint: .bottomLeading, endPoint: .topTrailing),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, dash: [3.4, 3.4])
                    )
                    .rotationEffect(rotation)
                    .frame(width: d, height: d)
                    .position(center)
                    .shadow(color: crowned ? gold.opacity(crownGlow * 0.7) : .clear, radius: 12)

                // Sub-circle: Load, inside the score ring.
                if let loadFraction {
                    let sd = d - lineWidth * 2 - 10
                    Circle()
                        .trim(from: 0, to: arcFraction)
                        .stroke(Theme.surface.opacity(0.6),
                                style: StrokeStyle(lineWidth: subLineWidth, lineCap: .round))
                        .rotationEffect(rotation)
                        .frame(width: sd, height: sd)
                        .position(center)
                    Circle()
                        .trim(from: 0, to: arcFraction * CGFloat(min(max(loadFraction, 0), 1)) * sweep)
                        .stroke(Theme.rsa.opacity(0.85),
                                style: StrokeStyle(lineWidth: subLineWidth, lineCap: .round))
                        .rotationEffect(rotation)
                        .frame(width: sd, height: sd)
                        .position(center)
                }

                if score > 0 {
                    Circle()
                        .fill(Theme.bg)
                        .overlay(Circle().strokeBorder(accent, lineWidth: 2))
                        .overlay(
                            Image(systemName: crowned ? "crown.fill" : "checkmark")
                                .font(.system(size: crowned ? 12 : 11, weight: .bold))
                                .foregroundStyle(accent)
                                .scaleEffect(crownScale)
                        )
                        .frame(width: knobRadius * 2, height: knobRadius * 2)
                        .position(knob)
                        .shadow(color: crowned ? gold.opacity(crownGlow) : .clear, radius: 8)
                }

                VStack(spacing: 2) {
                    Text("\(score)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                    Text(caption)
                        .font(Theme.monoLabel)
                        .foregroundStyle(crowned ? gold : Theme.dim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .position(center)
            }
        }
        .frame(height: 196)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(crowned
            ? "Session score \(score) out of 100. \(caption). Crowned."
            : "Session score \(score) out of 100. \(caption).")
        .onAppear(perform: animateIn)
    }

    private func animateIn() {
        guard !reduceMotion else {
            sweep = 1; crownGlow = crowned ? 0.45 : 0; rayBloom = 1
            return
        }
        withAnimation(.easeOut(duration: 0.9)) { sweep = 1 }
        guard crowned else { return }

        // The crown lands as the sweep finishes, so it reads as the result of
        // the dial filling rather than as decoration sitting on top of it.
        crownScale = 0.1
        withAnimation(.spring(response: 0.4, dampingFraction: 0.5).delay(0.8)) { crownScale = 1 }
        withAnimation(.easeOut(duration: 1.1).delay(0.85)) { rayBloom = 1 }
        withAnimation(.easeInOut(duration: 0.7).delay(0.85)) { crownGlow = 0.9 }
        withAnimation(.easeInOut(duration: 1.4).delay(1.6)) { crownGlow = 0.35 }
    }
}
