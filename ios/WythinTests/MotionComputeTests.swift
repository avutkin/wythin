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

    // MARK: - High-pass (gravity removal) for the motion scope

    func testHighPassConvergesToZeroOnConstantGravity() {
        // A constant reading is pure gravity — after ~5 time constants the
        // residual must be gone, so a still wearer draws a flat line at zero.
        var gravity = SIMD3<Float>(0, 0, 1000)
        var residual = SIMD3<Float>.zero
        for _ in 0..<2000 {   // 10 s at 200 Hz, alpha 1/200
            residual = MotionCompute.highPassStep(
                gravity: &gravity, sample: .init(-180, -120, 970), alpha: 1 / 200)
        }
        XCTAssertEqual(residual.x, 0, accuracy: 0.5)
        XCTAssertEqual(residual.y, 0, accuracy: 0.5)
        XCTAssertEqual(residual.z, 0, accuracy: 0.5)
    }

    func testHighPassPassesSuddenMovement() {
        // After settling, a 100 mg jolt must come through almost whole.
        var gravity = SIMD3<Float>(0, 0, 970)
        for _ in 0..<2000 {
            _ = MotionCompute.highPassStep(gravity: &gravity, sample: .init(0, 0, 970), alpha: 1 / 200)
        }
        let residual = MotionCompute.highPassStep(
            gravity: &gravity, sample: .init(0, 0, 1070), alpha: 1 / 200)
        XCTAssertEqual(residual.z, 100, accuracy: 2)
    }

    func testMotionStateThresholds() {
        XCTAssertEqual(MotionCompute.state(rms: 5),  .still)
        XCTAssertEqual(MotionCompute.state(rms: 12), .still,  "12 is the edge of still")
        XCTAssertEqual(MotionCompute.state(rms: 20), .subtle)
        XCTAssertEqual(MotionCompute.state(rms: 40), .subtle, "40 is the edge of subtle")
        XCTAssertEqual(MotionCompute.state(rms: 80), .moving)
    }

    func testResidualRMS() {
        // Constant 30 mg on one axis → RMS 30.
        let hp: [SIMD3<Float>] = Array(repeating: .init(30, 0, 0), count: 100)
        XCTAssertEqual(MotionCompute.residualRMS(hp[...]), 30, accuracy: 0.01)
        XCTAssertEqual(MotionCompute.residualRMS(ArraySlice<SIMD3<Float>>()), 0)
    }
}
