import Foundation

// MARK: - Box breath engine
//
// The single timebase for a guided breath session. The pips, the perimeter sweep
// and the metronome click cannot desync because there is nothing to keep in sync —
// all three read this one object.
//
// Beats fire on absolute deadlines computed from the pacer's start rather than by
// repeatedly adding an interval to "now", so a long session doesn't accumulate
// drift.

/// Where a session is at a given beat. A pure function of the beat index, so it
/// can be asserted on without waiting for real time.
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

    private(set) var pattern: BreathPattern
    private(set) var bpm:     Int

    private(set) var state:   BreathState
    /// Seconds since the pacer last (re)started. Reconfiguring resets it; the
    /// session's own total is tracked separately by the view for logging.
    private(set) var elapsed: TimeInterval = 0
    private(set) var isRunning = false

    /// Called on every beat, accent flag included. The session view hangs the
    /// metronome cue off this.
    var onBeat: ((BreathState) -> Void)?

    private var timer:     DispatchSourceTimer?
    private var beatIndex: Int = 0   // beats already fired since the pacer started

    init(pattern: BreathPattern = .box, bpm: Int = 60) {
        self.pattern = pattern
        self.bpm     = max(1, bpm)
        self.state   = BoxBreathEngine.state(atBeat: 0, pattern: pattern)
    }

    deinit { timer?.cancel() }

    // MARK: Pure timing

    /// The state at a given beat index (0-based). Integer arithmetic only — no
    /// tempo involved, because a phase is a whole number of beats by construction.
    static func state(atBeat index: Int, pattern: BreathPattern) -> BreathState {
        let cycleBeats = pattern.cycleBeats
        guard cycleBeats > 0 else {
            return BreathState(phase: .inhale, beatInPhase: 1, cycle: 1)
        }

        let total     = max(0, index)
        let cycle     = total / cycleBeats + 1
        var intoCycle = total % cycleBeats

        for phase in BreathPhase.allCases {
            let beats = pattern.beats(phase)
            if beats == 0 { continue }              // a pattern may skip a hold
            if intoCycle < beats {
                return BreathState(phase: phase, beatInPhase: intoCycle + 1, cycle: cycle)
            }
            intoCycle -= beats
        }

        // Unreachable while cycleBeats > 0, but a total beats a crash.
        return BreathState(phase: .inhale, beatInPhase: 1, cycle: cycle)
    }

    /// The state `seconds` into a session at a given tempo.
    static func state(at seconds: TimeInterval, pattern: BreathPattern, bpm: Int) -> BreathState {
        guard bpm > 0 else { return state(atBeat: 0, pattern: pattern) }
        let beat = Int((max(0, seconds) * Double(bpm) / 60.0).rounded(.down))
        return state(atBeat: beat, pattern: pattern)
    }

    /// Seconds per beat at the current tempo.
    var beatDuration: TimeInterval { 60.0 / Double(max(1, bpm)) }

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

    /// Apply new settings. The pacer restarts from beat 1 of the inhale, because
    /// resuming mid-phase under a different tempo would put the accent somewhere
    /// other than the phase change — the one thing this design guarantees.
    func reconfigure(pattern: BreathPattern, bpm: Int) {
        let newBPM = max(1, bpm)
        guard pattern != self.pattern || newBPM != self.bpm else { return }
        self.pattern = pattern
        self.bpm     = newBPM
        guard isRunning else {
            state = BoxBreathEngine.state(atBeat: 0, pattern: pattern)
            return
        }
        timer?.cancel()
        restartClock()
    }

    private func restartClock() {
        let start = DispatchTime.now()
        beatIndex = 0
        elapsed   = 0
        state     = BoxBreathEngine.state(atBeat: 0, pattern: pattern)
        onBeat?(state)                              // beat 1 fires immediately

        let interval = beatDuration
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Deadlines are absolute offsets from `start`, so scheduling jitter on one
        // beat doesn't push every later beat along with it.
        timer.schedule(deadline: start + interval,
                       repeating: interval,
                       leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.advance() }
        self.timer = timer
        timer.resume()
    }

    private func advance() {
        beatIndex += 1
        elapsed    = Double(beatIndex) * beatDuration
        state      = BoxBreathEngine.state(atBeat: beatIndex, pattern: pattern)
        onBeat?(state)
    }
}
