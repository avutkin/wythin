import Foundation

/// Turns a stored session into the 0–100 readings the row displays.
///
/// Only indices whose inputs are already persisted appear. An index with no
/// data is **left out entirely** rather than shown empty — the row this
/// replaces printed three dashes and a "1 of 7", which told its reader nothing
/// except that the app was unsure of itself.
///
/// Warm-up speed, Steadiness and Readiness are absent from this list on
/// purpose: they need a time-to-half-range, a second-half drift and a
/// pre-session anchor read, none of which is stored yet. They arrive with the
/// field that feeds them, not before.
extension ActivityLog {

    var scoredIndices: [ScoredIndex] {
        [
            brakeReleaseIndex,
            efficiencyIndex,
            bounceBackIndex,
        ].compactMap { $0 }
    }

    /// How far the calm brake came off for the work that was done.
    var brakeReleaseIndex: ScoredIndex? {
        guard case let .score(value, _) = suppressionAxis else { return nil }
        return BrakeReleaseIndex.index(score: value,
                                       troughDC: duringDCTrough.map(Double.init))
    }

    /// Brake given up per extra beat — the price, where Brake release is the depth.
    ///
    /// Chest motion does not measure barbell work, so a session with no
    /// external work signal has no efficiency to report and says so by absence.
    var efficiencyIndex: ScoredIndex? {
        guard hasExternalWorkSignal, efficiencySlope != nil,
              let value = efficiencyScore else { return nil }
        let brake = ExerciseSuppression.brakePerBeat(dcPre: beforeDC.map(Double.init),
                                                     dcDuring: duringDC.map(Double.init),
                                                     hrPre: beforeHR.map(Double.init),
                                                     hrDuring: duringHR.map(Double.init))
        return ScoredIndex(
            name: "Efficiency",
            value: value,
            verdict: value >= IndexBand.keepAbove ? "cheap for the work"
                   : value >= IndexBand.actBelow  ? "fair price"
                                                  : "expensive per beat",
            detail: brake.map { String(format: "%.2f ms/beat", $0) } ?? "")
    }

    /// How fast the system came back, from the readings that survived.
    ///
    /// Decoupling is passed a history count of zero until it is stored, which
    /// keeps it out of the mean rather than letting an unscored construct
    /// silently weight the result.
    var bounceBackIndex: ScoredIndex? {
        let value = BounceBackIndex.score(hrr60Bpm: hrr60Bpm,
                                          halfRecoveryMinutes: halfRecoveryMinutes,
                                          decoupling: nil,
                                          decouplingMean: nil,
                                          decouplingHistoryCount: 0)
        return BounceBackIndex.index(value: value,
                                     halfRecoveryMinutes: halfRecoveryMinutes)
    }

    /// The quantities with no good or bad direction.
    ///
    /// Kept apart from the scored grid so the screen never implies a verdict on
    /// how much work was done. A heavier session is not a better one.
    var ungradedDoses: [UngradedDose] {
        var out: [UngradedDose] = []
        if let load = exerciseLoad {
            out.append(UngradedDose(name: "Load",
                                    value: "\(Int(load.rounded()))",
                                    caption: "effort × time"))
        }
        if let peak = duringHRPeak {
            // The mockup captions this "81% of reserve", which needs the
            // personal ceiling and therefore a model context. The row has no
            // context, so it states what it knows rather than estimating a
            // ceiling — the fraction belongs on the detail screen, which does.
            out.append(UngradedDose(name: "Peak",
                                    value: "\(Int(Double(peak).rounded())) bpm",
                                    caption: "highest reached"))
        }
        return out
    }
}
