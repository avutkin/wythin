import SwiftUI

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
        return LiveWhyRow(
            displayName: contribution.metric.displayName.uppercased(),
            bandText: bandText,
            barWidth: LiveWhyBar.width(value: contribution.value),
            isStrong: abs(contribution.value) > 0.6)
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
    /// A no-op when there is no state yet: "Gathering data…" is not stale.
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
/// a collapsible Current State block (collapsed row always visible; WHY the
/// only thing behind the drop-down), then RIGHT NOW as its own always-visible
/// section that does not move when the drop-down opens or closes.
struct LiveStateWidget: View {
    @Environment(AppEnvironment.self) var env
    let store: LiveStateStore
    let potentialStore: DayPotentialStore
    @State private var refreshTask: Task<Void, Never>?
    /// Mirrors `DayPotentialStrip`'s own `dayPotentialExpanded` — same
    /// pattern, a sibling key, so the two cards' drop-downs persist
    /// independently across relaunch.
    @AppStorage("currentStateExpanded") private var expanded = false

    private var isConnected: Bool {
        if case .connected = env.ble.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Capacity first — the day frames the moment.
            DayPotentialStrip(store: potentialStore)
            Divider().overlay(Theme.dim.opacity(0.2))

            currentStateSection

            // RIGHT NOW (and the LLM's own bullets) is a sibling of the
            // collapsible block above, not nested inside it — expanding or
            // collapsing the Current State drop-down only changes the WHY
            // list's own visibility and never this section's.
            if let text = store.text {
                narrationSection(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .onAppear {
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
    /// there is anything to show it for; the WHY list beneath it is the only
    /// thing the drop-down reveals, and only when there's a local reading to
    /// build it from.
    @ViewBuilder
    private var currentStateSection: some View {
        if let spec = LiveCollapsedRowSpec.build(state: store.state, reading: store.reading,
                                                 text: store.text,
                                                 provisional: store.baseline?.provisional ?? false,
                                                 isStale: store.isStale) {
            VStack(alignment: .leading, spacing: 14) {
                collapsedRow(spec)
                // WHY is the ONLY thing the drop-down reveals, and only when
                // there's both a local reading to build it from AND the spec
                // says this row is actually expandable — the insight-only
                // fallback (`spec.isExpandable == false`) has no reading, so
                // this can never be true for it regardless of `expanded`.
                if spec.isExpandable, expanded, let state = store.state, let reading = store.reading {
                    whyList(state, reading: reading)
                }
            }
        } else {
            Text("Gathering data… pull down to refresh")
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
    /// this card, not only on the strip above it. The chevron sits right
    /// after the text instead of stranded at the far trailing edge (a large
    /// `Spacer` before it, not after, is what caused that): a small
    /// `Spacer(minLength: 0)` after the chevron still lets the tinted
    /// background stretch to the card's full width.
    @ViewBuilder
    private func collapsedRow(_ spec: LiveCollapsedRowSpec) -> some View {
        let content = HStack(alignment: .top, spacing: 12) {
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
            if spec.isExpandable {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(spec.accent)
                    .padding(.top, 5)
                Spacer(minLength: 0)
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

    /// Everything the LLM writes: its own descriptive bullets, then the
    /// RIGHT NOW recommendation. Both stay coloured by `insight.state` — the
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
    /// A sibling of `currentStateSection`, not nested inside it — this is
    /// what keeps RIGHT NOW from moving when the Current State drop-down
    /// opens or closes.
    @ViewBuilder
    private func narrationSection(_ text: String) -> some View {
        let insight = LiveStateInsight(raw: text)
        let accent  = insight.state?.color ?? Theme.accent
        VStack(alignment: .leading, spacing: 14) {
            if !insight.bullets.isEmpty {
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
            }

            if let recommendation = insight.recommendation {
                recommendationBlock(recommendation, accent: accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(row.isStrong ? Theme.accent : Theme.breathe)
                            .frame(width: CGFloat(row.barWidth), height: 3)
                        Text(row.displayName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text)
                    }
                    Text(row.bandText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                        .padding(.leading, 53)
                }
            }
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
