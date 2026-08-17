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
// A hold session needs sounds that say *keep going* for several seconds at a
// time, not a beat. So the breaths get glides — pitch and volume rising through
// the inhale, falling through the exhale — which you can follow without looking
// at anything, and the hold is bracketed by two short beeps.

@MainActor
final class HoldCue {

    enum Sound { case inhale, exhale, beep }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private var inhale: AVAudioPCMBuffer?
    private var exhale: AVAudioPCMBuffer?
    private var beep:   AVAudioPCMBuffer?
    private var glideSeconds = 0

    private let beepHaptic  = UIImpactFeedbackGenerator(style: .rigid)
    private let phaseHaptic = UIImpactFeedbackGenerator(style: .soft)

    var isMuted = false
    private var isStarted = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        beep = HoldCue.beepTone(format: format)
    }

    /// Glides are as long as the breath they pace, so they have to be rebuilt
    /// whenever that setting changes. Cached on length — the setup screen can
    /// step the value repeatedly without resynthesising each time.
    func prepare(breatheSeconds: Int) {
        guard breatheSeconds != glideSeconds else { return }
        glideSeconds = breatheSeconds
        inhale = HoldCue.glide(from: 196, to: 392, seconds: Double(breatheSeconds),
                               swell: true, format: format)
        exhale = HoldCue.glide(from: 392, to: 196, seconds: Double(breatheSeconds),
                               swell: false, format: format)
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
            // Silent audio still leaves the on-screen countdown and the haptics,
            // so a failure here does not sink the session.
            isStarted = false
        }
        beepHaptic.prepare()
        phaseHaptic.prepare()
    }

    func stop() {
        player.stop()
        engine.stop()
        isStarted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func play(_ sound: Sound) {
        switch sound {
        case .beep:             beepHaptic.impactOccurred()
        case .inhale, .exhale:  phaseHaptic.impactOccurred()
        }

        guard !isMuted, isStarted else { return }
        let buffer: AVAudioPCMBuffer?
        switch sound {
        case .inhale: buffer = inhale
        case .exhale: buffer = exhale
        case .beep:   buffer = beep
        }
        guard let buffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts])
    }

    // MARK: Synthesis

    /// A tone sweeping between two pitches over the whole phase. Phase is
    /// accumulated rather than computed from `sin(2π f t)` directly — with a
    /// changing frequency the direct form drifts out of phase with itself and
    /// the sweep audibly warbles.
    private static func glide(from f0: Double, to f1: Double, seconds: Double,
                              swell: Bool, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate   = format.sampleRate
        let frames = AVAudioFrameCount(rate * seconds)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        let fade = 0.12                     // seconds, both ends
        var phase = 0.0

        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let u = t / seconds             // 0…1 through the phase

            let freq = f0 + (f1 - f0) * u
            phase += 2 * .pi * freq / rate

            // Swell in for the inhale, ebb out for the exhale, so volume carries
            // the direction even for someone who can't hear the pitch move.
            let shape = swell ? (0.35 + 0.65 * u) : (1.0 - 0.65 * u)

            // Soft ends so the buffer never starts or stops on a discontinuity.
            let edge = min(1, min(t, seconds - t) / fade)

            channel[i] = Float(sin(phase) * shape * edge * 0.22)
        }
        return buffer
    }

    /// Short, clean and higher than the glides, so it reads as an instruction
    /// rather than part of the breath.
    private static func beepTone(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate     = format.sampleRate
        let duration = 0.16
        let frames   = AVAudioFrameCount(rate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        let attack = 0.005
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let envelope = (t < attack ? t / attack : 1) * exp(-14 * t)
            channel[i] = Float(sin(2 * .pi * 880 * t) * envelope * 0.5)
        }
        return buffer
    }
}
