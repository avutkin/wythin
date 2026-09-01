import SwiftUI

/// One metric's presentation + data-access definition. Shared by the tile
/// grid and the stacked charts so the two views cannot drift.
struct ActivityMetricDef: Identifiable {
    var id: String { label }
    let label:     String
    /// The measurement this name belongs to. Every surface showing a
    /// metric — the Live tiles and charts, the Activities grid and charts,
    /// the Track charts — resolves its title through `metricDef(_:)`
    /// instead of typing one, which is what stops the same measure being
    /// called two things on two screens.
    let metric:    LiveMetric
    /// Short tag for compact tiles.
    let techLabel: String
    /// Spelled-out measure with its abbreviation, e.g. "Respiratory Sinus
    /// Arrhythmia (RSA)". Shown wherever there is room — the Track trend cards
    /// and the session detail charts — so an abbreviation is never the only
    /// thing naming a metric. Falls back to `techLabel` when empty.
    var techFull:  String = ""
    let unit:      String
    let direction: BenefitDirection
    let extract:   (MetricsHistoryPoint) -> Double?
    let format:    (Double?) -> String
    // Stored ActivityLog fields for this metric, used to compute the
    // 2-month per-activity-type average uplift from past sessions.
    let beforeKey: KeyPath<ActivityLog, Float?>
    let duringKey: KeyPath<ActivityLog, Float?>
    /// One-to-two sentences: why improving this metric matters and the state
    /// to expect. Shown under the metric's chart in the detail view.
    let why:       String
    /// How much continuous clean signal this metric needs before it can be
    /// computed at all, in words. Non-nil only for the metrics with a warm-up
    /// long enough to go missing in a five-minute pre-session window — which is
    /// the usual reason a tile has a value but no percentage.
    var warmUp:    String? = nil
}

extension ActivityMetricDef {
    /// Benefit-signed % change of `current` vs `base` (positive = better),
    /// e.g. this session's during-average vs the 2-month baseline.
    ///
    /// Clamped to ±100%. A `.target`-direction metric (e.g. Harmony/DFA α1,
    /// target 1.0) has a benefit of `-|x - target|`, which is ill-conditioned
    /// near the target — a healthy, near-target base makes `bb` tiny, so a
    /// modest absolute move in `current` can blow up to an enormous percent.
    /// Without the clamp that one outlier metric would swamp the mean this
    /// feeds (impactDeltaPct), which is why it's clamped here rather than at
    /// each call site: every consumer of benefitDelta gets the same bound.
    func benefitDelta(current: Double?, base: Double?) -> Double? {
        rawBenefitDelta(current: current, base: base)
            .map { min(max($0, -Self.deltaBound), Self.deltaBound) }
    }

    /// The bound `benefitDelta` clamps to.
    ///
    /// It exists for the MEAN — `impactDeltaPct` averages all nine metrics, and
    /// one ill-conditioned `.target` metric could otherwise decide the whole
    /// number. The Activities card does NOT use it: a session's per-metric
    /// change is printed raw, because a clamped "+100%" is a marker and the
    /// reader has no way to tell it from a measurement. Track's period-over-
    /// period delta is the one display that keeps it, and for the `.target`
    /// reason rather than the mean one — see `TrackSeriesBuilder`.
    static let deltaBound: Double = 100

    /// The same change, unclamped. Only for deciding whether a value was
    /// clamped: near a `.target` metric's target this is ill-conditioned and can
    /// be enormous, which is exactly why the clamped form is what gets averaged.
    func rawBenefitDelta(current: Double?, base: Double?) -> Double? {
        guard let c = current, let b = base else { return nil }
        let bb = direction.benefit(b)
        guard bb != 0 else { return nil }
        return (direction.benefit(c) - bb) / abs(bb) * 100
    }

    /// Whether this change is off the end of the scale rather than on it.
    func isClamped(current: Double?, base: Double?) -> Bool {
        guard let raw = rawBenefitDelta(current: current, base: base) else { return false }
        return abs(raw) > Self.deltaBound
    }

    /// Position of `value` on a 0…1 benefit axis spanning `others` (higher =
    /// better = right). Returns nil when the span collapses or data is missing.
    func benefitPosition(of value: Double?, across others: [Double?]) -> Double? {
        guard let v = value else { return nil }
        let benefits = ([value] + others).compactMap { $0.map(direction.benefit) }
        guard let lo = benefits.min(), let hi = benefits.max(), hi > lo else { return nil }
        let frac = (direction.benefit(v) - lo) / (hi - lo)
        return 0.08 + frac * 0.84   // inset so end dots stay off the edges
    }
}

private func f0(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
private func f2(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
private func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
private func fFloat(_ v: Double?, _ fmt: (Float?) -> String) -> String { fmt(v.map { Float($0) }) }

/// The app's single naming registry: every metric with a consumer name, in
/// `LiveMetric` declaration order — the order the Live tiles, the Live charts,
/// the Activities grid and the Track charts all follow.
///
/// `ln RMSSD` is deliberately absent. It is `log(RMSSD)` — the same
/// measurement on another scale — so a tile of its own both counted RMSSD
/// twice in the impact mean and forced a second consumer name, which is how
/// "Calm Power" came to mean RMSSD on Live and ln RMSSD here. The quantity is
/// still computed and still drives the live-state recovery axis; it just no
/// longer claims a name.
let activityMetricDefs: [ActivityMetricDef] = [
    .init(label: "Vagal Tone",          metric: .dc,            techLabel: "DC",     techFull: "Deceleration Capacity (DC)", unit: "ms",  direction: .higher,      extract: { $0.dc.map(Double.init) },      format: f1,                                 beforeKey: \.beforeDC,    duringKey: \.duringDC,
          why: "Vagal Tone (Deceleration Capacity) is your relaxation and recovery capacity — your vagal “brake”, how readily the heart slows. Higher means deeper parasympathetic recovery; expect it to climb as you settle.",
          warmUp: "about 2½ minutes"),
    .init(label: "Adaptive Capacity",   metric: .rcmse,         techLabel: "RCMSE",  techFull: "Multiscale Sample Entropy (RCMSE)", unit: "",    direction: .higher,      extract: { $0.rcmse.map(Double.init) },   format: f2,                                 beforeKey: \.beforeRCMSE, duringKey: \.duringRCMSE,
          why: "Adaptive Capacity (Refined Composite Multiscale Entropy) reflects how flexible your system is across timescales. Higher signals a resilient, responsive heart; expect a modest rise with calm focus.",
          warmUp: "about 1½ minutes"),
    .init(label: "Inner Noise",         metric: .pip,           techLabel: "PIP",    techFull: "Percentage of Inflection Points (PIP)", unit: "%",   direction: .lower,       extract: { $0.pip.map(Double.init) },     format: f1,                                 beforeKey: \.beforePIP,   duringKey: \.duringPIP,
          why: "Inner Noise (Percentage of Inflection Points) captures beat-to-beat jitter — erratic, non-restorative variability. Lower means a cleaner, calmer signal; expect it to fall as you relax.",
          warmUp: "about 30 seconds"),
    .init(label: "Harmony",             metric: .dfa1,          techLabel: "DFA α1", techFull: "Detrended Fluctuation Analysis (DFA α1)", unit: "",    direction: .target(1.0), extract: { $0.dfa1.map(Double.init) },    format: f2,                                 beforeKey: \.beforeDFA1,  duringKey: \.duringDFA1,
          why: "Harmony (DFA α1) is the fractal balance of your heartbeat, with ~1.0 the healthy sweet spot. Moving toward 1.0 signals well-organised regulation; expect it to approach 1.0 as you relax."),
    .init(label: "Stress Balance",      metric: .stressBalance, techLabel: "SNS",    techFull: "100·(1 − RMSSD index) (SNS %)", unit: "%",   direction: .lower,       extract: { pt in
              AutonomicCompute.balance(rmssd: pt.rmssd, lf: pt.lfPower, hf: pt.hfPower,
                                       breathBPM: pt.breathBPM, meanBPM: pt.meanBPM,
                                       baselineRmssd: nil).map { Double($0.sns) * 100 }
          }, format: f0,                                 beforeKey: \.beforeStress, duringKey: \.duringStress,
          why: "Stress Balance is a breathing-robust 0–100 dial of how revved-up vs calm you are — the same one the Live view shows. It is built from RMSSD against your baseline, so paced breaths correctly read as calmer. Lower means you’re shifting into rest-and-digest; expect it to drop through the session."),
    .init(label: "Breath Rate",         metric: .breathBPM,     techLabel: "BR",     techFull: "Breaths per minute (br/min)", unit: "br/min", direction: .lower, extract: { $0.breathBPM.map(Double.init) }, format: f1,          beforeKey: \.beforeBreath, duringKey: \.duringBreath,
          why: "Breath Rate is how fast you are breathing — the one measure on this screen you can change on purpose, right now. Slower gives the vagal brake more of each out-breath to work with; expect it to fall toward about 6 br/min as a paced practice lands."),
    .init(label: "Conscious Breathing", metric: .rsa,           techLabel: "RSA",    techFull: "Respiratory Sinus Arrhythmia (RSA)", unit: "ms",  direction: .higher,      extract: { $0.rsaMs.map(Double.init) },   format: { fFloat($0, MetricFormat.ms) },    beforeKey: \.beforeRSA,   duringKey: \.duringRSA,
          why: "Conscious Breathing (Respiratory Sinus Arrhythmia) is the swing of heart rate with each breath — the clearest sign of vagal tone. Higher means slow, deep breathing is landing; expect it to rise with paced diaphragmatic breaths."),
    .init(label: "Calm Power",          metric: .rmssd,         techLabel: "RMSSD",  techFull: "Root Mean Square of Successive Differences (RMSSD)", unit: "ms",  direction: .higher,      extract: { $0.rmssd.map(Double.init) },   format: { fFloat($0, MetricFormat.ms) },    beforeKey: \.beforeRMSSD, duringKey: \.duringRMSSD,
          why: "Calm Power (RMSSD) is your core beat-to-beat variability — the headline marker of recovery and vagal tone. Higher signals a rested, adaptable system; expect it to rise during restful practice."),
    .init(label: "Pulse",               metric: .hr,            techLabel: "HR",     techFull: "Heart Rate (HR)", unit: "bpm", direction: .lower,       extract: { $0.meanBPM.map(Double.init) }, format: { fFloat($0, MetricFormat.bpm) },   beforeKey: \.beforeHR,    duringKey: \.duringHR,
          why: "Pulse (Heart Rate) reflects the overall load on your heart. A lower rate during practice means you’re offloading stress and settling; expect it to fall as you relax."),
]

/// Overall Variability, deliberately *outside* the registry above.
///
/// SDNN is a named, charted metric — the Track day-level trend and the Live
/// history chart both draw it — but it is not an Activities-grid metric: the
/// grid keeps its nine slots, and a session's before/during uplift is not the
/// reading SDNN is for. It still lives here, beside the registry, so its
/// consumer name and unit are typed once and Track and Live cannot drift.
let sdnnMetricDef = ActivityMetricDef(
    label: "Overall Variability", metric: .sdnn, techLabel: "SDNN",
    techFull: "Standard Deviation of NN intervals (SDNN)", unit: "ms",
    direction: .higher,
    extract: { $0.sdnn.map(Double.init) },
    format: f1,
    beforeKey: \.beforeSDNN, duringKey: \.duringSDNN,
    why: "Overall Variability (SDNN) is the total spread of your beat-to-beat intervals — every rhythm, fast and slow, folded into one number.")

/// The name and presentation for one measurement. Every screen resolves its
/// title through this instead of typing one, so a metric cannot end up
/// called two different things on two screens.
func metricDef(_ metric: LiveMetric) -> ActivityMetricDef {
    guard let d = activityMetricDefs.first(where: { $0.metric == metric }) else {
        preconditionFailure("no ActivityMetricDef names \(metric.rawValue)")
    }
    return d
}

/// Grid of the named metrics. Each tile shows the peak-during value with a
/// large benefit-signed peak-uplift % and a small avg-during %. Used inside
/// ActivityDetailView, which renders its own header separately.
struct ActivityMetricsGrid: View {
    let metrics: [(def: ActivityMetricDef, stats: ActivityMetricStats)]
    /// Metric id → average absolute "during" value across other sessions of
    /// the same activity type over the past 2 months (the baseline).
    let history: [String: Double]
    /// Metric id → average uplift % (during vs before) over the past 2 months.
    let historyUplift: [String: Double]

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(metrics, id: \.def.id) { m in
                let base = history[m.def.id]
                MetricTile(
                    label:            m.def.label,
                    techLabel:        m.def.techLabel,
                    value:            m.def.format(m.stats.duringMean),
                    unit:             m.def.unit,
                    avgUpliftPct:     m.stats.avgUpliftPct.map { Float($0) },
                    historyValue:     base.map { m.def.format($0) },
                    historyDeltaPct:  historyDelta(m.def, current: m.stats.duringMean, base: base),
                    historyUpliftPct: historyUplift[m.def.id].map { Float($0) }
                )
            }
        }
        .cardStyle()
    }

    /// Benefit-signed % of this session's during-average vs the 2-month
    /// baseline (green = better, matching the tiles).
    private func historyDelta(_ def: ActivityMetricDef, current: Double?, base: Double?) -> Float? {
        guard let c = current, let b = base else { return nil }
        let bb = def.direction.benefit(b)
        guard bb != 0 else { return nil }
        return Float((def.direction.benefit(c) - bb) / abs(bb) * 100)
    }
}
