import XCTest
@testable import Wythin

final class MotionComputeTests: XCTestCase {

    private func constant(_ v: SIMD3<Float>, count: Int) -> [SIMD3<Float>] {
        Array(repeating: v, count: count)
    }

    func testReturnsNilBelowMinimumSamples() {
        XCTAssertNil(MotionCompute.magnitudeSD(accXYZ: constant(.init(0, 0, 1000), count: 50)))
    }

    func testPerfectlyStillIsZero() {
        let sd = MotionCompute.magnitudeSD(accXYZ: constant(.init(0, 0, 1000), count: 400))
        XCTAssertEqual(sd ?? -1, 0, accuracy: 0.001)
    }

    func testAlternatingMagnitudeGivesHalfThePeakToPeak() {
        // Magnitudes alternate 1000 / 1100 → mean 1050, SD 50.
        var samples: [SIMD3<Float>] = []
        for i in 0..<400 {
            samples.append(.init(0, 0, i.isMultiple(of: 2) ? 1000 : 1100))
        }
        let sd = MotionCompute.magnitudeSD(accXYZ: samples)
        XCTAssertEqual(sd ?? -1, 50, accuracy: 0.5)
    }
}
