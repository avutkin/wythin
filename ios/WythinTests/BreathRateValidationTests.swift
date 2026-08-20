import XCTest
@testable import Wythin

/// Accuracy validation for the breathing-rate estimator.
///
/// The shipped estimator is spectral (Welch PSD → dominant peak → parabolic
/// refinement). Spectral methods share a family of failure modes — harmonics,
/// leakage, drift — so validating one against itself proves little. These
/// tests score it against **two independent methods on the same signals**,
/// with a known ground truth:
///
///   • zero-crossing — a pure time-domain count of how often the band-limited
///     waveform crosses its mean, so it shares no machinery with the FFT;
///   • autocorrelation — periodicity from self-similarity in the time domain,
///     which is robust where spectral leakage is worst.
///
/// Agreement across three methods that fail differently is real evidence.
/// Where they disagree, the case is documented rather than tuned away.
final class BreathRateValidationTests: XCTestCase {

    private let fs: Float = 200   // PolarH10Profile.accSampleRate

    // MARK: - Reference implementations (test-only, deliberately naive)

    /// Breaths per minute by counting mean-crossings of the band-limited
    /// signal. Two crossings per breath.
    private func zeroCrossingBPM(_ signal: [Float]) -> Float? {
        guard let filtered = BreathingCompute.bandpassFilter(
                signal, lowHz: 0.08, highHz: 0.6, fs: fs) else { return nil }
        let mean = filtered.reduce(0, +) / Float(filtered.count)
        // Hysteresis at ±10% of the signal's own amplitude, so noise riding on
        // the mean line isn't counted as a breath.
        let amp = filtered.map { abs($0 - mean) }.reduce(0, +) / Float(filtered.count)
        let band = amp * 0.1
        var crossings = 0
        var above: Bool?
        for v in filtered {
            if v > mean + band {
                if above == false { crossings += 1 }
                above = true
            } else if v < mean - band {
                if above == true { crossings += 1 }
                above = false
            }
        }
        guard crossings >= 2 else { return nil }
        let seconds = Float(signal.count) / fs
        return Float(crossings) / 2 / seconds * 60
    }

    /// Breaths per minute from the first strong autocorrelation peak.
    private func autocorrelationBPM(_ signal: [Float]) -> Float? {
        guard let filtered = BreathingCompute.bandpassFilter(
                signal, lowHz: 0.08, highHz: 0.6, fs: fs) else { return nil }
        // Decimate to 5 Hz — breathing needs no more, and it keeps the O(n²)
        // correlation tractable.
        let step = Int(fs / 5)
        let x = stride(from: 0, to: filtered.count, by: step).map { filtered[$0] }
        let mean = x.reduce(0, +) / Float(x.count)
        let c = x.map { $0 - mean }
        // Lags spanning 4–30 br/min at 5 Hz.
        let minLag = Int(5 * 60 / 30), maxLag = min(Int(5 * 60 / 4), c.count - 1)
        guard maxLag > minLag else { return nil }
        // The FIRST strong peak, not the global maximum: a periodic signal
        // correlates at every multiple of its period, and dividing by the
        // shrinking overlap biases longer lags upward — which is exactly how
        // this reference first reported 6 br/min for an 18 br/min signal.
        var r = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var sum: Float = 0
            for i in 0..<(c.count - lag) { sum += c[i] * c[i + lag] }
            r[lag] = sum / Float(c.count - lag)
        }
        let peak = r[minLag...maxLag].max() ?? 0
        guard peak > 0 else { return nil }
        var bestLag = 0
        for lag in (minLag + 1)..<maxLag where r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1] {
            if r[lag] >= 0.75 * peak { bestLag = lag; break }
        }
        guard bestLag > 0 else { return nil }
        return 5 * 60 / Float(bestLag)
    }

    // MARK: - Signal generation

    /// Chest-motion-like signal: a breathing sinusoid plus optional noise,
    /// slow postural drift, and a harmonic (real chest expansion is not a
    /// pure sine — the exhale is longer than the inhale).
    private func signal(bpm: Float, samples: Int = 16384, snr: Float = 10,
                        drift: Bool = false, harmonic: Float = 0,
                        seed: UInt64 = 12345) -> [Float] {
        var rng = seed
        func noise() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return (Float(rng >> 33) / Float(UInt32.max) - 0.5) * 2
        }
        let hz = bpm / 60
        return (0..<samples).map { i in
            let t = Float(i) / fs
            var v = sin(2 * .pi * hz * t)
            if harmonic > 0 { v += harmonic * sin(2 * .pi * 2 * hz * t) }
            if drift        { v += 3 * sin(2 * .pi * 0.01 * t) }   // 0.01 Hz sway
            return v + noise() / snr
        }
    }

    private func spectralBPM(_ s: [Float]) -> Float? {
        BreathingCompute.computeRate(accZ: s)?.bpm
    }

    // MARK: - Validation

    /// Across the physiological range, in clean conditions, all three methods
    /// must land within a bin of the truth — and of each other.
    func testThreeMethodsAgreeAcrossThePhysiologicalRange() {
        var spectralError: [Float] = []
        for truth: Float in [6, 9, 12, 15, 18, 24] {
            let s = signal(bpm: truth)
            guard let spec = spectralBPM(s),
                  let zc   = zeroCrossingBPM(s),
                  let ac   = autocorrelationBPM(s) else {
                XCTFail("a method returned nil at \(truth) br/min"); continue
            }
            XCTAssertEqual(spec, truth, accuracy: 1.5, "spectral at \(truth)")
            XCTAssertEqual(zc,   truth, accuracy: 1.5, "zero-crossing at \(truth)")
            XCTAssertEqual(ac,   truth, accuracy: 1.5, "autocorrelation at \(truth)")
            spectralError.append(abs(spec - truth))
        }
        let mae = spectralError.reduce(0, +) / Float(spectralError.count)
        XCTAssertLessThan(mae, 0.8, "spectral mean absolute error across the range")
    }

    /// Postural sway an order of magnitude larger than the breath is the
    /// commonest real-world contaminant — it sits below the breathing band,
    /// and the estimator must not lock onto it.
    func testSurvivesLargePosturalDrift() {
        for truth: Float in [10, 15, 20] {
            let s = signal(bpm: truth, drift: true)
            guard let spec = spectralBPM(s) else {
                XCTFail("no reading at \(truth) br/min under drift"); continue
            }
            XCTAssertEqual(spec, truth, accuracy: 1.5,
                           "drift pulled the estimate at \(truth) br/min")
        }
    }

    /// A real breath waveform carries a second harmonic. The estimator must
    /// report the fundamental, not double the rate.
    func testReportsFundamentalNotHarmonic() {
        for truth: Float in [9, 12, 15] {
            let s = signal(bpm: truth, harmonic: 0.45)
            guard let spec = spectralBPM(s) else {
                XCTFail("no reading at \(truth) br/min with harmonic"); continue
            }
            XCTAssertEqual(spec, truth, accuracy: 1.5,
                           "locked onto the harmonic at \(truth) br/min")
        }
    }

    /// Degrading SNR should cost accuracy gracefully and then refuse to
    /// answer — never report a confident wrong number.
    func testDegradesToNilRatherThanGuessing() {
        let clean = spectralBPM(signal(bpm: 15, snr: 10))
        XCTAssertEqual(clean ?? 0, 15, accuracy: 1.5)

        let noisy = spectralBPM(signal(bpm: 15, snr: 2))
        if let noisy { XCTAssertEqual(noisy, 15, accuracy: 3.0, "noisy but confident") }

        // Worth recording: a sine buried 50× under WHITE noise is still
        // recovered, because the breath concentrates in one bin while the
        // noise spreads across all of them. That processing gain is a real
        // property of the spectral method, not a fluke.
        XCTAssertEqual(spectralBPM(signal(bpm: 15, snr: 0.02)) ?? 0, 15, accuracy: 1.5)

        // What must NOT happen is inventing a rate when no breathing exists.
        var rng: UInt64 = 4242
        let pureNoise: [Float] = (0..<16384).map { _ in
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(rng >> 33) / Float(UInt32.max) - 0.5
        }
        XCTAssertNil(spectralBPM(pureNoise))
    }

    /// End-to-end through the tracker: a stream carrying occasional wild
    /// spectral picks must come out closer to the truth than it went in.
    ///
    /// Deterministic by construction — no RNG, so a failure is always a real
    /// regression rather than an unlucky seed.
    func testTrackerImprovesOnRawPerTickEstimates() {
        let truth: Float = 13
        var tracker = BreathRateTracker()
        var rawError: Float = 0
        var trackedError: Float = 0

        for i in 0..<40 {
            // Normal ticks wobble ±1 around the truth; every seventh is a
            // wild pick, alternating high and low so the errors can't cancel.
            let raw: Float = (i % 7 == 0)
                ? truth + (i % 14 == 0 ? 11 : -9)
                : truth + (i % 2 == 0 ? 1 : -1)
            rawError += abs(raw - truth)
            let tracked = tracker.update([.init(bpm: raw, confidence: 6)], dt: 2) ?? raw
            trackedError += abs(tracked - truth)
        }

        XCTAssertLessThan(trackedError, rawError * 0.5,
                          "tracking did not halve the error against raw per-tick picks")
        XCTAssertEqual(tracker.bpm ?? 0, truth, accuracy: 1.0,
                       "tracked rate drifted away from the truth")
    }

}
