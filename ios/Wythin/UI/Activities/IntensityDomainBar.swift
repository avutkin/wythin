import SwiftUI

/// Time spent in each DFA α1 intensity domain, as one stacked bar.
///
/// This is the intensity *distribution*, which is what separates a spiky
/// interval session from a steady tempo that happens to share its average.
/// Over a week it also answers whether the training is genuinely polarised or
/// living in the grey zone.
struct IntensityDomainBar: View {
    let moderateSec: Double
    let heavySec:    Double
    let severeSec:   Double

    private var segments: [(domain: IntensityDomain, seconds: Double, color: Color, label: String)] {
        [
            (.moderate, moderateSec, Theme.accent,       "moderate"),
            (.heavy,    heavySec,    Theme.domainHeavy,  "heavy"),
            (.severe,   severeSec,   Theme.domainSevere, "severe"),
        ].filter { $0.1 > 0 }   // a zero-duration domain is omitted, not drawn as a sliver
    }

    private var total: Double { segments.reduce(0) { $0 + $1.seconds } }

    private func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }

    var body: some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geo in
                    // A 2pt gap between fills: where two saturated segments touch
                    // directly, the boundary reads as a third colour.
                    let gaps = CGFloat(max(segments.count - 1, 0)) * 2
                    let usable = max(geo.size.width - gaps, 1)
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.domain) { seg in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(seg.color)
                                .frame(width: usable * CGFloat(seg.seconds / total))
                        }
                    }
                }
                .frame(height: 16)

                HStack(spacing: 12) {
                    ForEach(segments, id: \.domain) { seg in
                        Text("\(minutes(seg.seconds)) \(seg.label)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(seg.color)
                            .monospacedDigit()
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                segments
                    .map { "\(minutes($0.seconds)) minutes \($0.label)" }
                    .joined(separator: ", ")
            )
        }
    }
}
