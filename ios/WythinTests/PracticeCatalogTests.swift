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

    func testExactlyOneStarredResonancePractice() {
        let starred = PracticeCatalog.starred
        XCTAssertEqual(starred.count, 1)
        XCTAssertEqual(starred.first?.id, "resonance")
        XCTAssertEqual(starred.first?.kind, .biofeedback(.resonance))
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

    func testEveryCategoryHasAtLeastOnePractice() {
        for category in PracticeCategory.allCases {
            XCTAssertFalse(PracticeCatalog.practices(in: category).isEmpty,
                           "\(category.rawValue) has no practices")
        }
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

    /// An empty state would render as a filter capsule leading to a blank grid.
    func testEveryStateHasAtLeastOnePractice() {
        for state in PracticeState.allCases {
            XCTAssertFalse(PracticeCatalog.practices(for: state).isEmpty,
                           "\(state.rawValue) has no practices")
        }
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
        XCTAssertFalse(box.isStarred, "only Resonance is featured")
        XCTAssertFalse(box.isBiofeedback)
    }

    /// A pacer session logs for the elapsed time under this subtype, so it has to
    /// survive the same invariant as everything else — asserted here explicitly
    /// because it's the one practice whose subtype is chosen by a live session.
    func testEveryPacerPracticeHasABreathPattern() {
        for practice in PracticeCatalog.practices {
            if case .pacer = practice.kind {
                XCTAssertNotNil(practice.breathPattern, "\(practice.id): pacer without a pattern")
                XCTAssertGreaterThan(practice.breathPattern?.cycleSeconds ?? 0, 0,
                                     "\(practice.id): zero-length cycle would stall the session")
            }
        }
    }
}
