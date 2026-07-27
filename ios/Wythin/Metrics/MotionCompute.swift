import Foundation

/// Stillness detection input for the day's rested anchor: how much the
/// accelerometer vector magnitude varied over the window.
///
/// The H10 reports ACC in mg, so this SD is in mg too — a seated-still read
/// sits in the low single digits, typing and walking are an order of
/// magnitude above. Compared against `AnchorThresholds.stillnessSD`.
enum MotionCompute {

    /// Minimum samples before the SD means anything (200 Hz × ~1 s).
    static let minimumSamples = 200

    /// SD of the ACC vector magnitude over the window, in mg.
    /// Returns nil when there aren't enough samples.
    static func magnitudeSD(accXYZ: [SIMD3<Float>]) -> Float? {
        guard accXYZ.count >= minimumSamples else { return nil }

        var sum: Float = 0
        var magnitudes = [Float]()
        magnitudes.reserveCapacity(accXYZ.count)
        for v in accXYZ {
            let m = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
            magnitudes.append(m)
            sum += m
        }
        let mean = sum / Float(magnitudes.count)

        var variance: Float = 0
        for m in magnitudes { variance += (m - mean) * (m - mean) }
        variance /= Float(magnitudes.count)

        return variance.squareRoot()
    }
}
