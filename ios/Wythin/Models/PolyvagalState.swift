import SwiftUI

// MARK: - Science Fact

struct ScienceFact: Identifiable {
    let id = UUID()
    let title:       String
    let description: String
    let source:      String?
}

// MARK: - PolyvagalState

enum PolyvagalState {
    case regulated
    case elevated
    case low
    case unknown

    // MARK: Inference (priority-ordered — first match wins)

    static func infer(from tick: MetricsTick?) -> PolyvagalState {
        guard let t = tick, let rmssd = t.rmssd, let bpm = t.meanBPM else { return .unknown }
        let coh = t.coherenceScore ?? 0
        if rmssd < 25 && bpm < 62 && coh < 0.3 { return .low }
        if rmssd < 30 && bpm > 80               { return .elevated }
        if rmssd < 30                            { return .elevated }
        if rmssd > 35 && coh > 0.5              { return .regulated }
        return .regulated
    }

    // MARK: Display

    var displayName: String {
        switch self {
        case .regulated: return LocalizedCopy.text("Balanced")
        case .elevated:  return LocalizedCopy.text("Elevated")
        case .low:       return LocalizedCopy.text("Quiet")
        case .unknown:   return LocalizedCopy.text("Reading...")
        }
    }

    var severity: String {
        switch self {
        case .regulated: return LocalizedCopy.text("Optimal")
        case .elevated:  return LocalizedCopy.text("Moderate")
        case .low:       return LocalizedCopy.text("Low")
        case .unknown:   return LocalizedCopy.text("—")
        }
    }

    var severityProgress: Float {
        switch self {
        case .regulated: return 0.85
        case .elevated:  return 0.45
        case .low:       return 0.20
        case .unknown:   return 0.0
        }
    }

    var stateDescription: String {
        switch self {
        case .regulated: return LocalizedCopy.text("Your nervous system is calm and regulated. You're ready to focus or connect.")
        case .elevated:  return LocalizedCopy.text("Your body is responding to stress. Your nervous system is in an activated state right now.")
        case .low:       return LocalizedCopy.text("Your nervous system appears quiet or fatigued. Energy and engagement are low.")
        case .unknown:   return LocalizedCopy.text("Connect your Polar H10 to see your current nervous system state.")
        }
    }

    var color: Color {
        switch self {
        case .regulated: return Color(red: 0.18, green: 0.78, blue: 0.60)
        case .elevated:  return Color(red: 1.00, green: 0.62, blue: 0.22)
        case .low:       return Color(red: 0.42, green: 0.62, blue: 0.90)
        case .unknown:   return Color.gray
        }
    }

    // MARK: Action

    var actionTitle: String {
        switch self {
        case .regulated: return LocalizedCopy.text("Maintain Coherence")
        case .elevated:  return LocalizedCopy.text("90-Second Breathing Reset")
        case .low:       return LocalizedCopy.text("Activation Breath")
        case .unknown:   return LocalizedCopy.text("Connect Sensor")
        }
    }

    var actionDescription: String {
        switch self {
        case .regulated: return LocalizedCopy.text("You're in a great state. A short resonance session will deepen and sustain this.")
        case .elevated:  return LocalizedCopy.text("A short guided breathing cycle to activate your parasympathetic nervous system and lower arousal.")
        case .low:       return LocalizedCopy.text("Use energizing breath cycles to raise arousal and increase engagement.")
        case .unknown:   return LocalizedCopy.text("Pair your Polar H10 to get personalized real-time recommendations.")
        }
    }

    var actionOutcome: String {
        switch self {
        case .regulated: return LocalizedCopy.text("Sustained HRV · Peak focus")
        case .elevated:  return LocalizedCopy.text("Reduced arousal · Improved HRV")
        case .low:       return LocalizedCopy.text("Increased energy · Better focus")
        case .unknown:   return LocalizedCopy.text("Real-time guidance")
        }
    }

    var actionDuration: String {
        switch self {
        case .regulated: return LocalizedCopy.text("~5 min")
        case .elevated:  return LocalizedCopy.text("90 sec")
        case .low:       return LocalizedCopy.text("~2 min")
        case .unknown:   return ""
        }
    }

    var actionIcon: String {
        switch self {
        case .regulated: return "waveform.path.ecg"
        case .elevated:  return "wind"
        case .low:       return "bolt.fill"
        case .unknown:   return "antenna.radiowaves.left.and.right"
        }
    }

    var actionButtonLabel: String {
        switch self {
        case .regulated: return LocalizedCopy.text("Start Breathing Session")
        case .elevated:  return LocalizedCopy.text("Start Breathing Reset")
        case .low:       return LocalizedCopy.text("Start Activation")
        case .unknown:   return LocalizedCopy.text("Connect Device")
        }
    }

    // MARK: Science Facts

    var scienceFacts: [ScienceFact] {
        switch self {
        case .elevated:
            return [
                ScienceFact(title: LocalizedCopy.text("Vagus Nerve Activation"),
                            description: LocalizedCopy.text("Stimulates the parasympathetic system to signal your body to relax."),
                            source: "Journal of Inflammation Research"),
                ScienceFact(title: LocalizedCopy.text("CO2 Regulation"),
                            description: LocalizedCopy.text("Balances blood chemistry to physically reduce the fight-or-flight response."),
                            source: "Journal of Applied Physiology"),
                ScienceFact(title: LocalizedCopy.text("Heart-Breath Coupling"),
                            description: LocalizedCopy.text("Synchronizes heart and breath rhythms to improve stress resilience."),
                            source: nil),
            ]
        case .regulated:
            return [
                ScienceFact(title: LocalizedCopy.text("RSA Amplification"),
                            description: LocalizedCopy.text("Slow breathing at resonance maximizes respiratory sinus arrhythmia amplitude."),
                            source: "Applied Psychophysiology and Biofeedback"),
                ScienceFact(title: LocalizedCopy.text("Baroreflex Sensitivity"),
                            description: LocalizedCopy.text("Coherent HRV training increases baroreflex gain for better blood pressure regulation."),
                            source: "Journal of Human Hypertension"),
                ScienceFact(title: LocalizedCopy.text("Prefrontal Engagement"),
                            description: LocalizedCopy.text("High vagal tone supports executive function, focus, and emotional regulation."),
                            source: nil),
            ]
        case .low:
            return [
                ScienceFact(title: LocalizedCopy.text("Sympathetic Activation"),
                            description: LocalizedCopy.text("Short bursts of fast breathing temporarily increase arousal and alertness."),
                            source: "Frontiers in Human Neuroscience"),
                ScienceFact(title: LocalizedCopy.text("Oxygen Delivery"),
                            description: LocalizedCopy.text("Rhythmic diaphragmatic movement improves venous return and cerebral oxygenation."),
                            source: nil),
                ScienceFact(title: LocalizedCopy.text("Arousal Regulation"),
                            description: LocalizedCopy.text("Controlled breathing cycles can shift the nervous system from dorsal to ventral vagal state."),
                            source: nil),
            ]
        case .unknown:
            return []
        }
    }
}
