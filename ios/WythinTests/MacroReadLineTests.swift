import XCTest
@testable import Wythin

/// `MacroReadLine.parse` is the only thing standing between a raw LLM reply
/// and which visual treatment each line gets (bulleted trend vs. accent-block
/// action vs. unstyled fallback prose) — get the classification wrong and the
/// card silently renders the wrong shape with no functional test noticing.
final class MacroReadLineTests: XCTestCase {

    func testBulletLineIsClassifiedAsBulletWithMarkerStripped() {
        let lines = MacroReadLine.parse("• Vagal tone climbed **all week**")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .bullet)
        XCTAssertEqual(lines[0].text, "Vagal tone climbed **all week**")
    }

    func testActionLineIsClassifiedAsActionWithMarkerStripped() {
        let lines = MacroReadLine.parse("→ Keep the evening breathing routine.")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .action)
        XCTAssertEqual(lines[0].text, "Keep the evening breathing routine.")
    }

    /// A line that is neither `•` nor `→` — e.g. a reply that reverted to
    /// the old "two sentences" shape, or any other unexpected text — must
    /// still come back as SOMETHING (`.prose`), not be silently dropped.
    func testLineWithNeitherMarkerIsClassifiedAsProseVerbatim() {
        let lines = MacroReadLine.parse("Your recovery markers held steady this week.")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .prose)
        XCTAssertEqual(lines[0].text, "Your recovery markers held steady this week.")
    }

    /// A reply with actions but no bullets at all must still parse — the
    /// actions must not require a bullet to precede them, and no bullet
    /// lines must be fabricated.
    func testReplyWithActionsButNoBulletsParsesOnlyActions() {
        let raw = "→ Keep the morning walk.\n→ Add one more recovery day."
        let lines = MacroReadLine.parse(raw)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.kind == .action })
        XCTAssertEqual(lines.map(\.text), ["Keep the morning walk.", "Add one more recovery day."])
    }

    func testFullReplyClassifiesEachLineIndependently() {
        let raw = """
        • Vagal tone climbed **all week**, a real gain
        • Inner noise stayed **elevated** most days
        → Keep the evening breathing routine
        → Add a third recovery day if energy dips
        """
        let lines = MacroReadLine.parse(raw)
        XCTAssertEqual(lines.map(\.kind), [.bullet, .bullet, .action, .action])
    }

    func testBlankLinesAreDropped() {
        let raw = "• A bullet\n\n\n→ An action\n"
        let lines = MacroReadLine.parse(raw)
        XCTAssertEqual(lines.count, 2)
    }

    /// Whitespace around a line (and around the marker) must not leak into
    /// the rendered text — a trailing space would visibly misalign the
    /// bolded span's trim in `MarkdownBullet.styled`.
    func testSurroundingWhitespaceIsTrimmedFromMarkerAndText() {
        let lines = MacroReadLine.parse("   •   Spaced out bullet   ")
        XCTAssertEqual(lines[0].text, "Spaced out bullet")
    }
}
