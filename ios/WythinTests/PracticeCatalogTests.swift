import XCTest
@testable import Wythin

final class PracticeCatalogTests: XCTestCase {

    // MARK: Subtype invariant

    /// Every practice's subtype must be a real member of its activityType's
    /// subtypes, so logging a practice always produces a valid ActivityLog and
    /// the prefilled logger sheet lands on a selectable subtype.
    func testEveryPracticeSubtypeIsAValidActivitySubtype() {
        for practice in PracticeCatalog.practices {
            guard let subtype = practice.subtype else { continue }
            XCTAssertTrue(
                practice.activityType.subtypes.contains(subtype),
                "\(practice.id): subtype '\(subtype)' is not a member of \(practice.activityType.rawValue).subtypes"
            )
        }
    }

    // MARK: Art

    func testEveryArtHasTwoColourStops() {
        for practice in PracticeCatalog.practices {
            XCTAssertEqual(practice.art.hexStops.count, 2, "\(practice.id): art needs two hex stops")
        }
    }

    func testPracticeIDsAreUnique() {
        let ids = PracticeCatalog.practices.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate practice id")
    }

    // MARK: Starred / featured

    /// Resonance carried the star and is out of the catalog for now, so nothing is
    /// featured and the hub simply shows no featured card.
    func testNothingIsFeaturedWhileTheCatalogIsTrimmed() {
        XCTAssertTrue(PracticeCatalog.starred.isEmpty)
    }

    // MARK: Lookups

    func testPracticesInCategoryReturnsOnlyThatCategory() {
        for category in PracticeCategory.allCases {
            let inCat = PracticeCatalog.practices(in: category)
            XCTAssertTrue(inCat.allSatisfy { $0.category == category })
        }
    }

    /// The catalog is deliberately trimmed to Box Breathing alone while the pacer
    /// is built out, so "every category is populated" cannot hold. This pins the
    /// trimmed state instead: when practices come back it fails, which is the
    /// reminder to restore the real invariant above it.
    func testCatalogIsTemporarilyThePacersOnly() {
        XCTAssertEqual(PracticeCatalog.practices.map(\.id),
                       ["box-breathing", "resonance-breathing", "coherent-breathing", "hold-breath"],
                       "catalog changed — restore the per-category and per-state coverage tests")
    }

    /// One art token across the catalog. If a practice ever needs its own again,
    /// this is the test that should be deleted deliberately rather than the
    /// consistency drifting away unnoticed.
    func testEveryPracticeSharesTheSameArt() {
        let arts = Set(PracticeCatalog.practices.map(\.art))
        XCTAssertEqual(arts.count, 1, "practices are meant to share one art token")
    }

    func testTheOnlyPopulatedCategoryIsBreathwork() {
        let populated = PracticeCategory.allCases.filter {
            !PracticeCatalog.practices(in: $0).isEmpty
        }
        XCTAssertEqual(populated, [.breathwork])
    }

    // MARK: States

    /// States drive the hub's filter, so an untagged practice is unreachable
    /// anywhere except the All tab.
    func testEveryPracticeHasAtLeastOneState() {
        for practice in PracticeCatalog.practices {
            XCTAssertFalse(practice.states.isEmpty, "\(practice.id): no states")
        }
    }

    func testNoPracticeRepeatsAState() {
        for practice in PracticeCatalog.practices {
            XCTAssertEqual(practice.states.count, Set(practice.states).count,
                           "\(practice.id): duplicate state")
        }
    }

    /// Both pacers serve focus and stress, so anxiety and sleep are empty for now
    /// — their capsules lead to a blank grid until the catalog is restored.
    func testOnlyFocusAndStressHavePracticesWhileTrimmed() {
        let populated = PracticeState.allCases.filter {
            !PracticeCatalog.practices(for: $0).isEmpty
        }
        XCTAssertEqual(populated, [.focus, .stress])
    }

    func testPracticesForStateReturnsOnlyThatState() {
        for state in PracticeState.allCases {
            XCTAssertTrue(PracticeCatalog.practices(for: state).allSatisfy {
                $0.states.contains(state)
            })
        }
    }

    /// Practices that exist for a state lead; ones that merely also serve it follow.
    func testPracticesForStateSortsPrimaryFirst() {
        for state in PracticeState.allCases {
            let results = PracticeCatalog.practices(for: state)
            let primaryFlags = results.map { $0.primaryState == state }
            let firstSecondary = primaryFlags.firstIndex(of: false) ?? primaryFlags.count
            XCTAssertFalse(primaryFlags[firstSecondary...].contains(true),
                           "\(state.rawValue): a primary practice sorted after a secondary one")
        }
    }

    // MARK: Pacer practices

    /// Both hold-free pacers open on 5.5 s a side. What separates them is how the
    /// session is set: Resonance in seconds, Coherent in clicks a phase and a
    /// tempo. Merging them once cost exactly that second control, so it is the
    /// thing worth pinning.
    func testTheTwoHoldFreePacersDifferInHowTheyAreSet() {
        guard let res = PracticeCatalog.practices.first(where: { $0.id == "resonance-breathing" }),
              let resPattern = res.breathPattern,
              let coh = PracticeCatalog.practices.first(where: { $0.id == "coherent-breathing" }),
              let cohPattern = coh.breathPattern else {
            return XCTFail("a hold-free pacer is missing from the catalog")
        }
        XCTAssertFalse(resPattern.hasHolds)
        XCTAssertFalse(cohPattern.hasHolds)

        XCTAssertEqual(res.paceControl, .seconds)
        XCTAssertEqual(coh.paceControl, .clicksAndNote(defaultNote: .eighth))
        XCTAssertNotEqual(res.paceControl, coh.paceControl,
                          "two hold-free pacers set the same way are one practice with two tiles")

        // Both land on 5.5 s a side — reached from opposite directions. Coherent's
        // defaultBPM is the tempo, not the click rate: the note supplies the rest.
        XCTAssertEqual(EvenCadence(beats: resPattern.inhale, bpm: res.defaultBPM).seconds,
                       5.5, accuracy: 0.0001)
        let cohClickRate = coh.defaultBPM * coh.defaultNote.clicksPerBeat
        XCTAssertEqual(Double(cohPattern.inhale) * 60.0 / Double(cohClickRate),
                       5.5, accuracy: 0.0001)
    }

    /// Coherent ships as eleven eighth-note counts at 60 BPM. Those three numbers
    /// have to multiply out to the 5.5 s the practice claims, or its own copy is
    /// wrong the moment the session opens.
    func testCoherentShipsOnElevenEighthsAtSixtyBPM() {
        guard let coh = PracticeCatalog.practices.first(where: { $0.id == "coherent-breathing" }),
              let pattern = coh.breathPattern else {
            return XCTFail("coherent-breathing missing from the catalog")
        }
        XCTAssertEqual(pattern.inhale, 11)
        XCTAssertEqual(pattern.exhale, 11)
        XCTAssertEqual(coh.defaultBPM, 60)
        XCTAssertEqual(coh.defaultNote, .eighth)

        let clickRate = coh.defaultBPM * coh.defaultNote.clicksPerBeat      // 120 clicks/min
        XCTAssertEqual(Double(pattern.inhale) * 60.0 / Double(clickRate), 5.5, accuracy: 0.0001)
        XCTAssertEqual(pattern.breathsPerMinute(bpm: clickRate), 60.0 / 11.0, accuracy: 0.0001)
    }

    /// A pacer set in seconds derives its tempo, so a practice that wants the
    /// tempo, note and per-phase counts has to say so — and only Coherent does.
    func testOnlyCoherentAsksForTheClicksAndNoteControls() {
        let inCounts = PracticeCatalog.practices
            .filter { if case .clicksAndNote = $0.paceControl { return true } else { return false } }
            .map(\.id)
        XCTAssertEqual(inCounts, ["coherent-breathing"])
    }

    /// Every count the session can reach has to resolve to a whole number of
    /// clicks at a whole click rate, or the accent stops landing on the turn.
    func testEveryNoteValueGivesAWholeClickRateAcrossTheTempoRange() {
        for note in NoteValue.allCases {
            for bpm in stride(from: 40, through: 120, by: 5) {
                let rate = bpm * note.clicksPerBeat
                XCTAssertGreaterThan(rate, 0, "\(note.label) at \(bpm) BPM")
                // A count is a whole click by construction, so a phase of n
                // counts is exactly n click-lengths.
                XCTAssertEqual(Double(7) * 60.0 / Double(rate),
                               7 * (60.0 / Double(rate)), accuracy: 0.0001)
            }
        }
    }

    /// A breath with holds is counted against a metronome by definition, so it
    /// gets both controls without having to ask.
    func testABreathWithHoldsDefaultsToClicksAndTempo() {
        guard let box = PracticeCatalog.practices.first(where: { $0.id == "box-breathing" }) else {
            return XCTFail("box-breathing missing")
        }
        XCTAssertEqual(box.paceControl, .beatsAndTempo)
    }

    /// Each of the pair keeps the study that its own framing rests on: the
    /// dose-response work behind six breaths a minute, the decision-making trial
    /// behind the 5.5-second framing.
    func testEachHoldFreePacerCitesTheStudyItsFramingRestsOn() {
        guard let res = PracticeCatalog.practices.first(where: { $0.id == "resonance-breathing" }),
              let coh = PracticeCatalog.practices.first(where: { $0.id == "coherent-breathing" }) else {
            return XCTFail("a hold-free pacer is missing")
        }
        XCTAssertTrue(Set(res.evidence.map(\.doi)).contains("10.3390/ijerph182312478"),
                      "resonance keeps its dose-response study")
        XCTAssertTrue(Set(coh.evidence.map(\.doi)).contains("10.1016/j.ijpsycho.2019.02.011"),
                      "coherent keeps its decision-making trial")
    }

    /// The session's pace stepper has to be able to reach every shipped pattern,
    /// or a practice opens on a setting its own controls can't express.
    func testEveryPacerPatternIsReachableFromTheSessionControls() {
        for practice in PracticeCatalog.practices {
            guard let pattern = practice.breathPattern else { continue }   // hold trainers have no pace
            // A clicks-and-note session counts further than a beat stepper does:
            // at an eighth of a beat a phase needs twice as many counts.
            let paceRange = { if case .clicksAndNote = practice.paceControl { return 2...24 }
                              else { return 2...12 } }()
            XCTAssertTrue(paceRange.contains(pattern.inhale),
                          "\(practice.id): \(pattern.inhale) counts is outside its own pace stepper's range")
            XCTAssertTrue(paceRange.contains(pattern.exhale),
                          "\(practice.id): \(pattern.exhale) counts is outside its own pace stepper's range")
            XCTAssertTrue((40...120).contains(practice.defaultBPM),
                          "\(practice.id): \(practice.defaultBPM) BPM is outside the tempo stepper's range")
            XCTAssertEqual(practice.defaultBPM % 5, 0,
                           "\(practice.id): the tempo stepper moves in fives, so \(practice.defaultBPM) is unreachable")
        }
    }

    func testHoldBreathIsASetBasedHoldTrainer() {
        guard let hold = PracticeCatalog.practices.first(where: { $0.id == "hold-breath" }),
              let plan = hold.holdProtocol else {
            return XCTFail("hold-breath missing from the catalog")
        }
        XCTAssertEqual(hold.kind, .holdTrainer(.standard))
        XCTAssertNil(hold.breathPattern, "a hold trainer is not a pacer")
        XCTAssertEqual(hold.activityType, .breathwork)
        XCTAssertEqual(hold.subtype, "Breath Hold")
        XCTAssertGreaterThan(plan.sets, 0)
        XCTAssertGreaterThan(plan.holdSeconds, 0)
    }

    /// This practice can make someone faint, so the warning is part of the
    /// content rather than something the session screen happens to render.
    func testHoldBreathWarnsAboutWaterInItsDescription() {
        guard let hold = PracticeCatalog.practices.first(where: { $0.id == "hold-breath" }) else {
            return XCTFail("hold-breath missing from the catalog")
        }
        XCTAssertTrue(hold.description.lowercased().contains("water"),
                      "the description must carry the water warning")
    }

    func testResonanceBreathingIsAHoldFreePacer() {
        guard let res = PracticeCatalog.practices.first(where: { $0.id == "resonance-breathing" }),
              let pattern = res.breathPattern else {
            return XCTFail("resonance-breathing missing from the catalog")
        }
        XCTAssertEqual(res.activityType, .breathwork)
        XCTAssertEqual(res.subtype, "Resonance")
        XCTAssertFalse(pattern.hasHolds, "resonance pauses at neither end")
        // Read at the practice's own tempo, not a hardcoded 60: the pace is
        // declared in beats, and beats only mean seconds against a tempo.
        XCTAssertEqual(pattern.breathsPerMinute(bpm: res.defaultBPM), 60.0 / 11.0, accuracy: 0.0001)
    }

    func testCoherentBreathingIsAHoldFreePacer() {
        guard let coh = PracticeCatalog.practices.first(where: { $0.id == "coherent-breathing" }),
              let pattern = coh.breathPattern else {
            return XCTFail("coherent-breathing missing from the catalog")
        }
        XCTAssertEqual(coh.activityType, .breathwork)
        XCTAssertEqual(coh.subtype, "Coherent Breathing")
        XCTAssertFalse(pattern.hasHolds, "the coherent breath pauses at neither end")
        // Read at the click rate the note produces, not at the tempo alone.
        XCTAssertEqual(pattern.breathsPerMinute(bpm: coh.defaultBPM * coh.defaultNote.clicksPerBeat),
                       60.0 / 11.0, accuracy: 0.0001)
    }

    func testBoxBreathingIsAPacerOnTheBoxPattern() {
        guard let box = PracticeCatalog.practices.first(where: { $0.id == "box-breathing" }) else {
            return XCTFail("box-breathing missing from the catalog")
        }
        XCTAssertEqual(box.kind, .pacer(.box))
        XCTAssertEqual(box.breathPattern, .box)
        XCTAssertEqual(box.activityType, .breathwork)
        XCTAssertEqual(box.subtype, "Box Breathing")
        XCTAssertFalse(box.isStarred, "the pacer is not the featured practice")
        XCTAssertFalse(box.isBiofeedback)
    }

    /// A pacer session logs for the elapsed time under this subtype, so it has to
    /// survive the same invariant as everything else — asserted here explicitly
    /// because it's the one practice whose subtype is chosen by a live session.
    func testEveryPacerPracticeHasABreathPattern() {
        for practice in PracticeCatalog.practices {
            if case .pacer = practice.kind {
                XCTAssertNotNil(practice.breathPattern, "\(practice.id): pacer without a pattern")
                XCTAssertGreaterThan(practice.breathPattern?.cycleBeats ?? 0, 0,
                                     "\(practice.id): zero-length cycle would stall the session")
            }
        }
    }

    // MARK: Evidence
    //
    // These are shown to the user as scientific backing, so the bar is that every
    // field resolves to a real, reachable paper. A malformed DOI here is a broken
    // citation on screen.

    private var allEvidence: [PracticeEvidence] {
        PracticeCatalog.practices.flatMap(\.evidence)
    }

    func testEveryPracticeExplainsHowItWorks() {
        for practice in PracticeCatalog.practices {
            XCTAssertFalse(practice.howItWorks.isEmpty, "\(practice.id): no mechanism given")
            for line in practice.howItWorks {
                XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(practice.id): blank howItWorks line")
            }
        }
    }

    func testEveryPracticeCitesAtLeastOneStudy() {
        for practice in PracticeCatalog.practices {
            XCTAssertFalse(practice.evidence.isEmpty, "\(practice.id): no evidence cited")
        }
    }

    func testEveryStudyHasACompleteCitation() {
        for study in allEvidence {
            XCTAssertFalse(study.title.isEmpty,   "\(study.doi): no title")
            XCTAssertFalse(study.authors.isEmpty, "\(study.doi): no authors")
            XCTAssertFalse(study.journal.isEmpty, "\(study.doi): no journal")
            XCTAssertFalse(study.finding.isEmpty, "\(study.doi): no finding")
            XCTAssertTrue((1950...2030).contains(study.year), "\(study.doi): implausible year")
        }
    }

    /// A DOI always starts "10." and carries a registrant prefix and a suffix.
    /// Anything else will not resolve, and a citation that does not resolve is
    /// worse than no citation.
    func testEveryDOIIsWellFormedAndResolvable() {
        for study in allEvidence {
            XCTAssertTrue(study.doi.hasPrefix("10."), "\(study.doi): not a DOI")
            let parts = study.doi.split(separator: "/", maxSplits: 1)
            XCTAssertEqual(parts.count, 2, "\(study.doi): DOI needs a prefix and a suffix")
            XCTAssertFalse(parts.last?.isEmpty ?? true, "\(study.doi): empty DOI suffix")
            XCTAssertEqual(study.url.scheme, "https")
            XCTAssertEqual(study.url.host, "doi.org")
            XCTAssertTrue(study.url.absoluteString.hasSuffix(study.doi))
        }
    }

    func testStudyBadgesAreShortEnoughForTheirChip() {
        for study in allEvidence {
            XCTAssertTrue((2...3).contains(study.mark.count),
                          "\(study.doi): mark '\(study.mark)' won't fit the badge")
            XCTAssertEqual(study.tint.count, 7, "\(study.doi): tint must be #RRGGBB")
            XCTAssertTrue(study.tint.hasPrefix("#"))
        }
    }

    /// The same paper cited by two practices must be the same record, not two
    /// transcriptions that could drift apart.
    func testAStudyCitedTwiceIsIdentical() {
        var byDOI: [String: PracticeEvidence] = [:]
        for study in allEvidence {
            if let existing = byDOI[study.doi] {
                XCTAssertEqual(existing, study, "\(study.doi): cited with differing details")
            }
            byDOI[study.doi] = study
        }
    }

    func testNoPracticeCitesTheSameStudyTwice() {
        for practice in PracticeCatalog.practices {
            let dois = practice.evidence.map(\.doi)
            XCTAssertEqual(dois.count, Set(dois).count, "\(practice.id): duplicate citation")
        }
    }
}
