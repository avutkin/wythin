import SwiftUI

/// The overall practice impact meter: the session's mean benefit-signed change
/// from before to during, on a diverging −20…+20 % scale centred on zero.
///
/// This replaced a 0–100 arc gauge. The arc encoded "progress toward 100",
/// which no longer describes the value — a negative delta is a real, valid
/// reading (a hard workout), not a low score.
struct PracticeImpactMeter: View {
    let delta:   Double     // benefit-signed percent
    let caption: String

    private static let domain: Double = 20

    /// Position on the track, 0…1, with 0.5 as zero change.
    static func fillFraction(_ delta: Double) -> Double {
        let clamped = min(max(delta, -domain), domain)
        return (clamped + domain) / (2 * domain)
    }

    /// True when the value ran past the domain and the bar is pinned.
    static func isClamped(_ delta: Double) -> Bool { abs(delta) > domain }

    private var frac:      Double { Self.fillFraction(delta) }
    private var isPositive: Bool  { delta >= 0 }
    private var barColor:  Color  { isPositive ? Theme.accent : Theme.warn }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(String(format: "%+.0f%%", delta))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(barColor)
                    .monospacedDigit()
                Text(caption)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Text("avg change, before → during")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim.opacity(0.6))
            }

            GeometryReader { geo in
                let w = geo.size.width
                let mid = w / 2
                let x = CGFloat(frac) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                        .frame(height: 8)

                    // Fill grows from the centre toward the value.
                    Rectangle().fill(barColor)
                        .frame(width: abs(x - mid), height: 8)
                        .offset(x: min(x, mid))
                        // A pinned bar gets a square outer end so it can't be
                        // read as an exact value at the domain edge.
                        .clipShape(RoundedRectangle(cornerRadius: Self.isClamped(delta) ? 0 : 4))

                    // Zero tick.
                    Rectangle().fill(Theme.dim)
                        .frame(width: 1.5, height: 14)
                        .offset(x: mid - 0.75)
                }
                .frame(height: 14)
            }
            .frame(height: 14)

            HStack {
                Text("−20%").font(Theme.monoLabel).foregroundStyle(Theme.dim.opacity(0.6))
                Spacer()
                Text("0").font(Theme.monoLabel).foregroundStyle(Theme.dim.opacity(0.6))
                Spacer()
                Text("+20%").font(Theme.monoLabel).foregroundStyle(Theme.dim.opacity(0.6))
            }
        }
    }
}
