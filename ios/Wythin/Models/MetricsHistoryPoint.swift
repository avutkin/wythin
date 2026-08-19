import Foundation

// MARK: - MetricsQualityFilter

/// Heuristic wear-detection for Polar H10.
/// When the strap is removed, SDNN collapses near zero (no real cardiac variability).
/// Three simultaneous per-field threshold tests, plus one cross-field
/// plausibility test, gate each tick.
enum MetricsQualityFilter {

    /// Ceiling on RMSSD as a fraction of the concurrent mean RR interval
    /// (`60_000 / meanBPM`, in ms). Successive-beat variability is bounded by
    /// how far apart beats are in the first place, so RMSSD cannot run away
    /// from the mean interval without the interval itself being wrong.
    ///
    /// 0.30 is deliberately permissive — roughly double the highest fraction
    /// plausible even in extreme resonance-breathing HRV at rest — because
    /// this gate runs at all ten `MetricsQualityFilter` call sites across the
    /// app, and a false rejection here doesn't just skip a chart point, it
    /// silently deletes real data from averages, morning anchors, and
    /// activity impact. Erring toward letting a rare true edge case through
    /// is far cheaper than erring toward dropping real physiology.
    ///
    /// Confirmed against production data: dropped/duplicated beats on the
    /// chest strap produced RMSSD ~150 ms at HR ~165 bpm (ratio 0.41, mean RR
    /// ~364 ms) for seven straight hours on 2026-07-28, and RMSSD 137 at HR
    /// 165.5 (ratio 0.38) on 2026-07-25 — both pass every check below in
    /// isolation (150 > 3, 165 is within 35...210), because none of them
    /// relate RMSSD to the heart rate it was measured alongside.
    static let maxRMSSDFraction: Double = 0.30

    static func isValid(_ pt: MetricsHistoryPoint) -> Bool {
        guard let sdnn  = pt.sdnn,    sdnn  > 5.0  else { return false }
        guard let rmssd = pt.rmssd,   rmssd > 3.0  else { return false }
        guard let bpm   = pt.meanBPM, bpm  >= 35.0,
              bpm <= 210.0                          else { return false }

        // Cross-field plausibility: at HR 165 the mean RR interval is only
        // ~364 ms, so an RMSSD of 150 ms means adjacent beats routinely
        // differ by 41% of that interval — impossible in sinus rhythm, but
        // invisible to the three checks above, each of which looks at a
        // single field alone. This is what actually catches the artifact.
        let meanRR = 60_000.0 / Double(bpm)
        guard Double(rmssd) <= maxRMSSDFraction * meanRR else { return false }

        return true
    }

    static func filter(_ pts: [MetricsHistoryPoint]) -> [MetricsHistoryPoint] {
        pts.filter { isValid($0) }
    }
}

// MARK: - MetricsHistoryPoint

/// Lightweight snapshot of scalar metrics from one compute tick (every ~2 s).
/// Strips array fields (PSD, breathPhases.filtered) so 24 h of history ≈ 4 MB.
struct MetricsHistoryPoint {
    let timestamp:  Date

    let ieRatio:    Float?   // BreathPhases.meanIE  (exhale/inhale)
    let vti:        Float?   // ln(RMSSD)
    let rmssd:      Float?   // ms
    let rsaMs:      Float?   // ms
    let sdnn:       Float?   // ms
    let pnn50:      Float?   // %
    let ulfPower:   Float?   // ms²  (ULF < 0.003 Hz)
    let vlfPower:   Float?   // ms²  (VLF 0.003–0.04 Hz)
    let lfPower:    Float?   // ms²
    let hfPower:    Float?   // ms²
    let lfHF:       Float?   // ratio
    let coherence:  Float?   // 0–1
    let cbi:        Float?   // 0–1
    let breathBPM:  Float?   // br/min
    let meanBPM:    Float?   // bpm
    let dfa1:          Float?
    let signalQuality: Float?
    let rrInvalidRate:   Float?   // fraction of RR dropped as implausible
    let rrCorrectedRate: Float?   // fraction of RR interpolated (missed/extra beat)
    let ecgQualityTier:  Int?     // SignalQualityTier.rawValue (0 poor…2 good)
    let rcmse:         Float?   // RCMSE mean entropy (scales 1–5)
    let pip:           Float?   // HR Fragmentation: % inflection points
    let ials:          Float?   // HR Fragmentation: inverse avg segment length
    let dc:            Float?   // Deceleration Capacity (ms)
    let motion:        Float?   // SD of ACC vector magnitude (mg) — stillness
    /// Which channel produced `breathBPM` — measured (ACC) or estimated (EDR).
    /// Defaulted so hand-built fixtures compile unchanged.
    var breathSource:  BreathSource? = nil

    init(from tick: MetricsTick) {
        timestamp  = tick.timestamp
        ieRatio    = tick.breathPhases?.meanIE
        vti        = tick.vti
        rmssd      = tick.rmssd
        rsaMs      = tick.rsaMs
        sdnn       = tick.sdnn
        pnn50      = tick.pnn50
        ulfPower   = tick.ulfPower
        vlfPower   = tick.vlfPower
        lfPower    = tick.lfPower
        hfPower    = tick.hfPower
        lfHF       = tick.lfHF
        coherence  = tick.coherenceScore
        cbi        = tick.cbi
        breathBPM  = tick.breathBPM
        meanBPM    = tick.meanBPM
        dfa1          = tick.dfa1
        signalQuality = tick.signalQuality
        rrInvalidRate   = tick.rrInvalidRate
        rrCorrectedRate = tick.rrCorrectedRate
        ecgQualityTier  = tick.ecgQuality?.tier.rawValue
        rcmse         = tick.rcmse
        pip           = tick.pip
        ials          = tick.ials
        dc            = tick.dc
        motion        = tick.motion
        breathSource  = tick.breathSource
    }

    init(from sample: HRVSample) {
        timestamp  = sample.timestamp
        ieRatio    = sample.ieRatio
        vti        = sample.vti
        rmssd      = sample.rmssd
        rsaMs      = sample.rsaMs
        sdnn       = sample.sdnn
        pnn50      = sample.pnn50
        ulfPower   = sample.ulfPower
        vlfPower   = sample.vlfPower
        lfPower    = sample.lfPower
        hfPower    = sample.hfPower
        lfHF       = sample.lfHF
        coherence  = sample.coherence
        cbi        = sample.cbi
        breathBPM  = sample.breathBPM
        meanBPM    = sample.meanBPM
        dfa1          = sample.dfa1
        signalQuality = sample.signalQuality
        rrInvalidRate   = sample.rrInvalidRate
        rrCorrectedRate = sample.rrCorrectedRate
        ecgQualityTier  = sample.ecgQualityTier
        rcmse         = sample.rcmse
        pip           = sample.pip
        ials          = sample.ials
        dc            = sample.dc
        motion        = sample.motion
        breathSource  = sample.breathSourceRaw.flatMap(BreathSource.init(rawValue:))
    }

    /// Convenience initializer for constructing a snapshot directly by field,
    /// without going through MetricsTick's full field list. Unlisted fields
    /// default to nil.
    init(
        timestamp: Date,
        meanBPM:   Float? = nil,
        rmssd:     Float? = nil,
        rsaMs:     Float? = nil,
        sdnn:      Float? = nil,
        lfHF:      Float? = nil,
        coherence: Float? = nil,
        breathBPM: Float? = nil,
        cbi:       Float? = nil,
        dfa1:      Float? = nil,
        rcmse:     Float? = nil,
        pip:       Float? = nil,
        dc:        Float? = nil,
        motion:    Float? = nil,
        signalQuality:  Float? = nil,
        ecgQualityTier: Int?   = nil
    ) {
        self.timestamp = timestamp
        self.ieRatio = nil
        self.vti = rmssd.map { log($0) }
        self.rmssd = rmssd
        self.rsaMs = rsaMs
        self.sdnn = sdnn
        self.pnn50 = nil
        self.ulfPower = nil
        self.vlfPower = nil
        self.lfPower = nil
        self.hfPower = nil
        self.lfHF = lfHF
        self.coherence = coherence
        self.cbi = cbi
        self.breathBPM = breathBPM
        self.meanBPM = meanBPM
        self.dfa1 = dfa1
        self.signalQuality = signalQuality
        self.rrInvalidRate = nil
        self.rrCorrectedRate = nil
        self.ecgQualityTier = ecgQualityTier
        self.rcmse = rcmse
        self.pip = pip
        self.ials = nil
        self.dc = dc
        self.motion = motion
    }

    /// Convenience initializer covering the fields the anchor pipeline reads.
    init(
        anchorTestTimestamp: Date,
        meanBPM: Float? = nil,
        vti: Float? = nil,
        dc: Float? = nil,
        pip: Float? = nil,
        dfa1: Float? = nil,
        breathBPM: Float? = nil,
        motion: Float? = nil,
        signalQuality: Float? = nil,
        rrInvalidRate: Float? = nil,
        ecgQualityTier: Int? = nil,
        coherence: Float? = nil,
        sdnn: Float? = nil,
        lfHF: Float? = nil
    ) {
        self.timestamp = anchorTestTimestamp
        self.ieRatio = nil
        self.vti = vti
        self.rmssd = vti.map { exp($0) }
        self.rsaMs = nil
        self.sdnn = sdnn
        self.pnn50 = nil
        self.ulfPower = nil
        self.vlfPower = nil
        self.lfPower = nil
        self.hfPower = nil
        self.lfHF = lfHF
        self.coherence = coherence
        self.cbi = nil
        self.breathBPM = breathBPM
        self.meanBPM = meanBPM
        self.dfa1 = dfa1
        self.signalQuality = signalQuality
        self.rrInvalidRate = rrInvalidRate
        self.rrCorrectedRate = nil
        self.ecgQualityTier = ecgQualityTier
        self.rcmse = nil
        self.pip = pip
        self.ials = nil
        self.dc = dc
        self.motion = motion
    }
}
