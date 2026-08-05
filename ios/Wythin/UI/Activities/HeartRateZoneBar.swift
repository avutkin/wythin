import SwiftUI

/// Time in each of the five heart-rate zones.
///
/// Sits beside the α1 domain bar rather than replacing it, and says which
/// question it answers, because two intensity displays with no explanation
/// invites reading one as a better version of the other. This one is about how
/// hard the heart worked; the domains are about which physiological system was
/// taxed.
struct HeartRateZoneBar: View {
    let split: [HeartRateZone: TimeInterval]

    private var segments: [(zone: HeartRateZone, seconds: Double)] {
        HeartRateZone.allCases
            .compactMap { z in (split[z]).map { (z, $0) } }
            .filter { $0.1 > 0 }
    }

    private var total: Double { segments.reduce(0) { $0 + $1.seconds } }

    private func colour(_ z: HeartRateZone) -> Color {
        switch z {
        case .z1: return Theme.breathe
        case .z2: return Theme.accent
        case .z3: return Theme.domainHeavy
        case .z4: return Theme.rsa
        case .z5: return Theme.domainSevere
        }
    }

    private func minutes(_ s: Double) -> Int { Int((s / 60).rounded()) }

    var body: some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geo in
                    let gaps = CGFloat(max(segments.count - 1, 0)) * 2
                    let usable = max(geo.size.width - gaps, 1)
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.zone) { seg in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(colour(seg.zone))
                                .frame(width: usable * CGFloat(seg.seconds / total))
                        }
                    }
                }
                .frame(height: 16)

                // Wraps rather than truncating: five labels do not fit on one
                // line on a narrow phone, and a clipped zone reads as absent.
                FlowRow(spacing: 10) {
                    ForEach(segments, id: \.zone) { seg in
                        Text("\(seg.zone.shortLabel) \(minutes(seg.seconds))m")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(colour(seg.zone))
                            .monospacedDigit()
                    }
                }

                if let p = HeartRateZones.polarisation(split) {
                    Text(String(format: "%.0f%% easy · %.0f%% tempo · %.0f%% hard. Zones are how hard your heart worked; the bar above is which system was taxed.",
                                p.easy * 100, p.middle * 100, p.hard * 100))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(segments
                .map { "\($0.zone.shortLabel), \($0.zone.label), \(minutes($0.seconds)) minutes" }
                .joined(separator: ", "))
        }
    }
}

/// Minimal wrapping row — the zone labels overflow one line on a narrow phone.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
