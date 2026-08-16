import Accelerate
import Foundation

/// Shared spectral peak-picking for the two breathing estimators (chest
/// accelerometer and ECG-derived respiration): the strongest *strict local
/// maximum* inside a band, gated by prominence, refined to sub-bin precision.
enum SpectralPeak {

    struct Result {
        let hz:         Float
        /// Peak power over the mean in-band power — the prominence the gate
        /// tested, exposed so multi-axis callers can rank candidates.
        let peakToMean: Float
    }

    /// `searchBand` and `acceptBand` are separate on purpose and must stay so.
    /// The PSD is *searched* wider than rates are *accepted* from, so every
    /// candidate inside the accept band has a neighbouring bin on each side to
    /// be a strict local maximum against. Without the margin, a candidate on
    /// the band edge has nothing to compare to, and the argmax of a
    /// monotonically decaying (drift-dominated) spectrum silently becomes the
    /// reported rate — the 8.79 br/min artefact floor in production, then the
    /// 5.86 floor once the edge moved. Requiring a genuine local maximum,
    /// with room to test it, removes the artefact rather than relocating it.
    static func dominant(freqs: [Float],
                         psd: [Float],
                         searchBand: ClosedRange<Float>,
                         acceptBand: ClosedRange<Float>,
                         minPeakToMean: Float) -> Result? {
        let search = zip(freqs, psd).filter { searchBand.contains($0.0) }
        guard search.count >= 3 else { return nil }

        let sFreqs = search.map { $0.0 }
        let sPSD   = search.map { $0.1 }

        // Strongest strict local maximum whose frequency is acceptable — not
        // the plain argmax. A spectrum with no breathing in it decays
        // monotonically across this range and contains no local maximum at
        // all, which correctly yields nil ("we cannot see your breathing")
        // instead of a confident-looking value pinned to the lowest bin.
        var best: Int?
        for i in 1..<(sPSD.count - 1) where acceptBand.contains(sFreqs[i]) {
            guard sPSD[i] > sPSD[i - 1], sPSD[i] >= sPSD[i + 1] else { continue }
            if best == nil || sPSD[i] > sPSD[best!] { best = i }
        }
        guard let peakIdx = best else { return nil }

        let bandPSD = zip(sFreqs, sPSD).filter { acceptBand.contains($0.0) }.map { $0.1 }
        let meanPSD = vDSP.mean(bandPSD)
        guard meanPSD > 0 else { return nil }

        let ratio = sPSD[peakIdx] / meanPSD
        guard ratio >= minPeakToMean else { return nil }

        return Result(hz: refinePeakHz(freqs: sFreqs, psd: sPSD, peakIdx: peakIdx),
                      peakToMean: ratio)
    }

    /// Refine a coarse spectral peak to sub-bin precision via quadratic
    /// (parabolic) interpolation over the peak bin and its immediate
    /// neighbours:
    ///
    ///   δ = 0.5 · (P[k-1] − P[k+1]) / (P[k-1] − 2·P[k] + P[k+1])
    ///   refined = (k + δ) · Δf
    ///
    /// `freqs`/`psd` are the arrays already restricted to the search band, and
    /// `peakIdx` is the raw argmax within them — so "edge of the search band"
    /// and "no neighbour on one side" are the same condition, checked once
    /// here. Falls back to the raw bin frequency (no NaN, no wild
    /// extrapolation) when the peak lacks a neighbour, the local spectrum is
    /// near-flat, or the fit isn't finite. `δ` is additionally clamped to
    /// ±0.5 bins — a larger value means the parabola doesn't fit the local
    /// shape and the raw bin is the safer answer.
    static func refinePeakHz(freqs: [Float], psd: [Float], peakIdx: Int) -> Float {
        let rawHz = freqs[peakIdx]
        guard peakIdx > 0, peakIdx < psd.count - 1 else { return rawHz }

        let pPrev = psd[peakIdx - 1]
        let pPeak = psd[peakIdx]
        let pNext = psd[peakIdx + 1]

        let denom = pPrev - 2 * pPeak + pNext
        guard abs(denom) > 1e-12 else { return rawHz }

        var delta = 0.5 * (pPrev - pNext) / denom
        guard delta.isFinite else { return rawHz }
        delta = min(max(delta, -0.5), 0.5)

        let binWidth = freqs[peakIdx + 1] - freqs[peakIdx]
        return rawHz + delta * binWidth
    }
}
