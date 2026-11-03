import XCTest
@testable import Wythin

/// The score's working, as the detail screen now shows it.
///
/// The parts are not a decoration on the score — they ARE the score, folded.
/// A part list that does not reproduce the number printed beside it is worse
/// than no explanation at all, so that identity is the first thing tested.
final class SleepScorePartsTests: XCTestCase {

    private func fullNight() -> SleepScoreInput {
        var input = SleepScoreInput(bedtimeSDMin: 35, asleepSec: 6.5 * 3600,
                                    needSec: 8 * 3600)
        input.bedtimeOutsideMin = 40
        input.longestUnbrokenSec = 110 * 60
        input.wakeBouts = 5
        input.steadyFraction = 0.72
        input.hrNadirDip = 11
        input.hrNadirFraction = 0.6
        input.quietDC = 7.2
        input.quietDCBaseline = 8.0
        input.quietRMSSD = 41
        input.quietRMSSDBaseline = 47
        return input
    }

    // MARK: - The parts are the score

    func testEverySectionsPartsFoldBackToItsScore() {
        let score = SleepScore.compute(fullNight())
        for (section, sectionScore) in score.sections {
            let parts = score.parts[section] ?? []
            XCTAssertFalse(parts.isEmpty, "\(section) was scored, so it must show what from")
            let weight = parts.reduce(0) { $0 + $1.weight }
            let folded = parts.reduce(0) { $0 + $1.weight * $1.score } / weight
            XCTAssertEqual(Double(sectionScore), folded, accuracy: 0.51,
                           "\(section) prints a number its own parts do not add up to")
        }
    }

    func testASectionThatWasNotMeasuredShowsNoParts() {
        var input = SleepScoreInput(bedtimeSDMin: nil, asleepSec: 7 * 3600, needSec: 8 * 3600)
        input.bedtimeOutsideMin = nil
        let score = SleepScore.compute(input)
        XCTAssertNil(score.sections[.timing])
        XCTAssertTrue((score.parts[.timing] ?? []).isEmpty,
                      "showing a range for a section with no input invents a measurement")
    }

    // MARK: - Where the marker sits

    /// The bar is read left-to-right as worse-to-better. A part scoring 100 has
    /// to sit at the right-hand end of it, or the picture contradicts the
    /// number printed above it.
    func testPositionRunsWorstToBestWithTheScore() {
        var input = fullNight()
        input.asleepSec = 8 * 3600          // need met in full
        guard let met = SleepScore.compute(input).parts[.duration]?.first else {
            return XCTFail("duration is scored")
        }
        XCTAssertEqual(met.score, 100, accuracy: 0.01)
        XCTAssertEqual(met.position, 1, accuracy: 0.01)

        input.asleepSec = 4 * 3600          // far past the worst end
        guard let missed = SleepScore.compute(input).parts[.duration]?.first else {
            return XCTFail("duration is scored")
        }
        XCTAssertEqual(missed.score, 0, accuracy: 0.01)
        XCTAssertEqual(missed.position, 0, accuracy: 0.01,
                       "a value beyond the worst end still has to be drawable")
    }

    func testPositionNeverLeavesTheBar() {
        for asleep in stride(from: 2.0, through: 12.0, by: 0.5) {
            var input = fullNight()
            input.asleepSec = asleep * 3600
            let p = SleepScore.compute(input).parts[.duration]?.first
            XCTAssertNotNil(p)
            XCTAssertGreaterThanOrEqual(p?.position ?? -1, 0)
            XCTAssertLessThanOrEqual(p?.position ?? 2, 1)
        }
    }

    /// The label under each end has to name the value at that end, because it
    /// is the only thing telling the reader what the scale is in.
    func testEveryPartCarriesBothEndsAndAValue() {
        let score = SleepScore.compute(fullNight())
        for part in score.parts.values.flatMap({ $0 }) {
            XCTAssertFalse(part.label.isEmpty)
            XCTAssertFalse(part.display.isEmpty, "\(part.label) shows no value")
            XCTAssertFalse(part.worstLabel.isEmpty, "\(part.label) has an unlabelled bad end")
            XCTAssertFalse(part.bestLabel.isEmpty, "\(part.label) has an unlabelled good end")
            XCTAssertNotEqual(part.worst, part.best, "\(part.label) is scored over no range")
            XCTAssertGreaterThan(part.weight, 0)
        }
    }

    // MARK: - Surviving the trip to disk

    func testPartsRoundTripThroughStorage() {
        let score = SleepScore.compute(fullNight())
        let restored = SleepScore.parts(fromJSON: score.partsJSON)
        XCTAssertEqual(restored, score.parts)
    }

    /// Nights scored before parts were stored must open, not crash and not
    /// show an empty range bar.
    func testANightStoredBeforePartsExistedDecodesToNothing() {
        XCTAssertTrue(SleepScore.parts(fromJSON: nil).isEmpty)
        XCTAssertTrue(SleepScore.parts(fromJSON: "not json").isEmpty)
    }
}
