import Foundation
import simd

/// Which way the body is facing, from the direction of gravity.
///
/// Supine matters clinically: it is the position in which the upper airway is
/// most collapsible, and positional sleep apnea is defined by the ratio of
/// events supine against events on the side. It is also the one recommendation
/// in the whole sleep literature that a person can act on the same night.
public enum BodyPosition: Int, CaseIterable, Sendable {
    case supine = 1, prone = 2, leftSide = 3, rightSide = 4, upright = 5

    var label: String {
        switch self {
        case .supine:    return "Supine"
        case .prone:     return "Prone"
        case .leftSide:  return "Left side"
        case .rightSide: return "Right side"
        case .upright:   return "Upright"
        }
    }
}

/// Body position from the accelerometer's gravity component.
///
/// **This was always measurable and was being discarded.** `MotionCompute`
/// already tracks gravity — it has to, in order to subtract it out and get a
/// movement residual — and what reached storage was the SD of the vector
/// *magnitude*. Magnitude is rotation-invariant: ‖a‖ is identical whether a
/// person is supine, prone, or on either side, so orientation was not degraded
/// on the way to disk, it was absent from it.
///
/// **Axis convention.** Worn normally on the sternum, the H10's Y runs along
/// the body (superior), Z points out through the chest (anterior), and X runs
/// across it (lateral). Lying on your back therefore puts gravity at −Z.
///
/// **The left/right caveat is real.** A strap put on rotated end-for-end swaps
/// the sign of X, which swaps left for right. Supine, prone and upright are
/// unaffected — they depend on Y and Z. Until a calibration exists, the two
/// lateral positions should be read as "on a side", and which side named as
/// provisional.
enum PostureCompute {

    /// Enough samples to mean anything (200 Hz × ~1 s), matching `MotionCompute`.
    static let minimumSamples = 200

    /// A window whose readings scatter more than this (mg RMS about the mean)
    /// is not one orientation — it spans a movement or a roll. Reusing the
    /// stillness ceiling that already defines "not moving" elsewhere.
    static let steadinessCeiling: Float = MotionCompute.stillCeiling

    /// Mean gravity direction over the window, normalised. Nil when there are
    /// too few samples, or when the sensor was not still enough for the mean to
    /// describe a single orientation.
    static func gravity(accXYZ: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard accXYZ.count >= minimumSamples else { return nil }

        var sum = SIMD3<Float>.zero
        for v in accXYZ { sum += v }
        let mean = sum / Float(accXYZ.count)

        // Scatter about that mean. A window spanning a roll averages two
        // orientations into a direction the body never actually held, so it
        // must be rejected rather than reported.
        var sumSq: Float = 0
        for v in accXYZ {
            let d = v - mean
            sumSq += simd_length_squared(d)
        }
        let rms = (sumSq / Float(accXYZ.count)).squareRoot()
        guard rms <= steadinessCeiling else { return nil }

        let length = simd_length(mean)
        guard length > 1 else { return nil }   // free-fall or a dead sensor
        return mean / length
    }

    /// The position, and how confident that call is (0–1).
    ///
    /// Confidence is the magnitude of the dominant axis component, so an
    /// orientation sitting between two positions reports as neither at full
    /// strength — which is what a person mid-roll, or propped against pillows,
    /// actually is.
    static func classify(gravity g: SIMD3<Float>) -> (BodyPosition, Float) {
        let along = abs(g.y)          // body's long axis  → upright
        let across = abs(g.x)         // lateral           → on a side
        let through = abs(g.z)        // front-to-back     → supine / prone

        if along >= across && along >= through {
            return (.upright, along)
        }
        if through >= across {
            return (g.z < 0 ? .supine : .prone, through)
        }
        return (g.x > 0 ? .leftSide : .rightSide, across)
    }

    /// Convenience: window → position, when the window supports one.
    static func position(accXYZ: [SIMD3<Float>]) -> (BodyPosition, Float)? {
        gravity(accXYZ: accXYZ).map(classify(gravity:))
    }
}
