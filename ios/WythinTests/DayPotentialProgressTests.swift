import XCTest
@testable import Wythin

/// The Day Potential strip's presentation-only logic: the display floor, the
/// crown ladder, and the copy that nudges toward the next crown. All three
/// are pure, so they are pinned here without a store or a SwiftData context.
final class DayPotentialProgressTests: XCTestCase {

    // MARK: - Display floor

    private func result(score: Int) -> PotentialResult {
        PotentialResult(
            score: score,
            band: PotentialBand.forScore(score),
            components: PotentialComponents(lnRMSSDz: 0, dcZ: 0, restingHRz: 0),
            penalties: PotentialPenalties(stability: 0, fragmentation: 0, organization: 0),
            saturated: false)
    }

    /// The regression this whole item exists to prevent: a hard morning must
    /// not display "0" beside the band word. Also pins the other half of the
    /// contract — the model itself is never touched by the floor.
    func testZeroScoreRoundTripsAsZeroInModelButDisplaysAsOne() {
        let r = result(score: 0)
        XCTAssertEqual(r.score, 0, "the stored/model score must stay exactly 0")
        XCTAssertEqual(DayPotentialDisplay.score(for: r), 1, "the displayed score must never read 0")
    }

    func testNoResultDisplaysNilNotZero() {
        XCTAssertNil(DayPotentialDisplay.score(for: nil))
    }

    func testScoreAboveFloorPassesThroughUnchanged() {
        XCTAssertEqual(DayPotentialDisplay.score(for: result(score: 45)), 45)
        XCTAssertEqual(DayPotentialDisplay.score(for: result(score: 1)), 1)
    }

    // MARK: - Crown ladder: raw maths (worked examples from the spec)

    func testZeroMorningsHasNoCrownsAtAll() {
        let c = CrownLadder.counts(forMorningCount: 0)
        XCTAssertEqual(c, CrownLadder.Counts(greens: 0, reds: 0, yellows: 0, hasWhite: false))
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 0), [])
    }

    func testElevenMorningsIsOneYellowAndOneWhite() {
        let c = CrownLadder.counts(forMorningCount: 11)
        XCTAssertEqual(c, CrownLadder.Counts(greens: 0, reds: 0, yellows: 1, hasWhite: true))
    }

    func test587MorningsIsFiveGreenZeroRedThreeYellowOneWhite() {
        let c = CrownLadder.counts(forMorningCount: 587)
        XCTAssertEqual(c, CrownLadder.Counts(greens: 5, reds: 0, yellows: 3, hasWhite: true))
    }

    // MARK: - Crown ladder: boundaries

    /// One away from a crown: the current week has six of its seven
    /// mornings, so only the white (in-progress) crown shows.
    func testSixMorningsShowsOnlyTheWhiteCrown() {
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 6), [CrownToken(.white)])
    }

    /// Exactly seven: one full week, no partial week left over, so the white
    /// crown must NOT appear.
    func testSevenMorningsIsExactlyOneYellowNoWhite() {
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 7), [CrownToken(.yellow)])
    }

    /// Four completed weeks (28 mornings) roll the four yellows into one red,
    /// landing on an exact multiple with no white crown.
    func testTwentyEightMorningsIsExactlyOneRedNoWhite() {
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 28), [CrownToken(.red)])
    }

    /// Sixteen completed weeks (112 mornings) roll the four reds into one
    /// green, again landing exactly with no white crown.
    func testOneHundredTwelveMorningsIsExactlyOneGreenNoWhite() {
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 112), [CrownToken(.green)])
    }

    /// One morning past a completed-week boundary puts the white crown back.
    func testOneMorningPastAWeekBoundaryShowsWhiteAgain() {
        let tokens = CrownLadder.tokens(forMorningCount: 8)
        XCTAssertTrue(tokens.contains(CrownToken(.white)))
    }

    // MARK: - Crown ladder: overflow

    /// At the collapse threshold, greens still draw individually — collapse
    /// must not trigger a step early.
    func testThreeGreensStillDrawIndividually() {
        // 3 greens, 0 red, 0 yellow, no white: 48 completed weeks, 336 mornings.
        let tokens = CrownLadder.tokens(forMorningCount: 336)
        XCTAssertEqual(tokens, [CrownToken(.green), CrownToken(.green), CrownToken(.green)])
    }

    /// One green past the threshold collapses to a single crown carrying a
    /// count, so the row can never grow unbounded after years of use.
    func testFourGreensCollapseToOneCrownWithACount() {
        // 4 greens, 0 red, 0 yellow, no white: 64 completed weeks, 448 mornings.
        let tokens = CrownLadder.tokens(forMorningCount: 448)
        XCTAssertEqual(tokens, [CrownToken(.green, overflowCount: 4)])
    }

    /// The 587-morning worked example also exercises overflow together with
    /// the other tiers: five greens collapse, yellows and white draw normally.
    func test587MorningsCollapsesGreensButDrawsOtherTiersIndividually() {
        let tokens = CrownLadder.tokens(forMorningCount: 587)
        XCTAssertEqual(tokens, [
            CrownToken(.green, overflowCount: 5),
            CrownToken(.yellow), CrownToken(.yellow), CrownToken(.yellow),
            CrownToken(.white),
        ])
    }

    // MARK: - Copy: count label (beside the crown row)

    func testZeroMorningsHasNoCountLabel() {
        XCTAssertNil(DayPotentialCrownCopy.countLabel(current: 0, total: 0))
    }

    func testOneMorningUsesSingularPlainFormRegardlessOfStreak() {
        // "1 consecutive day" would be silly, so even when the one morning
        // on record is itself the current run, the label stays plain.
        XCTAssertEqual(DayPotentialCrownCopy.countLabel(current: 1, total: 1), "1 day of measurement")
    }

    /// The spec's own worked example: an unbroken run of eleven that
    /// accounts for every morning on record earns the "consecutive" wording.
    func testElevenMorningsWithNoGapUsesConsecutiveWording() {
        XCTAssertEqual(DayPotentialCrownCopy.countLabel(current: 11, total: 11),
                       "11 consecutive days of measurement")
    }

    /// The case that matters: the cumulative total is eleven, but the
    /// current run is shorter, meaning a day was missed somewhere in the
    /// history. The label must fall back to the plain, total-only wording
    /// rather than claiming a consecutive run that isn't true. A test that
    /// only ever passed equal `current`/`total` pairs would still pass even
    /// if the code always printed "consecutive" — this one would not.
    func testGapBetweenCurrentAndTotalDropsConsecutiveWording() {
        XCTAssertEqual(DayPotentialCrownCopy.countLabel(current: 4, total: 11),
                       "11 days of measurement")
    }

    // MARK: - Copy: nudge line (beneath the progress bar)

    func testZeroMorningsInvitesRatherThanReprimands() {
        let text = DayPotentialCrownCopy.nudgeText(forMorningCount: 0)
        XCTAssertEqual(text, "Record a morning to start your first crown.")
        XCTAssertFalse(text.contains("0"), "must not claim zero mornings as a fact to report")
    }

    func testOneDayRemainingUsesSingularNoun() {
        // 6 mornings in: one more closes the week, so the nudge must say
        // "1 day", not "1 days". The week being closed is the first ever,
        // so its colour is yellow.
        XCTAssertEqual(DayPotentialCrownCopy.nudgeText(forMorningCount: 6),
                       "1 day to your next yellow crown")
    }

    /// The spec's own worked example: 11 mornings is 4 into the second
    /// week, so 3 remain, and that week is an ordinary yellow.
    func testElevenMorningsNudgeMatchesTheSpecExample() {
        XCTAssertEqual(DayPotentialCrownCopy.nudgeText(forMorningCount: 11),
                       "3 days to your next yellow crown")
    }

    /// Landing exactly on a boundary starts a fresh full week toward the one
    /// after it, which at this point in the ladder is still yellow.
    func testExactlyOnACrownBoundaryPointsAFullWeekAhead() {
        XCTAssertEqual(DayPotentialCrownCopy.nudgeText(forMorningCount: 7),
                       "7 days to your next yellow crown")
    }

    // MARK: - Copy: the colour word must agree with the silhouette's tint

    /// This is the regression the whole feature exists to prevent: the
    /// sentence and the trailing silhouette are painted from two different
    /// call sites, and only sharing `nextCrownColor` keeps them honest. Pins
    /// it at the red collapse boundary — one morning short of the 4th
    /// completed week, the week whose completion rolls four yellows into a
    /// red (see `testFourthYellowCompletingTurnsIntoARed` above) — so a test
    /// that merely checked "contains a colour word" could not pass while the
    /// word and the underlying colour had actually diverged.
    func testAtTheRedCollapseBoundaryTheWordAndTheColourAgree() {
        let mornings = 27
        let color = CrownLadder.nextCrownColor(forMorningCount: mornings)
        XCTAssertEqual(color, .red, "test setup: 27 mornings must be one day from the red-collapse boundary")
        XCTAssertEqual(DayPotentialCrownCopy.nudgeText(forMorningCount: mornings),
                       "1 day to your next \(color.word) crown")
        XCTAssertEqual(DayPotentialCrownCopy.nudgeText(forMorningCount: mornings),
                       "1 day to your next red crown")
    }

    /// Same guard at the green collapse boundary — one morning short of the
    /// 16th completed week, which rolls four reds into a green (see
    /// `testFourthRedCompletingTurnsIntoAGreen` above).
    func testAtTheGreenCollapseBoundaryTheWordAndTheColourAgree() {
        let mornings = 111
        let color = CrownLadder.nextCrownColor(forMorningCount: mornings)
        XCTAssertEqual(color, .green, "test setup: 111 mornings must be one day from the green-collapse boundary")
        XCTAssertEqual(DayPotentialCrownCopy.nudgeText(forMorningCount: mornings),
                       "1 day to your next \(color.word) crown")
        XCTAssertEqual(DayPotentialCrownCopy.nudgeText(forMorningCount: mornings),
                       "1 day to your next green crown")
    }

    /// The user has asked three times for no dash construction in this UI —
    /// this pins that regression directly rather than trusting a one-off read.
    func testCopyNeverUsesADashConstruction() {
        for mornings in [0, 1, 6, 7, 11, 14, 28, 587] {
            let nudge = DayPotentialCrownCopy.nudgeText(forMorningCount: mornings)
            XCTAssertFalse(nudge.contains("—"), "\(mornings) mornings produced a dash: \(nudge)")
            XCTAssertFalse(nudge.contains(" - "), "\(mornings) mornings produced a hyphen dash: \(nudge)")
            // Exercised at both an unbroken run and a gapped one, since the
            // two branches produce different sentences.
            if let count = DayPotentialCrownCopy.countLabel(current: mornings, total: mornings) {
                XCTAssertFalse(count.contains("—"), "\(mornings) mornings produced a dash: \(count)")
                XCTAssertFalse(count.contains(" - "), "\(mornings) mornings produced a hyphen dash: \(count)")
            }
            if let count = DayPotentialCrownCopy.countLabel(current: 0, total: mornings) {
                XCTAssertFalse(count.contains("—"), "\(mornings) mornings (gapped) produced a dash: \(count)")
                XCTAssertFalse(count.contains(" - "), "\(mornings) mornings (gapped) produced a hyphen dash: \(count)")
            }
        }
    }

    /// A "best run yet" claim ages badly the instant a day is missed — the
    /// copy must never assert it, regression-tested directly since the old
    /// streak label used to say exactly this.
    func testCopyNeverClaimsABestRun() {
        for mornings in [0, 1, 6, 7, 11, 14, 28, 587] {
            XCTAssertFalse(DayPotentialCrownCopy.nudgeText(forMorningCount: mornings).lowercased().contains("best"))
        }
    }

    // MARK: - Progress bar fraction

    func testZeroMorningsIsAnEmptyBar() {
        XCTAssertEqual(CrownLadder.progressFraction(forMorningCount: 0), 0)
    }

    func testMidWeekBarIsTheRemainderOverSeven() {
        // 11 mornings: 1 completed week (7) plus 4 into the second.
        XCTAssertEqual(CrownLadder.progressFraction(forMorningCount: 11), 4.0 / 7.0,
                       accuracy: 0.0001)
    }

    /// The naive `mornings % 7` is zero right on a boundary — that must not
    /// flash the bar back to empty the instant a crown is earned.
    func testExactCrownBoundaryIsAFullBarNotAnEmptyOne() {
        XCTAssertEqual(CrownLadder.progressFraction(forMorningCount: 7), 1.0)
        XCTAssertEqual(CrownLadder.progressFraction(forMorningCount: 28), 1.0)
    }

    // MARK: - Next crown colour

    func testFirstCrownEverToBeEarnedIsYellow() {
        XCTAssertEqual(CrownLadder.nextCrownColor(forMorningCount: 0), .yellow)
    }

    func testMidRunNextCrownStaysYellow() {
        // 11 mornings: the 2nd week is in progress, and 2 is not a multiple
        // of 4 or 16, so it will land as another plain yellow.
        XCTAssertEqual(CrownLadder.nextCrownColor(forMorningCount: 11), .yellow)
    }

    /// 28 mornings is exactly 4 completed weeks — the same boundary already
    /// pinned in `testTwentyEightMorningsIsExactlyOneRedNoWhite` above, where
    /// the ladder collapses those 4 yellows into 1 red. The bar reads full
    /// at this exact instant (see the progress-fraction tests), so the
    /// colour it shows must match that new red crown, not still be yellow.
    func testFourthYellowCompletingTurnsIntoARed() {
        XCTAssertEqual(CrownLadder.nextCrownColor(forMorningCount: 28), .red)
    }

    /// One morning earlier — 21 mornings, exactly 3 completed weeks — must
    /// NOT yet show red, guarding that the transition lands exactly on 28
    /// and not a week either side of it.
    func testThirdYellowCompletingStaysYellow() {
        XCTAssertEqual(CrownLadder.nextCrownColor(forMorningCount: 21), .yellow)
    }

    /// 112 mornings is exactly 16 completed weeks — the boundary pinned in
    /// `testOneHundredTwelveMorningsIsExactlyOneGreenNoWhite`, where 4 reds
    /// collapse into 1 green. The bar's colour must follow that upgrade too.
    func testFourthRedCompletingTurnsIntoAGreen() {
        XCTAssertEqual(CrownLadder.nextCrownColor(forMorningCount: 112), .green)
    }

    /// 84 mornings (12 completed weeks) is the 3rd red — four reds still
    /// fit under the green threshold of 16 — guarding that the red rule
    /// alone, without also checking "is it a multiple of 16", doesn't fire
    /// green too early.
    func testThirdRedCompletingStaysRedNotGreen() {
        XCTAssertEqual(CrownLadder.nextCrownColor(forMorningCount: 84), .red)
    }

    /// 105 mornings (15 completed weeks) is an ordinary yellow, one week
    /// short of the green-making 16th — guards the green boundary isn't off
    /// by one in the other direction.
    func testWeekBeforeTheGreenTransitionStaysYellow() {
        XCTAssertEqual(CrownLadder.nextCrownColor(forMorningCount: 105), .yellow)
    }
}

// MARK: - Progress bar geometry

/// The capsule bar's fill width and marker clamping — the one part of the
/// restyle that is real logic rather than paint, so it is pinned here
/// independent of any view.
///
/// The travelling marker used to be a plain circle (`knobCenterX`,
/// `knobRadius: 11` — half of a 22pt-diameter circle); it is now a crown
/// icon drawn in a fixed 20pt square frame (`DayPotentialStrip.markerSize`),
/// so the function and every pinned value below moved from "knob"/circle
/// wording to "marker" wording and from radius 11 to radius 10 to match.
/// The clamp arithmetic itself is unchanged — only the real half-width fed
/// into it changed, which is exactly the "re-derive from the shape's actual
/// size" fix this rename exists to pin.
final class DayPotentialBarGeometryTests: XCTestCase {

    func testFillWidthAtZeroFractionIsZero() {
        XCTAssertEqual(DayPotentialBarGeometry.fillWidth(fraction: 0, trackWidth: 200), 0)
    }

    func testFillWidthAtFullFractionIsTheWholeTrack() {
        XCTAssertEqual(DayPotentialBarGeometry.fillWidth(fraction: 1, trackWidth: 200), 200)
    }

    func testFillWidthAtMidFractionIsHalfTheTrack() {
        XCTAssertEqual(DayPotentialBarGeometry.fillWidth(fraction: 0.5, trackWidth: 200), 100)
    }

    /// A fraction outside 0...1 must never paint past either end of the
    /// capsule, even though `CrownLadder.progressFraction` should not itself
    /// produce one — this guards the geometry independently of that caller.
    func testFillWidthClampsFractionOutsideZeroToOne() {
        XCTAssertEqual(DayPotentialBarGeometry.fillWidth(fraction: 1.4, trackWidth: 200), 200)
        XCTAssertEqual(DayPotentialBarGeometry.fillWidth(fraction: -0.2, trackWidth: 200), 0)
    }

    /// At 0%, the naive centre (x=0) would draw the marker half off the left
    /// edge of the capsule — it must clamp to sit fully on the track so it
    /// stays visible at the very start.
    func testMarkerCenterAtZeroPercentClampsOntoTheTrack() {
        XCTAssertEqual(DayPotentialBarGeometry.markerCenterX(fraction: 0, trackWidth: 200, markerRadius: 10), 10)
    }

    /// At 100%, the naive centre (x=trackWidth) would draw the marker half
    /// off the right edge — the same clamp, the other direction, so it
    /// stays visible at the very end too.
    func testMarkerCenterAtFullPercentClampsOntoTheTrack() {
        XCTAssertEqual(DayPotentialBarGeometry.markerCenterX(fraction: 1, trackWidth: 200, markerRadius: 10), 190)
    }

    func testMarkerCenterMidTrackNeedsNoClamping() {
        XCTAssertEqual(DayPotentialBarGeometry.markerCenterX(fraction: 0.5, trackWidth: 200, markerRadius: 10), 100)
    }

    /// A track too narrow to hold the marker at all — its own footprint
    /// alone exceeds the track width — must not invert the clamp into a
    /// negative or out-of-range position; it settles on the track's centre
    /// instead.
    func testMarkerCenterOnATrackNarrowerThanTheMarkerFallsBackToCentre() {
        XCTAssertEqual(DayPotentialBarGeometry.markerCenterX(fraction: 0.5, trackWidth: 10, markerRadius: 10), 5)
    }
}

// MARK: - This week's row

final class DayPotentialWeekRowTests: XCTestCase {

    /// UTC, so the fixed reference dates below can't drift with the machine
    /// running the test.
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: Monday-first index

    /// Every weekday, Monday through Sunday, pinned individually — a
    /// regression that only shifted the mapping by one would still pass a
    /// looser "index is in 0...6" assertion, so each day gets its own exact
    /// expectation.
    func testMondayFirstIndexForEveryWeekday() {
        // 2026-08-03...09 is a real Monday-through-Sunday run.
        let expected: [(Int, Int, Int, Int)] = [
            (2026, 8, 3, 0),  // Monday
            (2026, 8, 4, 1),  // Tuesday
            (2026, 8, 5, 2),  // Wednesday
            (2026, 8, 6, 3),  // Thursday
            (2026, 8, 7, 4),  // Friday
            (2026, 8, 8, 5),  // Saturday
            (2026, 8, 9, 6),  // Sunday
        ]
        for (y, m, d, index) in expected {
            XCTAssertEqual(DayPotentialWeekRow.mondayFirstIndex(for: date(y, m, d), calendar: utc),
                           index, "\(y)-\(m)-\(d) should be index \(index)")
        }
    }

    // MARK: Cell marking, including a month boundary

    /// Monday 2026-01-26 through Sunday 2026-02-01 is a real week that
    /// crosses from January into February, with "today" mid-week on the
    /// Thursday. Mornings are logged on Monday, Wednesday and today only —
    /// everything else, including the still-future Friday/Saturday/Sunday,
    /// must read as unmarked rather than "missed".
    func testWeekCellsAcrossAMonthBoundaryMarkOnlyTheLoggedDays() {
        let monday    = date(2026, 1, 26)
        let tuesday   = date(2026, 1, 27)
        let wednesday = date(2026, 1, 28)
        let thursday  = date(2026, 1, 29)  // "today"
        let friday    = date(2026, 1, 30)
        let saturday  = date(2026, 1, 31)
        let sunday    = date(2026, 2, 1)

        let logged: Set<Date> = [monday, wednesday, thursday]
        let cells = DayPotentialWeekRow.cells(loggedDays: logged, today: thursday, calendar: utc)

        XCTAssertEqual(cells.map(\.date), [monday, tuesday, wednesday, thursday, friday, saturday, sunday])
        XCTAssertEqual(cells.map(\.isLogged), [true, false, true, true, false, false, false],
                       "only Monday, Wednesday and today should be marked")
        XCTAssertEqual(cells.map(\.isToday), [false, false, false, true, false, false, false],
                       "exactly Thursday should be flagged as today")
    }

    /// Reference date itself a Sunday: the week must still start on the
    /// preceding Monday, not roll into the following one.
    func testWeekStartingReferenceOnASundayStillOpensOnMonday() {
        let sunday = date(2026, 2, 1)
        let cells = DayPotentialWeekRow.cells(loggedDays: [], today: sunday, calendar: utc)
        XCTAssertEqual(cells.first?.date, date(2026, 1, 26))
        XCTAssertEqual(cells.last?.date, sunday)
    }
}

// MARK: - Seating the crowns on the rail

final class DayPotentialCrownSeatingTests: XCTestCase {

    /// The whole point: the crown's lower edge lands on the rail's lower
    /// edge, not through its middle. Asserted as the derived bottom rather
    /// than the centre, so it fails if the arithmetic drifts either way.
    func testCrownBottomLandsOnTheRailBottom() {
        let rowHeight: CGFloat = 36, trackHeight: CGFloat = 3, glyph: CGFloat = 20
        let centreY = DayPotentialBarGeometry.crownCenterY(
            rowHeight: rowHeight, trackHeight: trackHeight, glyphHeight: glyph)
        let crownBottom = centreY + glyph / 2
        let railBottom  = rowHeight / 2 + trackHeight / 2
        XCTAssertEqual(crownBottom, railBottom, accuracy: 0.001)
    }

    /// A centred crown would sit at rowHeight/2. Seating it must move it up,
    /// or the change did nothing — this is the test that fails if someone
    /// reverts to centring.
    func testSeatedCrownSitsHigherThanACentredOne() {
        let centreY = DayPotentialBarGeometry.crownCenterY(
            rowHeight: 36, trackHeight: 3, glyphHeight: 20)
        XCTAssertLessThan(centreY, 18)
    }

    /// Two crowns of different sizes must still land on the same rail line.
    func testDifferentSizedCrownsShareTheSameBottomEdge() {
        let big = DayPotentialBarGeometry.crownCenterY(
            rowHeight: 36, trackHeight: 3, glyphHeight: 20) + 20 / 2
        let small = DayPotentialBarGeometry.crownCenterY(
            rowHeight: 36, trackHeight: 3, glyphHeight: 17) + 17 / 2
        XCTAssertEqual(big, small, accuracy: 0.001)
    }

    /// A thicker rail lowers the seat, since the rail's own bottom drops.
    func testAThickerRailSeatsTheCrownLower() {
        let thin = DayPotentialBarGeometry.crownCenterY(
            rowHeight: 36, trackHeight: 3, glyphHeight: 20)
        let thick = DayPotentialBarGeometry.crownCenterY(
            rowHeight: 36, trackHeight: 18, glyphHeight: 20)
        XCTAssertGreaterThan(thick, thin)
    }
}
