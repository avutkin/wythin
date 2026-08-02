import Foundation

/// The resting-to-ceiling heart-rate span every intensity number divides by.
///
/// %HRR, Load and the VSI slope all rest on this, so getting it wrong biases
/// all of them in the same direction at once. It lives in one place because it
/// was previously computed twice — once when storing the response, once again
/// in the detail view for the chart — and two copies of a definition drift.
struct ReserveSpan: Equatable {
    let restingHR: Float
    let ceiling:   Float

    /// A last-resort span for a device with no history at all.
    static let fallback = ReserveSpan(restingHR: 60, ceiling: 180)

    /// Resting heart rate, in order of trustworthiness.
    ///
    /// 1. The median of recent daily anchors. The anchor detector already finds
    ///    a still, rested window and takes the median heart rate in it — that is
    ///    a true resting rate, and the app computes it for other screens.
    /// 2. Failing that, the 5th percentile of heart rate **while barely moving**.
    /// 3. Failing that, the 5th percentile of everything.
    ///
    /// The distinction matters more than it looks. Straps are worn mostly during
    /// exercise, so the 5th percentile of all samples sits well above true rest
    /// — which shrinks the reserve span, and inflates %HRR and Load for every
    /// session. Using an anchor-derived resting rate removes that bias.
    static func build(anchorRestingHRs: [Float],
                      bpm: [Float],
                      motion: [Float?]) -> ReserveSpan {
        let resting = anchorResting(anchorRestingHRs)
            ?? stillResting(bpm: bpm, motion: motion)
            ?? percentile(bpm, 0.05)
            ?? fallback.restingHR
        return ReserveSpan(restingHR: resting,
                           ceiling: HRCeiling.ceiling(bpm: bpm, restingHR: resting))
    }

    private static func anchorResting(_ values: [Float]) -> Float? {
        let clean = values.filter { HRCeiling.plausible.contains($0) }.sorted()
        guard !clean.isEmpty else { return nil }
        return clean[clean.count / 2]
    }

    /// 5th percentile of heart rate over samples taken while essentially still.
    /// Needs a reasonable number of them, or it is just the same noisy estimate.
    private static func stillResting(bpm: [Float], motion: [Float?]) -> Float? {
        guard bpm.count == motion.count else { return nil }
        let still = zip(bpm, motion).compactMap { hr, m -> Float? in
            guard let m, m < AnchorThresholds.stillnessSD else { return nil }
            return hr
        }
        guard still.count >= 200 else { return nil }
        return percentile(still, 0.05)
    }

    private static func percentile(_ values: [Float], _ p: Float) -> Float? {
        let clean = values.filter { HRCeiling.plausible.contains($0) }.sorted()
        guard !clean.isEmpty else { return nil }
        return clean[Int(p * Float(clean.count - 1))]
    }
}
