import Foundation

// MARK: - Breath-hold engine
//
// One timebase for a set-based hold session, in the same shape as
// BoxBreathEngine: the phase mapping is a pure function of elapsed seconds, and
// a DispatchSourceTimer ticks it on absolute deadlines from the start so a long
// session doesn't drift.
//
// Unlike the pacers this one finishes. A hold session is a fixed number of sets,
// and running past the last one would be a different practice.

struct HoldState: Equatable {
    let phase:              HoldPhase
    let set:                Int   // 1-based
    let secondsIntoPhase:   Int
    let secondsLeftInPhase: Int
    let isFinished:         Bool

    /// The countdown the hold screen shows. Counts down rather than up, because
    /// the useful question during a hold is how much is left, not how much is
    /// done.
    var countdown: String {
        let t = max(0, secondsLeftInPhase)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// What the ear should hear on a given second.
///
/// A pure function of the state so the sound design can be asserted without
/// playing anything — the pattern is easy to get subtly wrong, and wrong here
/// means someone breathing to the wrong cue with their eyes shut.
enum HoldCueEvent: Equatable {
    case count    // one second of a breath, ticking it off
    case turn     // the double that marks inhale handing over to exhale
    case boundary // the long tone opening or closing a hold
    case silent   // inside the hold, where nothing should interrupt

    static func at(_ state: HoldState) -> HoldCueEvent {
        guard state.secondsIntoPhase == 0 else {
            // Mid-phase: count the breaths, leave the hold alone.
            return state.phase == .hold ? .silent : .count
        }
        switch state.phase {
        case .inhale: return .boundary   // also closes the hold that preceded it
        case .exhale: return .turn
        case .hold:   return .boundary
        }
    }
}

@Observable
final class BreathHoldEngine {

    private(set) var plan:    HoldProtocol
    private(set) var state:   HoldState
    private(set) var elapsed: Int = 0
    private(set) var isRunning = false

    /// Fires every second, including the first. The session view hangs the audio
    /// off this: the cue for a second is a pure function of the state, so one
    /// callback covers both the per-second counting and the boundary tones —
    /// and there is no second callback to fire twice on a phase change.
    var onTick: ((HoldState) -> Void)?
    /// Fires once when the last set's hold ends.
    var onFinish: (() -> Void)?

    private var timer: DispatchSourceTimer?

    init(plan: HoldProtocol = .standard) {
        self.plan  = plan
        self.state = BreathHoldEngine.state(at: 0, plan: plan)
    }

    deinit { timer?.cancel() }

    // MARK: Pure timing

    /// Where the session is `seconds` in. Each set runs inhale → exhale → hold,
    /// so the hold lands on empty lungs.
    static func state(at seconds: Int, plan: HoldProtocol) -> HoldState {
        let setLength = plan.setSeconds
        guard setLength > 0, plan.sets > 0 else {
            return HoldState(phase: .inhale, set: 1, secondsIntoPhase: 0,
                             secondsLeftInPhase: 0, isFinished: true)
        }

        let t = max(0, seconds)
        if t >= plan.totalSeconds {
            return HoldState(phase: .hold, set: plan.sets, secondsIntoPhase: plan.holdSeconds,
                             secondsLeftInPhase: 0, isFinished: true)
        }

        let set  = t / setLength + 1
        let into = t % setLength

        if into < plan.breatheSeconds {
            return HoldState(phase: .inhale, set: set, secondsIntoPhase: into,
                             secondsLeftInPhase: plan.breatheSeconds - into, isFinished: false)
        }
        if into < plan.breatheSeconds * 2 {
            let p = into - plan.breatheSeconds
            return HoldState(phase: .exhale, set: set, secondsIntoPhase: p,
                             secondsLeftInPhase: plan.breatheSeconds - p, isFinished: false)
        }
        let p = into - plan.breatheSeconds * 2
        return HoldState(phase: .hold, set: set, secondsIntoPhase: p,
                         secondsLeftInPhase: plan.holdSeconds - p, isFinished: false)
    }

    /// 0…1 through the current phase — drives the depleting ring and the
    /// expanding circle.
    var phaseProgress: Double {
        let total = plan.seconds(state.phase)
        guard total > 0 else { return 0 }
        return Double(state.secondsIntoPhase) / Double(total)
    }

    /// 0…1 through the whole session.
    var sessionProgress: Double {
        guard plan.totalSeconds > 0 else { return 0 }
        return min(Double(elapsed) / Double(plan.totalSeconds), 1)
    }

    // MARK: Transport

    func start() {
        guard !isRunning else { return }
        isRunning = true
        elapsed   = 0
        state     = BreathHoldEngine.state(at: 0, plan: plan)
        onTick?(state)

        let began = DispatchTime.now()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: began + .seconds(1), repeating: .seconds(1),
                       leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.advance() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer     = nil
        isRunning = false
    }

    /// Only meaningful before `start()` — the setup screen owns the numbers, and
    /// changing the plan mid-session would leave the set count ambiguous.
    func configure(_ plan: HoldProtocol) {
        guard !isRunning else { return }
        self.plan  = plan
        self.state = BreathHoldEngine.state(at: 0, plan: plan)
    }

    private func advance() {
        elapsed += 1
        let next = BreathHoldEngine.state(at: elapsed, plan: plan)
        let justFinished = next.isFinished && !state.isFinished
        state = next

        if justFinished {
            stop()
            onTick?(next)            // the long tone closing the final hold
            onFinish?()
            return
        }
        onTick?(next)
    }
}
