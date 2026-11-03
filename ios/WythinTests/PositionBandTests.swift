import XCTest
@testable import Wythin

/// The POSITION strip: contiguous stretches the body held one orientation.
final class PositionBandTests: XCTestCase {

    private func points(_ spec: [(BodyPosition?, Int)]) -> [MetricsHistoryPoint] {
        let start = Date(timeIntervalSince1970: 1_755_000_000)
        var out: [MetricsHistoryPoint] = []
        var i = 0
        for (pos, count) in spec {
            for _ in 0..<count {
                out.append(MetricsHistoryPoint(
                    anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                    meanBPM: 52, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                    breathBPM: 13, motion: 5, bodyPosition: pos,
                    signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2))
                i += 1
            }
        }
        return out
    }

    func testContiguousSamePositionBecomesOneBand() {
        let bands = PreparedNight.positionBands(points([(.supine, 40)]))
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands.first?.position, .supine)
    }

    func testAPositionChangeSplitsTheBand() {
        let bands = PreparedNight.positionBands(points([(.supine, 30), (.leftSide, 30)]))
        XCTAssertEqual(bands.map(\.position), [.supine, .leftSide])
        XCTAssertEqual(bands[0].end, bands[1].start, "bands are contiguous in time")
    }

    func testUnknownStretchesAreNotInventedAsAPosition() {
        // Nil is "the sensor was moving", not a posture. It must leave a gap,
        // not be absorbed into whichever neighbour happens to be adjacent.
        let bands = PreparedNight.positionBands(points([(.supine, 20), (nil, 20), (.prone, 20)]))
        XCTAssertEqual(bands.map(\.position), [.supine, .prone])
        XCTAssertLessThan(bands[0].end, bands[1].start, "the moving stretch stays a gap")
    }

    func testAFlickerTooBriefToBeARollIsNotABand() {
        // One tick of a different orientation between two long stretches is
        // noise in the gravity estimate, not the person turning over.
        let bands = PreparedNight.positionBands(points([(.supine, 40), (.prone, 1), (.supine, 40)]))
        XCTAssertEqual(bands.map(\.position), [.supine], "a single tick is not a position change")
    }

    func testANightWithNoPositionDataHasNoBands() {
        XCTAssertTrue(PreparedNight.positionBands(points([(nil, 60)])).isEmpty)
    }

    // MARK: - Was position ever measured on this night?

    // Two nights produce no bands for completely different reasons, and the
    // screen has to be able to tell them apart: one predates position storage
    // and can NEVER show it, the other recorded orientation but the person
    // never held one long enough to count. Saying "not recorded" about the
    // second, or drawing a blank for the first, are both lies.

    func testANightThatPredatesPositionStorageReportsNoTicks() {
        let night = PreparedNight(points: points([(nil, 60)]))
        XCTAssertEqual(night.positionTicks, 0)
        XCTAssertTrue(night.positionBands.isEmpty)
    }

    func testANightThatMeasuredPositionButNeverHeldOneReportsTicks() {
        // Orientation was stored on every one of these ticks; no stretch
        // survives the two-minute floor, so there are no bands.
        let night = PreparedNight(points: points([(.supine, 1), (.leftSide, 1),
                                                  (.supine, 1), (.prone, 1)]))
        XCTAssertEqual(night.positionTicks, 4)
        XCTAssertTrue(night.positionBands.isEmpty)
    }

    func testPositionMinutesComeFromTheBandsNotTheRawTicks() {
        // 40 ticks x 30 s = 20 min supine, then 40 more on the left.
        let night = PreparedNight(points: points([(.supine, 40), (.leftSide, 40)]))
        XCTAssertEqual(night.positionMinutes[.supine], 20)
        XCTAssertEqual(night.positionMinutes[.leftSide], 20)
        XCTAssertNil(night.positionMinutes[.prone], "a position never held is absent, not zero")
    }

    func testSupineShareIsOfTheTimeAPositionWasKnown() {
        // Not of the whole night: the gaps are stretches where the sensor was
        // moving, and dividing by them would understate every position.
        let night = PreparedNight(points: points([(.supine, 40), (nil, 40), (.leftSide, 40)]))
        XCTAssertEqual(night.positionMinutes[.supine], 20)
        XCTAssertEqual(night.supineSharePct, 50)
    }

    func testSupineShareIsNilWhenNoPositionWasEverHeld() {
        XCTAssertNil(PreparedNight(points: points([(nil, 60)])).supineSharePct)
    }
}

// MARK: - Precomputed draw data

/// The montage stuttered because three of its channels rebuilt their geometry
/// from ~19,000 samples on every redraw, and the tracker redraws continuously
/// while a finger is down. These pin the shape of the precomputed forms.
final class PreparedNightDrawDataTests: XCTestCase {

    private func point(_ minutesIn: Double, motion: Float?) -> MetricsHistoryPoint {
        let base = Calendar.current.date(from: DateComponents(
            year: 2026, month: 8, day: 20, hour: 23))!
        return MetricsHistoryPoint(anchorTestTimestamp: base.addingTimeInterval(minutesIn * 60),
                                   meanBPM: 52, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                                   breathBPM: 13, motion: motion,
                                   signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2)
    }

    func testStageRunsCoverTheNightWithoutOverlapping() {
        let pts = (0..<400).map { point(Double($0) * 0.5, motion: 4) }
        let night = PreparedNight(points: pts)

        XCTAssertFalse(night.stageRuns.isEmpty)
        for (a, b) in zip(night.stageRuns, night.stageRuns.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "runs must not overlap")
            XCTAssertNotEqual(a.stage, b.stage, "adjacent runs must differ, or they are one run")
        }
        XCTAssertEqual(night.stageRuns.first?.start, pts.first?.timestamp)
    }

    func testStageRunsAreFarFewerThanSamples() {
        // The whole point: a run per stage change, not a run per tick.
        let pts = (0..<400).map { point(Double($0) * 0.5, motion: 4) }
        let night = PreparedNight(points: pts)
        XCTAssertLessThan(night.stageRuns.count, pts.count / 4)
    }

    func testMotionTicksAreThinnedButKeepTheLoudest() {
        // One unmistakable spike among thousands of quiet ticks must survive
        // the thinning — dropping every nth sample would lose exactly the
        // movements the strip exists to show.
        var pts = (0..<4000).map { point(Double($0) * 0.05, motion: 30) }
        pts[2000] = point(100, motion: 900)
        let night = PreparedNight(points: pts)

        XCTAssertLessThanOrEqual(night.motionTicks.count, PreparedNight.maxMotionTicks)
        XCTAssertEqual(night.motionTicks.map(\.scale).max() ?? 0, 1.0, accuracy: 0.0001,
                       "the loudest movement of the night must survive thinning")
    }

    func testQuietNightYieldsNoMotionTicks() {
        let night = PreparedNight(points: (0..<200).map { point(Double($0) * 0.5, motion: nil) })
        XCTAssertTrue(night.motionTicks.isEmpty)
    }
}
