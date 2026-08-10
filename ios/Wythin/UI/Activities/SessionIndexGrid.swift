import SwiftUI

/// The scored readings for an activating session, on one 0–100 scale.
///
/// Every reading here used to arrive in its own unit — 0.09 ms/beat beside
/// 3.8 min beside 148 bpm — so nothing could be compared and none of it said
/// whether it was good. One scale and three bands fix both at once.
struct SessionIndexGrid: View {

    let indices: [ScoredIndex]
    let doses: [UngradedDose]

    private let columns = [GridItem(.flexible(), spacing: 6),
                           GridItem(.flexible(), spacing: 6),
                           GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(indices, id: \.name) { IndexCell(index: $0) }
            }
            if !indices.isEmpty { legend }
            if !doses.isEmpty { doseRow }
        }
    }

    /// The bands, in the words they are for. The thresholds come from
    /// `IndexBand` so the legend cannot outlive a change to them.
    private var legend: some View {
        FlowRow(spacing: 10) {
            ForEach([IndexBand.act, .improve, .keep], id: \.self) { band in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(band.tint)
                        .frame(width: 6, height: 6)
                    Text(band.legend)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }

    /// Load and peak, kept out of the scored grid and labelled as to why.
    private var doseRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("NOT GRADED — HOW MUCH YOU DID, NOT HOW WELL")
                .font(.system(size: 8, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                ForEach(doses, id: \.name) { dose in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(dose.name)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                            Text(dose.value)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.text)
                        }
                        Text(dose.caption)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Theme.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }
}

/// One index: the number, its position on the scale, what it means, and the
/// measurement it came from — in decreasing size, so a reader can stop after
/// any line and still have something true.
private struct IndexCell: View {

    let index: ScoredIndex

    var body: some View {
        VStack(spacing: 4) {
            Text(index.name)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("\(index.value)")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(index.band.tint)
                .monospacedDigit()

            // A number without a position is just a number.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.text.opacity(0.09))
                    Capsule().fill(index.band.tint)
                        .frame(width: geo.size.width * CGFloat(index.value) / 100)
                }
            }
            .frame(height: 3)

            Text(index.verdict)
                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(index.band.tint)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if !index.detail.isEmpty {
                Text(index.detail)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 9)
        .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension IndexBand {

    /// White for "fine" rather than a third hue: an ordinary reading should not
    /// compete for attention with the one that needs it.
    var tint: Color {
        switch self {
        case .act:     return Theme.warn
        case .improve: return Theme.text
        case .keep:    return Theme.accent
        }
    }
}

extension IndexBand: Hashable {}
