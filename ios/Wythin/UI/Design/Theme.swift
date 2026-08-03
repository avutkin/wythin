import SwiftUI

// MARK: - Colour Palette

enum Theme {
    // Backgrounds
    static let bg      = Color(hex: "#0C0C0C")   // pure near-black
    static let card    = Color(hex: "#171717")   // dark surface
    static let surface = Color(hex: "#222222")   // elevated surface (nested cards, icon containers)
    static let border  = Color(hex: "#2A2A2A")   // neutral subtle border

    // Accents (used in charts and metric colors)
    static let accent  = Color(hex: "#00E5A0")   // ECG green
    static let hrv     = Color(hex: "#818CF8")   // indigo — HRV metrics
    static let rsa     = Color(hex: "#FB923C")   // amber — RSA
    static let warn    = Color(hex: "#FF6B6B")   // soft red
    static let coh     = Color(hex: "#39D353")   // coherence green
    static let breathe = Color(hex: "#58A6FF")   // blue — breathing
    static let ulf     = Color(hex: "#A78BFA")   // muted violet — ULF

    // Exercise intensity domains, from DFA α1. Moderate reuses `accent`.
    //
    // Deliberately not `rsa` and `warn`: that pair sits at ΔE 10.9 in normal
    // vision, which is genuinely hard to tell apart in a stacked bar where the
    // two segments touch. These were validated against the card surface at
    // ΔE 22.3 normal and 11.8 protan.
    static let domainHeavy  = Color(hex: "#FDBA2D")   // DFA α1 0.50–0.75
    static let domainSevere = Color(hex: "#F43F5E")   // DFA α1 < 0.50

    // Text
    static let text    = Color(hex: "#FFFFFF")   // pure white
    static let dim     = Color(hex: "#787878")   // medium gray

    // MARK: Typography

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    static let monoSmall:    Font = .system(size: 11, design: .monospaced)
    static let monoBody:     Font = .system(size: 13, design: .monospaced)
    static let monoLabel:    Font = .system(size: 11, design: .monospaced)
    static let displayLarge: Font = .system(size: 42, weight: .bold, design: .default)

    // MARK: Spacing

    static let cardPad:    CGFloat = 16
    static let cardRadius: CGFloat = 16
}

// MARK: - Color hex initialiser

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: h)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >>  8) & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - View Modifiers

extension View {
    func cardStyle() -> some View {
        self
            .padding(Theme.cardPad)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
    }

    func monoLabel(_ text: String, color: Color = Theme.dim) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(Theme.monoLabel)
                .foregroundStyle(color)
            self
        }
    }
}

// MARK: - Markdown Bullet Styling

/// Renders an LLM bullet's `**bold**` markdown, brightening the bold span(s)
/// to the primary text color against a dim body. Both the Live widget's
/// bullets and the Track macro read's bullets ask the model for the exact
/// same convention — one bold key-idea span per bullet (see
/// `_LIVE_STATE_SYSTEM_PROMPT` and `_MACRO_TREND_SYSTEM_PROMPT` on the
/// server) — so there is one renderer for it, not one per screen. This used
/// to be a `private func` on `LiveStateWidget` alone; the macro read grew its
/// own separate (monospaced, unstyled) rendering of the identical markup
/// instead of sharing this, which is exactly the drift this extraction
/// closes.
enum MarkdownBullet {
    static func styled(_ s: String) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        for run in attr.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            attr[run.range].foregroundColor = Theme.text
        }
        return attr
    }
}

// MARK: - Metric Value Formatter

enum MetricFormat {
    static func bpm(_ v: Float?)      -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
    static func ms(_ v: Float?)       -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
    static func ratio(_ v: Float?)    -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
    static func percent(_ v: Float?)  -> String { v.map { String(format: "%.1f%%", $0) } ?? "—" }
    static func score(_ v: Float?)    -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
    static func hz(_ v: Float?)       -> String { v.map { String(format: "%.3f", $0) } ?? "—" }
}
