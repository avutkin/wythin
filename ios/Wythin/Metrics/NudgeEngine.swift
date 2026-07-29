import Foundation

// MARK: - Durations

/// Stretches the metric window cannot hold.
///
/// The buffer keeps 45 minutes; the sedentary rule needs 50 and the load rule
/// 90, so these are tracked as scalars alongside it.
struct NudgeDurations: Equatable {

    /// Sustained motion above this, for long enough, counts as exertion.
    static let exertionMg: Float = 60
    static let exertionMinSeconds: TimeInterval = 180

    private(set) var stillSince:   Date?
    private(set) var loadSince:    Date?
    /// Last moment exertion was confirmed. Feeds the post-exertion lockout.
    private(set) var lastActiveAt: Date?

    private var exertionSince: Date?

    init() {}

    mutating func ingest(motion: Float?, now: Date) {
        // A connected, uninterrupted stretch — reset only by `interrupt()`.
        if loadSince == nil { loadSince = now }

        guard let motion else { return }

        if motion >= Self.exertionMg {
            let since = exertionSince ?? now
            exertionSince = since
            if now.timeIntervalSince(since) >= Self.exertionMinSeconds {
                lastActiveAt = now
            }
        } else {
            exertionSince = nil
        }

        if motion < ExerciseVeto.stillnessMg {
            if stillSince == nil { stillSince = now }
        } else {
            stillSince = nil
        }
    }

    /// A data gap, standby, or a logged activity breaks every stretch.
    ///
    /// `lastActiveAt` deliberately survives: the lockout is exactly what should
    /// outlive the activity that caused it.
    mutating func interrupt() {
        stillSince = nil
        loadSince = nil
        exertionSince = nil
    }
}

// MARK: - Suppression

/// Why no nudge was considered. A value rather than a bool so the settings row
/// and the shadow log can both explain themselves.
enum NudgeSuppressionReason: String, Equatable {
    case quietHours
    case strapOff
    case activityInProgress
    case noBaseline
    case warmingUp
    case budgetExhausted
}

enum NudgeSuppression {

    /// Ordered most-specific first, so the reported reason is the useful one.
    static func evaluate(now: Date,
                         bleStandby: Bool,
                         activityInProgress: Bool,
                         baseline: AnchorBaseline?,
                         signals: NudgeSignals?,
                         ledger: NudgeLedger,
                         calendar: Calendar = .current) -> NudgeSuppressionReason? {

        if bleStandby         { return .strapOff }
        if activityInProgress { return .activityInProgress }
        if baseline == nil    { return .noBaseline }
        if signals == nil     { return .warmingUp }
        if NudgeBudget.isQuietHours(now, calendar: calendar) { return .quietHours }

        // Nothing left to spend today. The focus window is exempt: it is silent
        // and keeps its own once-a-day allowance.
        let today = ledger.rolledOver(to: now, calendar: calendar)
        if today.downshiftCount >= NudgeBudget.maxDownshiftPerDay,
           !NudgeBudget.allows(.focusWindow, ledger: ledger, now: now, calendar: calendar) {
            return .budgetExhausted
        }
        return nil
    }
}

// MARK: - Outcome

/// One evaluation's result, recorded whether or not anything fired.
struct NudgeEvaluation: Equatable {
    let at: Date
    let candidates: [NudgeTriggerID]
    let selected: NudgeTriggerID?
    let suppression: NudgeSuppressionReason?
    /// True in Phase 1 for every selection: nothing is delivered yet.
    let shadowed: Bool
}

// MARK: - Shadow log

protocol NudgeShadowLogging: AnyObject {
    func record(_ evaluation: NudgeEvaluation)
}

/// Phase 1 output: a JSONL trail of what *would* have fired, so the thresholds
/// — nearly all of which are first guesses — can be tuned against real wear
/// before anyone is ever interrupted.
final class NudgeShadowLog: NudgeShadowLogging {

    private let url: URL?
    private let formatter = ISO8601DateFormatter()

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        url = dir?.appendingPathComponent("nudge-shadow.jsonl")
    }

    func record(_ e: NudgeEvaluation) {
        guard let url else { return }
        let row: [String: Any] = [
            "at": formatter.string(from: e.at),
            "candidates": e.candidates.map(\.rawValue),
            "selected": e.selected?.rawValue as Any,
            "suppression": e.suppression?.rawValue as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

// MARK: - Engine

/// Owns the buffer, the duration accumulators, per-trigger state and the
/// ledger, and answers once a minute: is there anything to say?
///
/// Phase 1 delivers nothing. Every selection is recorded and dropped.
@MainActor
final class NudgeEngine {

    /// Slow metrics move over ~20 minutes; evaluating faster than this only
    /// burns battery.
    static let evaluationInterval: TimeInterval = 55
    static let sustainDefault = 3
    /// The acute path trades a little confidence for speed — being late is its
    /// only real failure mode.
    static let sustainAcute = 2
    static let cooldown: TimeInterval = 30 * 60

    private(set) var buffer = NudgeSampleBuffer()
    private(set) var durations = NudgeDurations()
    private(set) var ledger = NudgeLedger()
    private var states: [String: NudgeTriggerState] = [:]
    private var lastEvaluatedAt: Date?

    private let log: NudgeShadowLogging

    init(log: NudgeShadowLogging = NudgeShadowLog()) {
        self.log = log
    }

    /// Called on every tick, foreground and background alike.
    func ingest(_ point: MetricsHistoryPoint, now: Date = .now) {
        buffer.append(point, now: now)
        durations.ingest(motion: point.motion, now: now)
    }

    /// A gap, standby, or a logged activity breaks every stretch.
    func interrupt() {
        durations.interrupt()
    }

    @discardableResult
    func evaluate(baseline: AnchorBaseline?,
                  bleStandby: Bool,
                  activityInProgress: Bool,
                  now: Date = .now,
                  calendar: Calendar = .current) -> NudgeEvaluation? {

        if let last = lastEvaluatedAt,
           now.timeIntervalSince(last) < Self.evaluationInterval { return nil }
        lastEvaluatedAt = now

        let signals = NudgeSignals.derive(from: buffer, baseline: baseline, now: now)

        if let reason = NudgeSuppression.evaluate(now: now,
                                                  bleStandby: bleStandby,
                                                  activityInProgress: activityInProgress,
                                                  baseline: baseline,
                                                  signals: signals,
                                                  ledger: ledger,
                                                  calendar: calendar) {
            return finish(NudgeEvaluation(at: now, candidates: [], selected: nil,
                                          suppression: reason, shadowed: true))
        }

        guard let signals, let baseline else {
            return finish(NudgeEvaluation(at: now, candidates: [], selected: nil,
                                          suppression: .warmingUp, shadowed: true))
        }

        let context = NudgeContext(now: now,
                                   stillSince: durations.stillSince,
                                   loadSince: durations.loadSince,
                                   lastActiveAt: durations.lastActiveAt)

        let matching = NudgeTriggers.evaluate(signals, baseline: baseline, context: context)

        // Advance every trigger's state machine, not only the matching ones —
        // a trigger that stopped matching still needs its release counted.
        var armed: [NudgeTriggerID] = []
        for id in NudgeTriggerID.allCases {
            let passed = matching.contains(id)
            let released = NudgeTriggers.releases(id, signals, baseline, context)
            let sustain = (id == .acuteSpike) ? Self.sustainAcute : Self.sustainDefault

            let (next, didFire) = NudgeStateMachine.advance(
                states[id.rawValue] ?? NudgeTriggerState(),
                passed: passed, released: released, now: now,
                sustain: sustain, cooldown: Self.cooldown)
            states[id.rawValue] = next
            if didFire { armed.append(id) }
        }

        let affordable = armed.filter {
            NudgeBudget.allows($0, ledger: ledger, now: now, calendar: calendar)
        }
        let selected = NudgePrecedence.select(affordable)
        if let selected {
            ledger = ledger.recording(selected, at: now, calendar: calendar)
        }

        return finish(NudgeEvaluation(at: now, candidates: matching, selected: selected,
                                      suppression: nil, shadowed: true))
    }

    private func finish(_ e: NudgeEvaluation) -> NudgeEvaluation {
        log.record(e)
        return e
    }
}
