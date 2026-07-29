import Accelerate
import XCTest
@testable import Wythin

/// Regression coverage for the RSA "unmeasurable" guard in RSACompute.compute.
///
/// Production data (2026-07-29, 110-minute window, 235 samples) showed rsaMs
/// averaging 0.057 ms (max 0.140 ms) — positive, so the old `guard rsaMs > 0`
/// passed and the chart drew a continuous line pinned near zero instead of a
/// gap. Root cause: accelerometer breath detection was unavailable, so
/// RSACompute fell back to the fixed HF band (0.15–0.40 Hz); the user's
/// variability was concentrated at low frequency (LF/HF ≈ 9.7), so HF-band
/// power — and therefore sqrt(2 * hfP) — was tiny but not exactly zero.
final class RSAComputeTests: XCTestCase {

    // MARK: - Fixtures

    /// Synthetic RR series with a sinusoidal oscillation of `ampMs` at `freqHz`,
    /// riding on a `baseMs` mean interval. Mirrors real RSA: the RR *interval*
    /// itself is modulated as a function of elapsed time.
    private static func oscillatingRR(count: Int, baseMs: Float, ampMs: Float, freqHz: Float) -> [Int] {
        var rr: [Int] = []
        rr.reserveCapacity(count)
        var t: Float = 0
        for _ in 0..<count {
            let v = baseMs + ampMs * sin(2 * Float.pi * freqHz * t)
            rr.append(Int(v.rounded()))
            t += v / 1000.0
        }
        return rr
    }

    // MARK: - The regression itself

    /// LF-dominant variability (0.10 Hz, well inside the 0.04–0.15 Hz LF band,
    /// far from the 0.15–0.40 Hz HF band RSACompute falls back to without a
    /// detected breathing frequency). RMSSD lands around 28 ms — comfortably
    /// past the sibling 1.0 ms flat-tachogram guard — while HF-band power is
    /// negligible, exactly reproducing the production scenario (strong LF/HF
    /// imbalance, healthy RMSSD, near-zero-but-positive HF power).
    ///
    /// Verified against the pre-fix guard (`rsaMs > 0`) that this fixture
    /// produces a tiny positive rsaMs (~0.16 ms) — i.e. this test fails on the
    /// old code and only passes once the guard uses a physiological floor.
    func testLFDominantVariabilityIsUnmeasurable() {
        let rr = Self.oscillatingRR(count: 30, baseMs: 800, ampMs: 80, freqHz: 0.10)

        // Sanity: RMSSD clears the flat-tachogram guard (1.0 ms) by a wide margin,
        // so it's not that guard doing the suppressing.
        let clean = HRVCompute.cleanRR(rr)
        let diffs = HRVCompute.differences(clean)
        let rmssd = diffs.isEmpty ? 0 : sqrt(vDSP.meanSquare(diffs))
        XCTAssertGreaterThan(rmssd, 20, "Fixture must comfortably clear the 1.0 ms RMSSD guard")

        let result = RSACompute.compute(rrMs: rr)
        XCTAssertNil(result, "Near-zero HF power from LF-dominant variability must read as unmeasurable (gap), not a tiny positive number")
    }

    // MARK: - Genuine respiratory signal still measures

    /// A real 0.25 Hz (15 breaths/min) oscillation of 40 ms amplitude, with the
    /// breathing frequency supplied (as BreathingCompute would normally detect
    /// it) so RSACompute uses the bandpass path. This must NOT be swallowed by
    /// the new floor — a threshold that suppresses real respiratory data would
    /// be worse than the bug it fixes.
    func testGenuineRespiratorySignalStillMeasures() {
        let rr = Self.oscillatingRR(count: 60, baseMs: 800, ampMs: 40, freqHz: 0.25)

        let result = RSACompute.compute(rrMs: rr, breathHz: 0.25)
        XCTAssertNotNil(result, "A genuine 40 ms respiratory oscillation must still be measurable")
        guard let m = result else { return }
        XCTAssertEqual(m.method, "bandpass")
        XCTAssertTrue((10...100).contains(m.rsaMs), "rsaMs (\(m.rsaMs)) should land in a plausible tens-of-ms range for a 40 ms input oscillation")
    }

    // MARK: - Existing guards still hold

    func testFewerThan30CleanIntervalsReturnsNil() {
        // 20 perfectly plausible RR values — below the 30-interval frequency-domain minimum.
        let rr = Array(repeating: 800, count: 20)
        XCTAssertNil(RSACompute.compute(rrMs: rr))
    }

    func testFlatTachogramReturnsNil() {
        // 30 identical RR values → RMSSD == 0, below the 1.0 ms flat-tachogram guard.
        let rr = Array(repeating: 800, count: 30)
        XCTAssertNil(RSACompute.compute(rrMs: rr))
    }
}
