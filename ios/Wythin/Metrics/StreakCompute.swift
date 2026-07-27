import Foundation

struct StreakResult: Equatable {
    let current:      Int
    let best:         Int
    let graceUsed:    Bool
    let totalAnchors: Int
}

/// Consecutive mornings with a valid anchor, forgiving one skipped day per
/// rolling 7.
///
/// Strict streaks punish travel and illness — the days the data is most
/// informative — and a broken streak is a common quit trigger, so a single
/// miss keeps the run alive.
enum StreakCompute {

    /// A second miss within this many traversed days ends the run.
    static let graceWindow = 7

    static func evaluate(days: Set<Date>, today: Date, calendar: Calendar = .current) -> StreakResult {
        let start = calendar.startOfDay(for: today)
        guard !days.isEmpty else {
            return StreakResult(current: 0, best: 0, graceUsed: false, totalAnchors: 0)
        }

        // Today not yet logged is not a miss — start the walk at yesterday.
        let anchorDay = days.contains(start)
            ? start
            : (calendar.date(byAdding: .day, value: -1, to: start) ?? start)
        let (current, graceUsed) = run(endingAt: anchorDay, days: days, calendar: calendar)

        let best = days.map { run(endingAt: $0, days: days, calendar: calendar).length }.max() ?? 0

        return StreakResult(current: current,
                            best: max(best, current),
                            graceUsed: graceUsed,
                            totalAnchors: days.count)
    }

    /// Walks backwards from `day`, counting logged days and allowing at most
    /// one miss in any `graceWindow` of traversed days.
    private static func run(endingAt day: Date,
                            days: Set<Date>,
                            calendar: Calendar) -> (length: Int, graceUsed: Bool) {
        guard days.contains(day) else { return (0, false) }

        var length = 0
        var graceUsed = false
        var missOffsets: [Int] = []
        var offset = 0

        while true {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: day) else { break }
            if days.contains(d) {
                length += 1
            } else {
                // A second miss inside the rolling window ends the run.
                if missOffsets.contains(where: { offset - $0 < graceWindow }) { break }
                missOffsets.append(offset)
                graceUsed = true
            }
            offset += 1
            // Stop once nothing older remains.
            if !days.contains(where: { $0 < d }) { break }
        }

        return (length, graceUsed)
    }
}
