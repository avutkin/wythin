import SwiftUI

/// The 0–100 headline for an exercise session, as an arc gauge.
///
/// At or above the crown threshold the gauge earns a crown: it drops in, the
/// arc sweeps, and a ring of rays blooms once. The celebration fires only on a
/// firm score — never on a provisional one — because a crown that appears today
/// and vanishes tomorrow costs more trust than it buys.
struct ExerciseScoreGauge: View {
    let score:   Int
    let caption: String
    let crowned: Bool

    @State private var sweep:      CGFloat = 0
    @State private var crownScale: CGFloat = 0.1
    @State private var crownGlow:  Double  = 0
    @State private var rayBloom:   CGFloat = 0

    private let lineWidth:   CGFloat = 14
    private let arcFraction: CGFloat = 240.0 / 360.0
    private let rotation = Angle.degrees(150)

    private var scoreFrac: CGFloat { CGFloat(min(max(score, 0), 100)) / 100 }

    private var arcColors: [Color] {
        crowned
            ? [Color(hex: "#FFD76E"), Color(hex: "#FFC01F"), Color(hex: "#FF9E2C")]
            : [Color(hex: "#8BE86B"), Theme.accent, Color(hex: "#2FCF9A")]
    }

    private var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                GeometryReader { geo in
                    let inset  = lineWidth / 2 + 10
                    let d      = min(geo.size.width, geo.size.height) - inset * 2
                    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

                    ZStack {
                        // Rays bloom outward once, behind the arc.
                        if crowned {
                            ForEach(0..<12, id: \.self) { i in
                                Capsule()
                                    .fill(Color(hex: "#FFC01F").opacity(0.55 * (1 - rayBloom)))
                                    .frame(width: 3, height: 14)
                                    .offset(y: -(d / 2 + 14 + rayBloom * 18))
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
                                LinearGradient(colors: arcColors,
                                               startPoint: .bottomLeading,
                                               endPoint: .topTrailing),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .rotationEffect(rotation)
                            .frame(width: d, height: d)
                            .position(center)
                            .shadow(color: crowned ? Color(hex: "#FFC01F").opacity(crownGlow * 0.7)
                                                   : .clear,
                                    radius: 14)
                    }
                }
                .frame(height: 176)

                VStack(spacing: 2) {
                    if crowned {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(LinearGradient(
                                colors: [Color(hex: "#FFE79A"), Color(hex: "#FFC01F")],
                                startPoint: .top, endPoint: .bottom))
                            .scaleEffect(crownScale)
                            .shadow(color: Color(hex: "#FFC01F").opacity(crownGlow), radius: 10)
                            .padding(.bottom, 2)
                    }
                    Text("\(score)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                }
            }

            // Outside the ZStack: inside it, the caption lands in the arc's
            // bottom gap and collides with the two stroke ends.
            Text(caption.uppercased())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(crowned ? Color(hex: "#FFC01F") : Theme.dim)
                .tracking(1.2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(crowned
            ? "Session score \(score) out of 100. \(caption). Crowned."
            : "Session score \(score) out of 100. \(caption).")
        .onAppear(perform: animateIn)
    }

    private func animateIn() {
        guard !reduceMotion else {
            sweep = 1; crownScale = 1; crownGlow = crowned ? 0.5 : 0; rayBloom = 1
            return
        }
        withAnimation(.easeOut(duration: 0.9)) { sweep = 1 }
        guard crowned else { crownScale = 1; return }

        // The crown lands just after the arc finishes drawing, so the reward
        // reads as the *result* of the sweep rather than as decoration on top.
        withAnimation(.spring(response: 0.45, dampingFraction: 0.5).delay(0.75)) {
            crownScale = 1
        }
        withAnimation(.easeOut(duration: 1.1).delay(0.8)) { rayBloom = 1 }
        withAnimation(.easeInOut(duration: 0.7).delay(0.8)) { crownGlow = 0.9 }
        withAnimation(.easeInOut(duration: 1.4).delay(1.5)) { crownGlow = 0.35 }
    }
}
