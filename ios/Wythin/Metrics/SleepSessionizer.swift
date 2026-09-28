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
    /// Every finished, unrecorded night in the window, oldest first.
    static func nightsToRecord(from points: [MetricsHistoryPoint],
                               now: Date,
                               recordedDays: Set<Date>) -> [SleepWindow] {
        settledNights(from: points, now: now)
            .filter { !recordedDays.contains($0.day) }
    }

    /// Every night in the lookback that may be written down now — recorded
    /// or not. The recorder uses the recorded ones too, to notice a stored
    /// night that has since grown.
    static func settledNights(from points: [MetricsHistoryPoint], now: Date) -> [SleepWindow] {
        let horizon = now.addingTimeInterval(-SleepThresholds.lookbackSec)
        let recent = points.filter { $0.timestamp >= horizon }
        return SleepDetector.detectAll(recent)
            .filter { isSettled($0, in: recent, now: now) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Whether a detected night is over, rather than merely paused.
    ///
    /// Two tests. Time first: `settleSec` must have passed since the detected
    /// end, or the person may simply be up for the bathroom. Then the tail:
    /// **no tick after the detected end may read as sleep inside the last
    /// `settleSec`.** The stopwatch alone was the race that truncated the
    /// night of 10–11 September 2026 — the sleeper had gone back under eight
    /// minutes before the poll, two short of the ten the detector needs to
    /// call sleep sustained, so the detected end still sat at the earlier
    /// wake, the 45 minutes had passed, and the night was sealed with an hour
    /// and a quarter of sleep still to come. Sleep-like ticks after the end,
    /// however few, mean the night may be continuing, and it waits. The cost
    /// is a later write on a quiet lie-in; the alternative was permanent.
    ///
    /// The tail is read against the night's own baseline, and only as far as
    /// `maxInBedWakeSec` past the end — sleep beyond that is a separate
    /// episode by the detector's own rule, and could not have joined this one.
    static func isSettled(_ night: SleepWindow, in points: [MetricsHistoryPoint], now: Date) -> Bool {
        guard now.timeIntervalSince(night.endedAt) >= SleepThresholds.settleSec else { return false }
        let tailEnd = min(now, night.endedAt.addingTimeInterval(SleepThresholds.maxInBedWakeSec))
        let inside = points.filter { $0.timestamp >= night.startedAt && $0.timestamp <= night.endedAt }
        let tail = points.filter { $0.timestamp > night.endedAt && $0.timestamp <= tailEnd }
        guard !tail.isEmpty else { return true }
        let all = (inside + tail).sorted { $0.timestamp < $1.timestamp }
        let stages = SleepStages.classify(all)
        guard stages.count == all.count else { return true }
        let lastSleepLike = Array(zip(all, stages))
            .last { point, stage in stage != SleepStage.wake && point.timestamp > night.endedAt }?
            .0.timestamp
        guard let lastSleepLike else { return true }
        return now.timeIntervalSince(lastSleepLike) >= SleepThresholds.settleSec
    }

    static func nightToRecord(from points: [MetricsHistoryPoint],
                              now: Date,
                              recordedDays: Set<Date>) -> SleepWindow? {
        let horizon = now.addingTimeInterval(-SleepThresholds.lookbackSec)
        let recent = points.filter { $0.timestamp >= horizon }
        guard let night = SleepDetector.detect(recent) else { return nil }

        // Still asleep, or going back to sleep? The detector trims to the last
        // sustained sleep, so a night in progress ends at roughly "now", and a
        // night whose sleeper has just gone back under ends at the earlier
        // wake. Writing it then would record however much of the night has
        // happened so far — see `isSettled`.
        guard isSettled(night, in: recent, now: now) else { return nil }

        guard !recordedDays.contains(night.day) else { return nil }
        return night
    }
}
