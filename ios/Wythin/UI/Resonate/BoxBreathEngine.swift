import Foundation

// MARK: - Box breath engine
//
// The single timebase for a guided breath session. The pips, the perimeter sweep
// and the metronome click cannot desync because there is nothing to keep in sync —
// all three read this one object.
//
// Beats fire on absolute deadlines computed from the session start rather than by
// repeatedly adding an interval to "now", so a twenty-minute session doesn't
// accumulate drift.

/// Where a session is at a given moment. A pure function of elapsed seconds, so
/// it can be asserted on without waiting for real time — see `BoxBreathEngine.state(at:pattern:)`.
struct BreathState: Equatable {
    let phase:       BreathPhase
    let beatInPhase: Int   // 1-based: beat 1 opens the phase and carries the accent
    let cycle:       Int   // 1-based

    /// Beat 1 of every phase is accented, which is what makes the cycle
    /// followable with your eyes closed: the accent *is* the corner turn.
    var isAccent: Bool { beatInPhase == 1 }
}

@Observable
final class BoxBreathEngine {

    let pattern: BreathPattern

    private(set) var state:   BreathState
    private(set) var elapsed: TimeInterval = 0
    private(set) var isRunning = false

    /// Called on every beat, accent flag included. The session view hangs the
    /// metronome cue off this.
    var onBeat: ((BreathState) -> Void)?

    private var timer:     DispatchSourceTimer?
    private var startedAt: DispatchTime?
    private var beatIndex: Int = 0   // beats already fired

    init(pattern: BreathPattern = .box) {
        self.pattern = pattern
        self.state   = BoxBreathEngine.state(at: 0, pattern: pattern)
    }

    deinit { timer?.cancel() }

    // MARK: Pure timing

    /// The state `seconds` into a session. Beat boundaries are inclusive on the
    /// left: at exactly 6.0 s of a 6-second inhale you are on beat 1 of the hold.
    static func state(at seconds: TimeInterval, pattern: BreathPattern) -> BreathState {
        let cycleLength = pattern.cycleSeconds
        guard cycleLength > 0 else {
            return BreathState(phase: .inhale, beatInPhase: 1, cycle: 1)
        }

        let total       = max(0, Int(seconds.rounded(.down)))
        let cycle       = total / cycleLength + 1
        var intoCycle   = total % cycleLength

        for phase in BreathPhase.allCases {
            let length = pattern.seconds(phase)
            if length == 0 { continue }             // a pattern may skip a hold
            if intoCycle < length {
                return BreathState(phase: phase, beatInPhase: intoCycle + 1, cycle: cycle)
            }
            intoCycle -= length
        }

        // Unreachable while cycleLength > 0, but a total beats a crash.
        return BreathState(phase: .inhale, beatInPhase: 1, cycle: cycle)
    }

    /// How far through the current phase, 0...1 — drives the perimeter sweep and
    /// the inner circle's scale.
    var phaseProgress: Double {
        let length = pattern.seconds(state.phase)
        guard length > 0 else { return 0 }
        return Double(state.beatInPhase - 1) / Double(length)
    }

    // MARK: Transport

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let start = DispatchTime.now()
        startedAt = start
        beatIndex = 0
        elapsed   = 0
        state     = BoxBreathEngine.state(at: 0, pattern: pattern)
        onBeat?(state)                              // beat 1 fires immediately

        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Deadlines are absolute offsets from `start`, so scheduling jitter on one
        // beat doesn't push every later beat along with it.
        timer.schedule(deadline: start + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.advance() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer     = nil
        isRunning = false
    }

    private func advance() {
        beatIndex += 1
        elapsed    = TimeInterval(beatIndex)
        state      = BoxBreathEngine.state(at: elapsed, pattern: pattern)
        onBeat?(state)
    }
}
