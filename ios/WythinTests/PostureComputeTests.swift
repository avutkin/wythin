import XCTest
import simd
@testable import Wythin

/// Body position from the gravity vector.
///
/// The signal was always there — `MotionCompute.highPassStep` already tracks
/// gravity in order to subtract it out — and was thrown away, leaving only the
/// SD of the vector *magnitude*, which is rotation-invariant by construction.
/// Supine and left-lateral produced byte-identical values.
final class PostureComputeTests: XCTestCase {

    /// One second of a perfectly still sensor holding the given orientation.
    private func still(_ g: SIMD3<Float>, samples: Int = 400) -> [SIMD3<Float>] {
        (0..<samples).map { _ in g * 1000 }   // H10 reports mg
    }

    // MARK: - The four lying positions

    func testGravityIntoTheBackReadsAsSupine() {
        let (pos, conf) = PostureCompute.classify(gravity: SIMD3(0, 0, -1))
        XCTAssertEqual(pos, .supine)
        XCTAssertGreaterThan(conf, 0.9)
    }

    func testGravityOutOfTheChestReadsAsProne() {
        XCTAssertEqual(PostureCompute.classify(gravity: SIMD3(0, 0, 1)).0, .prone)
    }

    func testGravityAcrossTheChestReadsAsALateralPosition() {
        XCTAssertEqual(PostureCompute.classify(gravity: SIMD3(1, 0, 0)).0, .leftSide)
        XCTAssertEqual(PostureCompute.classify(gravity: SIMD3(-1, 0, 0)).0, .rightSide)
    }

    func testGravityAlongTheBodyReadsAsUpright() {
        // Standing and sitting are the same call here — the strap cannot tell
        // them apart, and for a night neither is "a sleeping position".
        XCTAssertEqual(PostureCompute.classify(gravity: SIMD3(0, -1, 0)).0, .upright)
        XCTAssertEqual(PostureCompute.classify(gravity: SIMD3(0, 1, 0)).0, .upright)
    }

    // MARK: - Refusing to answer

    func testAnOrientationBetweenTwoPositionsIsNotConfidentlyEither() {
        // Halfway between supine and left-side. A classifier that reports one
        // of them at full confidence is lying about a genuinely ambiguous case.
        let g = simd_normalize(SIMD3<Float>(1, 0, -1))
        let (_, conf) = PostureCompute.classify(gravity: g)
        XCTAssertLessThan(conf, 0.8, "a 45° orientation is not a confident call")
    }

    func testTooFewSamplesYieldsNoGravityEstimate() {
        XCTAssertNil(PostureCompute.gravity(accXYZ: still(SIMD3(0, 0, -1), samples: 10)))
    }

    func testMovementYieldsNoGravityEstimate() {
        // Gravity is only meaningful when the sensor is still; during a roll
        // the mean of the window is a smear between two orientations.
        var moving = still(SIMD3(0, 0, -1), samples: 200)
        moving += still(SIMD3(1, 0, 0), samples: 200)
        XCTAssertNil(PostureCompute.gravity(accXYZ: moving),
                     "a window spanning a position change is not a position")
    }

    // MARK: - End to end

    func testAStillSupineWindowClassifiesAsSupine() {
        guard let g = PostureCompute.gravity(accXYZ: still(SIMD3(0, 0, -1))) else {
            return XCTFail("a still window should yield gravity")
        }
        XCTAssertEqual(PostureCompute.classify(gravity: g).0, .supine)
    }

    func testGravityIsNormalisedSoScaleDoesNotMatter() {
        // The H10 reports mg, but nothing downstream should depend on that.
        guard let g = PostureCompute.gravity(accXYZ: still(SIMD3(0, 0, -1))) else {
            return XCTFail("no gravity")
        }
        XCTAssertEqual(simd_length(g), 1, accuracy: 0.01)
    }
}
