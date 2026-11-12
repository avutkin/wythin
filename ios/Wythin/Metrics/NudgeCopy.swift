import Foundation

// MARK: - Interventions

enum NudgeInterventionID: String, CaseIterable, Equatable {
    case resonance, sighing, box, observe, stretch, walk
}

/// One thing the user can actually do, with the two properties that decide
/// whether they *can* do it right now: how long it takes and where it works.
struct NudgeIntervention: Equatable {
    let id: NudgeInterventionID
    let title: String
    let minutes: Int
    /// Notification action label — short, imperative.
    let actionLabel: String
    /// One plain sentence: the mechanism, not a citation.
    let why: String
    /// Needs to get up and go somewhere.
    let requiresLeavingDesk: Bool
    /// Can be done in a meeting: nothing audible, nothing visible.
    let isSilent: Bool
    /// Needs breath-hold phases the pacer cannot express yet.
    let needsPacerHolds: Bool
}

enum NudgeInterventionLibrary {

    static let all: [NudgeIntervention] = [
        .init(id: .resonance,
              title: LocalizedCopy.text("Slow breathing"),
              minutes: 5,
              actionLabel: LocalizedCopy.text("Start 5-minute reset"),
              why: LocalizedCopy.text("Breathing at about six a minute is the pace your heart rhythm swings widest at, which settles the whole system."),
              requiresLeavingDesk: false, isSilent: false, needsPacerHolds: false),

        .init(id: .sighing,
              title: LocalizedCopy.text("Sighing breaths"),
              minutes: 5,
              actionLabel: LocalizedCopy.text("Take 5 minutes"),
              why: LocalizedCopy.text("A double in-breath then a long sigh out, which shifts how you feel faster than anything else this short."),
              requiresLeavingDesk: false, isSilent: false, needsPacerHolds: true),

        .init(id: .box,
              title: LocalizedCopy.text("Box breathing"),
              minutes: 5,
              actionLabel: LocalizedCopy.text("Start box breathing"),
              why: LocalizedCopy.text("Equal counts in, hold, out, hold — easy to remember and you can do it without anyone noticing."),
              requiresLeavingDesk: false, isSilent: true, needsPacerHolds: true),

        .init(id: .observe,
              title: LocalizedCopy.text("Just watch your breath"),
              minutes: 10,
              actionLabel: LocalizedCopy.text("Sit for 10 minutes"),
              why: LocalizedCopy.text("No pacing, no counting — just following the breath. Works anywhere, including in a meeting."),
              requiresLeavingDesk: false, isSilent: true, needsPacerHolds: false),

        .init(id: .stretch,
              title: LocalizedCopy.text("Gentle stretches"),
              minutes: 8,
              actionLabel: LocalizedCopy.text("Stretch for a bit"),
              why: LocalizedCopy.text("Easy positions you hold and relax into — supported, never straining. Straining does the opposite."),
              requiresLeavingDesk: false, isSilent: true, needsPacerHolds: false),

        .init(id: .walk,
              title: LocalizedCopy.text("A short walk"),
              minutes: 10,
              actionLabel: LocalizedCopy.text("Start a walk"),
              why: LocalizedCopy.text("Ten minutes moving, outside and in daylight if you can — it restores focus better than pushing on does."),
              requiresLeavingDesk: true, isSilent: false, needsPacerHolds: false),
    ]

    static func intervention(_ id: NudgeInterventionID) -> NudgeIntervention {
        all.first { $0.id == id }!
    }

    /// Primary first, then alternates in decreasing evidence order for that
    /// state. Stretching never leads: its effect peaks about half an hour
    /// later, which does not answer "right now".
    private static let ordering: [NudgeTriggerID: [NudgeInterventionID]] = [
        .vagalWithdrawal: [.resonance, .box, .observe, .stretch],
        .sustainedLoad:   [.walk, .stretch, .observe, .resonance],
        .stuckStill:      [.walk, .stretch, .observe, .box],
        .acuteSpike:      [.sighing, .resonance, .box, .observe],
        .focusWindow:     [],
    ]

    /// The menu for one trigger, after removing what the user switched off and
    /// what the pacer cannot yet do.
    static func menu(for trigger: NudgeTriggerID,
                     disabled: Set<NudgeInterventionID> = [],
                     pacerHoldsAvailable: Bool = false) -> [NudgeIntervention] {
        (ordering[trigger] ?? [])
            .filter { !disabled.contains($0) }
            .map(intervention)
            .filter { pacerHoldsAvailable || !$0.needsPacerHolds }
    }
}

// MARK: - Content

struct NudgeContent: Equatable {
    let title: String
    let body: String
    /// Primary first; empty for the focus window, which is informational.
    let options: [NudgeIntervention]
}

/// Plain language only. The rest of the app holds itself to this standard and
/// the nudge deck is where jargon would most easily creep back in.
enum NudgeCopy {

    static func render(_ id: NudgeTriggerID, options: [NudgeIntervention]) -> NudgeContent {
        switch id {
        case .vagalWithdrawal:
            return NudgeContent(
                title: LocalizedCopy.text("You've been running hot"),
                body: LocalizedCopy.text("Your stress dial has been climbing for half an hour and is sitting in the revved-up zone. A few minutes of slow breathing brings it down."),
                options: options)

        case .sustainedLoad:
            return NudgeContent(
                title: LocalizedCopy.text("You've been at it a while"),
                body: LocalizedCopy.text("Ninety minutes of steady output, and your recovery signal is drifting down with it. Ten minutes away from the screen restores more than pushing through does."),
                options: options)

        case .stuckStill:
            return NudgeContent(
                title: LocalizedCopy.text("You've been still for a while"),
                body: LocalizedCopy.text("Nearly an hour without moving. Ten minutes outside — ideally daylight — resets more than you'd expect."),
                options: options)

        case .acuteSpike:
            return NudgeContent(
                title: LocalizedCopy.text("Something just landed"),
                body: LocalizedCopy.text("Your heart rate jumped without you moving. A few minutes of slow breathing takes the edge off before it settles in."),
                options: options)

        case .focusWindow:
            return NudgeContent(
                title: LocalizedCopy.text("This was your window"),
                body: LocalizedCopy.text("You were calm, steady and clear for a long stretch. Worth protecting that slot tomorrow."),
                options: [])
        }
    }
}
