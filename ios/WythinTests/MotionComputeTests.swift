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

    // MARK: - Movement event detection (the "did it feel that?" counter)

    func testDetectorCountsOneEventPerExcursion() {
        var d = MotionEventDetector()
        // still → burst (3 samples above trigger) → still
        XCTAssertNil(d.step(magnitude: 5))
        XCTAssertNil(d.step(magnitude: 50))
        XCTAssertNil(d.step(magnitude: 90))
        XCTAssertNil(d.step(magnitude: 40))
        let event = d.step(magnitude: 5)
        XCTAssertEqual(event?.peak ?? 0, 90, accuracy: 0.01, "Event reports the excursion's peak")
        XCTAssertEqual(d.count, 1, "One excursion is one movement, however many samples it lasts")
    }

    func testDetectorHysteresisDoesNotFlicker() {
        // Between release (15) and trigger (35) the state must hold, both ways.
        var d = MotionEventDetector()
        XCTAssertNil(d.step(magnitude: 25))          // below trigger: still still
        XCTAssertEqual(d.count, 0)
        _ = d.step(magnitude: 60)                    // now moving
        XCTAssertNil(d.step(magnitude: 25), "Mid-band while moving: no event end yet")
        XCTAssertNil(d.step(magnitude: 60))
        XCTAssertEqual(d.count, 1, "Dipping into the band and back is still ONE movement")
        XCTAssertNotNil(d.step(magnitude: 5))
    }

    func testDetectorCountsSeparateEvents() {
        var d = MotionEventDetector()
        _ = d.step(magnitude: 60); _ = d.step(magnitude: 5)   // event 1
        _ = d.step(magnitude: 80)
        let second = d.step(magnitude: 5)                      // event 2
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(second?.peak ?? 0, 80, accuracy: 0.01)
    }

    func testResidualRMS() {
        // Constant 30 mg on one axis → RMS 30.
        let hp: [SIMD3<Float>] = Array(repeating: .init(30, 0, 0), count: 100)
        XCTAssertEqual(MotionCompute.residualRMS(hp[...]), 30, accuracy: 0.01)
        XCTAssertEqual(MotionCompute.residualRMS(ArraySlice<SIMD3<Float>>()), 0)
    }
}
