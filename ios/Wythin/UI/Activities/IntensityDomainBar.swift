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
                        Text("\(minutes(seg.seconds)) min \(seg.label)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(seg.color)
                            .monospacedDigit()
                    }
                }
                // "29 moderate" says nothing on its own. These are effort
                // zones read from the heartbeat's own structure, not heart-rate
                // zones, so they need naming in plain words.
                Text("How long you spent in each effort zone — moderate is conversational, heavy is above your aerobic threshold, severe is all-out.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
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
