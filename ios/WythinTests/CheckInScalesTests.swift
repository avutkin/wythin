import XCTest
@testable import Wythin

/// `FeltStateDraft` — the in-progress check-in. `nil` IS the touched flag;
/// a regression that initialised a scale to 50 "so the knob starts
/// somewhere" would be invisible in the UI and poison every saved row.
final class FeltStateDraftTests: XCTestCase {

    func testAFreshDraftHasNoAnswersAtAll() {
        let draft = FeltStateDraft.empty
        for key in FeltStateScaleKey.allCases {
            XCTAssertNil(draft[key], "\(key)")
        }
        XCTAssertFalse(draft.hasAnyAnswer)
    }

    func testAnUntouchedScalePersistsAsNilNeverAsTheMidpoint() {
        var draft = FeltStateDraft.empty
        draft.focus = 80
        let log = draft.makeLog(kind: .moment, dayKey: "2026-09-13", wornMinutes: 12)
        XCTAssertEqual(log.focus, 80)
        XCTAssertNil(log.energy)
        XCTAssertNil(log.stress)
        XCTAssertNil(log.mood)
        XCTAssertNil(log.anxiety)
        XCTAssertNil(log.sleep)
    }

    func testAPartiallyFilledCheckInSavesAnsweredScalesAndLeavesRestNil() {
        var draft = FeltStateDraft.empty
        draft.energy = 65
        draft.sleep  = 40
        let log = draft.makeLog(kind: .previousDay, dayKey: "2026-09-12", wornMinutes: nil)
        XCTAssertEqual(log.energy, 65)
        XCTAssertEqual(log.sleep, 40)
        XCTAssertNil(log.focus)
        XCTAssertTrue(draft.hasAnyAnswer)
    }

    func testMakeLogStampsKindDayKeyTimezoneAndWornMinutes() {
        var draft = FeltStateDraft.empty
        draft.mood = 70
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let log = draft.makeLog(kind: .moment, dayKey: "2027-01-15", wornMinutes: 13.5,
                                timezone: "Asia/Tokyo", now: now)
        XCTAssertEqual(log.kind, "moment")
        XCTAssertEqual(log.dayKey, "2027-01-15")
        XCTAssertEqual(log.wornMinutes, 13.5)
        XCTAssertEqual(log.timezone, "Asia/Tokyo")
        XCTAssertEqual(log.timestamp, now, "the save instant, never back-dated")
        XCTAssertNil(log.stateKey)
    }

    func testPreviousDayKindIsSpelledTheServersWay() {
        let log = FeltStateDraft.empty.makeLog(kind: .previousDay, dayKey: "2026-09-12", wornMinutes: nil)
        XCTAssertEqual(log.kind, "previous_day")
    }

    func testSubscriptReadsAndWritesTheMatchingScale() {
        var draft = FeltStateDraft.empty
        draft[.anxiety] = 72
        XCTAssertEqual(draft[.anxiety], 72)
        XCTAssertEqual(draft.anxiety, 72)
        XCTAssertNil(draft[.focus])
    }
}

/// "Untouched is not the middle": a never-dragged scale renders a centred
/// grey knob with NO fill, so it cannot be confused with an answer of 50.
final class FeltStateKnobSpecTests: XCTestCase {

    func testUntouchedRendersCenteredWithNoFillAndIsNotTouched() {
        let spec = FeltStateKnobSpec.build(value: nil)
        XCTAssertEqual(spec.knobFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(spec.fillFraction, 0, accuracy: 0.001)
        XCTAssertFalse(spec.isTouched)
    }

    func testAnActualMidpointAnswerIsDistinctFromUntouched() {
        let spec = FeltStateKnobSpec.build(value: 50)
        XCTAssertEqual(spec.knobFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(spec.fillFraction, 0.5, accuracy: 0.001)
        XCTAssertTrue(spec.isTouched)
    }

    func testExtremeValuesMapToTheirEnds() {
        XCTAssertEqual(FeltStateKnobSpec.build(value: 0).knobFraction, 0, accuracy: 0.001)
        XCTAssertEqual(FeltStateKnobSpec.build(value: 100).knobFraction, 1, accuracy: 0.001)
    }

    func testOutOfRangeValuesClampRatherThanOverflow() {
        XCTAssertEqual(FeltStateKnobSpec.build(value: -20).knobFraction, 0, accuracy: 0.001)
        XCTAssertEqual(FeltStateKnobSpec.build(value: 140).knobFraction, 1, accuracy: 0.001)
    }
}

final class FeltStateDragMappingTests: XCTestCase {

    func testMidTrackMapsToFifty() {
        XCTAssertEqual(FeltStateDragMapping.value(x: 50, trackWidth: 100), 50, accuracy: 0.001)
    }

    func testEdgesMapToTheEnds() {
        XCTAssertEqual(FeltStateDragMapping.value(x: 0, trackWidth: 100), 0, accuracy: 0.001)
        XCTAssertEqual(FeltStateDragMapping.value(x: 100, trackWidth: 100), 100, accuracy: 0.001)
    }

    func testADragPastEitherEdgeClamps() {
        XCTAssertEqual(FeltStateDragMapping.value(x: -40, trackWidth: 100), 0, accuracy: 0.001)
        XCTAssertEqual(FeltStateDragMapping.value(x: 260, trackWidth: 100), 100, accuracy: 0.001)
    }

    func testAZeroWidthTrackReturnsZeroRatherThanDividingByZero() {
        XCTAssertEqual(FeltStateDragMapping.value(x: 50, trackWidth: 0), 0, accuracy: 0.001)
    }
}

/// Which scales each prompt asks, in the order the sheet renders them, and
/// the copy that goes with them. Pinned so a later edit cannot reorder or
/// renumber a scale by accident.
final class CheckInKindTests: XCTestCase {

    func testTheMomentAsksFiveScalesFeelFirst() {
        XCTAssertEqual(CheckInKind.moment.scales, [.mood, .focus, .energy, .anxiety, .stress])
    }

    func testThePreviousDayAsksFourPlusSleep() {
        XCTAssertEqual(CheckInKind.previousDay.scales, [.focus, .energy, .anxiety, .stress, .sleep])
    }

    func testEveryScaleHasBothAnchorWordsAndNeitherIsEmptyOrNumeric() {
        let digits = CharacterSet.decimalDigits
        for key in FeltStateScaleKey.allCases {
            XCTAssertFalse(key.leftAnchor.isEmpty, "\(key)")
            XCTAssertFalse(key.rightAnchor.isEmpty, "\(key)")
            XCTAssertNotEqual(key.leftAnchor, key.rightAnchor, "\(key)")
            XCTAssertNil(key.leftAnchor.rangeOfCharacter(from: digits), "\(key)")
            XCTAssertNil(key.rightAnchor.rangeOfCharacter(from: digits), "\(key)")
        }
    }

    func testTheSleepScaleNamesLastNightNotYesterday() {
        XCTAssertTrue(FeltStateScaleKey.sleep.label.lowercased().contains("last night"))
    }

    func testTitlesAndHelpersArePinnedAndShort() {
        XCTAssertEqual(CheckInKind.moment.title, "How do you feel right now?")
        XCTAssertEqual(CheckInKind.previousDay.title, "Yesterday, on average")
        for kind in [CheckInKind.moment, .previousDay] {
            XCTAssertLessThanOrEqual(kind.helper.count, 45, "\(kind)")
            XCTAssertFalse(kind.helper.contains("—"), "\(kind)")
        }
    }

    func testWireKindsMatchTheServer() {
        XCTAssertEqual(CheckInKind.moment.wireValue, "moment")
        XCTAssertEqual(CheckInKind.previousDay.wireValue, "previous_day")
    }
}
