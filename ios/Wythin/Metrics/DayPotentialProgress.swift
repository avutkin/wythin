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
    enum Color: Equatable { case white, yellow, red, green }
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

// MARK: - Nudge copy

/// The line beside the crowns. Points at the next crown rather than
/// recapping the past, because tomorrow's morning recording is the thing it
/// can actually influence — a "best run yet" claim ages badly the moment a
/// day is missed, and this line must be true every single day it renders.
enum DayPotentialCrownCopy {
    static func text(forMorningCount mornings: Int) -> String {
        guard mornings > 0 else {
            return "Record a morning to start your first crown."
        }
        let remainder = mornings % 7
        let toNext = remainder == 0 ? 7 : 7 - remainder
        let noun = mornings == 1 ? "morning" : "mornings"
        return "\(mornings) \(noun) · \(toNext) to your next crown"
    }
}
