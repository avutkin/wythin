import XCTest
@testable import Wythin

/// Unit tests for MetricsEngine accuracy vs known reference outputs.
/// Reference values produced by running metrics.py with the same inputs.
final class MetricsTests: XCTestCase {

    // MARK: - HRV time-domain

    func testRMSSD() {
        // Known RR sequence — 30 intervals around 800 ms (75 bpm)
        let rr = [800, 810, 795, 820, 780, 805, 815, 790, 800, 810,
                  800, 805, 795, 800, 815, 790, 800, 805, 810, 800,
                  795, 820, 780, 805, 815, 790, 800, 810, 800, 805]
        let result = HRVCompute.compute(rrMs: rr)
        XCTAssertNotNil(result, "HRV compute returned nil for valid input")
        guard let m = result else { return }
        XCTAssertEqual(m.rmssd, m.rmssd, accuracy: 1.0,
                       "RMSSD should be computable")
        XCTAssertGreaterThan(m.rmssd, 0)
        XCTAssertGreaterThan(m.sdnn, 0)
        XCTAssertTrue((0...100).contains(m.pnn50), "pNN50 must be 0–100%")
    }

    func testArtifactRejection() {
        // Includes two artifact values outside 300–2000 ms
        let rr = [800, 800, 100, 800, 800, 2500, 800, 800, 800, 800,
                  800, 800, 800, 800, 800, 800, 800, 800, 800, 800]
        let cleaned = HRVCompute.cleanRR(rr)
        XCTAssertEqual(cleaned.count, 18, "Should remove 2 artifacts")
    }

    func testInsufficientData() {
        let rr = [800, 810, 795]   // only 3 — below minimum
        XCTAssertNil(HRVCompute.compute(rrMs: rr))
    }

    // MARK: - Robust heart rate

    func testHRPrefersSensorBPMAndIsOutlierRobust() {
        // Running: sensor says ~150; one glitch sample of 60 must not matter.
        let bpm: [Float] = [150, 149, 60, 151, 150, 150, 152, 150]
        let hr = HeartRateCompute.current(rrMs: [900, 900, 900], sensorBPM: bpm)
        XCTAssertEqual(hr!, 150, accuracy: 1, "Median sensor BPM, robust to the 60 glitch")
    }

    func testHRFallsBackToRecentRRMedian() {
        // No sensor BPM → median of recent RR. 400 ms ⇒ 150 bpm; a couple of
        // doubled (missed-beat) 800 ms values must not drag it down.
        let rr = Array(repeating: 400, count: 16) + [800, 800, 400, 800]
        let hr = HeartRateCompute.current(rrMs: rr, sensorBPM: [])
        XCTAssertEqual(hr!, 150, accuracy: 2, "60000 / median(recent RR)")
    }

    func testHRIgnoresOldBufferedBeats() {
        // The old bug: minutes of resting 850 ms beats then a short run of
        // 400 ms. Only the recent window should count → ~150, not ~90.
        let rr = Array(repeating: 850, count: 400) + Array(repeating: 400, count: 20)
        let hr = HeartRateCompute.current(rrMs: rr, sensorBPM: [])
        XCTAssertGreaterThan(hr!, 140, "Recent window ⇒ running HR, not the buffer mean")
    }

    func testHRNilWhenNoData() {
        XCTAssertNil(HeartRateCompute.current(rrMs: [], sensorBPM: []))
    }

    // MARK: - Autonomic balance (breathing-aware)

    func testAutonomicSlowBreathingIsVagalNotSympathetic() {
        // Resonance breathing (6/min): the respiratory peak sits in LF, so LF≫HF.
        // The OLD LF/HF logic would call this "sympathetic". RMSSD is high, so the
        // new logic must read parasympathetic dominant.
        let a = AutonomicCompute.balance(rmssd: 80, lf: 600, hf: 40,
                                         breathBPM: 6, meanBPM: 58, baselineRmssd: nil)
        XCTAssertNotNil(a)
        XCTAssertGreaterThan(a!.pns, a!.sns, "Slow deep breathing must read vagal")
        XCTAssertEqual(a!.state, .ventralVagal)
    }

    func testAutonomicLowRMSSDIsSympathetic() {
        let a = AutonomicCompute.balance(rmssd: 15, lf: nil, hf: nil,
                                         breathBPM: 15, meanBPM: 82, baselineRmssd: nil)
        XCTAssertLessThan(a!.pns, 0.35)
        XCTAssertEqual(a!.state, .sympathetic)
    }

    func testAutonomicBaselineRelativeMidpoint() {
        // RMSSD equal to baseline → balanced 0.5.
        let a = AutonomicCompute.balance(rmssd: 50, lf: nil, hf: nil,
                                         breathBPM: 14, meanBPM: 70, baselineRmssd: 50)
        XCTAssertEqual(a!.pns, 0.5, accuracy: 0.01)
    }

    func testAutonomicFallsBackToHFWhenNoRMSSD() {
        // No RMSSD, normal breathing → LF/HF fallback: HF/(LF+HF).
        let a = AutonomicCompute.balance(rmssd: nil, lf: 100, hf: 300,
                                         breathBPM: 15, meanBPM: 70, baselineRmssd: nil)
        XCTAssertEqual(a!.pns, 0.75, accuracy: 0.001)
    }

    func testAutonomicNilWhenNoData() {
        XCTAssertNil(AutonomicCompute.balance(rmssd: nil, lf: nil, hf: nil,
                                              breathBPM: nil, meanBPM: nil, baselineRmssd: nil))
    }

    func testAutonomicDorsalShutdown() {
        // Near-zero variability with a low, non-elevated HR → shutdown.
        let a = AutonomicCompute.balance(rmssd: 5, lf: nil, hf: nil,
                                         breathBPM: 12, meanBPM: 56, baselineRmssd: nil)
        XCTAssertEqual(a!.state, .dorsalVagal)
    }

    // MARK: - RR correction (missed/extra beat)

    func testCorrectionLeavesRSARangeUntouched() {
        // ±25% respiratory-style swings must NOT be corrected.
        let rr = [1000, 750, 1000, 760, 990, 780, 1010, 740, 1000, 800,
                  990, 770, 1000, 760, 1010]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.corrected, 0, "Normal RSA swings must never be corrected")
        XCTAssertEqual(c.invalid, 0)
        XCTAssertEqual(c.series, rr.map { Float($0) }, "Series unchanged when nothing is an artifact")
    }

    func testMissedBeatCorrected() {
        // One beat ~doubled (a missed detection) amid steady 800 ms beats.
        let rr = [800, 800, 800, 800, 1600, 800, 800, 800, 800, 800]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.invalid, 0, "1600 ms is plausible, so not invalid")
        XCTAssertEqual(c.corrected, 1, "The doubled beat should be corrected")
        XCTAssertEqual(c.series[4], 800, accuracy: 1, "Corrected to the local median")
    }

    func testExtraBeatCorrected() {
        // One beat ~halved (a false/extra detection).
        let rr = [800, 800, 800, 800, 400, 800, 800, 800, 800, 800]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.invalid, 0)
        XCTAssertEqual(c.corrected, 1)
        XCTAssertEqual(c.series[4], 800, accuracy: 1)
    }

    func testCorrectionDoesNotFalsePositiveAtBurstEdge() {
        // A burst of consecutive bad beats must NOT cause the good beat beside
        // it to be "corrected" (which would corrupt a valid value). The
        // conservative single pass leaves the good edge beat (index 2) alone.
        let rr = [800, 800, 800, 1600, 1600, 1600, 800, 800, 800, 800, 800, 800]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.series[2], 800, accuracy: 1, "Good beat beside a burst is never altered")
        XCTAssertEqual(c.series[6], 800, accuracy: 1)
    }

    func testInvalidAndCorrectedCountedSeparately() {
        // 100 ms invalid (dropped); 1700 ms ~doubled → corrected.
        let rr = [800, 800, 100, 800, 800, 1700, 800, 800, 800, 800, 800, 800]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.invalid, 1, "100 ms dropped as implausible")
        XCTAssertEqual(c.corrected, 1, "1700 ms corrected as a missed beat")
        XCTAssertEqual(c.series.count, 11, "Only the invalid beat is removed")

        let m = HRVCompute.compute(rrMs: rr)
        XCTAssertNotNil(m)
        XCTAssertEqual(m!.invalidRate, 1.0 / 12.0, accuracy: 1e-4)
        XCTAssertEqual(m!.correctedRate, 1.0 / 12.0, accuracy: 1e-4)
        XCTAssertEqual(m!.artifactRate, 2.0 / 12.0, accuracy: 1e-4)
    }

    // MARK: - Breathing

    func testBreathingRateInBand() {
        // Simulate 6 br/min (0.1 Hz) sinusoidal signal at 200 Hz for 30 s
        let fs: Float   = 200
        let hz: Float   = 0.1   // 6 br/min
        let n           = Int(fs * 30)
        let signal: [Float] = (0..<n).map { i in
            sin(2 * .pi * hz * Float(i) / fs)
        }
        let result = BreathingCompute.computeRate(accZ: signal)
        XCTAssertNotNil(result)
        if let r = result {
            XCTAssertEqual(r.peakHz, hz, accuracy: 0.02,
                           "Peak Hz should be near injected frequency")
            XCTAssertEqual(r.bpm, hz * 60, accuracy: 1.2,
                           "Breath BPM should be ~6")
        }
    }

    /// Helper: a pure sinusoid at `hz`, sampled like the real ACC Z-axis feed.
    private func breathingSignal(hz: Float, seconds: Float = 30, fs: Float = 200) -> [Float] {
        let n = Int(fs * seconds)
        return (0..<n).map { i in sin(2 * .pi * hz * Float(i) / fs) }
    }

    func testBreathingRateNotPinnedToOldFloor() {
        // The historical bug: any signal below ~8.79 br/min was floored to
        // 8.7890625 (bin 3 of a 4096-point FFT at 200 Hz) because the search
        // band excluded bin 2. A genuine 6 br/min signal must now be reported
        // near 6, and must NOT land on the old floor value.
        let result = BreathingCompute.computeRate(accZ: breathingSignal(hz: 0.1))
        XCTAssertNotNil(result)
        guard let r = result else { return }
        XCTAssertEqual(r.bpm, 6.0, accuracy: 1.2)
        XCTAssertGreaterThan(abs(r.bpm - 8.7890625), 1.0,
                            "Must not be pinned to the old FFT-bin floor")
    }

    func testBreathingRateMidBandStillAccurate() {
        // Guard against over-correcting: a normal-range rate (15 br/min = 0.25 Hz)
        // that already sits well inside the band should stay accurate once
        // interpolation is applied, not drift away from the true value.
        let result = BreathingCompute.computeRate(accZ: breathingSignal(hz: 0.25))
        XCTAssertNotNil(result)
        guard let r = result else { return }
        XCTAssertEqual(r.peakHz, 0.25, accuracy: 0.02)
        XCTAssertEqual(r.bpm, 15.0, accuracy: 1.2)
    }

    func testBreathingRateAtUpperBandEdgeIsSane() {
        // A true rate near the top of the accepted band (~29 br/min). This used to
        // land on the last bin of the band-restricted arrays with no right-hand
        // neighbour, so it fell back to the raw bin centre (0.48828125). The
        // search window now extends past the accepted band, so the bin has a
        // neighbour on both sides and interpolation applies here too — landing
        // closer to the true 0.483 Hz than the raw bin ever could.
        let result = BreathingCompute.computeRate(accZ: breathingSignal(hz: 0.483))
        XCTAssertNotNil(result)
        guard let r = result else { return }
        XCTAssertTrue(r.peakHz.isFinite)
        XCTAssertTrue(r.bpm.isFinite)
        XCTAssertEqual(r.peakHz, 0.483, accuracy: 0.01,
                       "Edge-of-band peak is now interpolated, not pinned to the bin centre")
    }

    // MARK: - Breathing: absence must read as absence
    //
    // The same defect has now shipped twice. The band opened at 0.10 Hz, so a
    // drift-dominated spectrum pinned to bin 3 (8.7890625 br/min); the edge moved
    // to 0.08 Hz and it pinned to bin 2 (5.859375) instead. Both times the lowest
    // in-band bin won by default because nothing checked the "peak" was a peak,
    // and both times it drew a perfectly flat line at full reported confidence.
    // These tests pin the behaviour rather than either specific floor value.

    /// Slow drift plus sensor noise — no breathing modulation at all.
    private func driftOnlySignal(seconds: Float = 60, fs: Float = 200) -> [Float] {
        let n = Int(fs * seconds)
        var rng = SystemRandomNumberGenerator()
        return (0..<n).map { i in
            let t = Float(i) / fs
            return 0.5 * sin(2 * .pi * 0.01 * t) + Float.random(in: -0.05...0.05, using: &rng)
        }
    }

    func testNoBreathingSignalReportsNothing() {
        XCTAssertNil(BreathingCompute.computeRate(accZ: driftOnlySignal()),
                     "Drift with no breathing must report nil, not the lowest in-band bin")
    }

    func testFlatlineReportsNothing() {
        let flat = [Float](repeating: 0, count: 200 * 60)
        XCTAssertNil(BreathingCompute.computeRate(accZ: flat),
                     "A dead signal must report nil, not a confident rate")
    }

    func testBroadbandNoiseReportsNothing() {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<(200 * 60)).map { _ in Float.random(in: -1...1, using: &rng) }
        XCTAssertNil(BreathingCompute.computeRate(accZ: noise),
                     "Noise has no dominant line and must not be read as breathing")
    }

    func testWeakButRealBreathingIsStillDetected() {
        // The absence checks must not be so strict that they suppress a genuine
        // but low-amplitude breath under heavy sensor noise.
        var rng = SystemRandomNumberGenerator()
        let fs: Float = 200
        let sig = (0..<Int(fs * 60)).map { i -> Float in
            let t = Float(i) / fs
            return 0.3 * sin(2 * .pi * 0.20 * t) + Float.random(in: -0.5...0.5, using: &rng)
        }
        let r = BreathingCompute.computeRate(accZ: sig)
        XCTAssertNotNil(r, "A real 12 br/min breath under noise must still be found")
        if let r { XCTAssertEqual(r.bpm, 12.0, accuracy: 2.0) }
    }

    func testRefinePeakHzFlatSpectrumFallsBackToRawBin() {
        // A perfectly flat local spectrum makes the parabolic denominator zero —
        // must fall back to the raw bin frequency, never NaN.
        let freqs: [Float] = [0.10, 0.15, 0.20, 0.25, 0.30]
        let psd:   [Float] = [3, 3, 3, 3, 3]
        let refined = SpectralPeak.refinePeakHz(freqs: freqs, psd: psd, peakIdx: 2)
        XCTAssertEqual(refined, freqs[2])
        XCTAssertTrue(refined.isFinite)
    }

    func testRefinePeakHzEdgeIndexFallsBackToRawBin() {
        // No left neighbour at index 0, no right neighbour at the last index —
        // both degenerate edges must fall back to the raw bin centre.
        let freqs: [Float] = [0.10, 0.15, 0.20]
        let psd:   [Float] = [9, 4, 1]
        XCTAssertEqual(SpectralPeak.refinePeakHz(freqs: freqs, psd: psd, peakIdx: 0), freqs[0])

        let psd2: [Float] = [1, 4, 9]
        XCTAssertEqual(SpectralPeak.refinePeakHz(freqs: freqs, psd: psd2, peakIdx: 2), freqs[2])
    }

    func testRefinePeakHzInteriorPeakIsClampedAndFinite() {
        // A well-formed interior peak should refine to a finite value within
        // half a bin of the raw bin centre (the documented ±0.5 clamp).
        let freqs: [Float] = [0.10, 0.15, 0.20, 0.25, 0.30]
        let psd:   [Float] = [1, 8, 10, 6, 1]
        let refined = SpectralPeak.refinePeakHz(freqs: freqs, psd: psd, peakIdx: 2)
        XCTAssertTrue(refined.isFinite)
        XCTAssertEqual(refined, freqs[2], accuracy: 0.025 /* ±0.5 bin, binWidth 0.05 */)
    }

    // MARK: - Tachogram interpolation

    func testInterpTachogramLength() {
        let rr: [Float] = Array(repeating: 800, count: 40)   // 40 beats at 800 ms
        // Expected duration ≈ 32 s; at 4 Hz → ~128 points
        let interp = HRVCompute.interpTachogram(rr, fs: 4.0)
        XCTAssertNotNil(interp)
        if let t = interp {
            XCTAssertGreaterThan(t.count, 100)
        }
    }

    // MARK: - CBI range

    func testCBIRange() {
        for _ in 0..<10 {
            let cbi = CoherenceCompute.computeCBI(
                rmssd:          Float.random(in: 10...100),
                peakHz:         Float.random(in: 0.05...0.4),
                coherenceScore: Float.random(in: 0...1),
                regularity:     Float.random(in: 0...1),
                peakCoherence:  Float.random(in: 0...1)
            )
            XCTAssertTrue((0...1).contains(cbi), "CBI must be in [0, 1], got \(cbi)")
        }
    }

    // MARK: - ECG quality wiring

    func testMetricsEngineComputesECGQuality() {
        let flatEcg = [Float](repeating: 50, count: 200)   // flatline — simulates lead-off
        let snapshot = DataSnapshot(ecg: flatEcg, accZ: [], accXYZ: [], rr: [], bpm: [])
        let tick = MetricsEngine.compute(from: snapshot)
        XCTAssertEqual(tick.ecgQuality?.tier, .poor)
        XCTAssertEqual(tick.ecgQuality?.reason, "lead-off")
    }

    // MARK: - Breath rate resilience (EDR fallback + three axes)

    /// 200 Hz accelerometer signal with breathing modulation on one axis.
    private func accSignal(breathHz: Float, samples: Int = 16384,
                           amplitude: Float = 30) -> [Float] {
        var seed: UInt64 = 7
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Float(seed >> 33) / Float(UInt32.max) - 0.5) * 2
        }
        return (0..<samples).map { i in
            amplitude * sin(2 * .pi * breathHz * Float(i) / 200) + noise()
        }
    }

    private func edrTachogram(brPerMin: Float, seconds: Float = 120) -> [Int] {
        var rr: [Int] = []
        var t: Float = 0
        while t < seconds {
            let ms = 800 + 40 * sin(2 * .pi * (brPerMin / 60) * t)
            rr.append(Int(ms))
            t += ms / 1000
        }
        return rr
    }

    /// The anti-circularity invariant: ACC unavailable + healthy RR gives a
    /// breath rate from the heart (EDR) — but breathHz, coherence and CBI
    /// must all stay nil, because deriving the breathing signal from the
    /// heart and correlating the heart against it would read artificially
    /// high and self-confirm. If a future change wires EDR into coherence,
    /// this fails.
    func testEDRFallbackNeverFeedsCoherence() {
        let snapshot = DataSnapshot(ecg: [], accZ: [], accXYZ: [],
                                    rr: edrTachogram(brPerMin: 15), bpm: [75])
        let tick = MetricsEngine.compute(from: snapshot)
        XCTAssertNotNil(tick.breathBPM, "EDR should have supplied a rate")
        XCTAssertEqual(tick.breathSource, .heart)
        XCTAssertEqual(tick.breathBPM ?? 0, 15, accuracy: 1.5)
        XCTAssertNil(tick.breathHz,       "EDR must not impersonate the ACC frequency")
        XCTAssertNil(tick.coherenceScore, "coherence needs two independent channels")
        XCTAssertNil(tick.cbi)
    }

    /// Agreeing channels fuse, and the reading is labelled measured.
    func testAgreeingSourcesFuseAndReadAsMeasured() {
        let z = accSignal(breathHz: 0.25)          // 15 br/min
        let xyz = z.map { SIMD3<Float>(0, 0, $0) }
        let snapshot = DataSnapshot(ecg: [], accZ: z, accXYZ: xyz,
                                    rr: edrTachogram(brPerMin: 15), bpm: [75])
        let tick = MetricsEngine.compute(from: snapshot)
        XCTAssertEqual(tick.breathSource, .accelerometer)
        XCTAssertEqual(tick.breathBPM ?? 0, 15, accuracy: 1.5)
        XCTAssertNotNil(tick.breathHz)
    }

    /// When the two channels disagree they cannot both be right: the more
    /// prominent peak wins, and the label follows the winner rather than
    /// claiming a measured reading the accelerometer didn't produce.
    func testDisagreeingSourcesAreLabelledByTheWinner() {
        let z = accSignal(breathHz: 0.25)          // 15 br/min
        let xyz = z.map { SIMD3<Float>(0, 0, $0) }
        let snapshot = DataSnapshot(ecg: [], accZ: z, accXYZ: xyz,
                                    rr: edrTachogram(brPerMin: 22), bpm: [75])
        let tick = MetricsEngine.compute(from: snapshot)
        let bpm = tick.breathBPM ?? 0
        XCTAssertTrue(abs(bpm - 15) < 1.5 || abs(bpm - 22) < 1.5,
                      "fusion invented a rate neither channel measured: \(bpm)")
        XCTAssertEqual(tick.breathSource, abs(bpm - 15) < 1.5 ? .accelerometer : .heart)
    }

    /// The rotated-strap case: modulation on X only, Z flat — the three-axis
    /// path recovers what the Z-only path missed.
    func testRotatedStrapBreathOnXAxisIsRecovered() {
        let x = accSignal(breathHz: 0.30)
        let xyz = x.map { SIMD3<Float>($0, 0, 0) }
        let rate = BreathingCompute.computeRate(accXYZ: xyz)
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate?.bpm ?? 0, 18, accuracy: 1.5)
    }

    /// Z-dominant input returns the same answer through the three-axis entry
    /// as through the single-axis one.
    func testThreeAxisMatchesSingleAxisOnZDominantSignal() {
        let z = accSignal(breathHz: 0.25)
        let xyz = z.map { SIMD3<Float>(0, 0, $0) }
        let viaZ   = BreathingCompute.computeRate(accZ: z)
        let viaXYZ = BreathingCompute.computeRate(accXYZ: xyz)
        XCTAssertEqual(viaZ?.bpm ?? -1, viaXYZ?.bpm ?? -2, accuracy: 0.001)
    }

    /// Below the raised minimum buffer (20.5 s) there is no reading at all —
    /// the old 6 s minimum produced 11.7 br/min bins, noise wearing a number.
    func testShortBufferYieldsNilNotCoarseGuess() {
        let short = accSignal(breathHz: 0.25, samples: 4000)
        XCTAssertNil(BreathingCompute.computeRate(accZ: short))
    }

}
