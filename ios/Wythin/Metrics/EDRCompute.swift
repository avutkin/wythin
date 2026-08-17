import Foundation

/// ECG-derived respiration: breathing rate recovered from the RR tachogram.
///
/// A fallback, never a preference. The two sources fail in almost disjoint
/// conditions — the accelerometer fails when you move; the respiratory
/// modulation EDR reads collapses when heart rate is high or vagal tone is
/// low — so this fills in only when the accelerometer path returns nil.
/// RR arrives on the heart-rate characteristic, a different channel from the
/// PMD streams, which is what lets Breath Rate survive a total PMD stall.
enum EDRCompute {

    static let searchBand:    ClosedRange<Float> = 0.10...0.60
    /// 9–30 br/min. The floor is 0.15 Hz, not 0.08: below roughly 0.15 Hz
    /// the respiratory peak cannot be separated from the Mayer wave, a
    /// genuine blood-pressure oscillation near 0.1 Hz that sits exactly on
    /// 6 br/min. A spectral method cannot tell them apart, and reporting the
    /// peak anyway would tell someone breathing at 14 that they're at 6.
    /// The cost is nil below 9 br/min — and it costs nothing in practice:
    /// this path only runs when ACC is out, which is overwhelmingly while
    /// moving, and nobody breathes at 6 br/min while moving. Genuine
    /// resonance work happens still, where ACC works and EDR isn't consulted.
    static let acceptBand:    ClosedRange<Float> = 0.15...0.50
    static let minPeakToMean: Float = 3.0
    static let minBeats:      Int   = 60

    struct Estimate {
        let bpm:        Float
        let confidence: Float   // peak-to-mean prominence
    }

    /// Breathing rate in br/min from the RR tachogram, or nil.
    ///
    /// At `rrFS` = 4 Hz with `nperseg` = 256 the bin width is 0.0156 Hz —
    /// 0.94 br/min over a 64 s window, roughly three times finer than the
    /// accelerometer path.
    static func estimate(rrMs: [Int]) -> Estimate? {
        let clean = HRVCompute.cleanRR(rrMs)
        guard clean.count >= minBeats,
              let interp = HRVCompute.interpTachogram(clean, fs: HRVCompute.rrFS)
        else { return nil }

        let mean = interp.reduce(0, +) / Float(interp.count)
        let detrended = interp.map { $0 - mean }

        let (freqs, psd) = HRVCompute.welchPSD(
            signal: detrended, fs: HRVCompute.rrFS,
            nperseg: min(256, detrended.count))

        guard let peak = SpectralPeak.dominant(freqs: freqs, psd: psd,
                                               searchBand: searchBand,
                                               acceptBand: acceptBand,
                                               minPeakToMean: minPeakToMean)
        else { return nil }

        // Subharmonic guard. Modulating RR intervals modulates the beat grid
        // itself, so a strong oscillation BELOW the accept band (the Mayer
        // wave at ~0.1 Hz) throws a second harmonic INSIDE it — a pure
        // 0.1 Hz oscillation otherwise reads as a confident 12 br/min. If
        // the spectrum carries more power at half the found frequency than
        // at the peak itself, the peak is the harmonic and the fundamental
        // is not a breath: report nothing rather than double the truth.
        let halfHz = peak.hz / 2
        if halfHz < acceptBand.lowerBound, halfHz >= searchBand.lowerBound {
            func power(near hz: Float) -> Float {
                zip(freqs, psd).min { abs($0.0 - hz) < abs($1.0 - hz) }?.1 ?? 0
            }
            if power(near: halfHz) > power(near: peak.hz) { return nil }
        }

        return Estimate(bpm: peak.hz * 60, confidence: peak.peakToMean)
    }

    /// Rate only — the shape most callers and tests want.
    static func computeRate(rrMs: [Int]) -> Float? { estimate(rrMs: rrMs)?.bpm }
}
