import Foundation

/// A coach's read on one exercise session, in three parts.
///
/// Deterministic and derived only from what was measured. The model-written
/// insight is still shown beneath this, but it is not load-bearing: it is
/// generated from a restorative-framed prompt that reads a hard session's
/// falling RSA as a fault, so it can contradict the score. These lines cannot.
struct SessionCoachSummary {
    /// What went well. Never empty — every session did something right.
    let strengths:   [String]
    /// What to change next time. Empty when there is nothing worth changing.
    let improvements: [String]
    /// The session to run next, and why.
    let nextSession: String
}

extension SessionCoachSummary {

    /// - Parameters:
    ///   - loadPercentile: this session's Load against recent history, 0–1,
    ///     or nil when there is not enough history to place it.
    static func build(overall: AxisValue,
                      suppression: AxisValue,
                      recovery: AxisValue,
                      efficiency: AxisValue,
                      load: Double?,
                      moderateSec: Double,
                      heavySec: Double,
                      severeSec: Double,
                      loadPercentile: Double?) -> SessionCoachSummary {

        func score(_ a: AxisValue) -> Int? {
            if case let .score(v, _) = a { return v }
            return nil
        }
        let mins = { (s: Double) in Int((s / 60).rounded()) }
        let hard = heavySec + severeSec

        // ── What was great ────────────────────────────────────────────────
        var strengths: [String] = []
        if let r = score(recovery), r >= 60 {
            strengths.append("Your vagal brake came back strongly — \(r)% of resting tone regained within ten minutes of stopping.")
        }
        if let s = score(suppression), s >= 60 {
            strengths.append("You held that heart rate cheaply: less vagal shutdown per beat than your recent sessions of this kind.")
        }
        if let e = score(efficiency), e >= 60 {
            strengths.append("Good mechanical economy — more work done per unit of autonomic cost than usual.")
        }
        if hard >= 600 {
            strengths.append("\(mins(hard)) minutes at or above your aerobic threshold. That is real training, not just time on your feet.")
        }
        if strengths.isEmpty {
            strengths.append(mins(moderateSec) > 0
                ? "You completed \(mins(moderateSec)) minutes of steady aerobic work."
                : "You showed up and logged it, which is the habit that makes the rest possible.")
        }

        // ── What to improve ───────────────────────────────────────────────
        var improvements: [String] = []
        if let r = score(recovery), r < 40 {
            improvements.append("Recovery was slow — only \(r)% of vagal tone back at ten minutes. Add five minutes of slow nasal breathing before you finish.")
        }
        if let s = score(suppression), s < 40 {
            improvements.append("This heart rate cost more vagal tone than usual, which usually means you arrived under-recovered rather than that the session was wrong.")
        }
        if severeSec >= 300 {
            improvements.append("\(mins(severeSec)) minutes in the severe domain. That is a large withdrawal to repay; keep it deliberate rather than accidental.")
        }
        if hard < 120 && (loadPercentile ?? 0) < 0.4 {
            improvements.append("Almost all of this sat below threshold. If it was meant to be easy, that is exactly right — if not, there is room to push.")
        }

        // ── The next session ──────────────────────────────────────────────
        let next: String
        if let r = score(recovery), r < 40 {
            next = "Something easy next: 30–40 minutes fully in the moderate domain, nothing above threshold, and see whether recovery comes back faster."
        } else if severeSec >= 300 || (loadPercentile ?? 0) > 0.8 {
            next = "Repeat this in about 48 hours. Before then, keep it aerobic — the adaptation happens while you stay out of the severe domain."
        } else if hard >= 600, let o = score(overall), o >= 70 {
            next = "This shape is working. Run it again at the same intensity and watch whether the same heart rate starts costing less."
        } else if hard < 120 {
            next = "Next time add two or three intervals above threshold, keeping everything between them genuinely easy."
        } else {
            next = "Repeat this session in 2–3 days at the same intensity. The comparison is what makes the number mean something."
        }

        return SessionCoachSummary(strengths: strengths,
                                   improvements: improvements,
                                   nextSession: next)
    }
}
