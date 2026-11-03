import Foundation

/// How tightly clustered the hour of falling asleep is, across whatever nights
/// were recorded — consecutive or not.
///
/// **This replaced the Sleep Regularity Index, and the reason is the device.**
/// SRI compares every minute of the day against the same minute 24 h earlier
/// and scores the agreement. That makes it a superb measure — it is the one
/// sleep number that beat duration head-to-head in 60,977 UK Biobank
/// participants — and a measure of *daily wear* just as much as of the sleeper.
/// A night the strap was not worn has no sleep in it, so it reads as a night
/// spent entirely awake, and every minute of it disagrees with the night
/// before. On a chest strap somebody puts on for a study of a few nights rather
/// than every night of their life, SRI does not report an irregular sleeper. It
/// reports an intermittent wearer, in a number indistinguishable from the
/// first.
///
/// Bedtime consistency asks the question intermittent wear can answer: of the
/// nights we did record, how close together was the time you fell asleep? A gap
/// between two nights costs nothing, because each night contributes one instant
/// and says nothing about the days around it. Three nights across three weeks
/// are as answerable as three in a row.
///
/// Circular statistics throughout, because clock times wrap. 23:50 and 00:10
/// are twenty minutes apart, and any measure that reports them as twenty-three
/// hours and forty is broken for exactly the people who go to bed near
/// midnight — which is most of them.
enum BedtimeConsistency {

    /// A spread needs three points to mean anything. With two, the "spread" is
    /// just half the gap between them, and one late night would read as a
    /// permanent habit.
    static let minNights = 3

    /// Circular standard deviation of sleep onset, in minutes.
    ///
    /// Nil until there are enough nights. The caller shows how many it had —
    /// a consistency figure without its sample size invites more confidence
    /// than three nights can carry.
    static func onsetSDMinutes(of windows: [SleepWindow]) -> Double? {
        guard windows.count >= minNights else { return nil }

        let cal = Calendar.current
        var sumSin = 0.0, sumCos = 0.0
        for w in windows {
            let comps = cal.dateComponents([.hour, .minute, .second], from: w.startedAt)
            let hour = comps.hour ?? 0
            let minute = comps.minute ?? 0
            let second = comps.second ?? 0
            let seconds = Double(hour * 3600 + minute * 60 + second)
            let angle = 2 * .pi * seconds / 86_400
            sumSin += sin(angle)
            sumCos += cos(angle)
        }
        let n = Double(windows.count)
        // Mean resultant length: 1 when every night landed on the same minute,
        // 0 when they are scattered evenly round the clock.
        let r = (sumSin * sumSin + sumCos * sumCos).squareRoot() / n
        guard r > 0 else { return nil }          // perfectly opposed: no centre to speak of
        // Yamartino / Mardia circular SD. Clamped because floating point can
        // put r a hair above 1 when every angle is identical, and log of that
        // is a negative zero the square root would turn into a NaN.
        let radians = (-2 * log(min(1, r))).squareRoot()
        return radians * 86_400 / (2 * .pi) / 60
    }
}

/// Where the night sits on the clock, as distinct from how consistent it is.
///
/// Consistency answers "do you keep the same hours"; it says nothing about
/// *which* hours, so someone reliably asleep at 03:00 scores full marks. This is
/// the other half, and it is the half available from a single night — which
/// matters on a strap somebody wears three times rather than every night.
///
/// ⚠️ **The evidence here is weaker than the regularity evidence and is not in
/// the August report.** Accelerometer-derived sleep onset in ~88,000 UK Biobank
/// participants showed lowest cardiovascular incidence for onset between 22:00
/// and 23:00, with raised hazard both after midnight *and* before 22:00 — a U,
/// not a ramp. Verify before this constant is defended to anyone.
///
/// That U is why "earlier is always better" is not what this scores. Going to
/// bed at 20:00 is scored as further from the middle of the window than 22:30,
/// because that is what the data says, and inventing a monotonic preference
/// would be picking the shape we liked over the one that was measured.
enum BedtimePlacement {

    /// The window with the lowest observed incidence. Both ends matter.
    static let windowStartMinutes: Double = 22 * 60
    static let windowEndMinutes:   Double = 23 * 60

    /// How far outside the window the score runs out. Three hours puts 01:00
    /// and 19:00 at zero, which is far enough that an ordinary late night still
    /// scores something.
    static let reachMinutes: Double = 180

    /// Minutes outside the window, zero when inside it.
    ///
    /// Circular, because a window that ends at 23:00 and an onset at 00:30 are
    /// ninety minutes apart, not twenty-two and a half hours.
    static func minutesOutside(_ onset: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: onset)
        let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        if minutes >= windowStartMinutes && minutes <= windowEndMinutes { return 0 }
        return min(circularGap(minutes, windowStartMinutes),
                   circularGap(minutes, windowEndMinutes))
    }

    private static func circularGap(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b)
        return min(raw, 1440 - raw)
    }
}
