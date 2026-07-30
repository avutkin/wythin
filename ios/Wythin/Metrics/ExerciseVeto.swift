import Foundation

/// Stops a downshift nudge reaching someone who is exercising.
///
/// Exertion and stress look alike in the metrics — both suppress RMSSD and lift
/// HR — so the separation has to come from context. The server prompt states
/// the governing rule: a high or rising HR with *good* recovery metrics is high
/// energy, not stress, and must not be called a stress state.
///
/// Four independent layers, because no single cue covers every case.
enum ExerciseVeto {

    /// Reused from the anchor detector, where it already means "seated still
    /// while worn". You cannot run and read under this.
    static var stillnessMg: Float { AnchorThresholds.stillnessSD }

    /// RMSSD stays suppressed and fragmentation elevated well after exertion
    /// ends, so the window has to clear before rules read it as a state.
    static let lockoutSeconds: Double = 45 * 60

    /// Above resting + this, treat as exertion regardless of what the
    /// accelerometer says.
    static let hrCeilingOverResting: Float = 35

    /// How far recovery may slip before "energy" stops being a fair reading.
    static let energyDzTolerance: Float = -0.3

    // MARK: Layer 1 — motion floor

    /// Window maximum, not mean: one burst is enough to make the window unsafe
    /// to read as a resting state.
    static func exceedsMotionFloor(_ s: NudgeSignals) -> Bool {
        guard let peak = s.slowMotion?.max else { return false }
        return peak >= stillnessMg
    }

    // MARK: Layer 2 — post-exertion lockout

    static func isWithinLockout(now: Date, lastActiveAt: Date?) -> Bool {
        guard let lastActiveAt else { return false }
        return now.timeIntervalSince(lastActiveAt) < lockoutSeconds
    }

    // MARK: Layer 3 — energy, not stress

    /// True when HR is climbing but recovery has held — the literal encoding of
    /// the rule above.
    ///
    /// Requires *positive* evidence that recovery is intact: an unknown dz does
    /// not earn a veto, it simply leaves the other layers to do the work. DC is
    /// treated as corroborating rather than required, since its baseline is
    /// optional and absent for anyone whose anchors are all short.
    static func isEnergyNotStress(_ s: NudgeSignals) -> Bool {
        guard s.slow["hr"]?.direction == "rising" else { return false }
        guard s.slow["rsa"]?.direction != "falling" else { return false }
        guard let dzLn = s.dzLnRMSSD, dzLn >= energyDzTolerance else { return false }
        if let dzDC = s.dzDC, dzDC < energyDzTolerance { return false }
        return true
    }

    // MARK: Layer 4 — HR ceiling

    /// Catches stationary cycling, rowing and machine work, where the chest
    /// barely moves and layer 1 misses entirely.
    static func exceedsHRCeiling(_ s: NudgeSignals, baseline: AnchorBaseline?) -> Bool {
        guard let baseline, let hr = s.fast["hr"]?.mean else { return false }
        return hr >= baseline.restingHR.mean + hrCeilingOverResting
    }

    // MARK: Composite

    static func vetoes(_ s: NudgeSignals,
                       baseline: AnchorBaseline?,
                       now: Date,
                       lastActiveAt: Date?) -> Bool {
        exceedsMotionFloor(s)
            || isWithinLockout(now: now, lastActiveAt: lastActiveAt)
            || isEnergyNotStress(s)
            || exceedsHRCeiling(s, baseline: baseline)
    }
}
