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
}

/// The WHY row's bar length: `value`'s magnitude as a fraction of the
/// strongest contribution in the (already ranked) list, so the ordering is
/// visible at a glance and not just readable from top-to-bottom position.
///
/// Returns plain `Double` rather than `CGFloat` so this stays testable
/// without importing SwiftUI/CoreGraphics; the view converts at the call
/// site.
enum LiveWhyBar {
    /// Floor so even the weakest surviving contribution still draws a
    /// visible sliver rather than a line too thin to see.
    static let minWidth: Double = 6
    static let maxWidth: Double = 46

    static func width(value: Float, strongest: Float) -> Double {
        let fraction = Double(abs(value)) / Double(max(strongest, 0.01))
        return max(minWidth, fraction * maxWidth)
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
        guard let baseline = LiveBaseline.build(rollups: rollups, now: now) else { return }
        self.baseline = baseline

        guard let reading = LiveReading.build(window: window, baseline: baseline, now: now) else { return }
        self.reading = reading

        let classified = LiveStateClassifier.classify(reading)
        let settled = hysteresis.settle(classified.key)
        state = settled == classified.key ? classified
            : LiveStateResult(key: settled, axes: classified.axes,
                              contributions: classified.contributions, isWeak: classified.isWeak)
    }
}

/// Small, always-visible widget showing the on-device state (name, feeling,
/// ranked WHY) plus an OpenAI-generated, purely descriptive account of the
/// nervous-system trend over the last 10 minutes.
///
/// The device-side half — header and, absent narration, the WHY list — needs
/// no network and appears as soon as there is a baseline and a covered
/// window: see `LiveStateStore.recomputeState`. The narration half updates
/// automatically at most once every 5 minutes while visible and
/// BLE-connected, or immediately when the user pulls the Live tab to refresh
/// (the first reading appears as soon as there's enough data). Never shows a
/// loading state on refresh — the previous description stays until a new one
/// replaces it.
struct LiveStateWidget: View {
    @Environment(AppEnvironment.self) var env
    let store: LiveStateStore
    let potentialStore: DayPotentialStore
    @State private var refreshTask: Task<Void, Never>?

    private var isConnected: Bool {
        if case .connected = env.ble.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Capacity first — the day frames the moment.
            DayPotentialStrip(store: potentialStore)
            Divider().overlay(Theme.dim.opacity(0.2))
            if let text = store.text {
                structured(text)
            } else if let state = store.state, let reading = store.reading {
                // No narration yet (or the network is down) but the device
                // already knows enough — never falls back to "Gathering
                // data…" once a local state exists.
                VStack(alignment: .leading, spacing: 14) {
                    header(for: state.key)
                    whyList(state, reading: reading)
                }
            } else {
                Text("Gathering data… pull down to refresh")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.dim)
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
                stopLoop()
            }
        }
    }

    // MARK: - Rendering

    /// Renders the parsed insight: a colored state-icon badge + personalized
    /// title, the trend bullets, and a distinct, state-tinted "right now"
    /// recommendation block.
    @ViewBuilder
    private func structured(_ text: String) -> some View {
        let insight = LiveStateInsight(raw: text)
        let accent  = (store.stateKey?.display ?? insight.state)?.color ?? Theme.accent
        VStack(alignment: .leading, spacing: 14) {
            if let key = store.stateKey {
                header(for: key)
            } else {
                header(title: insight.title, feeling: nil,
                      iconName: insight.state?.iconName ?? "waveform.path.ecg", accent: accent)
            }

            if !insight.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
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

    /// The on-device header for a settled state key: title and feeling both
    /// from `LiveStateCopy`, icon/colour bridged from `LiveState` via
    /// `LiveStateKey.display`.
    @ViewBuilder
    private func header(for key: LiveStateKey) -> some View {
        header(title: LiveStateCopy.title(for: key),
              feeling: LiveStateCopy.feeling(for: key),
              iconName: key.display?.iconName ?? "waveform.path.ecg",
              accent: key.display?.color ?? Theme.accent)
    }

    /// Plain-value header, deliberately decoupled from `LiveStateInsight` —
    /// the local-only path (no narration text yet) has no server reply to
    /// parse one out of, and constructing `LiveStateInsight(raw: "")` purely
    /// to satisfy a parameter type would hand it a nil `state` and an empty
    /// `title`, which is what fed the fallback icon/title below anyway.
    /// Simpler to just pass the values every call site already has.
    @ViewBuilder
    private func header(title: String, feeling: String?, iconName: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(accent.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("CURRENT STATE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                if let feeling {
                    Text(feeling)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
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

    /// The ranked drivers, straight from the classifier. Bar length is the
    /// metric's actual pull on the state (`LiveWhyBar`, keyed on
    /// `StateContribution.value`); the band sentence underneath describes the
    /// metric's own reading (`LiveWhyBand`, keyed on `reading`'s `effective`
    /// for that metric) — see the doc on `LiveStateStore.reading` for why
    /// those are two different numbers.
    @ViewBuilder
    private func whyList(_ state: LiveStateResult, reading: LiveReading) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHY")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
            let strongest = state.contributions.first.map { abs($0.value) } ?? 1
            ForEach(state.contributions, id: \.metric) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(abs(c.value) > 0.6 ? Theme.accent : Theme.breathe)
                            .frame(width: CGFloat(LiveWhyBar.width(value: c.value, strongest: strongest)),
                                   height: 3)
                        Text(c.metric.displayName.uppercased())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text)
                    }
                    Text(LiveWhyBand.text(for: reading.readings[c.metric]?.effective ?? 0))
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
