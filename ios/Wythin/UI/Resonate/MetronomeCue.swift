import AVFoundation
import UIKit

// MARK: - Metronome cue
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
