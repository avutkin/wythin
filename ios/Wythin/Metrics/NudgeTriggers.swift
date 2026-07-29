import Foundation

// MARK: - Identity

enum NudgeTriggerID: String, CaseIterable, Equatable {
    case vagalWithdrawal = "downshift.vagal_withdrawal"
    case sustainedLoad   = "downshift.sustained_load"
    case stuckStill      = "downshift.stuck_still"
    case acuteSpike      = "downshift.acute_spike"
    case focusWindow     = "focus.window_open"

    var isDownshift: Bool { self != .focusWindow }
}

/// Duration state the metric window cannot carry.
///
/// `stillSince` and `loadSince` outlive the 45-minute buffer, so they are
/// tracked as scalars and reset on movement, on an activity, on a data gap or
/// on standby.
struct NudgeContext {
    var now: Date
    var stillSince: Date?
    var loadSince: Date?
    var lastActiveAt: Date?
}

// MARK: - Rules

/// The signature half of the engine: given the evidence, which triggers are
/// true right now. Sustain, hysteresis, budget and precedence live elsewhere —
/// this answers only "does the state match".
enum NudgeTriggers {

    // D1 — the balance dial is the sympathetic reference line, which is
    // RMSSD 21.5 ms. Change is scored in personal SD units.
    static let arousalDialLine:     Float = 65
    static let arousalDzLimit:      Float = -0.8
    /// Below ~10 br/min the vagal respiratory peak leaves the HF band; slow
    /// paced breathing is inherently vagal and must never read as stress.
    static let spontaneousBreathMin: Float = 9

    // D2 — between the "drifting" and "in harmony" reference lines.
    static let loadSeconds:      TimeInterval = 90 * 60
    static let loadDFA1Ceiling:  Float = 0.85
    static let loadDzLimit:      Float = -0.5

    // D3 — sedentary exposure is itself the thing being corrected.
    static let stillSeconds: TimeInterval = 50 * 60

    // D4 — a rise this size with the chest still cannot be exertion.
    static let spikeRiseBPM:      Float = 12
    static let spikeOverResting:  Float = 15

    // F1 — parasympathetic reference line, "mod" RSA line, harmony band.
    static let focusDialCeiling:   Float = 45
    static let focusRSAFloor:      Float = 30
    static let focusDFA1Range:     ClosedRange<Float> = 0.90...1.20
    static let focusCoherenceFloor: Float = 0.50
    static let focusBreathRange:   ClosedRange<Float> = 10...20

    static func evaluate(_ s: NudgeSignals,
                         baseline: AnchorBaseline?,
                         context: NudgeContext) -> [NudgeTriggerID] {

        // No anchors at all means no personal frame of reference. A provisional
        // baseline is fine — its widened denominator makes early reads
        // conservative on its own.
        guard let baseline else { return [] }

        var fired: [NudgeTriggerID] = []

        let vetoed = ExerciseVeto.vetoes(s, baseline: baseline,
                                         now: context.now, lastActiveAt: context.lastActiveAt)

        if !vetoed {
            if matchesVagalWithdrawal(s)             { fired.append(.vagalWithdrawal) }
            if matchesSustainedLoad(s, context)      { fired.append(.sustainedLoad) }
            if matchesStuckStill(context)            { fired.append(.stuckStill) }
            if matchesAcuteSpike(s, baseline)        { fired.append(.acuteSpike) }
        }

        // F1 is silent and carries its own stillness, quality and breathing
        // gates, so it is not subject to the downshift preconditions.
        if matchesFocusWindow(s, baseline) { fired.append(.focusWindow) }

        return fired
    }

    // MARK: D1

    static func matchesVagalWithdrawal(_ s: NudgeSignals) -> Bool {
        guard let dial = s.slowBalance,
              dial.direction == "rising",
              dial.shape == TrendShape.steadyRise.rawValue,
              let end = dial.end, end >= arousalDialLine,
              let dz = s.dzLnRMSSD, dz <= arousalDzLimit,
              let breath = s.slow["breath_bpm"]?.mean, breath >= spontaneousBreathMin
        else { return false }
        return true
    }

    // MARK: D2

    static func matchesSustainedLoad(_ s: NudgeSignals, _ c: NudgeContext) -> Bool {
        guard let since = c.loadSince,
              c.now.timeIntervalSince(since) >= loadSeconds,
              let dfa1 = s.slow["dfa1"]?.end, dfa1 <= loadDFA1Ceiling,
              let dz = s.dzLnRMSSD, dz <= loadDzLimit
        else { return false }
        return true
    }

    // MARK: D3

    static func matchesStuckStill(_ c: NudgeContext) -> Bool {
        guard let since = c.stillSince else { return false }
        return c.now.timeIntervalSince(since) >= stillSeconds
    }

    // MARK: D4

    static func matchesAcuteSpike(_ s: NudgeSignals, _ baseline: AnchorBaseline) -> Bool {
        guard let hr = s.fast["hr"],
              hr.shape == TrendShape.steadyRise.rawValue,
              let start = hr.start, let end = hr.end,
              end - start >= spikeRiseBPM,
              end >= baseline.restingHR.mean + spikeOverResting,
              let peakMotion = s.fastMotion?.max, peakMotion < ExerciseVeto.stillnessMg,
              s.fast["rsa"]?.direction == "falling"
        else { return false }
        return true
    }

    // MARK: F1

    /// Nine simultaneous conditions over 30 minutes. A false positive here is
    /// worse than a miss: the claim is that this is the best state the person
    /// gets, and it is spent on their hardest work.
    static func matchesFocusWindow(_ s: NudgeSignals, _ baseline: AnchorBaseline) -> Bool {
        guard s.slowSignalClean else { return false }

        // Level — vagally-mediated HRV carries the claim.
        guard let dial = s.slowBalance, let dialMean = dial.mean, dialMean <= focusDialCeiling,
              let rmssdMean = s.slow["rmssd"]?.mean, rmssdMean > 0,
              let z = baseline.lnRMSSD.z(log(rmssdMean), prior: BaselinePrior.lnRMSSD), z >= 0,
              let rsa = s.slow["rsa"], let rsaMean = rsa.mean, rsaMean >= focusRSAFloor,
              let dfa1 = s.slow["dfa1"]?.mean, focusDFA1Range.contains(dfa1),
              let coh = s.slow["coherence"]?.mean, coh >= focusCoherenceFloor
        else { return false }

        // Stability — HR is the only series that moves fast enough for its
        // volatility to mean anything; the slow ones are buffer-smoothed.
        guard let dialShape = dial.shape, Self.settlingShapes.contains(dialShape),
              let rsaShape = rsa.shape, Self.holdingShapes.contains(rsaShape),
              s.slow["hr"]?.volatility == "low"
        else { return false }

        // Context — seated and working, breathing spontaneously.
        guard let motion = s.slowMotion?.mean, motion < ExerciseVeto.stillnessMg,
              let breath = s.slow["breath_bpm"]?.mean, focusBreathRange.contains(breath)
        else { return false }

        return true
    }

    /// Flat or still settling.
    private static let settlingShapes = [TrendShape.plateau.rawValue, TrendShape.steadyFall.rawValue]
    /// Flat or still improving.
    private static let holdingShapes  = [TrendShape.plateau.rawValue, TrendShape.steadyRise.rawValue]

    // MARK: - Release

    /// Has the condition clearly let go?
    ///
    /// Release thresholds sit ~5 % back toward normal from the arm thresholds.
    /// Without that band a signal resting exactly on its threshold would arm,
    /// release and re-arm indefinitely; with it, the state has to genuinely
    /// recover before the trigger can speak again.
    static func releases(_ id: NudgeTriggerID,
                         _ s: NudgeSignals,
                         _ baseline: AnchorBaseline,
                         _ c: NudgeContext) -> Bool {
        switch id {
        case .vagalWithdrawal:
            let dial = s.slowBalance?.end ?? 0
            let dz = s.dzLnRMSSD ?? 0
            return dial < arousalDialLine - 3 || dz > arousalDzLimit + 0.2

        case .sustainedLoad:
            let dfa1 = s.slow["dfa1"]?.end ?? 1.0
            let dz = s.dzLnRMSSD ?? 0
            return dfa1 > loadDFA1Ceiling + 0.04 || dz > loadDzLimit + 0.15

        case .stuckStill:
            // Duration-based: movement itself is the release.
            guard let since = c.stillSince else { return true }
            return c.now.timeIntervalSince(since) < stillSeconds

        case .acuteSpike:
            guard let hr = s.fast["hr"], let start = hr.start, let end = hr.end else { return true }
            return end - start < spikeRiseBPM - 3

        case .focusWindow:
            guard let dial = s.slowBalance?.mean else { return true }
            return dial > focusDialCeiling + 2 || !matchesFocusWindow(s, baseline)
        }
    }
}
