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

    // MARK: Referential integrity

    func testEveryPracticeReferencesAKnownTeacher() {
        for practice in PracticeCatalog.practices {
            XCTAssertNotNil(
                PracticeCatalog.teacher(practice.teacherID),
                "\(practice.id): unknown teacherID '\(practice.teacherID)'"
            )
        }
    }

    func testPracticeAndTeacherIDsAreUnique() {
        let practiceIDs = PracticeCatalog.practices.map(\.id)
        XCTAssertEqual(practiceIDs.count, Set(practiceIDs).count, "duplicate practice id")
        let teacherIDs = PracticeCatalog.teachers.map(\.id)
        XCTAssertEqual(teacherIDs.count, Set(teacherIDs).count, "duplicate teacher id")
    }

    // MARK: Art

    func testEveryArtHasTwoColourStops() {
        for practice in PracticeCatalog.practices {
            XCTAssertEqual(practice.art.hexStops.count, 2, "\(practice.id): art needs two hex stops")
        }
        for teacher in PracticeCatalog.teachers {
            XCTAssertEqual(teacher.art.hexStops.count, 2, "\(teacher.id): art needs two hex stops")
        }
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

    func testPracticesByTeacherReturnsOnlyThatTeacher() {
        for teacher in PracticeCatalog.teachers {
            let byTeacher = PracticeCatalog.practices(byTeacher: teacher.id)
            XCTAssertTrue(byTeacher.allSatisfy { $0.teacherID == teacher.id })
        }
    }

    /// The catalog is deliberately trimmed to Box Breathing alone while the pacer
    /// is built out, so "every category is populated" cannot hold. This pins the
    /// trimmed state instead: when practices come back it fails, which is the
    /// reminder to restore the real invariant above it.
    func testCatalogIsTemporarilyBoxBreathingOnly() {
        XCTAssertEqual(PracticeCatalog.practices.map(\.id), ["box-breathing"],
                       "catalog changed — restore the per-category and per-state coverage tests")
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

    /// Box Breathing serves focus and stress, so anxiety and sleep are empty for
    /// now — their capsules lead to a blank grid until the catalog is restored.
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
}
