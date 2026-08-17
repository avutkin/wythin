import Accelerate
import Foundation

// MARK: - Breathing Output

struct BreathingMetrics {
    let peakHz:     Float   // dominant breathing frequency
    let bpm:        Float   // breaths per minute
    let regularity: Float   // 0–1 (peak prominence ratio / 6)
    /// Raw peak-to-mean prominence — how far the breathing line stands above
    /// the rest of the band. Carried unclamped (unlike `regularity`) so the
    /// fusion and tracking stages can weight estimates against each other.
    var confidence: Float = 0
    let psdFreqs:   [Float]
    let psdValues:  [Float]
}

struct BreathPhases {
    struct Breath {
        let inhaleDur:    Float   // seconds
        let exhaleDur:    Float   // seconds
        let depth:        Float   // filtered signal amplitude
        let ieRatio:      Float   // exhale/inhale
        let tInhaleStart: Float   // seconds relative to now (negative = past)
        let tInhaleEnd:   Float
        let tExhaleEnd:   Float
    }

    let breaths:     [Breath]
    let meanIE:      Float
    let meanInhale:  Float
    let meanExhale:  Float
    let meanDepth:   Float
    let nBreaths:    Int
    let filtered:    [Float]
    let filteredT:   [Float]
}

// MARK: - BreathingCompute

enum BreathingCompute {

    private static let accFS:         Float = Float(PolarH10Profile.accSampleRate)  // 200 Hz
    // 4.8–30 br/min. With fftLen = 8192 the bin width is fs/8192 ≈ 0.0244 Hz
    // (1.46 br/min); 0.08 Hz keeps genuine slow/resonance breathing
    // (~6 br/min) reachable, with sub-bin precision from parabolic
    // interpolation in `SpectralPeak`, not from the band itself.
    private static let breathBand:    ClosedRange<Float> = 0.08...0.50
    // Searched wider than accepted — see `SpectralPeak.dominant`'s doc for
    // why the two bands must stay separate (the 8.79 / 5.86 br/min artefact
    // floors both came from collapsing them).
    private static let searchBand:    ClosedRange<Float> = 0.03...0.60
    /// A candidate peak must carry at least this multiple of the mean in-band
    /// power. Broadband noise throws up shallow local maxima all over the band;
    /// a real breath is a narrow, dominant line.
    private static let minPeakToMean: Float = 3.0
    /// Prominence at which the principal-component estimate is trusted without
    /// also evaluating the individual axes.
    private static let confidentPeakToMean: Float = 5.0
    /// 4096 samples = 20.5 s. `welchPSD` floors the segment to a power of
    /// two, so shorter buffers collapse silently: at the old 6 s minimum the
    /// FFT length was 1024 — a bin width of 0.195 Hz, 11.7 br/min, spanning
    /// the entire accept band in about two bins. Those early readings were
    /// noise wearing a number. At 4096 the resolution can never fall below
    /// 2.93 br/min, and reaches 1.46 once 41 s has buffered. The visible
    /// cost: the first reading appears ~20 s after strap-on instead of 6.
    private static let minAccBreath:  Int   = 4096
    private static let minAccPhases:  Int   = Int(accFS * 20)   // 20 s

    // MARK: Public

    /// Estimate breathing rate from all three ACC axes.
    ///
    /// Chest expansion is a single direction in space, and a strap that has
    /// rotated on the torso spreads it across all three sensor axes — so the
    /// primary estimate comes from the **principal component**, the direction
    /// of greatest breathing-band motion, rather than from whichever axis
    /// happens to be closest to it. Individual axes are then tried only if the
    /// projection fails to produce a confident peak, and the most prominent
    /// candidate wins.
    static func computeRate(accXYZ: [SIMD3<Float>]) -> BreathingMetrics? {
        var best: (metrics: BreathingMetrics, peakToMean: Float)?

        if let projected = principalProjection(accXYZ), let r = rate(axis: projected) {
            // A clearly dominant line needs no second opinion — this is the
            // common case and costs one transform.
            if r.peakToMean >= confidentPeakToMean { return r.metrics }
            best = r
        }
        for axis in [accXYZ.map(\.z), accXYZ.map(\.x), accXYZ.map(\.y)] {
            guard let r = rate(axis: axis) else { continue }
            if best == nil || r.peakToMean > best!.peakToMean { best = r }
        }
        return best?.metrics
    }

    /// Projects the three axes onto their principal component within the
    /// breathing band.
    ///
    /// Band-limiting first is what makes this find *breathing* rather than
    /// posture: gravity and gross movement carry far more variance than chest
    /// expansion, so a PCA of the raw signal would return the direction of
    /// walking, not of breath.
    static func principalProjection(_ v: [SIMD3<Float>]) -> [Float]? {
        guard v.count >= minAccBreath else { return nil }
        guard let x = bandpassFilter(v.map(\.x), lowHz: 0.08, highHz: 0.6, fs: accFS),
              let y = bandpassFilter(v.map(\.y), lowHz: 0.08, highHz: 0.6, fs: accFS),
              let z = bandpassFilter(v.map(\.z), lowHz: 0.08, highHz: 0.6, fs: accFS)
        else { return nil }

        // 3×3 covariance of the band-limited axes (already ~zero-mean).
        var c = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
        let cols = [x, y, z]
        let n = Float(v.count)
        for i in 0..<3 {
            for j in i..<3 {
                var sum: Float = 0
                for k in 0..<v.count { sum += cols[i][k] * cols[j][k] }
                c[i][j] = sum / n
                c[j][i] = c[i][j]
            }
        }

        // Dominant eigenvector by power iteration — 3×3, so this converges in
        // a handful of passes and needs no linear-algebra dependency.
        var e: [Float] = [0, 0, 1]   // seeded on Z, the nominal chest normal
        for _ in 0..<24 {
            var next = [Float](repeating: 0, count: 3)
            for i in 0..<3 {
                for j in 0..<3 { next[i] += c[i][j] * e[j] }
            }
            let norm = (next[0] * next[0] + next[1] * next[1] + next[2] * next[2]).squareRoot()
            guard norm > 1e-12 else { return nil }
            e = next.map { $0 / norm }
        }
        return (0..<v.count).map { k in e[0] * x[k] + e[1] * y[k] + e[2] * z[k] }
    }

    /// Single-axis entry, retained for tests and callers already holding Z.
    static func computeRate(accZ: [Float]) -> BreathingMetrics? {
        rate(axis: accZ)?.metrics
    }

    private static func rate(axis: [Float]) -> (metrics: BreathingMetrics, peakToMean: Float)? {
        guard axis.count >= minAccBreath else { return nil }

        // Normalise
        let mean  = vDSP.mean(axis)
        var z     = vDSP.subtract(axis, [Float](repeating: mean, count: axis.count))
        let std   = HRVCompute.standardDeviation(z)
        if std > 0 { z = vDSP.divide(z, std) }

        // The finer 8192-bin resolution only engages once the buffer can
        // feed it 3 half-overlapping segments. In between (a filling buffer,
        // or a caller still handing over 60 s arrays), 8192 would fit ONE
        // segment — a bare periodogram whose variance lets broadband-noise
        // spikes through the prominence gate. 4096 keeps ≥2 segments
        // averaged all the way down to the minimum buffer.
        let nperseg = z.count >= 16384 ? 8192 : 4096
        let (freqs, psd) = HRVCompute.welchPSD(
            signal: z, fs: accFS, nperseg: min(nperseg, z.count))

        guard let peak = SpectralPeak.dominant(freqs: freqs, psd: psd,
                                               searchBand: searchBand,
                                               acceptBand: breathBand,
                                               minPeakToMean: minPeakToMean)
        else { return nil }

        let band = zip(freqs, psd).filter { breathBand.contains($0.0) }
        let metrics = BreathingMetrics(
            peakHz:     peak.hz,
            bpm:        peak.hz * 60,
            regularity: min(peak.peakToMean / 6.0, 1.0),
            confidence: peak.peakToMean,
            psdFreqs:   band.map { $0.0 },
            psdValues:  band.map { $0.1 }
        )
        return (metrics, peak.peakToMean)
    }

    /// Segment breathing into inhale/exhale phases via bandpass + peak detection.
    /// Mirrors `compute_breath_phases` in metrics.py.
    static func computePhases(accZ: [Float]) -> BreathPhases? {
        guard accZ.count >= minAccPhases else { return nil }

        // Bandpass 0.05–0.8 Hz (3–48 br/min)
        guard let filtered = bandpassFilter(accZ, lowHz: 0.05, highHz: 0.8, fs: accFS) else {
            return nil
        }

        let std = HRVCompute.standardDeviation(filtered)
        let minProm = max(std * 0.30, 1e-6)
        let minDist = Int(accFS * 1.5)   // ≥ 1.5 s → max 40 br/min

        let peaks   = findPeaks( filtered, minDistance: minDist, minProminence: minProm)
        let troughs = findPeaks(filtered.map { -$0 }, minDistance: minDist, minProminence: minProm)

        guard peaks.count >= 2, troughs.count >= 2 else { return nil }

        let tArr   = (0..<filtered.count).map { Float($0) / accFS }
        let tNow   = tArr.last ?? 0

        var breaths: [BreathPhases.Breath] = []
        for i in 0..<troughs.count - 1 {
            let t1 = troughs[i]
            let t2 = troughs[i + 1]
            let mid = peaks.filter { $0 > t1 && $0 < t2 }
            guard let p = mid.first else { continue }

            let inh = Float(p  - t1) / accFS
            let exh = Float(t2 - p)  / accFS
            let dep = filtered[p] - filtered[t1]

            // Physiological sanity: 1.5–60 s cycle, half-phases ≥ 0.4 s
            guard (1.5...(60.0)).contains(inh + exh), inh >= 0.4, exh >= 0.4 else { continue }

            breaths.append(BreathPhases.Breath(
                inhaleDur:    inh,
                exhaleDur:    exh,
                depth:        dep,
                ieRatio:      exh / inh,
                tInhaleStart: tArr[t1] - tNow,
                tInhaleEnd:   tArr[p]  - tNow,
                tExhaleEnd:   tArr[t2] - tNow
            ))
        }
        guard !breaths.isEmpty else { return nil }

        let recent = Array(breaths.suffix(12))
        let win    = Int(accFS * 30)
        let sigSlice = Array(filtered.suffix(win))
        let tRel     = sigSlice.indices.map { Float($0 - sigSlice.count) / accFS }

        return BreathPhases(
            breaths:    recent,
            meanIE:     recent.map { $0.ieRatio }.reduce(0, +) / Float(recent.count),
            meanInhale: recent.map { $0.inhaleDur }.reduce(0, +) / Float(recent.count),
            meanExhale: recent.map { $0.exhaleDur }.reduce(0, +) / Float(recent.count),
            meanDepth:  recent.map { abs($0.depth) }.reduce(0, +) / Float(recent.count),
            nBreaths:   breaths.count,
            filtered:   sigSlice,
            filteredT:  tRel
        )
    }

    // MARK: DSP helpers

    /// 4th-order Butterworth bandpass filter via biquad cascade (matches scipy.butter order=4).
    static func bandpassFilter(_ signal: [Float], lowHz: Float, highHz: Float, fs: Float) -> [Float]? {
        // Design 2nd-order biquad sections analytically for Butterworth bandpass
        // A 4th-order Butterworth bandpass = 2 biquad sections in series
        guard let sections = butterworthBPCoeffs(order: 4, lowHz: lowHz, highHz: highHz, fs: fs) else {
            return nil
        }
        var out = signal
        for section in sections {
            out = applyBiquad(out, b: section.b, a: section.a)
        }
        // Forward-backward filter (sosfiltfilt equivalent)
        let outFwd = out
        var outRev = outFwd.reversed().map { $0 }
        for section in sections {
            outRev = applyBiquad(outRev, b: section.b, a: section.a)
        }
        return outRev.reversed().map { $0 }
    }

    /// Biquad section coefficients (b0,b1,b2 / a0,a1,a2 normalised so a0=1).
    struct BiquadSection {
        let b: [Float]   // [b0, b1, b2]
        let a: [Float]   // [1, a1, a2]
    }

    /// Design a 4th-order Butterworth bandpass filter as biquad sections.
    /// Uses bilinear transform from pre-warped analogue prototype.
    static func butterworthBPCoeffs(order: Int, lowHz: Float, highHz: Float,
                                    fs: Float) -> [BiquadSection]? {
        guard lowHz > 0, highHz > lowHz, highHz < fs / 2 else { return nil }
        // Pre-warp digital cutoffs to analogue
        let wl = 2 * fs * tan(.pi * lowHz  / fs)
        let wh = 2 * fs * tan(.pi * highHz / fs)
        let bw = wh - wl
        let w0 = sqrt(wl * wh)

        // For a 4th-order bandpass, we need 2 second-order sections.
        // Each section is produced from a first-order Butterworth lowpass prototype
        // transformed to a bandpass section.
        //
        // 1st-order LP prototype poles: s = -1 (normalised)
        // Bandpass transform: s → (s² + w0²) / (bw·s)  →  gives 2nd-order BP
        // Two such sections → 4th-order overall
        var sections: [BiquadSection] = []
        for _ in 0..<(order / 2) {
            // Analogue BP section: H(s) = (bw·s) / (s² + bw·s + w0²)
            // Bilinear transform: s → 2*fs*(z-1)/(z+1)
            let k  = 2 * fs
            let k2 = k * k
            let denom = k2 + bw * k + w0 * w0
            let b0 =  bw * k / denom
            let b1 =  0.0 as Float
            let b2 = -bw * k / denom
            let a1 = (2 * (w0 * w0 - k2)) / denom
            let a2 = (k2 - bw * k + w0 * w0) / denom
            sections.append(BiquadSection(b: [b0, b1, b2], a: [1, a1, a2]))
        }
        return sections
    }

    /// Apply a single biquad IIR section (direct form II transposed).
    private static func applyBiquad(_ x: [Float], b: [Float], a: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var w1: Float = 0, w2: Float = 0
        for i in 0..<x.count {
            let xi = x[i]
            let yi = b[0] * xi + w1
            w1 = b[1] * xi - a[1] * yi + w2
            w2 = b[2] * xi - a[2] * yi
            y[i] = yi
        }
        return y
    }

    /// Simple peak detection: returns indices of local maxima with minimum distance
    /// and minimum prominence constraints (approximation — not scipy quality but sufficient).
    static func findPeaks(_ signal: [Float], minDistance: Int, minProminence: Float) -> [Int] {
        var peaks: [Int] = []
        let n = signal.count
        guard n > 2 else { return [] }

        // Find all local maxima
        var candidates: [Int] = []
        for i in 1..<n - 1 {
            if signal[i] > signal[i - 1] && signal[i] >= signal[i + 1] {
                candidates.append(i)
            }
        }

        // Apply min distance and prominence
        for c in candidates {
            // Prominence: height above the higher of the two surrounding minima
            let leftMin  = signal[0..<c].min() ?? 0
            let rightMin = signal[(c + 1)...].min() ?? 0
            let prom = signal[c] - max(leftMin, rightMin)
            guard prom >= minProminence else { continue }

            // Distance from last accepted peak
            if let last = peaks.last, c - last < minDistance { continue }
            peaks.append(c)
        }
        return peaks
    }
}
