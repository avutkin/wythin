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

    // MARK: - Motion scope (gravity-free view of the raw stream)

    /// EMA time constant of the gravity estimate, as the per-sample weight.
    /// 1/200 at 200 Hz ≈ a 1-second horizon: slow enough that breathing and
    /// gestures pass through, fast enough to re-settle after a posture change.
    static let gravityAlpha: Float = 1 / 200

    /// How still is still, in mg RMS of the gravity-free residual. Breathing
    /// alone reads well under `stillCeiling`; deliberate movement clears
    /// `subtleCeiling` easily.
    static let stillCeiling:  Float = 12
    static let subtleCeiling: Float = 40

    enum MotionState { case still, subtle, moving }

    /// One step of gravity tracking: fold `sample` into the running gravity
    /// estimate and return the gravity-free residual — the part of the reading
    /// that is movement, not orientation.
    static func highPassStep(gravity: inout SIMD3<Float>,
                             sample: SIMD3<Float>,
                             alpha: Float = gravityAlpha) -> SIMD3<Float> {
        gravity += (sample - gravity) * alpha
        return sample - gravity
    }

    /// RMS of the residual vector magnitude over a window, in mg.
    static func residualRMS(_ residuals: ArraySlice<SIMD3<Float>>) -> Float {
        guard !residuals.isEmpty else { return 0 }
        var sumSq: Float = 0
        for r in residuals { sumSq += r.x * r.x + r.y * r.y + r.z * r.z }
        return (sumSq / Float(residuals.count)).squareRoot()
    }

    static func state(rms: Float) -> MotionState {
        if rms <= stillCeiling  { return .still }
        if rms <= subtleCeiling { return .subtle }
        return .moving
    }
}

/// Turns the residual-magnitude stream into discrete, countable movements —
/// the scope's proof that a gesture registered. Hysteresis (enter above
/// `trigger`, leave below `release`) so one movement is one event, not a
/// flicker of them.
struct MotionEventDetector {
    static let trigger: Float = 35   // mg — well above breathing
    static let release: Float = 15   // mg — must settle before the next event

    struct Event: Equatable {
        /// Largest residual magnitude during the excursion, in mg.
        let peak: Float
    }

    private(set) var inMotion = false
    private(set) var count = 0
    private var peak: Float = 0

    /// Feed one residual magnitude; returns the finished event when a
    /// movement ends, nil otherwise. `count` increments when one begins.
    mutating func step(magnitude: Float) -> Event? {
        if magnitude > Self.trigger {
            if !inMotion { inMotion = true; count += 1 }
            peak = max(peak, magnitude)
        } else if inMotion && magnitude < Self.release {
            inMotion = false
            defer { peak = 0 }
            return Event(peak: peak)
        } else if inMotion {
            peak = max(peak, magnitude)
        }
        return nil
    }
}
