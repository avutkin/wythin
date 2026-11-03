import SwiftUI

/// One input to a section: the range it is scored over, where tonight landed,
/// and what that was worth.
///
/// This replaced a paragraph. The prose said what a section was *for*, which is
/// worth saying once and does not answer the question people actually ask —
/// "why 26?" A range with a marker on it answers that without being read: the
/// eye finds the dot, the two ends say what good and bad look like in the
/// metric's own units, and the number on the right is the arithmetic.
struct SleepPartBar: View {
    let part: SleepScore.Part

    /// Warm at the bad end, cool at the good one, and deliberately not a
    /// traffic light. A night is not a pass or a fail, and three hard colour
    /// bands invite the reader to chase the band rather than read the value.
    private var tint: Color {
        switch part.score {
        case ..<34:  return Theme.warn
        case ..<67:  return Color(hex: "#FFC01F")
        default:     return Theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(part.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 6)
                Text(part.display)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tint)
                Text("\(Int(part.score.rounded()))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .frame(width: 24, alignment: .trailing)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.surface)
                        .frame(height: 5)
                    Capsule()
                        .fill(tint.opacity(0.5))
                        .frame(width: max(4, geo.size.width * part.position), height: 5)
                    // The marker, not a fill edge: the value is a point on a
                    // range, and a bar that only fills reads as a proportion of
                    // something — which is what the section score is, not this.
                    Circle()
                        .fill(tint)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                        .offset(x: max(0, min(geo.size.width - 9, geo.size.width * part.position - 4.5)))
                }
                .frame(height: 9)
            }
            .frame(height: 9)

            HStack {
                Text(part.worstLabel)
                Spacer()
                // Only worth saying when the section has more than one input.
                if part.weight < 1 {
                    Text("\(Int((part.weight * 100).rounded()))% of this section")
                        .foregroundStyle(Theme.dim.opacity(0.7))
                    Spacer()
                }
                Text(part.bestLabel)
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(Theme.dim.opacity(0.8))
        }
    }
}
