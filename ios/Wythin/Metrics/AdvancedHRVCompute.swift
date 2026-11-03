import Accelerate
import Foundation

// MARK: - Output structs

struct RCMSEResult {
    /// Per-scale entropy values (index 0 = scale 1).
    let values:    [Float]
    /// Mean entropy across scales 1–5 (or fewer if data is short).
    let meanEntropy: Float
    let windowSize:  Int
}

struct HRFragResult {
    /// % of inflection points (higher = more fragmented). Healthy: ~55%.
    let pip:  Float
    /// Inverse average segment length (higher = more fragmented). Healthy: ~0.52.
    let ials: Float
    /// % of beats in short segments (len ≤ 2). Higher = more fragmented. Healthy: ~62%.
    let pss:  Float
}

/// One delineated beat: where R landed in the supplied window, and the QT
/// interval measured from QRS onset to T-wave end.
struct QTBeat {
    let rIndex: Int
    let qtMs:   Float
}

struct DCResult {
    /// Deceleration Capacity in ms. Healthy 5-min range: ~6–9 ms. <4.5 ms = high risk (24h norm).
    let dc: Float
    /// Acceleration Capacity in ms (mirror metric).
    let ac: Float
    let anchorCount: Int
}

// MARK: - Advanced HRV Compute

enum AdvancedHRVCompute {

    // ── RCMSE ────────────────────────────────────────────────────────────────

    static let rcmseMinIntervals = 100
    private static let rcmseScales     = Array(1...10)
    private static let rcmseM: Int     = 2
    private static let rcmseR: Float   = 0.15   // tolerance = 0.15 × SD(original)

    /// Refined Composite Multiscale Sample Entropy (Wu et al. 2014).
    /// Requires ≥ 100 RR intervals. Returns nil otherwise.
    static func computeRCMSE(rrMs: [Int]) -> RCMSEResult? {
        let rr = HRVCompute.cleanRR(rrMs)
        guard rr.count >= rcmseMinIntervals else { return nil }

        let sd  = standardDeviation(rr)
        guard sd > 0 else { return nil }
        let tol = rcmseR * sd

        var values = [Float]()
        for tau in rcmseScales {
            guard rr.count / tau >= 10 else { break }
            var totalA = 0, totalB = 0
            for k in 1...tau {
                let cg = coarseGrain(rr, tau: tau, offset: k)
                let (a, b) = templateCounts(cg, m: rcmseM, r: Double(tol))
                totalA += a
                totalB += b
            }
            guard totalB > 0, totalA > 0 else { break }
            values.append(-log(Float(totalA) / Float(totalB)))
        }
        guard !values.isEmpty else { return nil }

        let report = min(values.count, 5)
        let mean   = values.prefix(report).reduce(0, +) / Float(report)
        return RCMSEResult(values: values, meanEntropy: mean, windowSize: rr.count)
    }

    // ── HR Fragmentation ──────────────────────────────────────────────────────

    static let hrfMinIntervals = 30

    /// HR Fragmentation indices (Costa et al. 2017).
    /// Returns nil when fewer than 30 NN intervals are available.
    static func computeHRF(rrMs: [Int]) -> HRFragResult? {
        let nn = HRVCompute.cleanRR(rrMs)
        let N  = nn.count
        guard N >= hrfMinIntervals else { return nil }

        // Increment series: delta[i] = nn[i+1] - nn[i]
        let delta = (0..<N-1).map { nn[$0+1] - nn[$0] }

        // Inflection points: delta[i] * delta[i+1] <= 0
        var inflectionAt = [Bool](repeating: false, count: delta.count)
        var inflectionCount = 0
        for i in 0..<(delta.count - 1) {
            if delta[i] * delta[i+1] <= 0 {
                inflectionAt[i] = true
                inflectionCount += 1
            }
        }
        let pip = Float(inflectionCount) / Float(N - 2) * 100.0

        // Segment extraction
        var segments = [Int]()
        var segLen   = 1
        for idx in 0..<(delta.count - 1) {
            if inflectionAt[idx] {
                segments.append(segLen)
                segLen = 1
            } else {
                segLen += 1
            }
        }
        segments.append(segLen)

        let totalSegs   = Float(segments.count)
        let totalInSegs = Float(segments.reduce(0, +))
        guard totalInSegs > 0 else { return nil }

        let ials = totalSegs / totalInSegs

        let nnInLong = Float(segments.filter { $0 >= 3 }.reduce(0, +))
        let pss      = (1.0 - nnInLong / totalInSegs) * 100.0

        return HRFragResult(pip: pip, ials: ials, pss: pss)
    }

    // ── Deceleration Capacity (PRSA) ──────────────────────────────────────────

    /// L parameter — validated for 5-min recordings (Bauer 2006, PMC11659320).
    private static let prsa_L = 64

    /// Smallest series that can actually yield a value, not merely survive the
    /// first `guard`. PRSA only takes anchors from `L ..< n - L`, so a series
    /// of length n offers `n - 2L` interior positions, split between
    /// deceleration and acceleration anchors — and `computeDC` needs 20 of
    /// each. The old value of 150 left 22 interior positions and so ~11
    /// anchors per direction: it promised a value it could never deliver, and
    /// returned nil at every length between 150 and roughly 190 while looking
    /// like the minimum had been met. 2L + 64 leaves 64 interior positions, so
    /// even a lopsided split clears 20 either way.
    static let dcMinIntervals = 2 * prsa_L + 64   // 192

    /// Deceleration and Acceleration Capacity via Phase-Rectified Signal Averaging
    /// (Bauer et al. 2006, Lancet).
    /// DC > 0 is normal. Healthy 5-min median ≈ 6.1 ms.
    static func computeDC(rrMs: [Int]) -> DCResult? {
        let L  = prsa_L
        let rr = cleanRRForPRSA(rrMs)
        guard rr.count >= dcMinIntervals else { return nil }

        // Deceleration anchors: rr[i] > rr[i-1], with boundary guard
        let decAnchors = (L..<rr.count - L).filter { rr[$0] > rr[$0 - 1] }
        let accAnchors = (L..<rr.count - L).filter { rr[$0] < rr[$0 - 1] }
        guard decAnchors.count >= 20, accAnchors.count >= 20 else { return nil }

        let dc = prsa(rr: rr, anchors: decAnchors, L: L)
        let ac = prsa(rr: rr, anchors: accAnchors, L: L)

        return DCResult(dc: Float(dc), ac: Float(ac), anchorCount: decAnchors.count)
    }

    // MARK: - Heart Rate Asymmetry

    /// Asymmetry is a distribution statistic. Below this it would be reporting
    /// the shape of a handful of beats, so it reports nothing instead. Matched
    /// to `rcmseMinIntervals` — the same "enough beats to have a shape" bar.
    static let hraMinIntervals = 100

    /// Guzik's Index: the share of short-term variance carried by
    /// decelerations, as a percentage (Guzik et al. 2006).
    ///
    /// Every other metric here reads the tachogram's *size*; this reads its
    /// *lopsidedness*. A heart that slows in big steps and speeds up in small
    /// ones is doing something different from one that does the reverse, even
    /// when both produce identical RMSSD.
    ///
    /// 50 % means decelerations and accelerations contribute equally. Health
    /// tends to sit a little above it; the reading is the distance from 50,
    /// not the raw number.
    ///
    /// Returns nil below `hraMinIntervals`, and on a perfectly flat series
    /// where there is no variance to apportion.
    static func computeHRA(rrMs: [Int]) -> Float? {
        let rr = HRVCompute.cleanRR(rrMs)
        guard rr.count >= hraMinIntervals else { return nil }

        // A deceleration is the heart slowing: the next interval is LONGER,
        // so the difference is positive. Getting this backwards inverts the
        // metric's meaning while leaving it in range, which no range check
        // would catch — hence the test that pins 75 %, not just "> 50".
        var decelSquares = 0.0
        var totalSquares = 0.0
        for (a, b) in zip(rr, rr.dropFirst()) {
            let d = Double(b - a)
            guard d != 0 else { continue }     // unchanged beats belong to neither side
            let sq = d * d
            totalSquares += sq
            if d > 0 { decelSquares += sq }
        }
        guard totalSquares > 0 else { return nil }
        return Float(decelSquares / totalSquares * 100)
    }

    // MARK: - QT delineation
    //
    // Everything else in this file reads the tachogram — a series the strap
    // hands us already made. QT is the one measure that needs the waveform,
    // so this is the app's only beat delineator.
    //
    // Two honest limits, both surfaced in the chart's copy rather than hidden
    // here. The H10 samples at 130 Hz, so one sample is 7.7 ms and QT can
    // never be more precise than roughly that. And T-wave end on a single
    // bipolar chest lead is the least reliable landmark in electrocardio-
    // graphy — this uses the tangent method, which is standard, not exact.

    /// Plausible QT range in ms. Outside this the delineation failed rather
    /// than the heart doing something interesting, so the beat is dropped.
    private static let qtPlausible: ClosedRange<Float> = 200...600

    /// Locate every beat in an ECG window and measure its QT interval.
    ///
    /// Returns one entry per beat that could be delineated with confidence;
    /// a window with no clean beats returns empty rather than guessing.
    static func delineateQT(ecg: [Float], fs: Float) -> [QTBeat] {
        let rPeaks = detectRPeaks(ecg: ecg, fs: fs)
        guard rPeaks.count >= 2 else { return [] }

        var out: [QTBeat] = []
        for (i, r) in rPeaks.enumerated() {
            // The T wave has to fit before the next beat starts.
            let nextR = i + 1 < rPeaks.count ? rPeaks[i + 1] : r + Int(fs)
            guard let qt = measureQT(ecg: ecg, fs: fs, r: r, nextR: nextR) else { continue }
            guard qtPlausible.contains(qt) else { continue }
            out.append(QTBeat(rIndex: r, qtMs: qt))
        }
        return out
    }

    /// Pan-Tompkins in miniature: differentiate, square, integrate over a
    /// QRS-width window, then take peaks above a threshold set from the
    /// window's own energy — no absolute microvolt constant, for the same
    /// reason `ECGQualityCompute` avoids one.
    private static func detectRPeaks(ecg: [Float], fs: Float) -> [Int] {
        guard ecg.count > Int(fs) else { return [] }

        var energy = [Float](repeating: 0, count: ecg.count)
        for i in 1..<ecg.count {
            let d = ecg[i] - ecg[i - 1]
            energy[i] = d * d
        }
        let w = max(Int(0.100 * fs), 3)          // ~100 ms, a QRS width
        var integrated = [Float](repeating: 0, count: energy.count)
        var running: Float = 0
        for i in 0..<energy.count {
            running += energy[i]
            if i >= w { running -= energy[i - w] }
            integrated[i] = running / Float(w)
        }

        // A flat or noise-only window has no peak standing above its own mean;
        // requiring a real multiple of it is what keeps a dead strap silent.
        let mean = integrated.reduce(0, +) / Float(integrated.count)
        guard let peak = integrated.max(), mean > 0, peak > 8 * mean else { return [] }
        let threshold = 0.25 * peak

        let refractory = Int(0.200 * fs)         // no two beats inside 200 ms
        var peaks: [Int] = []
        var i = 1
        while i < integrated.count - 1 {
            if integrated[i] >= threshold,
               integrated[i] >= integrated[i - 1], integrated[i] > integrated[i + 1],
               peaks.last.map({ i - $0 >= refractory }) ?? true {
                // The integrator lags the true R by about half its window;
                // refine to the largest deflection nearby.
                let lo = max(0, i - w), hi = min(ecg.count - 1, i + 2)
                var best = lo
                for k in lo...hi where abs(ecg[k]) > abs(ecg[best]) { best = k }
                if peaks.last.map({ best - $0 >= refractory }) ?? true { peaks.append(best) }
            }
            i += 1
        }
        return peaks
    }

    /// QRS onset to T-wave end for one beat, by the tangent method.
    private static func measureQT(ecg: [Float], fs: Float, r: Int, nextR: Int) -> Float? {
        // Baseline from the PQ segment — the flattest stretch of a beat.
        let bLo = r - Int(0.120 * fs), bHi = r - Int(0.080 * fs)
        guard bLo >= 0, bHi > bLo else { return nil }
        let baseline = ecg[bLo..<bHi].reduce(0, +) / Float(bHi - bLo)

        // QRS onset: walk back from R to where the trace last sat on baseline.
        let qLimit = max(0, r - Int(0.080 * fs))
        var qOnset = qLimit
        var k = r
        while k > qLimit {
            if abs(ecg[k] - baseline) < abs(ecg[r] - baseline) * 0.05 { qOnset = k; break }
            k -= 1
        }

        // T search: past the QRS, and stopping short of the next beat.
        let tLo = r + Int(0.100 * fs)
        let tHi = min(min(r + Int(0.500 * fs), nextR - Int(0.050 * fs)), ecg.count - 1)
        guard tHi > tLo + 3 else { return nil }

        var tPeak = tLo
        for i in tLo...tHi where abs(ecg[i] - baseline) > abs(ecg[tPeak] - baseline) { tPeak = i }
        guard tPeak < tHi - 1 else { return nil }

        // Steepest descent off the T peak, then that tangent's baseline crossing.
        var steepest = tPeak, maxSlope: Float = 0
        for i in tPeak..<tHi {
            let slope = abs(ecg[i + 1] - ecg[i])
            if slope > maxSlope { maxSlope = slope; steepest = i }
        }
        guard maxSlope > 0 else { return nil }

        let signedSlope = ecg[steepest + 1] - ecg[steepest]
        guard signedSlope != 0 else { return nil }
        let toBaseline  = baseline - ecg[steepest]
        let extraSamples = toBaseline / signedSlope
        guard extraSamples.isFinite, extraSamples >= 0 else { return nil }
        let tEnd = Float(steepest) + min(extraSamples, Float(tHi - steepest))

        return (tEnd - Float(qOnset)) / fs * 1000
    }

    // MARK: - QT Variability Index

    /// Berger's QT Variability Index (Berger et al. 1997):
    ///
    ///     QTVI = log10[ (QTv / QTm²) / (HRv / HRm²) ]
    ///
    /// Both variabilities are normalised by the square of their own mean, so
    /// the index is a ratio of *relative* wobble: 0 means QT and heart rate
    /// are equally unsteady, and positive means repolarisation is doing
    /// something the heart rate does not explain. That normalisation is the
    /// whole point of the measure — it is what makes it more than a second
    /// view of HRV.
    ///
    /// Nil when either side has no variance to speak of, since the log of a
    /// zero ratio is not a reading.
    static func qtvi(qtMs: [Float], rrMs: [Float]) -> Float? {
        guard qtMs.count >= 3, rrMs.count >= 3 else { return nil }

        func meanVar(_ xs: [Float]) -> (mean: Double, variance: Double) {
            let m = xs.reduce(0) { $0 + Double($1) } / Double(xs.count)
            let v = xs.reduce(0) { $0 + (Double($1) - m) * (Double($1) - m) } / Double(xs.count)
            return (m, v)
        }

        let (qtM, qtV) = meanVar(qtMs)
        // Heart rate, not interval: the index is defined on HR.
        let (hrM, hrV) = meanVar(rrMs.map { $0 > 0 ? 60_000 / $0 : 0 })

        guard qtM > 0, hrM > 0, qtV > 0, hrV > 0 else { return nil }
        let ratio = (qtV / (qtM * qtM)) / (hrV / (hrM * hrM))
        guard ratio > 0, ratio.isFinite else { return nil }
        return Float(log10(ratio))
    }

    // MARK: - Private helpers

    /// PRSA averaging and Haar wavelet extraction.
    private static func prsa(rr: [Double], anchors: [Int], L: Int) -> Double {
        var X = [Double](repeating: 0, count: 2 * L)
        for anchor in anchors {
            for k in -L..<L {
                X[k + L] += rr[anchor + k]
            }
        }
        let M = Double(anchors.count)
        X = X.map { $0 / M }
        // DC = (X[0] + X[1] - X[-1] - X[-2]) / 4
        // Array indices: k=-2→L-2, k=-1→L-1, k=0→L, k=1→L+1
        return (X[L] + X[L + 1] - X[L - 1] - X[L - 2]) / 4.0
    }

    /// Artifact rejection for PRSA only: keep intervals in [300, 2500] ms and
    /// exclude beats differing > 20% from predecessor. PRSA/DC is uniquely
    /// sensitive to ectopic beats (phase-rectified averaging around each
    /// accel/decel anchor), unlike the time/frequency-domain metrics, which
    /// need to see genuine large RSA swings during paced breathing — so this
    /// stricter filter is intentionally NOT part of the shared `HRVCompute.cleanRR`.
    /// PRSA's input cleaning — the same pass every other metric uses.
    ///
    /// This used to be a Malik-style successive-difference filter: drop any
    /// beat more than 20 % from the previous *accepted* one. It had two
    /// problems, and together they were keeping DC off the Live chart for
    /// about sixteen minutes at a stretch.
    ///
    /// It deadlocked. The anchor it compared against was the last beat it had
    /// accepted, and a rejection left that anchor untouched — so once the true
    /// RR level moved further than the threshold from it (standing up, a sigh,
    /// a run of ectopy), every following beat was rejected too and the anchor
    /// never advanced to catch up. The series died at the shift and stayed
    /// dead until that segment aged out of the 1200-beat ring buffer.
    ///
    /// And the threshold was wrong for this signal anyway: `HRVCompute.cleanRR`
    /// documents why the app does not use a successive-difference rule — real
    /// RSA during paced breathing routinely swings ±20–30 %, so a 20 % rule
    /// discards physiology, not artifacts. PRSA averages over hundreds of
    /// anchors and is robust to the residual noise that pass leaves behind;
    /// what it cannot survive is having most of its beats thrown away.
    static func cleanRRForPRSA(_ rrMs: [Int]) -> [Double] {
        HRVCompute.cleanRR(rrMs).map(Double.init)
    }

    /// Create k-th coarse-grained series at scale τ (1-indexed offset k, 1…τ).
    private static func coarseGrain(_ rr: [Float], tau: Int, offset k: Int) -> [Float] {
        let length = rr.count / tau
        return (1...length).compactMap { j -> Float? in
            let start = (j - 1) * tau + (k - 1)
            let end   = j * tau + (k - 2)
            guard end < rr.count else { return nil }
            let slice = Array(rr[start...end])
            return vDSP.mean(slice)
        }
    }

    /// Count template matches of length m (B) and m+1 (A) using Chebyshev distance.
    private static func templateCounts(_ y: [Float], m: Int, r: Double) -> (A: Int, B: Int) {
        let L = y.count
        guard L > m + 1 else { return (0, 0) }
        var B = 0, A = 0
        for i in 0..<(L - m) {
            for j in (i + 1)..<(L - m) {
                // Length-m match
                var matchM = true
                for p in 0..<m {
                    if abs(Double(y[i + p] - y[j + p])) > r { matchM = false; break }
                }
                if matchM {
                    B += 1
                    // Extend to m+1
                    if i + m < L, j + m < L {
                        if abs(Double(y[i + m] - y[j + m])) <= r { A += 1 }
                    }
                }
            }
        }
        return (A, B)
    }

    private static func standardDeviation(_ v: [Float]) -> Float {
        guard v.count > 1 else { return 0 }
        let mean = vDSP.mean(v)
        let sq   = vDSP.sumOfSquares(vDSP.subtract(v, [Float](repeating: mean, count: v.count)))
        return sqrt(sq / Float(v.count - 1))
    }
}

// MARK: - QT Tracker

/// Accumulates QT measurements across ticks so QTVI has enough beats to mean
/// anything.
///
/// One ECG window is ~10 s — about eleven beats — and Berger's index is
/// conventionally computed over a few hundred. Worse, the windows overlap:
/// the buffer holds 10 s and the tick fires every 2 s, so eight seconds of
/// every window has already been counted. This keeps a rolling series and
/// admits only beats newer than the newest one it already holds.
///
/// Stateful, so it lives outside `MetricsEngine` — which is a pure
/// per-snapshot function — exactly as the breathing-rate tracker does.
final class QTTracker {

    /// ~5 minutes at 60 bpm, comfortably past Berger's 256 beats.
    private let maxBeats = 300

    private struct Beat {
        let time: Date
        let qtMs: Float
    }
    private var beats: [Beat] = []

    /// Delineate one ECG window and fold any genuinely new beats in.
    /// Returns the current QTVI, or nil while there is not enough to say.
    @discardableResult
    func update(ecg: [Float], fs: Float, windowEnd: Date) -> Float? {
        let found = AdvancedHRVCompute.delineateQT(ecg: ecg, fs: fs)
        let newest = beats.last?.time

        for b in found {
            // Where this beat sits in real time: the window ends at
            // `windowEnd`, so a sample is (count - index) / fs seconds old.
            let age  = Double(ecg.count - b.rIndex) / Double(fs)
            let time = windowEnd.addingTimeInterval(-age)
            // A tenth of a second of slack absorbs delineation jitter on a
            // beat seen twice, without ever swallowing a real one — no two
            // beats are 100 ms apart.
            if let newest, time <= newest.addingTimeInterval(0.1) { continue }
            beats.append(Beat(time: time, qtMs: b.qtMs))
        }

        if beats.count > maxBeats { beats.removeFirst(beats.count - maxBeats) }
        return qtvi
    }

    /// Berger's index over the accumulated series. The RR side is taken from
    /// the beats' own spacing rather than the strap's RR, so both halves of
    /// the ratio describe the same beats.
    var qtvi: Float? {
        guard beats.count >= 32 else { return nil }
        let rr = zip(beats, beats.dropFirst()).map {
            Float($1.time.timeIntervalSince($0.time) * 1000)
        }.filter { (300...2000).contains($0) }
        guard rr.count >= 32 else { return nil }
        return AdvancedHRVCompute.qtvi(qtMs: beats.map(\.qtMs), rrMs: rr)
    }

    /// How many beats the series currently holds. Test seam: the overlap
    /// dedup is the whole reason this class exists, and it is invisible from
    /// `qtvi` alone, which stays nil until 32 beats regardless.
    var beatCountForTesting: Int { beats.count }

    /// A connection gap or a doffed strap makes the next beat discontinuous
    /// with the last, so the series starts again.
    func reset() { beats.removeAll() }
}
