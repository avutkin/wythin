import AVFoundation
import UIKit

// MARK: - Session audio
//
// Two cue engines share this file because they share the synthesis approach:
// the project ships no audio assets, so every sound here is generated into a
// PCM buffer at init and replayed from it.
//
// MARK: Metronome cue
//
// The audible and tactile half of the pacer. The project ships no audio assets,
// so the two clicks are synthesized once at init — a short sine burst under a
// fast exponential decay, pitched higher for the accent — and replayed from
// buffers thereafter, which keeps each beat allocation-free.
//
// The audio session is .playback/.mixWithOthers deliberately: a metronome that
// goes silent with the ringer off is a bug, and one that stops the user's music
// is rude.

@MainActor
final class MetronomeCue {

    enum Beat { case accent, plain }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var accentBuffer: AVAudioPCMBuffer?
    private var plainBuffer:  AVAudioPCMBuffer?

    private let accentHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let plainHaptic  = UIImpactFeedbackGenerator(style: .light)

    /// Muting silences the click but keeps the haptics — the point of the mute
    /// button is to practise in a quiet room, not to lose the beat.
    var isMuted = false

    private var isStarted = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        // A4 and the E5 a fifth above it — consonant, so the accent reads as a
        // lift rather than an interruption.
        accentBuffer = MetronomeCue.tone(frequency: 659.25, format: format, gain: 0.5)
        plainBuffer  = MetronomeCue.tone(frequency: 440.00, format: format, gain: 0.32)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    // MARK: Transport

    func start() {
        guard !isStarted else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                            options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            player.play()
            isStarted = true
        } catch {
            // A metronome that can't make sound still paces fine on haptics and
            // the on-screen count, so a failure here doesn't sink the session.
            isStarted = false
        }
        accentHaptic.prepare()
        plainHaptic.prepare()
    }

    func stop() {
        player.stop()
        engine.stop()
        isStarted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Beats

    func play(_ beat: Beat) {
        switch beat {
        case .accent: accentHaptic.impactOccurred()
        case .plain:  plainHaptic.impactOccurred()
        }

        guard !isMuted, isStarted,
              let buffer = (beat == .accent ? accentBuffer : plainBuffer) else { return }
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts])
    }

    // MARK: Synthesis

    /// A soft struck tone, roughly a wooden mallet.
    ///
    /// Three things make it pleasant rather than a hard tick. The 6 ms attack
    /// ramp removes the waveform discontinuity that reads as a "click". The slow
    /// decay over ~300 ms lets it ring instead of snapping shut. And two quiet
    /// harmonics give the fundamental some body, so it doesn't sound like a test
    /// tone.
    private static func tone(frequency: Double, format: AVAudioFormat,
                             gain: Double) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let duration   = 0.30
        let frames     = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        let attack = 0.006          // seconds
        let decay  = 9.0            // e-folds per second

        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate

            // Ramp in, then ring out.
            let envelope = (t < attack ? t / attack : 1) * exp(-decay * t)

            // Harmonics decay faster than the fundamental, as struck wood does.
            var sample = sin(2 * .pi * frequency * t)
            sample += 0.28 * sin(2 * .pi * frequency * 2 * t) * exp(-decay * 1.8 * t)
            sample += 0.10 * sin(2 * .pi * frequency * 3 * t) * exp(-decay * 3.0 * t)

            channel[frame] = Float(sample * envelope * gain)
        }
        return buffer
    }
}

// MARK: - Breath-hold cue
//
// The hold session counts out loud rather than sliding. A short tone marks each
// second of a breath, a double marks the inhale handing over to the exhale, and
// a long tone opens and closes every hold. The hold itself is silent: the one
// place you least want a noise is halfway through holding your breath.
//
// This replaced a pair of pitch glides. A five-second slide told you a breath
// was happening but never where in it you were, and it was heard as intense —
// a continuous tone has no beat to sit behind.

@MainActor
final class HoldCue {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private var countTone:    AVAudioPCMBuffer?
    private var turnTone:     AVAudioPCMBuffer?
    private var boundaryTone: AVAudioPCMBuffer?

    private let softHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let firmHaptic = UIImpactFeedbackGenerator(style: .rigid)

    var isMuted = false
    private var isStarted = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Seconds tick at 587 Hz; boundaries sit a fifth below at 392 and ring
        // far longer, so a hold opening reads as heavier rather than just louder.
        countTone    = HoldCue.tone(frequency: 587.33, seconds: 0.09, decay: 26, gain: 0.20, format: format)
        turnTone     = HoldCue.doubleTone(frequency: 587.33, gap: 0.14, format: format)
        boundaryTone = HoldCue.tone(frequency: 392.00, seconds: 0.55, decay: 5,  gain: 0.26, format: format)
    }

    func start() {
        guard !isStarted else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                            options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            player.play()
            isStarted = true
        } catch {
            // Silent audio still leaves the countdown and the haptics, so a
            // failure here does not sink the session.
            isStarted = false
        }
        softHaptic.prepare()
        firmHaptic.prepare()
    }

    func stop() {
        player.stop()
        engine.stop()
        isStarted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Nothing plays for `.silent` — the hold is meant to be undisturbed.
    func play(_ event: HoldCueEvent) {
        switch event {
        case .count:           softHaptic.impactOccurred()
        case .turn, .boundary: firmHaptic.impactOccurred()
        case .silent:          return
        }

        guard !isMuted, isStarted else { return }
        let buffer: AVAudioPCMBuffer?
        switch event {
        case .count:    buffer = countTone
        case .turn:     buffer = turnTone
        case .boundary: buffer = boundaryTone
        case .silent:   buffer = nil
        }
        guard let buffer else { return }
        // No .interrupts: a count landing while a boundary still rings should
        // layer over it, not chop it off.
        player.scheduleBuffer(buffer, at: nil, options: [])
    }

    // MARK: Synthesis

    /// One struck tone. The short attack ramp keeps it from clicking; the decay
    /// rate is what separates a tick from a held note.
    private static func tone(frequency: Double, seconds: Double, decay: Double,
                             gain: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate   = format.sampleRate
        let frames = AVAudioFrameCount(rate * seconds)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        let attack = 0.006
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let envelope = (t < attack ? t / attack : 1) * exp(-decay * t)
            var sample = sin(2 * .pi * frequency * t)
            sample += 0.20 * sin(2 * .pi * frequency * 2 * t) * exp(-decay * 2 * t)
            channel[i] = Float(sample * envelope * gain)
        }
        return buffer
    }

    /// Two counts in one buffer, so the turn is unmistakably not a count. Built
    /// as a single buffer rather than two scheduled plays, which would leave the
    /// gap at the mercy of the audio queue.
    private static func doubleTone(frequency: Double, gap: Double,
                                   format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate   = format.sampleRate
        let single = 0.09
        let frames = AVAudioFrameCount(rate * (gap + single))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        let attack = 0.006
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            var value = 0.0
            for onset in [0.0, gap] where t >= onset && t < onset + single {
                let u = t - onset
                let envelope = (u < attack ? u / attack : 1) * exp(-26 * u)
                value += sin(2 * .pi * frequency * u) * envelope
            }
            channel[i] = Float(value * 0.20)
        }
        return buffer
    }
}
