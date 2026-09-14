import SwiftUI

// The check-in's model and control. Every decision a view would otherwise
// take on the fly — what nil looks like, where a drag lands, which scales a
// prompt asks — is a pure type here so it can be tested without a view host.
// First built for the Live widget in August (a8aa086), removed the same day,
// resurrected for the sheet on 2026-09-13.

/// The two prompts. `wireValue` is the server's `kind`.
enum CheckInKind: String, Equatable {
    case moment, previousDay

    var wireValue: String {
        switch self {
        case .moment:      return "moment"
        case .previousDay: return "previous_day"
        }
    }

    /// The scales the sheet renders, in order.
    var scales: [FeltStateScaleKey] {
        switch self {
        case .moment:      return [.mood, .focus, .energy, .anxiety, .stress]
        case .previousDay: return [.focus, .energy, .anxiety, .stress, .sleep]
        }
    }

    var title: String {
        switch self {
        case .moment:      return "How do you feel right now?"
        case .previousDay: return "Yesterday, on average"
        }
    }

    /// One short clause under the title. No dash constructions and short
    /// enough never to wrap on the narrowest phone.
    var helper: String {
        switch self {
        case .moment:      return "A few seconds. Skip any you like."
        case .previousDay: return "The day as a whole, not its best moment."
        }
    }
}

/// The six scales. Anchor words follow the onboarding sliders so the
/// baseline and the check-ins share a vocabulary. Nothing else is ever shown
/// alongside the control — no number — so where the knob sits is the whole
/// answer.
enum FeltStateScaleKey: String, CaseIterable {
    case mood, focus, energy, anxiety, stress, sleep

    var label: String {
        switch self {
        case .mood:    return "FEEL"
        case .focus:   return "FOCUS"
        case .energy:  return "ENERGY"
        case .anxiety: return "ANXIETY"
        case .stress:  return "STRESS"
        case .sleep:   return "LAST NIGHT'S SLEEP"
        }
    }

    var leftAnchor: String {
        switch self {
        case .mood:    return "low"
        case .focus:   return "scattered"
        case .energy:  return "depleted"
        case .anxiety: return "calm"
        case .stress:  return "easy"
        case .sleep:   return "broken"
        }
    }

    var rightAnchor: String {
        switch self {
        case .mood:    return "great"
        case .focus:   return "sharp"
        case .energy:  return "charged"
        case .anxiety: return "on edge"
        case .stress:  return "under load"
        case .sleep:   return "deep"
        }
    }
}

/// The in-progress check-in: one optional 0–100 value per scale. `nil` IS
/// the touched flag — a scale the user has never dragged has no value here
/// at all, rather than a value that happens to equal whatever default the
/// view might otherwise pick. `makeLog` carries that straight through to
/// `FeltStateLog`, so "untouched" survives all the way to the saved row.
struct FeltStateDraft: Equatable {
    var mood:    Double?
    var focus:   Double?
    var energy:  Double?
    var anxiety: Double?
    var stress:  Double?
    var sleep:   Double?

    static let empty = FeltStateDraft()

    subscript(key: FeltStateScaleKey) -> Double? {
        get {
            switch key {
            case .mood:    return mood
            case .focus:   return focus
            case .energy:  return energy
            case .anxiety: return anxiety
            case .stress:  return stress
            case .sleep:   return sleep
            }
        }
        set {
            switch key {
            case .mood:    mood = newValue
            case .focus:   focus = newValue
            case .energy:  energy = newValue
            case .anxiety: anxiety = newValue
            case .stress:  stress = newValue
            case .sleep:   sleep = newValue
            }
        }
    }

    /// A fully-untouched draft has nothing worth persisting — Done stays
    /// disabled against it rather than writing an all-blank row.
    var hasAnyAnswer: Bool {
        FeltStateScaleKey.allCases.contains { self[$0] != nil }
    }

    /// Builds the row to persist. One pure function rather than an inline
    /// `FeltStateLog(...)` at the save call site, so the untouched-stays-nil
    /// mapping is a single tested place.
    func makeLog(kind: CheckInKind, dayKey: String, wornMinutes: Double?,
                 timezone: String = TimeZone.current.identifier,
                 stateKey: String? = nil, now: Date = .now) -> FeltStateLog {
        FeltStateLog(timestamp: now, kind: kind.wireValue, focus: focus, energy: energy,
                     stress: stress, mood: mood, anxiety: anxiety, sleep: sleep,
                     dayKey: dayKey, timezone: timezone, wornMinutes: wornMinutes,
                     stateKey: stateKey)
    }
}

/// A scale's rendered knob position and fill, decided in one pure place so
/// "untouched is not the middle" — grey, centred knob, no fill — is a fact
/// about `nil` the view reads off, not a branch it has to remember.
struct FeltStateKnobSpec: Equatable {
    /// 0...1 fraction along the track where the knob's centre sits.
    let knobFraction: Double
    /// 0...1 fraction of the track that renders as filled. Zero for an
    /// untouched scale: any fill for a value that was never answered would
    /// read as a real reading.
    let fillFraction: Double
    let isTouched: Bool

    static func build(value: Double?) -> FeltStateKnobSpec {
        guard let value else {
            return FeltStateKnobSpec(knobFraction: 0.5, fillFraction: 0, isTouched: false)
        }
        let fraction = min(max(value / 100, 0), 1)
        return FeltStateKnobSpec(knobFraction: fraction, fillFraction: fraction, isTouched: true)
    }
}

/// Converts a drag's raw position on the track into a stored 0–100 value.
/// Pure and separate from the gesture handler so the clamping at both ends
/// is tested without a view host.
enum FeltStateDragMapping {
    static func value(x: Double, trackWidth: Double) -> Double {
        guard trackWidth > 0 else { return 0 }
        let fraction = min(max(x / trackWidth, 0), 1)
        return fraction * 100
    }
}

/// One scale: label, a drag track with a thumb-sized knob, anchor words at
/// each end. The whole track is the target — a tap places the knob too.
struct FeltStateScaleRow: View {
    let key: FeltStateScaleKey
    @Binding var value: Double?

    private let knobSize: CGFloat = 28
    private let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key.label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            GeometryReader { geo in
                let trackWidth = max(0, geo.size.width - knobSize)
                let spec = FeltStateKnobSpec.build(value: value)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.dim.opacity(0.18))
                        .frame(height: 6)
                        .padding(.horizontal, knobSize / 2)
                    if spec.isTouched {
                        Capsule()
                            .fill(Theme.accent.opacity(0.6))
                            .frame(width: CGFloat(spec.fillFraction) * trackWidth, height: 6)
                            .padding(.leading, knobSize / 2)
                    }
                    Circle()
                        .fill(spec.isTouched ? Theme.accent : Theme.dim.opacity(0.5))
                        .frame(width: knobSize, height: knobSize)
                        .overlay(Circle().strokeBorder(Theme.bg.opacity(0.3), lineWidth: 0.5))
                        .offset(x: CGFloat(spec.knobFraction) * trackWidth)
                }
                .frame(height: rowHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            value = FeltStateDragMapping.value(x: g.location.x - knobSize / 2,
                                                               trackWidth: trackWidth)
                        }
                )
            }
            .frame(height: rowHeight)
            // The ends of the scale in plain white: they are the only words
            // that say what a position means, so they must read at a glance.
            HStack {
                Text(key.leftAnchor)
                Spacer()
                Text(key.rightAnchor)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(key.label)
        .accessibilityValue(value.map { "\(Int($0.rounded())) of 100" } ?? "not set")
    }
}
