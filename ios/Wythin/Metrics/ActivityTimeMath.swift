import Foundation

/// Arithmetic shared by every sheet that shows a start, a duration and an end.
///
/// Pure so the clamping can be tested without a view. The sheets keep the start
/// and the duration as their source of truth — the end time is a projection of
/// those two, and editing it writes back a duration rather than becoming a
/// third independent value that can drift out of agreement with them.
enum ActivityTimeMath {

    /// A session shorter than this is a mis-tap; longer than this is almost
    /// always a forgotten stop rather than a real six-hour practice.
    static let minimumMinutes: Double = 1
    static let maximumMinutes: Double = 180

    /// The end implied by a start and a duration.
    static func end(start: Date, minutes: Double) -> Date {
        start.addingTimeInterval(clampMinutes(minutes) * 60)
    }

    /// The duration implied by an end, clamped to the allowed span.
    ///
    /// An end before the start would otherwise produce a negative duration and
    /// a session that finishes before it begins.
    static func minutes(start: Date, end: Date) -> Double {
        clampMinutes(end.timeIntervalSince(start) / 60)
    }

    static func clampMinutes(_ m: Double) -> Double {
        min(max(m, minimumMinutes), maximumMinutes)
    }

    /// Whether an end time is reachable from this start without clamping — used
    /// to decide whether to show the picker's choice back unchanged.
    static func isWithinRange(start: Date, end: Date) -> Bool {
        let m = end.timeIntervalSince(start) / 60
        return m >= minimumMinutes && m <= maximumMinutes
    }

    /// Formatted "ends 15:42" for the Start Now row.
    static func endLabel(start: Date, minutes: Double?) -> String? {
        guard let minutes else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: end(start: start, minutes: minutes))
    }
}
