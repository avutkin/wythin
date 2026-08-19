import Foundation

/// Decides *when* the app may write a night down.
///
/// `SleepDetector` answers what the night was; this answers whether it is safe
/// to record it yet. The two questions are genuinely separate, and conflating
/// them is how a poll that runs every few minutes ends up either truncating a
/// night at 03:00 or writing the same night a hundred times before breakfast.
///
/// **The app never claims to know you are asleep while you are asleep.** That
/// is deliberate. Wake detection is the weakest channel any wearable has —
/// published specificity runs 29–52% — so a live "you're asleep now" call would
/// be wrong often, and wrong in a way the user would see. Retrospection is
/// strictly easier: by morning the whole shape of the night is on disk, the
/// boundaries can be found by looking at both sides of every transition, and
/// nothing has to be guessed in real time.
enum SleepSessionizer {

    /// The one night that is finished, recent, and not yet written — or nil.
    ///
    /// - Parameters:
    ///   - points: recent tick history, oldest first or not, it is sorted.
    ///   - now: the clock, injected so this stays pure and testable.
    ///   - recordedDays: `SleepWindow.day` for nights already stored.
    static func nightToRecord(from points: [MetricsHistoryPoint],
                              now: Date,
                              recordedDays: Set<Date>) -> SleepWindow? {
        let horizon = now.addingTimeInterval(-SleepThresholds.lookbackSec)
        let recent = points.filter { $0.timestamp >= horizon }
        guard let night = SleepDetector.detect(recent) else { return nil }

        // Still asleep? The detector trims to the last sustained sleep, so a
        // night in progress ends at roughly "now". Writing it then would record
        // however much of the night has happened so far and, being idempotent
        // afterwards, never correct itself.
        guard now.timeIntervalSince(night.endedAt) >= SleepThresholds.settleSec else { return nil }

        guard !recordedDays.contains(night.day) else { return nil }
        return night
    }
}
