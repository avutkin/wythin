import Foundation

// MARK: - Aggregated Tick Output

/// All metrics computed from one DataSnapshot. Produced every ~2 s.
struct MetricsTick {
    let timestamp: Date

    // Time-domain HRV
    let meanBPM: Float?
    let sdnn:    Float?
    let rmssd:   Float?
    let pnn50:   Float?
    let vti:     Float?

    // Frequency-domain HRV
    let ulfPower: Float?
    let vlfPower: Float?
    let lfPower:  Float?
    let hfPower:  Float?
    let lfHF:     Float?

    // RSA
    let rsaMs:  Float?
    let rsaIdx: Float?

    // Breathing
    /// Fused breathing rate. `var` because `AppEnvironment` runs the temporal
    /// tracker (`BreathRateTracker`) over consecutive ticks and writes the
    /// tracked value back — the per-tick spectral pick is an observation, not
    /// the final answer.
    var breathBPM:    Float?
    let breathHz:     Float?
    let regularity:   Float?
    /// Which channel produced `breathBPM`. `breathBPM` non-nil while
    /// `breathHz` is nil is a deliberate asymmetry, not an oversight: when
    /// the source is `.heart` (EDR), `breathHz` and `regularity` stay nil so
    /// RSA's bandpass, coherence and CBI never consume a breathing signal
    /// derived from the heart itself — coherence would become the heart
    /// correlated with itself and read artificially high. Do not "fix" this
    /// by forwarding the EDR frequency into `breathHz`.
    var breathSource: BreathSource? = nil
    /// Peak prominence behind `breathBPM`, for the tracker's weighting.
    /// Transient — never persisted, never synced.
    var breathConfidence: Float? = nil

    // Coherence & CBI
    let coherenceScore: Float?
    let cbi:            Float?

    // Nonlinear HRV
    let dfa1: Float?   // DFA α1 short-term scaling exponent (scales 4–16)

    // Signal quality
    let signalQuality: Float?

    /// RR artifact breakdown (fractions 0–1) — dropped-as-implausible vs
    /// interpolated missed/extra beats. Defaulted so preview/aggregate
    /// constructors need not supply them.
    var rrInvalidRate:   Float? = nil
    var rrCorrectedRate: Float? = nil

    /// SD of ACC vector magnitude (mg) over the window — stillness input for
    /// the day's rested anchor. Defaulted so existing constructors compile.
    ///
    /// Note this is rotation-invariant and therefore says nothing about which
    /// way the body is facing; `bodyPosition` carries that.
    var motion: Float? = nil

    /// Which way the body was facing, from the gravity direction, plus how
    /// confident that call is. Nil while moving — a window spanning a roll is
    /// not a position. See `PostureCompute`.
    var bodyPosition: BodyPosition? = nil
    var positionConfidence: Float? = nil

    /// ECG waveform quality (flatline/clipping check) — live-only, not persisted.
    let ecgQuality: ECGQualityResult?

    // Advanced nonlinear HRV (computed on slower cadence — needs 100–350 beats)
    let rcmse: Float?   // Refined Composite Multiscale Entropy mean (scales 1–5)
    let pip:   Float?   // HR Fragmentation: % inflection points (higher = more fragmented)
    let ials:  Float?   // HR Fragmentation: inverse avg segment length
    let dc:    Float?   // Deceleration Capacity in ms (Bauer 2006, PRSA)

    // Phase info (for UI breathing ring)
    let breathPhases: BreathPhases?

    // PSD for chart display
    let psdFreqs:  [Float]?
    let psdValues: [Float]?

    // RR–Breathing coherence spectrum
    let coherenceFreqs:  [Float]?
    let coherenceValues: [Float]?
}

/// Which channel a breathing-rate reading came from.
enum BreathSource: Int, Codable {
    case accelerometer = 0   // measured — chest expansion via ACC
    case heart         = 1   // estimated — ECG-derived respiration (EDR)
}

// MARK: - MetricsEngine

/// Coordinates all metric computation from a DataSnapshot.
/// Designed to run on a background task (not MainActor).
enum MetricsEngine {

    /// Compute a full MetricsTick from a data snapshot.
    /// Heavy: runs Welch PSD, FFT, biquad filters. Call from a background Task.
    static func compute(from snapshot: DataSnapshot) -> MetricsTick {
        let rrMs = snapshot.rr

        // --- Time-domain HRV ---
        let hrv = HRVCompute.compute(rrMs: rrMs)

        // --- Robust heart rate ---
        // Prefer the sensor's own recent BPM (motion-robust), median-filtered,
        // instead of the whole-buffer RR mean (which reads low during a run).
        let robustBPM = HeartRateCompute.current(rrMs: rrMs, sensorBPM: snapshot.bpm) ?? hrv?.meanBPM

        // --- DFA α1 ---
        let dfa = DFACompute.compute(rrMs: rrMs)

        // --- ECG waveform quality ---
        let ecgQuality = ECGQualityCompute.compute(ecg: snapshot.ecg)

        // --- Advanced nonlinear metrics (need 100–350 beats, more expensive) ---
        let rcmseResult = AdvancedHRVCompute.computeRCMSE(rrMs: rrMs)
        let hrfResult   = AdvancedHRVCompute.computeHRF(rrMs: rrMs)
        let dcResult    = AdvancedHRVCompute.computeDC(rrMs: rrMs)

        // --- Breathing: accelerometer first (all three axes), EDR fallback ---
        // RR arrives on the heart-rate characteristic, so the fallback
        // survives a total PMD stall; it is consulted only when ACC yields
        // nothing (see `MetricsTick.breathSource` for the circularity rule).
        // Both estimators run every tick and are fused by prominence: two
        // independent channels agreeing on a rate is stronger evidence than
        // either alone, and when they disagree the more dominant peak wins
        // rather than being averaged into a rate nobody measured.
        let breathing = BreathingCompute.computeRate(accXYZ: snapshot.accXYZ)

        // Which way the body is facing. Nil while moving — a window spanning a
        // roll averages two orientations into one the body never held.
        let posture = PostureCompute.position(accXYZ: snapshot.accXYZ)
        let edr       = EDRCompute.estimate(rrMs: rrMs)
        var candidates: [BreathRateTracker.Estimate] = []
        if let b = breathing { candidates.append(.init(bpm: b.bpm, confidence: b.confidence)) }
        if let e = edr       { candidates.append(.init(bpm: e.bpm, confidence: e.confidence)) }
        let fusedBreath = BreathRateTracker.fuse(candidates)
        let phases    = BreathingCompute.computePhases(accZ: snapshot.accZ)

        // --- RSA ---
        // Use only the most recent 90 RR intervals (~90 s at 60 bpm) so RSA is stable
        // against transient fluctuations while still reflecting current autonomic state.
        let rrForRSA = rrMs.count > 90 ? Array(rrMs.suffix(90)) : rrMs
        let rsa = RSACompute.compute(rrMs: rrForRSA, breathHz: breathing?.peakHz)

        // --- Coherence ---
        let coherence = CoherenceCompute.compute(
            rrMs: rrMs, accZ: snapshot.accZ, peakHz: breathing?.peakHz)

        // --- CBI ---
        let cbi: Float? = coherence.map {
            CoherenceCompute.computeCBI(
                rmssd:           hrv?.rmssd,
                peakHz:          breathing?.peakHz,
                coherenceScore:  $0.score,
                regularity:      breathing?.regularity ?? 0,
                peakCoherence:   $0.peakCoherence
            )
        }

        return MetricsTick(
            timestamp:      Date(),
            meanBPM:        robustBPM,
            sdnn:           hrv?.sdnn,
            rmssd:          hrv?.rmssd,
            pnn50:          hrv?.pnn50,
            vti:            hrv?.vti,
            ulfPower:       hrv?.ulfPower,
            vlfPower:       hrv?.vlfPower,
            lfPower:        hrv?.lfPower,
            hfPower:        hrv?.hfPower,
            lfHF:           hrv?.lfHF,
            rsaMs:          rsa?.rsaMs,
            rsaIdx:         rsa?.rsaIdx,
            breathBPM:      fusedBreath?.bpm,
            breathHz:       breathing?.peakHz,       // never EDR — circularity rule
            regularity:     breathing?.regularity,   // never EDR
            // Names the channel that actually produced the answer: when the
            // two disagree, the arbitration above picks one, and labelling it
            // .accelerometer merely because ACC computed *something* would
            // mark an estimated reading as measured.
            breathSource:   fusedBreath.map { fused in
                                breathing.map { abs($0.bpm - fused.bpm) <= 2 } == true
                                    ? .accelerometer : .heart
                            },
            breathConfidence: fusedBreath?.confidence,
            coherenceScore: coherence?.score,
            cbi:            cbi,
            dfa1:           dfa?.alpha1,
            // Quality reflects only truly-lost (dropped) beats — corrected
            // beats are repaired, so they must NOT flag a window as poor
            // quality (they are surfaced on the Signal Artifacts / RR Corrected
            // charts instead). Including them made the amber bands over-trigger.
            signalQuality:  hrv.map { 1 - $0.invalidRate },
            rrInvalidRate:   hrv?.invalidRate,
            rrCorrectedRate: hrv?.correctedRate,
            motion:          MotionCompute.magnitudeSD(accXYZ: snapshot.accXYZ),
            bodyPosition:       posture?.0,
            positionConfidence: posture?.1,
            ecgQuality:     ecgQuality,
            rcmse:          rcmseResult?.meanEntropy,
            pip:            hrfResult?.pip,
            ials:           hrfResult?.ials,
            dc:             dcResult?.dc,
            breathPhases:   phases,
            psdFreqs:        hrv?.psdFreqs,
            psdValues:       hrv?.psdValues,
            coherenceFreqs:  coherence?.freqs,
            coherenceValues: coherence?.coherence
        )
    }
}
