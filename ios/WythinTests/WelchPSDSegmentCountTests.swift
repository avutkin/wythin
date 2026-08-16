import XCTest
@testable import Wythin

/// The breath-rate resolution change rests on one property of `welchPSD`'s
/// loop bounds: a 16384-sample buffer at nperseg 8192 must average 3
/// half-overlapping segments, not degrade to a single bare periodogram (the
/// 12000-sample buffer would have). The property belongs to `welchPSD`, so it
/// gets its own test instead of being assumed inside BreathingCompute's.
final class WelchPSDSegmentCountTests: XCTestCase {

    /// Segment count isn't exposed, so it is measured through variance: the
    /// PSD of white noise averaged over k segments has k× less variance than
    /// a single periodogram. 3 segments must land measurably below 1.
    func testBufferGrowthRestoresSegmentAveraging() {
        var seed: UInt64 = 42
        func rand() -> Float {   // deterministic LCG so the test can't flake
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 33) / Float(UInt32.max) - 0.5
        }
        let noise16384 = (0..<16384).map { _ in rand() }
        let noise8192  = Array(noise16384.prefix(8192))

        func psdRelativeVariance(_ signal: [Float]) -> Float {
            let (_, psd) = HRVCompute.welchPSD(signal: signal, fs: 200, nperseg: 8192)
            let body = psd.dropFirst(4).dropLast(4)   // skip DC/Nyquist edges
            let mean = body.reduce(0, +) / Float(body.count)
            let varSum = body.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
            return (varSum / Float(body.count)) / (mean * mean)
        }

        let single   = psdRelativeVariance(noise8192)    // exactly 1 segment
        let averaged = psdRelativeVariance(noise16384)   // must be 3 segments

        // 3 half-overlapping segments give roughly a 2–3× variance reduction;
        // a buffer that only fit one segment would show no reduction at all.
        XCTAssertLessThan(averaged, single * 0.65,
            "16384 samples at nperseg 8192 did not average multiple segments")
    }
}
