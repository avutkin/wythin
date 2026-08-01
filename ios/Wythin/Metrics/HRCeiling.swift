import Foundation

/// The personal upper anchor for %HR-reserve, learned from the wearer's own
/// history rather than assumed from their age.
///
/// 220-minus-age carries a standard deviation of roughly ±11 bpm across
/// individuals, which makes it useless as a per-person denominator: two people
/// the same age can differ by 30 bpm at maximum. Every intensity number
/// downstream — %HRR, Load, the VSI slope — divides by this span, so an
/// assumed ceiling would quietly bias all of them.
///
/// The 99th percentile of what this heart has actually done is both
/// self-calibrating and honest. It needs no profile input, and it rises as
/// fitness and hard-effort history accumulate.
enum HRCeiling {

    /// Plausible instantaneous heart rate. Outside this is strap dropout at the
    /// bottom or artifact at the top, and must not set the ceiling.
    static let plausible: ClosedRange<Float> = 30...220

    /// Minimum working span above resting, so the denominator can never
    /// collapse toward zero for someone whose history holds no hard efforts.
    /// Without it, a sedentary first week would make every %HRR read ~100 %.
    static let minimumSpan: Float = 60

    /// 99th percentile of `bpm`, floored at `restingHR + minimumSpan`.
    ///
    /// `bpm` is expected to be roughly the last 180 days of `meanBPM` samples.
    /// The 99th percentile rather than the maximum, because a single corrupted
    /// beat would otherwise define the span for months.
    static func ceiling(bpm: [Float], restingHR: Float) -> Float {
        let floor = restingHR + minimumSpan
        let clean = bpm.filter { plausible.contains($0) }.sorted()
        guard !clean.isEmpty else { return floor }
        let idx = Int(0.99 * Float(clean.count - 1))
        return max(clean[idx], floor)
    }
}
