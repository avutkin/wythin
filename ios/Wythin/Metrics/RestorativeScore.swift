import Foundation

/// The 0–100 score for a restorative practice — meditation, breathwork, a nap,
/// thermal work.
///
/// Built from how much the named metrics improved, and nothing else. The
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

    /// Credit a single benefit-signed change earns, 0…1.
    ///
    /// A metric that got worse contributes nothing rather than a negative. The
    /// penalty is already there — it drags the mean down by occupying a slot
    /// with zero — and letting it go negative would let one noisy metric erase
    /// several real improvements.
    static func credit(_ uplift: Double) -> Double {
        min(max(uplift / fullMarks, 0), 1)
    }

    /// - Parameter uplifts: benefit-signed % change, during vs before, one per
    ///   metric. Already signed so that positive is better for every metric —
    ///   a falling heart rate arrives here as a positive.
    static func score(uplifts: [Double?]) -> Int? {
        score(during: uplifts, after: Array(repeating: nil, count: uplifts.count))
    }

    /// The score across both phases.
    ///
    /// A practice is worth two things: that it shifted you, and that the shift
    /// held. Scoring only the during-window rewarded a session whose gains
    /// evaporated the moment it ended exactly as much as one that lasted.
    ///
    /// Each metric contributes the mean of whichever phases it has, then the
    /// metrics are averaged. Doing it per metric rather than pooling all
    /// eighteen numbers matters: a metric measured in only one phase would
    /// otherwise carry half the weight of its neighbours for no reason other
    /// than missing data.
    static func score(during: [Double?], after: [Double?]) -> Int? {
        let perMetric = zip(during, after).compactMap { d, a -> Double? in
            let phases = [d, a].compactMap { $0 }.map(credit)
            guard !phases.isEmpty else { return nil }
            return phases.reduce(0, +) / Double(phases.count)
        }
        guard perMetric.count >= minimumMetrics else { return nil }
        return Int((perMetric.reduce(0, +) / Double(perMetric.count) * 100).rounded())
    }

    /// How many of the nine actually improved.
    ///
    /// Reported alongside the score but never as its explanation: the score is
    /// about the *size* of the improvements, this is about the *count*, and
    /// printing them next to each other unexplained made a 9-of-9 session
    /// scoring 63 look like an error.
    static func improvedCount(uplifts: [Double?]) -> (improved: Int, measured: Int) {
        let present = uplifts.compactMap { $0 }
        return (present.filter { $0 > 0 }.count, present.count)
    }

    /// The average improvement the score actually represents, in percent.
    ///
    /// This is what makes the score checkable: 63 is a mean improvement of
    /// about 12.6 %, because full marks is +20 %. Regressions are floored at
    /// zero here for the same reason they are in `score` — so the printed
    /// average cannot disagree with the number above it.
    static func meanImprovement(uplifts: [Double?]) -> Double? {
        let present = uplifts.compactMap { $0 }
        guard present.count >= minimumMetrics else { return nil }
        return present.map { max($0, 0) }.reduce(0, +) / Double(present.count)
    }

    /// The average improvement across both phases — the figure the score is
    /// built from once `after` is included, so the two stay checkable.
    static func meanImprovement(during: [Double?], after: [Double?]) -> Double? {
        let all = (during + after).compactMap { $0 }
        guard all.count >= minimumMetrics else { return nil }
        return all.map { max($0, 0) }.reduce(0, +) / Double(all.count)
    }

    /// Metrics whose improvement was large enough to earn full marks, and so
    /// could not lift the score any further. Worth naming: a +65 % metric
    /// contributes exactly what a +20 % one does, which surprises people.
    static func cappedCount(uplifts: [Double?]) -> Int {
        uplifts.compactMap { $0 }.filter { $0 >= fullMarks }.count
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
