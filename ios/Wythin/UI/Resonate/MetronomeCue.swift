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

// MARK: - Scripted breath cue
//
// The third engine in this file, for a breath that is walked through rather than
// counted. It needs two sounds the other two do not.
//
// A natural inhale or exhale gets a soft breathy "juh" that swells and fades
// across the whole step — filtered noise whose colour opens as you draw in and
// closes as you let go, so the sound *is* the breath rather than a marker beside
// it. Silence would leave someone guessing whether the guide had stopped; a
// click would make an own-pace breath into a count.
//
// The top-up and the squeeze are single efforts, not durations. They get one
// hard cue that sweeps — up for the sip past full, down for the push past empty
// — and nothing after it. Counting through a move that is over in one push is
// what made it feel like a phase rather than an effort.

@MainActor
final class ScriptedCue {

    enum Event: Equatable {
        case stepOpen      // a step begins
        case breatheIn     // walk the inhale
        case breatheOut    // walk the exhale
        case count         // one second of a short counted move
        case pumpUp        // the one-second rib flare: quick, light, over at once
        case surgeUp       // one strong sip, past full
        case surgeDown     // one strong push, past empty
        case warn          // a hold is about to end
        case silent
    }

    private let engine = AVAudioEngine()
    /// Short cues and the breath sound get a node each, and the reason is not
    /// tidiness. An AVAudioPlayerNode plays what it is given in sequence, so a
    /// six-second breath sitting in the same queue would hold back the tone that
    /// opens the next step — and a natural step can be tapped short, which is
    /// exactly when that delay would be seconds long and audible.
    private let player       = AVAudioPlayerNode()
    private let breathPlayer = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private var openTone:  AVAudioPCMBuffer?
    private var countTone: AVAudioPCMBuffer?
    private var warnTone:  AVAudioPCMBuffer?
    private var pumpTone:  AVAudioPCMBuffer?
    private var upTone:    AVAudioPCMBuffer?
    private var downTone:  AVAudioPCMBuffer?
    private var inBreath:  AVAudioPCMBuffer?
    private var outBreath: AVAudioPCMBuffer?

    private let softHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let firmHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)

    var isMuted = false
    private var isStarted = false
    private var breathSeconds: Double = 0

    init() {
        engine.attach(player)
        engine.attach(breathPlayer)
        engine.connect(player,       to: engine.mainMixerNode, format: format)
        engine.connect(breathPlayer, to: engine.mainMixerNode, format: format)

        openTone  = ScriptedCue.tone(frequency: 392.00, seconds: 0.40, decay: 6,  gain: 0.20, format: format)
        countTone = ScriptedCue.tone(frequency: 587.33, seconds: 0.09, decay: 26, gain: 0.18, format: format)
        warnTone  = ScriptedCue.doubleTone(frequency: 587.33, gap: 0.14, format: format)
        // Bright and short, well clear of the count tone: the pump is one flick,
        // not a beat in a sequence.
        pumpTone  = ScriptedCue.tone(frequency: 784.00, seconds: 0.16, decay: 19, gain: 0.24, format: format)
        upTone    = ScriptedCue.sweep(from: 165, to: 330, format: format)
        downTone  = ScriptedCue.sweep(from: 330, to: 146, format: format)
        prepareBreath(seconds: 4)
    }

    /// Rebuild the two breath sounds to the length the guide is set to. Called
    /// when a session starts and whenever the BREATH setting moves, so the sound
    /// always runs exactly as long as the step it is walking.
    func prepareBreath(seconds: Int) {
        let length = Double(max(1, min(20, seconds)))
        guard length != breathSeconds else { return }
        breathSeconds = length
        inBreath  = ScriptedCue.breath(seconds: length, rising: true,  format: format)
        outBreath = ScriptedCue.breath(seconds: length, rising: false, format: format)
    }

    func start() {
        guard !isStarted else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                            options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            player.play()
            breathPlayer.play()
            isStarted = true
        } catch {
            // Haptics and the screen still carry the practice, so a failure here
            // does not sink the session.
            isStarted = false
        }
        softHaptic.prepare()
        firmHaptic.prepare()
        heavyHaptic.prepare()
    }

    func stop() {
        player.stop()
        breathPlayer.stop()
        engine.stop()
        isStarted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func play(_ event: Event) {
        switch event {
        case .count:                 softHaptic.impactOccurred()
        case .pumpUp:                firmHaptic.impactOccurred()
        case .stepOpen, .warn:       firmHaptic.impactOccurred()
        case .surgeUp, .surgeDown:   heavyHaptic.impactOccurred()
        case .breatheIn, .breatheOut: softHaptic.impactOccurred()
        case .silent:                return
        }

        guard !isMuted, isStarted else { return }

        switch event {
        case .breatheIn, .breatheOut:
            guard let buffer = (event == .breatheIn ? inBreath : outBreath) else { return }
            breathPlayer.scheduleBuffer(buffer, at: nil, options: [.interrupts])

        case .stepOpen, .surgeUp, .surgeDown, .pumpUp:
            // A step boundary ends the breath before it. Tapping a natural step
            // short would otherwise leave its sound running underneath the next
            // move, which reads as being asked to keep breathing in during a
            // hold. stop() drops everything queued on that node; play() re-arms it.
            breathPlayer.stop()
            breathPlayer.play()
            schedule(shortBuffer(for: event))

        case .count, .warn:
            schedule(shortBuffer(for: event))

        case .silent:
            return
        }
    }

    private func shortBuffer(for event: Event) -> AVAudioPCMBuffer? {
        switch event {
        case .stepOpen:  return openTone
        case .count:     return countTone
        case .warn:      return warnTone
        case .surgeUp:   return upTone
        case .surgeDown: return downTone
        case .pumpUp:    return pumpTone
        default:         return nil
        }
    }

    /// No .interrupts: a count landing while the step tone still rings should
    /// layer over it rather than chop it off.
    private func schedule(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: [])
    }

    // MARK: Synthesis

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

    /// A pitch that moves, low and with some weight behind it. The direction is
    /// the message — up for the sip past full, down for the push past empty.
    ///
    /// Pitched roughly an octave below where this started out. High and quick
    /// read as a notification; this cue is asking for real effort, so it wants
    /// the register of something being lifted rather than something pinging.
    private static func sweep(from: Double, to: Double,
                              format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate    = format.sampleRate
        let seconds = 0.72
        let travel  = 0.34
        let frames  = AVAudioFrameCount(rate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        // Phase is accumulated rather than computed from t: sin(2πft) with a
        // moving f steps the phase discontinuously and buzzes.
        var phase = 0.0, subPhase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let f = from + (to - from) * min(1, t / travel)
            phase    += 2 * .pi * f / rate
            subPhase += 2 * .pi * f / 2 / rate

            let envelope = (t < 0.010 ? t / 0.010 : 1) * exp(-3.2 * t)
            var sample = sin(phase)
            sample += 0.45 * sin(subPhase)                    // an octave under, for mass
            sample += 0.22 * sin(2 * phase) * exp(-7 * t)     // enough edge to cut through
            channel[i] = Float(sample * envelope * 0.30)
        }
        return buffer
    }

    /// The breath itself, shaped so its direction is unmistakable.
    ///
    /// Three things move together across the step, and all three run one way for
    /// an inhale and the other for an exhale:
    ///
    ///   colour  — a resonant band sweeps up as the chest fills, down as it empties
    ///   weight  — an inhale grows into itself; an exhale starts full and lets go
    ///   body    — the low end thins as the breath climbs, thickens as it falls
    ///
    /// The earlier version swelled and faded the same way in both directions, so
    /// only the filter carried the message and the sound read as generic breath
    /// noise. A gradient in loudness is what makes the shape legible.
    private static func breath(seconds: Double, rising: Bool,
                               format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate   = format.sampleRate
        let frames = AVAudioFrameCount(rate * seconds)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        // xorshift rather than Double.random: half a million calls per breath,
        // built on the main thread when the setting changes.
        var seed: UInt32 = 0x9E37_79B9
        func noise() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            return Double(Int32(bitPattern: seed)) / Double(Int32.max)
        }

        let open = 1850.0, closed = 340.0
        var lowpass = 0.0
        var band = 0.0, low = 0.0          // state-variable filter, for the formant

        // Edges only. The gradient does the work in between, so the envelope is
        // just there to stop the buffer starting or ending on a step.
        let edge = 0.06

        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let p = t / seconds                          // 0 … 1 across the breath

            // Everything is written in terms of how far the chest has filled, so
            // an exhale is genuinely the inhale run backwards rather than a
            // separate sound that happens to fall.
            let fullness = rising ? p : 1 - p

            let source = noise()

            // Broadband bed, opening and closing with the breath.
            let cutoff = closed + (open - closed) * fullness
            let a = 1 - exp(-2 * .pi * cutoff / rate)
            lowpass += a * (source - lowpass)

            // A resonant band riding on top. This is the part the ear tracks as
            // a glide rather than as a hiss getting brighter.
            let centre = 320 + 900 * fullness
            let f = 2 * sin(.pi * centre / rate)
            low  += f * band
            let high = source - low - 0.55 * band
            band += f * high

            // Weight: an inhale gathers, an exhale spends what it has.
            let gradient = rising ? 0.25 + 0.75 * p
                                  : 1.00 - 0.72 * p

            var envelope = gradient
            if p < edge      { envelope *= p / edge }
            if p > 1 - edge  { envelope *= (1 - p) / edge }

            // The low body thins out as the breath climbs.
            let bodyGain = 0.9 - 0.45 * fullness

            // 90 ms of quiet low voice at the top of the breath — the consonant.
            let onset = t < 0.09 ? 0.40 * sin(2 * .pi * 138 * t) * (1 - t / 0.09) : 0

            let sample = lowpass * 2.3 * bodyGain + band * 0.9 + onset
            channel[i] = Float(sample * envelope * 0.17)
        }
        return buffer
    }
}
