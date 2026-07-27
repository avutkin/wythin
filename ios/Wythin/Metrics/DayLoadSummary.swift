import Foundation

/// The "how the day has gone so far" line under Day Potential.
///
/// Deliberately NOT LLM-generated: it is the only part of the card that
/// changes through the day, and a template updates continuously for free and
/// never rewords itself. It is also the only place today's running average is
/// allowed to appear — the live-state read never compares to an average.
enum DayLoadSummary {

    /// Nothing meaningful to say before this much of the day has passed.
    static let minimumHours: Double = 2

    static func text(anchorLnRMSSD: Float,
                     dayMeanLnRMSSD: Float?,
                     hoursElapsed: Double) -> String? {
        guard hoursElapsed >= minimumHours,
              let dayMean = dayMeanLnRMSSD,
              anchorLnRMSSD > 1e-6 else { return nil }

        let hours = Int(hoursElapsed.rounded())
        let ratio = dayMean / anchorLnRMSSD

        let tail: String
        switch ratio {
        case 0.95...:
            tail = "you've barely dipped below where you started — **most of the reserve is still there**."
        case 0.85..<0.95:
            tail = "you've been spending it **steadily** rather than in spikes."
        default:
            tail = "you've already used **a lot of it** — what's left is worth protecting."
        }

        return "\(hours) hours in, \(tail)"
    }
}
