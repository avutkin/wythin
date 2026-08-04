import Foundation

// MARK: - Score floor

/// The number shown beside the band word — floored so a genuinely low
/// reading never reads as a broken one.
///
/// A computed score of 0 is real data: PotentialScore, the stored
/// `PotentialResult`, and the server all keep seeing exactly that. But a
/// bare "0" next to "DEPLETED" looks like the app failed rather than like a
/// hard morning, so only the digit on screen is floored — never the model.
enum DayPotentialDisplay {
    static let scoreFloor = 1

    static func score(for result: PotentialResult?) -> Int? {
        guard let result else { return nil }
        return max(result.score, scoreFloor)
    }
}

// MARK: - Crown ladder

/// A single crown to draw. `overflowCount` is non-nil only for a collapsed
/// crown standing in for more than `CrownLadder.collapseThreshold` of its
/// colour — see `CrownLadder` for why that collapse exists.
struct CrownToken: Equatable {
    enum Color: Equatable {
        case white, yellow, red, green

        /// The word this colour is called on screen. Kept on the enum itself
        /// so the nudge copy and the trailing silhouette's tint can only ever
        /// read it from one place — they cannot drift apart by editing one
        /// site and forgetting the other.
        var word: String {
            switch self {
            case .white:  return "white"
            case .yellow: return "yellow"
            case .red:    return "red"
            case .green:  return "green"
            }
        }
    }
    let color: Color
    let overflowCount: Int?

    init(_ color: Color, overflowCount: Int? = nil) {
        self.color = color
        self.overflowCount = overflowCount
    }
}

/// Turns a cumulative count of recorded mornings into a base-4 ladder of
/// crowns: four yellow become one red, four red become one green.
///
/// Counted cumulatively rather than as an unbroken run — "number of days
/// with recordings compound" was the user's own framing. Rewarding the
/// total is deliberately kinder than a consecutive-day streak: missing a
/// Tuesday should cost a day, not the whole ladder.
enum CrownLadder {

    /// Above this many individual crowns of one colour, the row switches to
    /// a single crown plus a count. Only green can grow unbounded — four
    /// years of daily mornings is ~13 — and by three crowns the row is
    /// already as wide as the busiest tier (yellow or red) ever gets, so
    /// that is where the collapse starts.
    static let collapseThreshold = 3

    struct Counts: Equatable {
        let greens:   Int
        let reds:     Int
        let yellows:  Int
        let hasWhite: Bool
    }

    /// The raw base-4 maths, uncollapsed — kept separate from `tokens` so
    /// the ladder arithmetic can be pinned exactly, independent of the
    /// display-only overflow decision.
    static func counts(forMorningCount mornings: Int) -> Counts {
        guard mornings > 0 else {
            return Counts(greens: 0, reds: 0, yellows: 0, hasWhite: false)
        }
        let weeks = mornings / 7
        return Counts(
            greens:   weeks / 16,
            reds:     (weeks % 16) / 4,
            yellows:  weeks % 4,
            hasWhite: mornings % 7 != 0)
    }

    /// The crowns to draw, greens collapsed once there would be more than
    /// `collapseThreshold` of them.
    static func tokens(forMorningCount mornings: Int) -> [CrownToken] {
        let c = counts(forMorningCount: mornings)
        var tokens: [CrownToken] = []

        if c.greens > collapseThreshold {
            tokens.append(CrownToken(.green, overflowCount: c.greens))
        } else {
            tokens.append(contentsOf: Array(repeating: CrownToken(.green), count: c.greens))
        }
        tokens.append(contentsOf: Array(repeating: CrownToken(.red), count: c.reds))
        tokens.append(contentsOf: Array(repeating: CrownToken(.yellow), count: c.yellows))
        if c.hasWhite { tokens.append(CrownToken(.white)) }

        return tokens
    }
}

// MARK: - Crown ladder: progress toward the next crown

extension CrownLadder {

    /// How far into the *current* week's run of mornings sits, as a 0–1
    /// fraction — the bar beneath the ladder fills this.
    ///
    /// A freshly completed week (`mornings` an exact multiple of seven) must
    /// read as a full bar, not an empty one: the naive remainder is zero
    /// right at that instant, which would flash the bar back to empty the
    /// same morning a crown was earned.
    static func progressFraction(forMorningCount mornings: Int) -> Double {
        guard mornings > 0 else { return 0 }
        let remainder = mornings % 7
        return remainder == 0 ? 1.0 : Double(remainder) / 7.0
    }

    /// The colour of the crown the progress bar is currently tracking: the
    /// one still being worked toward while the bar is partial, or the one
    /// that was just finished at the instant the bar reads full.
    ///
    /// That second case is why this is keyed off the *ceiling* week number
    /// rather than always looking one week ahead — at an exact boundary
    /// (say, 28 mornings) the week that finishes is week 4 itself, the one
    /// that collapses four yellows into a red, not week 5. Getting this
    /// wrong would show the outline crown turning red a week early, out of
    /// step with the red crown the ladder above it just grew.
    ///
    /// Mirrors the collapse rule in `counts(forMorningCount:)`: a crown is
    /// yellow unless finishing it also finishes a run of four (which makes
    /// it a red) or a run of sixteen (which makes it a green). Kept as its
    /// own pure function, separate from the token list, so the outline
    /// crown at the end of the progress bar can pick its colour without
    /// re-deriving the whole ladder.
    static func nextCrownColor(forMorningCount mornings: Int) -> CrownToken.Color {
        guard mornings > 0 else { return colorForWeek(1) }
        let remainder = mornings % 7
        let weekNumber = remainder == 0 ? mornings / 7 : mornings / 7 + 1
        return colorForWeek(weekNumber)
    }

    private static func colorForWeek(_ n: Int) -> CrownToken.Color {
        if n % 16 == 0 { return .green }
        if n % 4 == 0  { return .red }
        return .yellow
    }
}

// MARK: - This week, at a glance

/// One day in the current-week row: whether it has a recorded morning, and
/// whether it's the day this is being shown on.
///
/// Deliberately carries no notion of "missed" — a day later in the week
/// than today hasn't happened yet, and marking it as a failure would be the
/// same scolding tone the rest of this strip has already dropped.
struct DayPotentialWeekCell: Equatable {
    let date: Date
    let isLogged: Bool
    let isToday: Bool
}

/// Builds the Monday-through-Sunday row shown under the crown ladder.
///
/// This counts a different thing than the ladder above it: the ladder is a
/// lifetime total that never resets, so a person can be mid-crown while
/// this week's row shows only two or three marks, or the other way around.
/// The row exists to answer "what has this week looked like so far", not to
/// restate the ladder's arithmetic — see `DayPotentialCrownCopy` for the
/// copy that must stay paired with the ladder instead.
enum DayPotentialWeekRow {

    /// Where `date` sits in a week that always starts on Monday, regardless
    /// of the device's own calendar settings — 0 for Monday, 6 for Sunday.
    static func mondayFirstIndex(for date: Date, calendar: Calendar = .current) -> Int {
        // `.weekday` is 1...7 for Sunday...Saturday under the Gregorian
        // calendar no matter how `firstWeekday` is configured, so this
        // stays Monday-first even on a device set to a Sunday-first week.
        let sundayFirst = calendar.component(.weekday, from: date)
        return (sundayFirst + 5) % 7
    }

    /// The seven cells for the calendar week containing `today`.
    static func cells(loggedDays: Set<Date>, today: Date,
                       calendar: Calendar = .current) -> [DayPotentialWeekCell] {
        let startOfToday = calendar.startOfDay(for: today)
        let offsetFromMonday = mondayFirstIndex(for: startOfToday, calendar: calendar)
        guard let monday = calendar.date(byAdding: .day, value: -offsetFromMonday, to: startOfToday)
        else { return [] }

        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { return nil }
            return DayPotentialWeekCell(date: day,
                                         isLogged: loggedDays.contains(day),
                                         isToday: day == startOfToday)
        }
    }
}

// MARK: - Crown copy

/// The two lines of copy attached to the ladder: the running total shown
/// beside the crowns, and the nudge shown beneath the progress bar.
///
/// Kept as two functions rather than one combined string because they now
/// sit in different places on screen — the count beside the crowns, the
/// nudge under the bar, with the calendar-week row between them. Both stay
/// anchored to the same cumulative count, never to the week row, since a
/// person can be mid-crown while this week's row shows something else
/// entirely and the copy must not pretend those are the same measurement.
enum DayPotentialCrownCopy {

    /// The running total beside the crown row. Nothing to show yet reads as
    /// an invitation rather than a "0 mornings" report card, so this is nil
    /// until the first one lands.
    static func countLabel(forMorningCount mornings: Int) -> String? {
        guard mornings > 0 else { return nil }
        let noun = mornings == 1 ? "morning" : "mornings"
        return "\(mornings) \(noun)"
    }

    /// The line beneath the progress bar. Points at the next crown rather
    /// than recapping the past, because tomorrow's morning recording is the
    /// thing it can actually influence — a "best run yet" claim ages badly
    /// the moment a day is missed, and this line must be true every single
    /// day it renders. Describes the bar's own measurement (mornings until
    /// the next crown) and nothing about the calendar week shown above it.
    ///
    /// Names the colour of that next crown via `CrownLadder.nextCrownColor`,
    /// the same function the trailing silhouette reads its tint from — so a
    /// week that is about to collapse into a red or green crown is always
    /// described in the same word the silhouette is painted, never "yellow"
    /// in prose next to a red outline.
    static func nudgeText(forMorningCount mornings: Int) -> String {
        guard mornings > 0 else {
            return "Record a morning to start your first crown."
        }
        let remainder = mornings % 7
        let toNext = remainder == 0 ? 7 : 7 - remainder
        let noun = toNext == 1 ? "day" : "days"
        let colorWord = CrownLadder.nextCrownColor(forMorningCount: mornings).word
        return "\(toNext) \(noun) to your next \(colorWord) crown"
    }
}
