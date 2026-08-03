import Foundation

/// The 0–100 score for a restorative practice — meditation, breathwork, a nap,
/// thermal work.
///
/// Built from how much the nine metrics improved, and nothing else. The
/// stronger the improvements, the higher the score. This replaces a signed
/// average change: "+23 %" answered *which direction* the session went, which
/// is a different question from *how good it was*, and a diverging meter
/// centred on zero made a session that merely held steady look like the middle
/// of the range rather than the bottom of it.
enum RestorativeScore {

    /// A benefit-signed improvement of this size on a metric is full marks.
    /// Chosen so a session that lifts most metrics by a fifth scores near the
    /// top, which is about where a genuinely deep practice lands.
    static let fullMarks: Double = 20

    /// Fewer than this many metrics with data and the mean is too thin to show.
    static let minimumMetrics = 3

    /// - Parameter uplifts: benefit-signed % change, during vs before, one per
    ///   metric. Already signed so that positive is better for every metric —
    ///   a falling heart rate arrives here as a positive.
    static func score(uplifts: [Double?]) -> Int? {
        let present = uplifts.compactMap { $0 }
        guard present.count >= minimumMetrics else { return nil }

        // A metric that got worse contributes nothing rather than a negative.
        // The penalty is already there — it drags the mean down by occupying a
        // slot with zero — and letting it go negative would let one noisy
        // metric erase several real improvements.
        let credits = present.map { min(max($0 / fullMarks, 0), 1) }
        return Int((credits.reduce(0, +) / Double(credits.count) * 100).rounded())
    }

    /// How many of the nine actually improved — the honest denominator behind
    /// the score, and the thing people check it against.
    static func improvedCount(uplifts: [Double?]) -> (improved: Int, measured: Int) {
        let present = uplifts.compactMap { $0 }
        return (present.filter { $0 > 0 }.count, present.count)
    }

    /// Plain-language read. Describes the practice, never the practitioner.
    static func caption(_ score: Int) -> String {
        switch score {
        case 80...:   return "deeply restorative"
        case 60..<80: return "restorative"
        case 40..<60: return "settling"
        case 20..<40: return "lightly settling"
        default:      return "held steady"
        }
    }
}
