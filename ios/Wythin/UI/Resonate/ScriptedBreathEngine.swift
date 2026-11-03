import Foundation

// MARK: - Scripted breath engine
//
// Walks a BreathScript one second at a time. Same shape as the other two
// engines — a DispatchSourceTimer on absolute deadlines, one callback the view
// hangs both the visual and the audio off — with one difference that the script
// forces:
//
// The pacers derive their state from elapsed seconds, so state is a pure
// function and nothing can drift. Here a natural step can be ended early by a
// tap, so where you are in the cycle is no longer implied by the clock. The
// engine therefore carries the position and moves it on the tick. The tick
// itself still runs on absolute deadlines, so the seconds inside a counted hold
// stay honest over a long session — which is the part that has to be exact.

struct ScriptedBreathState: Equatable {
    let stepIndex:         Int
    let cycle:             Int   // 1-based
    let secondsIntoStep:   Int
    let secondsLeftInStep: Int

    /// What the middle of the circle shows on a counted step.
    var countdown: String {
        let t = max(0, secondsLeftInStep)
        return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : "\(t)"
    }
}

@Observable
final class ScriptedBreathEngine {

    private(set) var script:  BreathScript
    private(set) var state:   ScriptedBreathState
    private(set) var elapsed: TimeInterval = 0
    private(set) var isRunning = false

    /// Fires on every second, and again immediately whenever a step changes, so
    /// a tapped-through step still gets its opening tone. The cue is derived
    /// from the state rather than passed alongside it, so there is no way for
    /// the two to disagree.
    var onTick: ((ScriptedBreathState, ScriptedCue.Event) -> Void)?

    private var timer: DispatchSourceTimer?
    private var ticks: Int = 0

    init(script: BreathScript = .stacking) {
        self.script = script
        self.state  = ScriptedBreathEngine.opening(script)
    }

    deinit { timer?.cancel() }

    // MARK: Pure walking
    //
    // The position moves through these three, so a whole cycle can be walked and
    // asserted without waiting on a clock — the same bargain the other engines
    // get for free by deriving state from elapsed seconds.

    /// The top of the cycle.
    static func opening(_ script: BreathScript) -> ScriptedBreathState {
        ScriptedBreathState(stepIndex: 0, cycle: 1, secondsIntoStep: 0,
                            secondsLeftInStep: script.steps.first?.pace.seconds ?? 1)
    }

    /// The next step, wrapping to the top and counting a cycle when it runs off
    /// the end.
    static func advanced(from state: ScriptedBreathState,
                         in script: BreathScript) -> ScriptedBreathState {
        guard !script.steps.isEmpty else { return opening(script) }
        let next    = state.stepIndex + 1
        let wrapped = next >= script.steps.count
        let index   = wrapped ? 0 : next
        return ScriptedBreathState(stepIndex: index,
                                   cycle: wrapped ? state.cycle + 1 : state.cycle,
                                   secondsIntoStep: 0,
                                   secondsLeftInStep: script.steps[index].pace.seconds)
    }

    /// One second on: further into this step, or over into the next one.
    static func ticked(from state: ScriptedBreathState,
                       in script: BreathScript) -> ScriptedBreathState {
        guard script.steps.indices.contains(state.stepIndex) else { return opening(script) }
        let seconds = script.steps[state.stepIndex].pace.seconds
        guard state.secondsIntoStep + 1 < seconds else {
            return advanced(from: state, in: script)
        }
        return ScriptedBreathState(stepIndex: state.stepIndex,
                                   cycle: state.cycle,
                                   secondsIntoStep: state.secondsIntoStep + 1,
                                   secondsLeftInStep: seconds - state.secondsIntoStep - 1)
    }

    // MARK: Cues

    /// What the ear hears at a given moment.
    ///
    /// A pure function of the position so the sound design can be asserted
    /// without playing anything. Getting this subtly wrong means someone
    /// breathing to the wrong cue with their eyes shut.
    static func cue(at state: ScriptedBreathState, script: BreathScript) -> ScriptedCue.Event {
        guard let step = script.steps.indices.contains(state.stepIndex)
                ? script.steps[state.stepIndex] : nil else { return .silent }

        if state.secondsIntoStep == 0 {
            switch step.move {
            // A breath at your own speed is walked through rather than marked:
            // the sound runs the length of the step and its colour tells you
            // which way you are going.
            case .inhale where step.pace.isNatural:  return .breatheIn
            case .exhale where step.pace.isNatural:  return .breatheOut
            // One effort, cued once and hard. Direction is the message.
            case .topUp:                             return .surgeUp
            case .squeezeOut:                        return .surgeDown
            // The rib flare gets its own quick, bright cue — it is over before a
            // sweep would have finished travelling.
            case .pump:                              return .pumpUp
            default:                                 return .stepOpen
            }
        }

        // The breath sound already covers its whole step.
        if step.pace.isNatural { return .silent }

        // Nothing follows a single effort. Ticking through one would make a
        // movement into a duration, which is exactly what it is not.
        if step.move.isSingleEffort { return .silent }

        if step.move.isLongHold {
            // Silent, except for a double three seconds out. The sip or squeeze
            // that closes a hold has to be prepared for, and being startled into
            // it is how people strain.
            return state.secondsLeftInStep == 3 ? .warn : .silent
        }

        return .count
    }

    // MARK: Transport

    func start() {
        guard !isRunning else { return }
        isRunning = true
        restartClock()
    }

    func stop() {
        timer?.cancel()
        timer     = nil
        isRunning = false
    }

    /// Move on now. Only offered for natural steps — a counted hold that could
    /// be tapped away is not a hold — and it re-bases the clock so the next step
    /// gets its full length.
    func advance() {
        guard isRunning else { return }
        state = ScriptedBreathEngine.advanced(from: state, in: script)
        emit()
        rebaseTimer()
    }

    /// Apply new lengths. Restarts at the top of the cycle: resuming mid-hold
    /// under a different hold length would leave someone sitting on empty for a
    /// duration neither number describes.
    func reconfigure(script: BreathScript) {
        guard script != self.script else { return }
        self.script = script
        state = ScriptedBreathEngine.opening(script)
        guard isRunning else { return }
        timer?.cancel()
        restartClock()
    }

    // MARK: Clock

    private func restartClock() {
        ticks   = 0
        elapsed = 0
        state   = ScriptedBreathEngine.opening(script)
        emit()
        rebaseTimer()
    }

    /// Deadlines are absolute offsets from now, so jitter on one second does not
    /// push the rest of the step along with it.
    private func rebaseTimer() {
        timer?.cancel()
        let start = DispatchTime.now()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: start + 1.0, repeating: 1.0, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        ticks  += 1
        elapsed = TimeInterval(ticks)

        state = ScriptedBreathEngine.ticked(from: state, in: script)
        emit()
    }

    private func emit() {
        onTick?(state, ScriptedBreathEngine.cue(at: state, script: script))
    }
}
