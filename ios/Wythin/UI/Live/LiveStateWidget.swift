import SwiftUI
import SwiftData

/// Plain-language band text for one metric's own `effective` reading (its
/// level adjusted by trend — see `MetricReading`).
///
/// Deliberately NOT fed a `StateContribution.value`: that quantity is weight
/// × effective (see `LiveStateClassifier.rankedPulls`), which is correct for
/// *ranking* the WHY list but is not on the same scale as the z-calibrated
/// thresholds below — a metric with a small axis weight would read as barely
/// moved even when its own reading was extreme. The contribution decides
/// order; this describes the metric on its own terms. Same bands as
/// `DayPotentialStore.level(_:)` so the same words mean the same thing
/// everywhere in the app.
enum LiveWhyBand {
    static func text(for effective: Float) -> String {
        switch effective {
        case 1.0...:         return "well above your usual"
        case 0.35..<1.0:     return "above your usual"
        case -0.35..<0.35:   return "right around your usual"
        case -1.0 ..< -0.35: return "below your usual"
        default:             return "well below your usual"
        }
    }

    /// Below this absolute native-unit baseline centre, a percentage swings
    /// wildly for a tiny absolute change — and divides by zero outright at
    /// exactly zero — so it is never printed. Deliberately a generic safety
    /// net rather than a per-metric figure: nothing in this codebase's
    /// metrics is expected to sit this close to zero in practice, so the
    /// exact value only matters for the degenerate case it exists to catch.
    private static let degenerateCentreThreshold: Float = 1e-3

    /// The user's chosen shape for a WHY row: the number leads, the plain
    /// meaning follows, no dash — "38% below your usual", not "well below
    /// your usual — 38%". Falls back to the qualitative band (`text(for:)`)
    /// in the two cases where a number would overstate what the reading
    /// actually supports:
    ///
    /// - `level` is in the neutral band. Checked by asking `text(for:)`
    ///   itself rather than repeating its `-0.35..<0.35` cutoff here, so the
    ///   two can never disagree about where "right around your usual" starts.
    ///   A number here would claim a precision the reading does not have.
    /// - the baseline centre is at or near zero (`degenerateCentreThreshold`),
    ///   where percent-of-a-near-zero quantity is not a meaningful figure.
    ///
    /// A percentage that itself rounds to 0% is treated the same way —
    /// "0% above your usual" reads as a contradiction of the row it sits in,
    /// so it falls back too.
    ///
    /// Takes `level`, deliberately NOT `effective`: `windowValue` and
    /// `baselineCentre` are both level-scale (trend plays no part in either),
    /// so banding on `effective` here could disagree in sign with the
    /// percentage this same call computes from them — see `LiveWhyRow.build`,
    /// the one call site, for the full reasoning and the regression test.
    static func text(level: Float, windowValue: Float, baselineCentre: Float) -> String {
        let band = text(for: level)
        guard band != "right around your usual" else { return band }
        guard abs(baselineCentre) > degenerateCentreThreshold else { return band }

        let percent = Int(((windowValue - baselineCentre) / baselineCentre * 100).rounded())
        guard percent != 0 else { return band }
        return percent > 0 ? "\(percent)% above your usual" : "\(-percent)% below your usual"
    }
}

/// The WHY row's bar length: `value`'s magnitude on a FIXED scale, so the bar
/// says how much the metric actually pulled, not merely where it ranks.
///
/// It used to normalise by the strongest contribution in the list, which made
/// the leading bar full-width unconditionally — including on a maximally flat
/// window, where the one fallback contribution rendered as a single confident
/// full-width bar. The spec's weak-call design says the opposite: "the impact
/// bars are all short. This is honest and visible, where the current version
/// hides a weak call behind equally confident prose." Rank is already legible
/// from top-to-bottom order; the bar's job is magnitude.
///
/// Returns plain `Double` rather than `CGFloat` so this stays testable
/// without importing SwiftUI/CoreGraphics; the view converts at the call
/// site.
enum LiveWhyBar {
    /// Floor so even the weakest surviving contribution still draws a
    /// visible sliver rather than a line too thin to see.
    static let minWidth: Double = 6
    static let maxWidth: Double = 46
    /// The pull that fills the bar: one axis-weighted personal SD. Anything
    /// beyond clamps rather than overflowing the row. UNCALIBRATED, chosen
    /// against `LiveThresholds.contributionFloor` (0.25) so a bullet that
    /// barely qualifies draws about a quarter of the length.
    static let fullScale: Float = 1.0
    /// The gap between the bar and the metric name in the WHY row's HStack.
    static let rowSpacing: Double = 7
    /// Where the metric name — and the explanation line beneath it — start:
    /// a fixed-width `maxWidth` column for the bar plus the HStack's own
    /// `rowSpacing`, so every row's name lines up at the same x regardless of
    /// that row's own (variable) bar length. The view pins the bar's
    /// CONTAINER at `maxWidth` and left-aligns the actual bar inside it,
    /// rather than sizing the HStack to the bar's drawn width.
    static let textIndent: Double = maxWidth + rowSpacing

    static func width(value: Float) -> Double {
        let fraction = min(Double(abs(value)) / Double(fullScale), 1)
        return minWidth + fraction * (maxWidth - minWidth)
    }
}

/// The card's own label, with whatever the reading is honestly unsure about
/// appended to it. Same shape as `DayPotentialStore.State.headline`, which
/// already appends "· EARLY DAYS" for a provisional score — reused here so
/// the words mean the same thing on both cards.
///
/// Every one of these three flags was computed and read by no view before
/// this: `LiveStateResult.isWeak`, `LiveBaseline.provisional`, and the held-
/// state case the spec's error table requires be marked stale.
enum LiveStateHeadline {
    static func text(isWeak: Bool, provisional: Bool, isStale: Bool) -> String {
        var parts = ["CURRENT STATE"]
        // Staleness leads: a held reading may well have been a strong call
        // when it was taken, so how old it is matters more than how firm.
        if isStale     { parts.append("NOT UPDATING") }
        if isWeak      { parts.append("WEAK SIGNAL") }
        if provisional { parts.append("EARLY DAYS") }
        return parts.joined(separator: " · ")
    }
}

/// One WHY row's rendered values, decided in one place so the choice of
/// *which quantity feeds which output* is a function call the view makes,
/// not an inline expression it could be quietly edited back to the wrong
/// shape.
///
/// The row deliberately describes TWO different quantities, one per output:
/// the bar's length (and the ranking that ordered the row) comes from
/// `contribution.value` — weight × `effective`, i.e. trend-adjusted, the
/// actual pull that earned the row its place in the list. The band text
/// comes from the metric's own `level` — its current position, trend
/// excluded. Those two can disagree in sign (a metric near its usual value
/// but moving fast can rank as a strong driver via `effective` while sitting
/// at `level` ≈ 0), and when they do, the text must follow `level`: the bar
/// says how much this metric moved the state, the text says where the
/// metric actually sits. A row can therefore rank high on trend while
/// reading "right around your usual" — that is honest and informative, not
/// a bug. Feeding `effective` to the band (the original wiring) instead
/// prints a direction word that can contradict the row's own ranking sign —
/// see `LiveWhyRowTests.testBandFollowsLevelEvenWhenEffectiveDisagreesInSign`.
struct LiveWhyRow: Equatable {
    let displayName: String
    let bandText: String
    let barWidth: Double
    let isStrong: Bool
    /// Which way a strong bar should read. Kept separate from a raw `Color`
    /// so this stays testable without importing SwiftUI — same shape as
    /// `LiveWhyBar.width`'s plain `Double`; the view converts at the call site.
    let tone: LiveWhyBarTone

    /// `reading` is looked up for `level` (and the native-unit pair that
    /// makes a percentage possible), never for ranking — ranking and bar
    /// length both come from `contribution.value`, which is already the
    /// classifier's own ranked-by-weighted-pull ordering.
    static func build(for contribution: StateContribution, reading: LiveReading) -> LiveWhyRow {
        let metricReading = reading.readings[contribution.metric]
        let bandText: String
        if let metricReading {
            bandText = LiveWhyBand.text(level: metricReading.level,
                                        windowValue: metricReading.windowValue,
                                        baselineCentre: metricReading.baselineCentre)
        } else {
            // No matching reading (see the doc on the fallback test) — no
            // native-unit pair to compute a percentage from either.
            bandText = LiveWhyBand.text(for: 0)
        }
        let isStrong = abs(contribution.value) > 0.6
        return LiveWhyRow(
            displayName: contribution.metric.displayName.uppercased(),
            bandText: bandText,
            barWidth: LiveWhyBar.width(value: contribution.value),
            isStrong: isStrong,
            tone: LiveWhyBarTone.of(value: contribution.value, isStrong: isStrong))
    }
}

/// Which way a WHY row's bar should read. `contribution.value`'s magnitude
/// (`isStrong`, see `LiveWhyRow.build`) fills the bar's length regardless of
/// sign — a downward driver and an upward driver of the same magnitude drew
/// identical bars, and a strong one always got `Theme.accent`, the same green
/// the app uses for its positive states (`engaged_performing`, `calm_alert`,
/// DayPotential's "good"/"full" band). A metric dragging the state DOWN
/// therefore rendered in the app's positive colour. The bar's colour now
/// carries the sign; its length still carries only magnitude.
enum LiveWhyBarTone: Equatable {
    /// Below the "strong" cut — nothing to call out either way.
    case weak
    /// A strong driver pushing the state UP.
    case positive
    /// A strong driver pushing the state DOWN — must never render in the
    /// app's positive-state green.
    case negative

    static func of(value: Float, isStrong: Bool) -> LiveWhyBarTone {
        guard isStrong else { return .weak }
        return value >= 0 ? .positive : .negative
    }
}

/// Bridges a classifier result to the icon/colour table `LiveState` already
/// owns. `LiveStateKey` (the classifier's nine keys) and `LiveState` (the
/// narration parser's nine keys, `LiveStateInsight.swift`) are the same
/// contract defined twice with matching raw strings — see `LiveStateKey`'s
/// doc — so bridging through `rawValue` reuses one icon/colour table instead
/// of maintaining a second one that could drift from it.
private extension LiveStateKey {
    var display: LiveState? { LiveState(rawValue: rawValue) }
}

/// Everything the collapsed row needs to render, decided in one pure place so
/// the view only draws what this returns. Unifies what used to be two
/// separate `collapsedRow` overloads (one for a settled local state, one for
/// the narration-only fallback) behind one decision: which of the three cases
/// — a local reading, a narration-only fallback, or nothing at all — applies,
/// and, critically, whether there's anything a drop-down could reveal.
///
/// `isExpandable` is what fixes the "dead chevron": the narration-only
/// fallback has no local `reading` to build a WHY list from, so it must never
/// present a control that toggles but reveals nothing. See
/// `LiveCollapsedRowSpecTests` for the pinned invariant.
struct LiveCollapsedRowSpec: Equatable {
    let title: String
    let feeling: String?
    let iconName: String
    let accent: Color
    let label: String
    /// Whether tapping the row can reveal a WHY list. False exactly when
    /// there is no local `reading` to build one from.
    let isExpandable: Bool

    /// Whether the drop-down should currently reveal its contents — the
    /// two-condition gate pulled out of the view body into a named, pure
    /// function, rather than left as an inline `spec.isExpandable &&
    /// expanded` the view alone evaluates. That inline form is exactly what
    /// shipped broken twice already behind a fully green suite (see the doc
    /// on `LiveCollapsedRowSpecTests` for the first instance): there was no
    /// way, without a SwiftUI view-hosting harness, to pin that the view
    /// kept ANDing both conditions rather than quietly dropping one. Naming
    /// the decision here closes that gap — a future edit that weakens the
    /// AND (e.g. to only `expanded`, or only `isExpandable`) now fails
    /// `testAllFourCombinationsMatchLogicalAnd` directly instead of only a
    /// screenshot review.
    static func revealsDropDown(isExpandable: Bool, expanded: Bool) -> Bool {
        isExpandable && expanded
    }

    static func build(state: LiveStateResult?, reading: LiveReading?, text: String?,
                      provisional: Bool, isStale: Bool) -> LiveCollapsedRowSpec? {
        if let state, reading != nil {
            return LiveCollapsedRowSpec(
                title:   LiveStateCopy.title(for: state.key),
                feeling: LiveStateCopy.feeling(for: state.key),
                iconName: state.key.display?.iconName ?? "waveform.path.ecg",
                accent:   state.key.display?.color ?? Theme.accent,
                label:   LiveStateHeadline.text(isWeak: state.isWeak, provisional: provisional, isStale: isStale),
                isExpandable: true)
        }
        if let text {
            // No local reading yet (very first session before enough data
            // has accumulated) but narration already arrived: fall back to
            // the insight's own header so the widget isn't blank. There is no
            // local WHY to reveal without a reading — `isExpandable: false`
            // is what keeps this row from presenting a chevron that can never
            // do anything.
            let insight = LiveStateInsight(raw: text)
            return LiveCollapsedRowSpec(
                title:   insight.title,
                feeling: nil,
                iconName: insight.state?.iconName ?? "waveform.path.ecg",
                accent:   insight.state?.color ?? Theme.accent,
                label:   "CURRENT STATE",
                isExpandable: false)
        }
        return nil
    }
}

/// What to say when there is neither a local reading nor narration text yet
/// — i.e. `LiveCollapsedRowSpec.build` returned nil. "Gathering data… pull
/// down to refresh" was shown for every such case, including the one where
/// pulling down cannot possibly help: the strap is off right now, so there is
/// no fresh window for a refresh to find regardless of how it's triggered.
/// This says which of the two real reasons applies instead.
enum LiveEmptyStateCopy {
    static func text(hasBaseline: Bool, isConnected: Bool) -> String {
        guard hasBaseline else {
            return "Building your baseline — check back in a few days."
        }
        return isConnected
            ? "Reading your first window…"
            : "No recent reading — connect your strap to see your current state."
    }
}

// MARK: - Felt-state check-in
//
// A second, independent drop-down below RIGHT NOW (accuracy design §5/§6):
// "How do you feel right now?", collapsing to four continuous drag scales
// and a save button. It drives nothing yet — it exists only to accumulate
// the ground truth a later calibration pass needs (`FeltStateLog`) — so every
// decision below is pure and pinned the same way `LiveWhyBand`/`LiveWhyRow`/
// `LiveStateHeadline`/`LiveCollapsedRowSpec` already are in this file.

/// The four felt-state scales, in the fixed order the design specifies:
/// focus and stress load on the classifier's Tension axis, energy on Energy.
/// Mood is the deliberate control — nothing in the physiology is expected to
/// predict it, so a later correlation there would be evidence of overfitting
/// rather than of insight.
enum FeltStateScaleKey: String, CaseIterable {
    case focus, energy, stress, mood

    var label: String {
        switch self {
        case .focus:  return "FOCUS"
        case .energy: return "ENERGY"
        case .stress: return "STRESS"
        case .mood:   return "MOOD"
        }
    }

    /// Anchor words at each end. Nothing else is ever shown alongside the
    /// control — no number — so where the knob sits is the entire answer.
    var leftAnchor: String {
        switch self {
        case .focus:  return "scattered"
        case .energy: return "drained"
        case .stress: return "calm"
        case .mood:   return "low"
        }
    }

    var rightAnchor: String {
        switch self {
        case .focus:  return "razor sharp"
        case .energy: return "buzzing"
        case .stress: return "overwhelmed"
        case .mood:   return "great"
        }
    }
}

/// The in-progress check-in: one optional 0–100 value per scale. `nil` IS the
/// touched flag the design calls for — a scale the user has never dragged has
/// no value here at all, rather than a value that happens to equal whatever
/// default the view might otherwise pick. `makeLog` carries that straight
/// through to `FeltStateLog` (see that type's own doc), so "untouched"
/// survives all the way to the saved row as `nil`, never as 50.
struct FeltStateDraft: Equatable {
    var focus:  Double?
    var energy: Double?
    var stress: Double?
    var mood:   Double?

    static let empty = FeltStateDraft()

    subscript(key: FeltStateScaleKey) -> Double? {
        get {
            switch key {
            case .focus:  return focus
            case .energy: return energy
            case .stress: return stress
            case .mood:   return mood
            }
        }
        set {
            switch key {
            case .focus:  focus = newValue
            case .energy: energy = newValue
            case .stress: stress = newValue
            case .mood:   mood = newValue
            }
        }
    }

    /// A fully-untouched draft has nothing worth persisting — the save
    /// button is a no-op against it rather than writing an all-blank row.
    var hasAnyAnswer: Bool {
        focus != nil || energy != nil || stress != nil || mood != nil
    }

    /// Builds the row to persist. Kept as one pure function rather than an
    /// inline `FeltStateLog(...)` call at the save button's call site, so the
    /// untouched-stays-nil mapping is a single tested place that can't be
    /// quietly edited back into writing a default.
    func makeLog(stateKey: LiveStateKey?, now: Date = .now) -> FeltStateLog {
        FeltStateLog(timestamp: now, focus: focus, energy: energy, stress: stress,
                    mood: mood, stateKey: stateKey?.rawValue)
    }
}

/// A scale's rendered knob position and fill, decided in one pure place so
/// "untouched is not the middle" — grey, centred knob, no fill — is a fact
/// about `nil` the view reads off, not a branch it has to remember to take
/// every time it draws a row.
struct FeltStateKnobSpec: Equatable {
    /// 0...1 fraction along the track where the knob's centre sits.
    let knobFraction: Double
    /// 0...1 fraction of the track that should render as filled. Zero for an
    /// untouched scale: filling any of the track for a value that was never
    /// answered would read as a real reading rather than as no reading.
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

/// Converts a drag gesture's raw position on the track into a stored 0–100
/// value. Pure and separate from the gesture handler itself so the clamping
/// at both ends — the one place a thumb dragged past either edge of the
/// track could otherwise write an out-of-range value — is tested without a
/// view host.
enum FeltStateDragMapping {
    static func value(x: Double, trackWidth: Double) -> Double {
        guard trackWidth > 0 else { return 0 }
        let fraction = min(max(x / trackWidth, 0), 1)
        return fraction * 100
    }
}

/// Fixed copy for the check-in's closed and confirmation rows — pulled out so
/// the words are one tested unit rather than literals repeated at each of
/// this section's call sites.
enum FeltStateCheckInCopy {
    static let question             = "How do you feel right now?"
    /// One short clause, not two joined by a dash — the row is a quiet
    /// invitation beneath Current State, not a second headline, and it must
    /// fit on one line at the default dynamic-type size on a standard phone
    /// width. Previously "A few seconds — helps your numbers mean
    /// something", which wrapped to two lines and put the whole section at
    /// three, outweighing the state row above it.
    static let helper               = "Helps your numbers mean something"
    static let skipHint             = "Skip any you like"
    static let confirmationTitle    = "Saved"
    static let confirmationSubtitle = "Checked in just now · tap to change"
}

/// Shared holder for the live-state insight so the widget's timed loop and the
/// Live tab's pull-to-refresh drive the same fetch and gating.
@MainActor
@Observable
final class LiveStateStore {
    var text: String?

    /// The locally-computed state: name, feeling and WHY all derive from
    /// this. Populated by `recomputeState`, independent of `text` and never
    /// gated by the narration's five-minute throttle — a handful of z-scores
    /// is cheap enough to redo on every poll.
    private(set) var state: LiveStateResult?
    /// Convenience so a view doesn't have to unwrap `state` just to read the
    /// key it settled on.
    var stateKey: LiveStateKey? { state?.key }
    private(set) var baseline: LiveBaseline?
    /// Kept alongside `state`, set together with it from the same recompute
    /// call — the WHY row looks up a contributing metric's own `effective`
    /// here for its band text, since `StateContribution.value` (weight ×
    /// effective) is the wrong quantity for that. See `LiveWhyBand`.
    private(set) var reading: LiveReading?

    /// The displayed state is being HELD rather than refreshed — the window
    /// stopped clearing `LiveThresholds.minCoverage`, or the strap
    /// disconnected and the poll loop stopped entirely. The spec's error
    /// table: "Too few points in window — hold the last state; mark it stale
    /// rather than blanking." Holding was already implemented; marking was
    /// not, so a state could sit on screen indefinitely presenting itself as
    /// current.
    ///
    /// False until there is something to hold: nothing on screen cannot be
    /// stale.
    private(set) var isStale = false

    private let hysteresis = LiveStateHysteresis()

    private var lastRefresh = Date.distantPast
    private var inFlight = false

    /// Never update the current state more often than this.
    private let minInterval: TimeInterval = 300   // 5 minutes

    /// Fetch a new insight from the current trend + absolute values. Automatic
    /// refreshes are capped to once every 5 minutes; `force` (a pull-to-refresh)
    /// updates immediately, and the first reading always populates an empty widget.
    func refresh(env: AppEnvironment, force: Bool = false) async {
        guard !inFlight else { return }

        // Pass today's points so each metric's dayMean is today's average, and
        // the 10-minute window (for the current value + trend) is the tail of it.
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let todayPoints = MetricsQualityFilter.filter(env.tickHistory.filter { $0.timestamp >= startOfDay })
        guard let trends = LiveStateTrendCompute.summarize(todayPoints) else { return }

        guard force || text == nil || Date().timeIntervalSince(lastRefresh) >= minInterval else { return }

        inFlight = true
        defer { inFlight = false }

        let payload = LiveStateInsightPayload(windowMinutes: 10, trends: trends)
        if let response = try? await env.sync.client.generateLiveStateInsight(payload) {
            text = response.text
            lastRefresh = Date()
        }
    }

    /// Reaches the two things the pure recompute below needs: the user's
    /// cached daily rollups (`AppEnvironment.trackCache`) and the live tick
    /// history already held in memory. Re-loads the cache from disk on every
    /// call rather than only once — if the user's very first cache-populating
    /// visit is to Track, in this same session, the state should not have to
    /// wait for a relaunch to notice. The file is small (see `TrackCache`'s
    /// own doc), so this is cheap enough for a 15-20 s poll.
    func recomputeState(env: AppEnvironment) {
        env.trackCache.load()
        let cutoff = Calendar.current.date(byAdding: .day, value: -AnchorBaseline.windowDays, to: Date())
            ?? .distantPast
        let rollups = env.trackCache.rollups(in: cutoff...Date())

        let windowCutoff = Date().addingTimeInterval(-Double(LiveThresholds.windowMinutes) * 60)
        let window = env.tickHistory.filter { $0.timestamp >= windowCutoff }

        recomputeState(rollups: rollups, window: window)
    }

    /// The pure half of the recompute path — baseline, then reading, then
    /// classification, then hysteresis — with no `AppEnvironment` dependency,
    /// so it can be driven directly in a test against hand-built rollups and
    /// a hand-built window.
    ///
    /// A silent no-op (whatever `state`/`baseline`/`reading` already held
    /// stays as it was) whenever there isn't yet enough data: Track has never
    /// been opened, or the window doesn't clear the coverage gate. That is
    /// the documented cold-start/offline fallback, not an error — the widget
    /// simply keeps showing the last thing it knew, the same way `text` does.
    func recomputeState(rollups: [DailyRollup], window: [MetricsHistoryPoint], now: Date = .now) {
        guard let baseline = LiveBaseline.build(rollups: rollups, now: now) else {
            markStale()
            return
        }
        self.baseline = baseline

        guard let reading = LiveReading.build(window: window, baseline: baseline, now: now) else {
            markStale()
            return
        }
        self.reading = reading
        isStale = false

        let classified = LiveStateClassifier.classify(reading)
        let settled = hysteresis.settle(classified.key)
        state = settled == classified.key ? classified
            : LiveStateResult(key: settled, axes: classified.axes,
                              contributions: classified.contributions, isWeak: classified.isWeak)
    }

    /// Whatever is on screen is no longer being refreshed. Called when the
    /// strap disconnects, which stops the poll loop outright — no recompute
    /// will ever run to notice on its own.
    ///
    /// A no-op when there is no state yet: an empty card (see
    /// `LiveEmptyStateCopy`) is not stale.
    func markStale() {
        if state != nil { isStale = true }
    }
}

/// Small, always-visible widget showing the on-device state (name, feeling,
/// ranked WHY, behind its own drop-down) plus an OpenAI-generated, purely
/// descriptive account of the nervous-system trend over the last 10 minutes.
///
/// The device-side half — collapsed row and ranked WHY — needs no network and
/// appears as soon as there is a baseline and a covered window (see
/// `LiveStateStore.recomputeState`). The narration half updates automatically
/// at most once every 5 minutes while visible and BLE-connected, or
/// immediately when the user pulls the Live tab to refresh (the first reading
/// appears as soon as there's enough data). Never shows a loading state on
/// refresh — the previous description stays until a new one replaces it.
///
/// Layout follows the approved design
/// (`docs/superpowers/specs/2026-08-02-current-state-accuracy-design.md` §5):
/// a collapsible Current State block (collapsed row always visible; WHY and
/// WHAT THIS MEANS are the only things behind the drop-down), then RIGHT NOW
/// as its own always-visible section that does not move when the drop-down
/// opens or closes. Collapsed, the card reads Current State → RIGHT NOW →
/// How do you feel; expanding only inserts WHY/WHAT THIS MEANS between the
/// first two.
struct LiveStateWidget: View {
    @Environment(AppEnvironment.self) var env
    let store: LiveStateStore
    let potentialStore: DayPotentialStore
    @State private var refreshTask: Task<Void, Never>?
    /// Named rather than an inline literal so `LiveStateWidgetKeyTests` can
    /// pin it: a silent rename here would reset every user's expanded/
    /// collapsed preference on next launch, with no test failure to say so.
    /// Mirrors `DayPotentialStrip`'s own `dayPotentialExpanded` — same
    /// pattern, a sibling key, so the two cards' drop-downs persist
    /// independently across relaunch.
    static let expansionStorageKey = "currentStateExpanded"
    @AppStorage(LiveStateWidget.expansionStorageKey) private var expanded = false

    /// Sibling of `expansionStorageKey` for the check-in's own drop-down — a
    /// distinct literal so the two independent sections (accuracy design §5)
    /// truly persist independently: toggling one must never be able to
    /// toggle the other, on this launch or the next. See
    /// `LiveStateWidgetKeyTests` for both keys pinned distinct.
    static let checkInStorageKey = "checkInExpanded"
    @AppStorage(LiveStateWidget.checkInStorageKey) private var checkInExpanded = false
    @State private var checkInDraft = FeltStateDraft.empty
    /// Set only for the lifetime of this view instance — a relaunch reopens
    /// the section as the plain question again rather than persisting the
    /// confirmation forever, which the design does not ask for.
    @State private var lastCheckIn: FeltStateLog?
    @Environment(\.modelContext) private var modelContext

    private var isConnected: Bool {
        if case .connected = env.ble.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Capacity first — the day frames the moment.
            DayPotentialStrip(store: potentialStore)
            Divider().overlay(Theme.dim.opacity(0.2))

            // Parsed once and threaded to both call sites below so WHAT THIS
            // MEANS (inside the drop-down) and RIGHT NOW (always visible)
            // never disagree about what the LLM actually said.
            let insight = store.text.map { LiveStateInsight(raw: $0) }

            // WHY and WHAT THIS MEANS both live behind the Current State
            // drop-down now — collapsing that row hides both explanations.
            // RIGHT NOW stays outside: the intended collapsed card is
            // Current State row → RIGHT NOW → How do you feel, and
            // expanding only inserts WHY/WHAT THIS MEANS between the first
            // two, never touches RIGHT NOW's own visibility.
            currentStateSection(insight: insight)

            // RIGHT NOW renders whenever the LLM produced a recommendation,
            // regardless of whether its bullets parsed — a reply with a
            // recommendation but no bullets must still show it.
            if let insight, let recommendation = insight.recommendation {
                recommendationBlock(recommendation, accent: insight.state?.color ?? Theme.accent)
            }

            // A sibling of every section above, not nested inside any of
            // them — it renders regardless of whether a local state or
            // narration exists yet, since the question "how do you feel"
            // owes nothing to either.
            Divider().overlay(Theme.dim.opacity(0.2))
            checkInSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .onAppear {
            // The local half (name, feeling, WHY) reads only stored rollups
            // and tick history already in memory — it owes nothing to BLE
            // being connected right now. `startLoop` below is what needs a
            // live connection (it also drives the network narration poll);
            // this recompute must not wait for it, or the card falsely
            // depends on the strap being on at the moment it first appears.
            store.recomputeState(env: env)
            if isConnected { startLoop() }
        }
        .onDisappear {
            stopLoop()
        }
        .onChange(of: env.ble.state) { _, newValue in
            if case .connected = newValue {
                startLoop()
            } else {
                // Stopping the loop means nothing will recompute, so whatever
                // is on screen stops being current the moment the strap goes.
                // Nothing else would ever notice.
                stopLoop()
                store.markStale()
            }
        }
    }

    // MARK: - Current State (collapsible)

    /// The collapsed row (tag, name, feeling, chevron) always renders once
    /// there is anything to show it for; WHY and WHAT THIS MEANS are the only
    /// things the drop-down reveals, and only when `LiveCollapsedRowSpec
    /// .revealsDropDown` says so — see that function's doc for why the gate
    /// is a named call here rather than an inline condition.
    @ViewBuilder
    private func currentStateSection(insight: LiveStateInsight?) -> some View {
        if let spec = LiveCollapsedRowSpec.build(state: store.state, reading: store.reading,
                                                 text: store.text,
                                                 provisional: store.baseline?.provisional ?? false,
                                                 isStale: store.isStale) {
            VStack(alignment: .leading, spacing: 14) {
                collapsedRow(spec)
                if LiveCollapsedRowSpec.revealsDropDown(isExpandable: spec.isExpandable, expanded: expanded) {
                    // WHY needs both a local reading to build it from AND
                    // the spec's own `isExpandable` — the insight-only
                    // fallback (`spec.isExpandable == false`) has no
                    // reading, so `revealsDropDown` is already false for it
                    // regardless of `expanded`, and this can never fire.
                    if let state = store.state, let reading = store.reading {
                        whyList(state, reading: reading)
                    }
                    // WHAT THIS MEANS used to be a body-level sibling of this
                    // whole section, so it stayed on screen even while this
                    // row was collapsed. Moved in here so the one chevron
                    // governs both explanations at once.
                    if let insight {
                        whatThisMeansSection(insight)
                    }
                }
            }
        } else {
            Text(LiveEmptyStateCopy.text(hasBaseline: store.baseline != nil, isConnected: isConnected))
                .font(Theme.monoBody)
                .foregroundStyle(Theme.dim)
        }
    }

    /// The whole row is the `Button`'s label — not just the chevron — same
    /// tap-target shape as `DayPotentialStrip.strip`. When `spec.isExpandable`
    /// is false (the insight-only fallback, which has no local `reading` to
    /// build a WHY list from) the row renders WITHOUT a `Button` or a chevron
    /// at all: a control that toggles but can never reveal anything is worse
    /// than no control, so it doesn't get one.
    ///
    /// Shares its affordance vocabulary with `DayPotentialStrip.strip` — a
    /// tinted fill, a rounded clip and a stroked border, both keyed off the
    /// row's own accent — so a tappable row reads as tappable everywhere on
    /// this card, not only on the strip above it.
    ///
    /// The chevron sits at the row's true trailing edge, vertically centred
    /// against the icon/text — matching `DayPotentialStrip.strip`, whose
    /// HStack uses the default centred alignment for exactly this reason. A
    /// `Spacer()` placed AFTER the chevron (a past attempt at "stranded",
    /// stop-gap fix) pushed it inboard instead, roughly wherever the text
    /// happened to end. The text block now claims the remaining width itself
    /// (`.frame(maxWidth: .infinity, alignment: .leading)`), so the chevron —
    /// the next and last child in the HStack — is pushed to the true
    /// trailing edge with no spacer needed at all.
    @ViewBuilder
    private func collapsedRow(_ spec: LiveCollapsedRowSpec) -> some View {
        let content = HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(spec.accent.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: spec.iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(spec.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(spec.label)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Text(spec.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                if let feeling = spec.feeling {
                    Text(feeling)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if spec.isExpandable {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(spec.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if spec.isExpandable {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(spec.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(spec.accent.opacity(0.22), lineWidth: 0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    // MARK: - Narration (WHAT THIS MEANS + RIGHT NOW)

    /// The LLM's own descriptive bullets, coloured by `insight.state` — the
    /// LLM's own read — even though the collapsed row above prefers the
    /// local state's colour when one exists. The two halves refresh on
    /// different clocks (`state` every 15-20 s, `text` at most every 5
    /// minutes), so this half must not end up wearing a colour that belongs
    /// to a state the device has since moved past — that would be exactly
    /// the "visibly disagreeing halves" a half-migrated card produces. Once a
    /// later plan makes narration state-bound (dropping stale text instead
    /// of recolouring it), this distinction goes away on its own; until then
    /// each half is coloured by its own source.
    ///
    /// Called from inside `currentStateSection`'s drop-down, alongside
    /// `whyList` — not a container the recommendation lives inside, and not a
    /// `body`-level sibling of it either: collapsing the Current State row
    /// must hide this along with WHY, which is exactly what being nested
    /// inside that same drop-down guarantees. Renders nothing when there are
    /// no bullets, at least one always shows when it renders anything at all.
    @ViewBuilder
    private func whatThisMeansSection(_ insight: LiveStateInsight) -> some View {
        if !insight.bullets.isEmpty {
            let accent = insight.state?.color ?? Theme.accent
            VStack(alignment: .leading, spacing: 8) {
                Text("WHAT THIS MEANS")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                ForEach(Array(insight.bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(accent.opacity(0.7))
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(styledBullet(bullet))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Renders `**bold**` markdown in a bullet and brightens the bold spans to
    /// the primary text color so the key idea stands out against the dim body.
    private func styledBullet(_ s: String) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        for run in attr.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            attr[run.range].foregroundColor = Theme.text
        }
        return attr
    }

    @ViewBuilder
    private func recommendationBlock(_ text: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("RIGHT NOW")
                    .font(Theme.monoLabel)
                    .foregroundStyle(accent)
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
    }

    /// The ranked drivers, straight from the classifier. Each row's values
    /// come from `LiveWhyRow.build` — the view only lays out what it's
    /// handed, so which number feeds the bar and which feeds the band
    /// sentence is decided in one tested place, not here.
    @ViewBuilder
    private func whyList(_ state: LiveStateResult, reading: LiveReading) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHY")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
            ForEach(state.contributions, id: \.metric) { c in
                let row = LiveWhyRow.build(for: c, reading: reading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: CGFloat(LiveWhyBar.rowSpacing)) {
                        // Fixed-width column so every row's bar occupies the
                        // same horizontal space regardless of its own drawn
                        // length — the name after it therefore starts at the
                        // same x on every row, in line with the explanation
                        // below (`textIndent` is this same column width).
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor(for: row.tone))
                            .frame(width: CGFloat(row.barWidth), height: 3)
                            .frame(width: CGFloat(LiveWhyBar.maxWidth), alignment: .leading)
                        Text(row.displayName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text)
                    }
                    Text(row.bandText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                        .padding(.leading, CGFloat(LiveWhyBar.textIndent))
                }
            }
        }
    }

    /// Maps `LiveWhyRow`'s pure `LiveWhyBarTone` to an actual colour — the
    /// one place a WHY bar's colour is chosen, so a downward driver can never
    /// end up on `Theme.accent` (the app's positive-state green) again.
    private func barColor(for tone: LiveWhyBarTone) -> Color {
        switch tone {
        case .weak:     return Theme.breathe
        case .positive: return Theme.accent
        case .negative: return Theme.warn
        }
    }

    // MARK: - Felt-state check-in

    /// Three phases: the closed question, the open form, and — after saving
    /// — a confirmation that itself replaces the other two until tapped.
    @ViewBuilder
    private var checkInSection: some View {
        if let saved = lastCheckIn {
            checkInConfirmationRow(saved)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                checkInCollapsedRow
                if checkInExpanded {
                    checkInForm
                }
            }
        }
    }

    /// Same tap affordance as `collapsedRow` above and `DayPotentialStrip
    /// .strip` — tinted fill, rounded clip, stroked border, whole row
    /// tappable — so this reads as a control the same way theirs do.
    ///
    /// Deliberately quiet: the question sits at a fraction of the state
    /// row's 20pt title, and the helper line is capped to one line rather
    /// than left to wrap — a check-in invitation should never visually
    /// outweigh the state it's asking about.
    private var checkInCollapsedRow: some View {
        Button {
            withAnimation(.snappy) { checkInExpanded.toggle() }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(FeltStateCheckInCopy.question)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(FeltStateCheckInCopy.helper)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: checkInExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.accent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The four scales, each a continuous drag control (see
    /// `FeltStateScaleRow`), then one full-width save button. "Skip any you
    /// like" sits under the button, not beside it, so it reads as
    /// permission rather than as a label on the control itself.
    private var checkInForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(FeltStateScaleKey.allCases, id: \.self) { key in
                FeltStateScaleRow(key: key, value: Binding(
                    get: { checkInDraft[key] },
                    set: { checkInDraft[key] = $0 }))
            }
            VStack(spacing: 6) {
                Button(action: saveCheckIn) {
                    Text("SAVE")
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.bg)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!checkInDraft.hasAnyAnswer)
                .opacity(checkInDraft.hasAnyAnswer ? 1 : 0.5)
                Text(FeltStateCheckInCopy.skipHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    /// A green tick and a fixed confirmation line, tappable to reopen the
    /// form for a fresh answer — "nothing to dismiss" per the design; this
    /// row IS the only control left on screen once saved.
    private func checkInConfirmationRow(_ saved: FeltStateLog) -> some View {
        Button {
            withAnimation(.snappy) {
                lastCheckIn = nil
                checkInExpanded = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FeltStateCheckInCopy.confirmationTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(FeltStateCheckInCopy.confirmationSubtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.accent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Writes a `FeltStateLog` via `FeltStateDraft.makeLog`, stamping it with
    /// whatever state key is on screen right now — the field that turns this
    /// row into a labelled example rather than a mood-diary entry (see
    /// `FeltStateLog`'s own doc). A no-op against a fully-untouched draft:
    /// there is nothing worth a blank row for.
    private func saveCheckIn() {
        guard checkInDraft.hasAnyAnswer else { return }
        let log = checkInDraft.makeLog(stateKey: store.stateKey)
        modelContext.insert(log)
        try? modelContext.save()
        checkInDraft = .empty
        withAnimation(.snappy) {
            checkInExpanded = false
            lastCheckIn = log
        }
    }

    // MARK: - Refresh loop

    private func startLoop() {
        guard refreshTask == nil else { return }
        // Recompute right away rather than waiting for the loop's first
        // sleep — it owes nothing to a network round trip, unlike `text`.
        store.recomputeState(env: env)
        refreshTask = Task {
            while !Task.isCancelled {
                // Poll on a short tick; the store decides whether to actually
                // fetch. Faster ticks until the first description lands.
                try? await Task.sleep(for: .seconds(store.text == nil ? 15 : 20))
                guard !Task.isCancelled else { break }
                store.recomputeState(env: env)
                await store.refresh(env: env)
                // Anchor detection keeps polling until a rested window
                // appears; once frozen the store's guards make this cheap.
                await potentialStore.refresh(env: env)
            }
        }
    }

    private func stopLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

/// One scale's drag control: a knob on a track, anchor words at each end, no
/// number ever shown — where the knob sits is the entire answer. Sized for a
/// thumb (28pt knob on a 30pt row) since this is a phone control used
/// one-handed. The geometry itself — where the knob and fill sit for a given
/// value, and what value a given drag position maps to — is decided by
/// `FeltStateKnobSpec`/`FeltStateDragMapping`, both pure and tested without a
/// view host; this struct only draws what they return.
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
                    // minimumDistance 0 so a plain tap on the track also
                    // places the knob, not only a drag — the whole track is
                    // the target, not just the 28pt circle.
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            value = FeltStateDragMapping.value(x: g.location.x - knobSize / 2,
                                                               trackWidth: trackWidth)
                        }
                )
            }
            .frame(height: rowHeight)
            HStack {
                Text(key.leftAnchor)
                Spacer()
                Text(key.rightAnchor)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
        }
    }
}
