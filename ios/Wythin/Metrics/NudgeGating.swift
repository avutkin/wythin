import Foundation

// MARK: - Sustain and hysteresis

enum NudgePhase: Equatable {
    case idle
    /// Consecutive passing evaluations so far.
    case arming(passes: Int)
    case fired(at: Date)
    /// Consecutive releasing evaluations since firing.
    case releasing(at: Date, count: Int)
}

struct NudgeTriggerState: Equatable {
    var phase: NudgePhase = .idle
    init() {}
    init(phase: NudgePhase) { self.phase = phase }
}

/// Per-trigger lifecycle: `idle → arming → fired → releasing → idle`.
///
/// Two properties matter more than the mechanics:
///
/// - **No flapping.** A signal oscillating across its threshold never reaches
///   `sustain` consecutive passes, so it never fires.
/// - **No nagging.** A condition that stays true fires *once*. Re-arming needs
///   the release threshold — deliberately set back from the arm threshold — to
///   hold twice *and* the cooldown to elapse. If arousal is high all afternoon
///   the user hears about it once.
enum NudgeStateMachine {

    /// Releasing must hold this many evaluations before the trigger re-arms.
    static let releasesToRearm = 2

    static func advance(_ state: NudgeTriggerState,
                        passed: Bool,
                        released: Bool,
                        now: Date,
                        sustain: Int,
                        cooldown: TimeInterval) -> (NudgeTriggerState, Bool) {

        switch state.phase {

        case .idle:
            guard passed else { return (state, false) }
            let passes = 1
            if passes >= sustain {
                return (NudgeTriggerState(phase: .fired(at: now)), true)
            }
            return (NudgeTriggerState(phase: .arming(passes: passes)), false)

        case .arming(let passes):
            guard passed else { return (NudgeTriggerState(phase: .idle), false) }
            let next = passes + 1
            if next >= sustain {
                return (NudgeTriggerState(phase: .fired(at: now)), true)
            }
            return (NudgeTriggerState(phase: .arming(passes: next)), false)

        case .fired(let firedAt):
            guard released else { return (state, false) }
            return (NudgeTriggerState(phase: .releasing(at: firedAt, count: 1)), false)

        case .releasing(let firedAt, let count):
            guard released else {
                // Condition came back before the release completed.
                return (NudgeTriggerState(phase: .fired(at: firedAt)), false)
            }
            let next = count + 1
            let cooledDown = now.timeIntervalSince(firedAt) >= cooldown
            if next >= releasesToRearm && cooledDown {
                return (NudgeTriggerState(phase: .idle), false)
            }
            return (NudgeTriggerState(phase: .releasing(at: firedAt, count: next)), false)
        }
    }
}

// MARK: - Precedence

/// Exactly one nudge per evaluation.
///
/// The focus window comes first because it is silent and cannot annoy; the
/// acute spike next because it is the only time-critical one; stillness last
/// because it tolerates delay better than anything else.
enum NudgePrecedence {

    static let order: [NudgeTriggerID] = [
        .focusWindow, .acuteSpike, .vagalWithdrawal, .sustainedLoad, .stuckStill,
    ]

    static func select(_ candidates: [NudgeTriggerID]) -> NudgeTriggerID? {
        order.first { candidates.contains($0) }
    }
}

// MARK: - Ledger

/// What has already fired today. Persisted so a background relaunch does not
/// hand the user a fresh allowance.
struct NudgeLedger: Equatable {
    var dayKey: String?
    var lastDownshiftAt: Date?
    var downshiftCount: Int = 0
    var lastFiredByID: [String: Date] = [:]
    var focusFiredDayKey: String?

    init() {}

    /// Returns a ledger with this firing recorded, rolling the day over first
    /// if the calendar day has changed.
    func recording(_ id: NudgeTriggerID, at now: Date, calendar: Calendar = .current) -> NudgeLedger {
        var next = rolledOver(to: now, calendar: calendar)
        next.lastFiredByID[id.rawValue] = now
        if id == .focusWindow {
            next.focusFiredDayKey = NudgeBudget.dayKey(now, calendar: calendar)
        } else {
            next.lastDownshiftAt = now
            next.downshiftCount += 1
        }
        return next
    }

    /// Day rollover is a key comparison rather than a timer, so crossing
    /// midnight while backgrounded resets correctly.
    func rolledOver(to now: Date, calendar: Calendar) -> NudgeLedger {
        let key = NudgeBudget.dayKey(now, calendar: calendar)
        guard dayKey != key else { return self }
        var next = NudgeLedger()
        next.dayKey = key
        // Per-id history survives rollover: the 3-hour anti-repeat window can
        // straddle midnight.
        next.lastFiredByID = lastFiredByID
        next.focusFiredDayKey = focusFiredDayKey
        return next
    }
}

// MARK: - Budget

enum NudgeBudget {

    static let maxDownshiftPerDay = 3
    static let minSpacing: TimeInterval = 90 * 60
    /// One rule must not eat the whole daily allowance.
    static let sameTriggerRepeat: TimeInterval = 3 * 60 * 60

    static let quietStartHour = 22
    static let quietEndHour   = 7

    /// First guess pending the work-hours question in the spec.
    static let workStartHour = 9
    static let workEndHour   = 18

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Suppressed, never queued: a stale nudge at 07:01 about last night's
    /// state is worse than no nudge.
    static func isQuietHours(_ now: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= quietStartHour || hour < quietEndHour
    }

    static func isWorkHours(_ now: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= workStartHour && hour < workEndHour
    }

    static func allows(_ id: NudgeTriggerID,
                       ledger: NudgeLedger,
                       now: Date,
                       calendar: Calendar = .current) -> Bool {

        let today = ledger.rolledOver(to: now, calendar: calendar)

        // Per-trigger anti-repeat applies to everything.
        if let last = today.lastFiredByID[id.rawValue],
           now.timeIntervalSince(last) < sameTriggerRepeat {
            return false
        }

        guard id.isDownshift else {
            // Silent, so exempt from spacing and the downshift cap — but once a
            // day and only while the user is plausibly working.
            guard isWorkHours(now, calendar: calendar) else { return false }
            return today.focusFiredDayKey != dayKey(now, calendar: calendar)
        }

        guard !isQuietHours(now, calendar: calendar) else { return false }
        guard today.downshiftCount < maxDownshiftPerDay else { return false }
        if let last = today.lastDownshiftAt, now.timeIntervalSince(last) < minSpacing {
            return false
        }
        return true
    }
}
