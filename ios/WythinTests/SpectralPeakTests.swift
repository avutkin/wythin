import XCTest
@testable import Wythin

final class SpectralPeakTests: XCTestCase {

    private let search: ClosedRange<Float> = 0.03...0.60
    private let accept: ClosedRange<Float> = 0.08...0.50

    /// Evenly spaced bins with a clean triangular peak.
    private func spectrum(peakAt hz: Float, bins: Int = 40,
                          df: Float = 0.02) -> (freqs: [Float], psd: [Float]) {
        let freqs = (0..<bins).map { Float($0) * df }
        let psd = freqs.map { f -> Float in
            let d = abs(f - hz)
            return d < df ? 10 - 5 * d / df : 1
        }
        return (freqs, psd)
    }

    func testCleanPeakIsFound() {
        let (freqs, psd) = spectrum(peakAt: 0.20)
        let r = SpectralPeak.dominant(freqs: freqs, psd: psd, searchBand: search,
                                      acceptBand: accept, minPeakToMean: 3.0)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.hz ?? 0, 0.20, accuracy: 0.01)
    }

    /// A monotonically decaying (drift-dominated) spectrum contains no local
    /// maximum — the artefact-floor case must yield nil, not the lowest bin.
    func testMonotonicDecayYieldsNil() {
        let freqs = (0..<40).map { Float($0) * 0.02 }
        let psd   = freqs.map { 10 / (1 + 50 * $0) }
        XCTAssertNil(SpectralPeak.dominant(freqs: freqs, psd: psd, searchBand: search,
                                           acceptBand: accept, minPeakToMean: 3.0))
    }

    /// A peak on the accept-band edge still has both neighbours to be a strict
    /// local maximum against, because the search band is wider.
    func testAcceptBandEdgePeakHasNeighboursFromSearchBand() {
        let (freqs, psd) = spectrum(peakAt: 0.08)
        let r = SpectralPeak.dominant(freqs: freqs, psd: psd, searchBand: search,
                                      acceptBand: accept, minPeakToMean: 3.0)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.hz ?? 0, 0.08, accuracy: 0.011)
    }

    /// Prominence gate: a shallow bump under the multiple-of-mean threshold
    /// is broadband noise, not a breath.
    func testShallowPeakIsRejected() {
        let freqs = (0..<40).map { Float($0) * 0.02 }
        var psd   = [Float](repeating: 1, count: 40)
        psd[10] = 1.5   // local max at 0.20 Hz, but only 1.5× the mean
        XCTAssertNil(SpectralPeak.dominant(freqs: freqs, psd: psd, searchBand: search,
                                           acceptBand: accept, minPeakToMean: 3.0))
    }

    /// Parabolic refinement lands within a fraction of a bin of the true
    /// off-bin frequency.
    func testRefinementRecoversSubBinPrecision() {
        // True peak at 0.21 Hz, bins at 0.02 — the argmax bin is 0.20.
        let df: Float = 0.02
        let freqs = (0..<40).map { Float($0) * df }
        let psd = freqs.map { f -> Float in exp(-pow((f - 0.21) / 0.015, 2)) * 10 + 1 }
        let r = SpectralPeak.dominant(freqs: freqs, psd: psd, searchBand: search,
                                      acceptBand: accept, minPeakToMean: 2.0)
        XCTAssertEqual(r?.hz ?? 0, 0.21, accuracy: Float(df) / 4)
    }
}
