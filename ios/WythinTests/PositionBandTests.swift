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
}
