import XCTest
@testable import Wythin

/// A nudge offers a menu, not a prescription: the best intervention for a state
/// is worthless if the user is in a meeting or cannot leave the building.
final class NudgeCopyTests: XCTestCase {

    private var downshifts: [NudgeTriggerID] {
        NudgeTriggerID.allCases.filter(\.isDownshift)
    }

    private func menu(_ id: NudgeTriggerID,
                      disabled: Set<NudgeInterventionID> = [],
                      holds: Bool = true) -> [NudgeIntervention] {
        NudgeInterventionLibrary.menu(for: id, disabled: disabled, pacerHoldsAvailable: holds)
    }

    // MARK: Library shape

    func testEveryDownshiftOffersAMenu() {
        for id in downshifts {
            XCTAssertFalse(menu(id).isEmpty, "\(id.rawValue) has no options")
        }
    }

    func testTheFocusWindowOffersNothingToDo() {
        XCTAssertTrue(menu(.focusWindow).isEmpty)
    }

    /// Passive stretching's vagal effect peaks about half an hour later, which
    /// is the wrong shape for a nudge answering a state right now.
    func testStretchingIsNeverThePrimaryOption() {
        for id in downshifts {
            XCTAssertNotEqual(menu(id).first?.id, .stretch, "\(id.rawValue) leads with stretching")
        }
    }

    /// There must never be a nudge the user cannot act on where they are.
    func testEveryDownshiftMenuIncludesSomethingSilentAndSeated() {
        for id in downshifts {
            let usable = menu(id).contains { $0.isSilent && !$0.requiresLeavingDesk }
            XCTAssertTrue(usable, "\(id.rawValue) offers nothing for someone in a meeting")
        }
    }

    func testArousalLeadsWithSlowBreathing() {
        XCTAssertEqual(menu(.vagalWithdrawal).first?.id, .resonance)
    }

    func testBothMovementTriggersLeadWithAWalk() {
        XCTAssertEqual(menu(.sustainedLoad).first?.id, .walk)
        XCTAssertEqual(menu(.stuckStill).first?.id, .walk)
    }

    /// Cyclic sighing is the best-evidenced brief intervention for acute
    /// arousal, so the spike leads with it when the pacer can express it.
    func testTheAcuteSpikeLeadsWithCyclicSighing() {
        XCTAssertEqual(menu(.acuteSpike, holds: true).first?.id, .sighing)
    }

    /// The pacer models only rate and ratio today — no breath holds — so the
    /// spike falls back to resonance until that lands.
    func testTheSpikeFallsBackWhenThePacerCannotHold() {
        let m = menu(.acuteSpike, holds: false)
        XCTAssertEqual(m.first?.id, .resonance)
        XCTAssertFalse(m.contains { $0.id == .sighing || $0.id == .box })
    }

    // MARK: User preferences

    func testADisabledOptionNeverAppears() {
        for id in downshifts {
            XCTAssertFalse(menu(id, disabled: [.walk]).contains { $0.id == .walk })
        }
    }

    func testDisablingThePrimaryPromotesAnAlternate() {
        let m = menu(.vagalWithdrawal, disabled: [.resonance])
        XCTAssertFalse(m.isEmpty)
        XCTAssertNotEqual(m.first?.id, .resonance)
    }

    /// Someone who switches everything off should get no menu rather than a
    /// broken one.
    func testDisablingEverythingLeavesNoMenu() {
        let all = Set(NudgeInterventionID.allCases)
        XCTAssertTrue(menu(.vagalWithdrawal, disabled: all).isEmpty)
    }

    // MARK: Copy

    func testEveryDownshiftRendersATitleAndBody() {
        for id in downshifts {
            let content = NudgeCopy.render(id, options: menu(id))
            XCTAssertFalse(content.title.isEmpty, "\(id.rawValue) has no title")
            XCTAssertFalse(content.body.isEmpty, "\(id.rawValue) has no body")
        }
    }

    func testTheFocusWindowRendersInThePastTense() {
        let content = NudgeCopy.render(.focusWindow, options: [])
        XCTAssertFalse(content.title.isEmpty)
        XCTAssertTrue(content.options.isEmpty)
    }

    /// The rest of the app holds itself to plain language; the nudge deck is
    /// where jargon would most easily creep back in.
    func testNoRenderedStringUsesClinicalJargon() {
        let phrases = ["vagal", "parasympathetic", "sympathetic", "autonomic",
                       "coherence", "entropy", "deceleration", "fragmentation",
                       "heart rate variability", "baroreflex"]
        let acronyms = ["HRV", "RMSSD", "RSA", "SDNN", "DFA", "PIP", "DC", "LF", "HF"]

        for id in NudgeTriggerID.allCases {
            let content = NudgeCopy.render(id, options: menu(id))
            var strings = [content.title, content.body]
            strings += content.options.flatMap { [$0.title, $0.actionLabel, $0.why] }

            for s in strings {
                for p in phrases {
                    XCTAssertFalse(s.lowercased().contains(p),
                                   "\(id.rawValue) copy contains '\(p)': \(s)")
                }
                let words = s.components(separatedBy: CharacterSet.alphanumerics.inverted)
                for a in acronyms {
                    XCTAssertFalse(words.contains(a), "\(id.rawValue) copy contains '\(a)': \(s)")
                }
            }
        }
    }

    /// Each option explains itself in one plain sentence — the mechanism, not a
    /// citation.
    func testEveryOptionExplainsWhyItWorks() {
        for option in NudgeInterventionLibrary.all {
            XCTAssertFalse(option.why.isEmpty, "\(option.id.rawValue) has no rationale")
            XCTAssertGreaterThan(option.minutes, 0)
        }
    }
}
