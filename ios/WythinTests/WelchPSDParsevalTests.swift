import XCTest
@testable import Wythin

/// Diagnostic test — NOT a behaviour spec.
///
/// Checks whether `HRVCompute.welchPSD` obeys Parseval's theorem: integrating
/// the returned PSD across all frequencies should recover the input signal's
/// variance. `fftMagnitudes` already divides its output by `pow2Len` (the FFT
/// length N), and `welchPSD` then applies the *standard* density scale
/// `1 / (wScale * fs * count)`, which assumes an *unnormalised* FFT. Applying
/// both would make the returned PSD too small by a factor of N².
///
/// This test measures the ratio directly at two FFT lengths (N = 256, 512).
/// If the error really is N², `1/ratio` should track N² (65,536 and 262,144)
/// rather than being ~1, ~N, or some other constant. The assertions expect
/// the *correct* behaviour (ratio ≈ 1); if the double-normalisation bug is
/// present, they are expected to FAIL — that failure, with the measured
/// numbers in its message, is the actual deliverable.
final class WelchPSDParsevalTests: XCTestCase {

    private let fs: Float = 4.0        // matches HRVCompute.rrFS
    private let amplitude: Float = 50.0
    private let freq: Float = 0.25     // on a bin centre for both N = 256 and N = 512

    private var expectedVariance: Float { amplitude * amplitude / 2 }

    /// Pure sinusoid, zero mean, `count` samples at `fs` Hz.
    private func sineSignal(count: Int) -> [Float] {
        (0..<count).map { n in
            amplitude * sin(2 * Float.pi * freq * Float(n) / fs)
        }
    }

    /// Integrates the PSD across the full returned frequency range using
    /// `HRVCompute.bandPower`'s trapezoidal rule, over a band spanning
    /// everything welchPSD returned.
    private func integratePSD(freqs: [Float], psd: [Float]) -> Float {
        guard let lo = freqs.first, let hi = freqs.last else { return 0 }
        // Widen slightly so the closed range's endpoints are included despite
        // Float rounding.
        let band: ClosedRange<Float> = (lo - 1e-6)...(hi + 1e-6)
        return HRVCompute.bandPower(freqs: freqs, psd: psd, band: band) ?? 0
    }

    private func runParsevalCase(signalCount: Int, nperseg: Int, expectedN: Int,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let signal = sineSignal(count: signalCount)
        let (freqs, psd) = HRVCompute.welchPSD(signal: signal, fs: fs, nperseg: nperseg)

        // Verify the FFT length the code actually used before interpreting
        // the ratio: welchPSD derives fftLen = 1 << floor(log2(min(nperseg, n))),
        // and freqStep = fs / fftLen, halfLen = fftLen/2 + 1 bins returned.
        let expectedFreqStep = fs / Float(expectedN)
        XCTAssertEqual(freqs.count, expectedN / 2 + 1,
                        "bin count implies a different N than expected \(expectedN)",
                        file: file, line: line)
        XCTAssertEqual(freqs[1], expectedFreqStep, accuracy: 1e-6,
                        "freq step implies a different N than expected \(expectedN)",
                        file: file, line: line)

        // Peak-bin sanity check: regardless of scale, the PSD's peak must sit
        // at the injected frequency (0.25 Hz). If this fails, the problem is
        // bigger than normalisation.
        let peakIndex = psd.indices.max(by: { psd[$0] < psd[$1] })!
        XCTAssertEqual(freqs[peakIndex], freq, accuracy: expectedFreqStep / 2 + 1e-6,
                        "PSD peak is at the wrong frequency (bin \(peakIndex) = \(freqs[peakIndex]) Hz) — " +
                        "this is a bigger problem than normalisation",
                        file: file, line: line)

        let integrated = integratePSD(freqs: freqs, psd: psd)
        let variance = expectedVariance
        let ratio = integrated / variance
        let inverseRatio = ratio == 0 ? Float.infinity : 1.0 / ratio
        let nSquared = Float(expectedN) * Float(expectedN)

        XCTAssertEqual(ratio, 1.0, accuracy: 0.15, """
            Parseval check failed for N = \(expectedN):
              integrated power = \(integrated)
              expected variance = \(variance)
              ratio (integrated / expected) = \(ratio)
              1 / ratio = \(inverseRatio)
              N^2 for this case = \(nSquared)
            """, file: file, line: line)
    }

    /// Case A: signal length 256, nperseg 256 → N = 256, predicted 1/ratio ≈ 65,536
    /// if the N² double-normalisation hypothesis holds.
    func testParseval_N256() {
        runParsevalCase(signalCount: 256, nperseg: 256, expectedN: 256)
    }

    /// Case B: signal length 512, nperseg 512 → N = 512, predicted 1/ratio ≈ 262,144
    /// if the N² double-normalisation hypothesis holds.
    func testParseval_N512() {
        runParsevalCase(signalCount: 512, nperseg: 512, expectedN: 512)
    }
}
