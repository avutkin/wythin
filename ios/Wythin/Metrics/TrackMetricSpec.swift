import SwiftUI

/// One metric as the Track charts need it: the shared `ActivityMetricDef`
/// (label, tech label, unit, benefit direction, formatter, "why" copy) plus
/// the chart-only concerns Track adds.
///
/// It wraps rather than extends `ActivityMetricDef` because that type is
/// consumed by the Activities grid and charts; adding chart-presentation
/// fields to it would leak Track's concerns into a shared model.
struct TrackMetricSpec: Identifiable {
    let def:    ActivityMetricDef
    let rollup: (DailyRollup) -> Double?
    let color:  Color
    /// Whether the y-axis starts at zero. False for index metrics whose values
    /// hover in a narrow band — a zero-based chart of numbers near 1.0 is a
    /// wall of identical bars.
    let zeroBased: Bool
    /// Reference used until there are `TrackSeriesBuilder.minBaselineDays`
    /// of the user's own data.
    let fallbackReference: Double
    /// Key used in the macro-read payload; must match the server's
    /// `_METRIC_NAMES` in `server/routers/insights.py`.
    let trendKey: String
    /// One-to-two sentences for the Track card footer: what the metric is,
    /// plus what a multi-day trend in it means. `def.why` is written for the
    /// Activities session-detail view ("expect it to climb as you settle")
    /// and is wrong here, where the chart is a week/month/6-month series of
    /// daily averages rather than a single in-progress session.
    let trendWhy: String

    var id: String { def.label }
}

enum TrackMetrics {

    /// The 7 charted metrics, in the same order `LiveMetric` declares its
    /// cases — the app's canonical display order, which the Live history
    /// charts and Live metric tiles follow too, so Track and Live agree on
    /// which metric reads as "first" instead of each screen inventing its own
    /// ordering. Pulse (`.hr`) and Calm Power (`.vti`) are deliberately
    /// excluded, along with every other `LiveMetric` case Track has no chart
    /// for (`.sdnn`, `.coherence`, `.breathBPM`, `.cbi`); the 7 that remain
    /// keep `LiveMetric`'s relative order.
    static let all: [TrackMetricSpec] = [
        .init(def: def("Vagal Tone"),          rollup: { $0.dc },
              color: Theme.accent,  zeroBased: true,  fallbackReference: 6.0,  trendKey: "dc",
              trendWhy: "Vagal Tone (Deceleration Capacity) is your relaxation and recovery capacity — your vagal “brake”, how readily the heart slows. A rising trend across days points to your nervous system recovering more easily; a flat or falling one is worth a lighter week."),
        .init(def: def("Adaptive Capacity"),   rollup: { $0.rcmse },
              color: Theme.ulf,     zeroBased: false, fallbackReference: 1.4,  trendKey: "rcmse",
              trendWhy: "Adaptive Capacity (Refined Composite Multiscale Entropy) reflects how flexible your system is across timescales. A gradual rise over days suggests your system is adapting well to your routine; a steady decline can signal accumulating strain."),
        .init(def: def("Inner Noise"),         rollup: { $0.pip },
              color: Theme.breathe, zeroBased: true,  fallbackReference: 55.0, trendKey: "pip",
              trendWhy: "Inner Noise (Percentage of Inflection Points) captures beat-to-beat jitter — erratic, non-restorative variability. A downward trend across days points to calmer regulation taking hold; a sustained climb is worth watching."),
        .init(def: def("Harmony"),             rollup: { $0.dfa1 },
              color: Theme.coh,     zeroBased: false, fallbackReference: 1.0,  trendKey: "dfa1",
              trendWhy: "Harmony (DFA α1) is the fractal balance of your heartbeat, with ~1.0 the healthy sweet spot. A trend settling near 1.0 signals well-organised regulation, while days drifting further from it in either direction are worth a closer look."),
        .init(def: def("Stress Balance"),      rollup: { $0.stressBalance },
              color: Theme.warn,    zeroBased: true,  fallbackReference: 50.0, trendKey: "stress_balance",
              trendWhy: "Stress Balance is a breathing-robust 0–100 dial of how revved-up vs calm you are — the same one the Live view shows, unfazed by the slow breathing that fools a raw LF/HF ratio. A lower trend across days means more of your life is happening in rest-and-digest; a rising one is worth easing off for a few days."),
        .init(def: def("Conscious Breathing"), rollup: { $0.rsaMs },
              color: Theme.rsa,     zeroBased: true,  fallbackReference: 40.0, trendKey: "rsa",
              trendWhy: "Conscious Breathing (Respiratory Sinus Arrhythmia) is the swing of heart rate with each breath — the clearest sign of vagal tone. A trend climbing over days suggests your breathing practice is taking hold; a flat line means it hasn't shown up yet in daily life."),
        .init(def: def("Energy Reserve"),      rollup: { $0.rmssd },
              color: Theme.hrv,     zeroBased: true,  fallbackReference: 40.0, trendKey: "rmssd",
              trendWhy: "Energy Reserve (HRV · RMSSD) is your core beat-to-beat variability — the headline marker of recovery and vagal tone. A trend climbing over days points to a system that's recovering well; a sustained dip is a cue to prioritise rest."),
        // Overall Variability rides Track only: its def is built inline
        // rather than added to `activityMetricDefs`, so the Activities grid
        // keeps its nine slots. Averaged over a full day of wear, daily SDNN
        // approximates the classic 24-hour clinical measure — which is why it
        // lives here as a day-level trend and not on the Live screen.
        .init(def: ActivityMetricDef(
                  label: "Overall Variability", techLabel: "SDNN", unit: "ms",
                  direction: .higher,
                  extract: { $0.sdnn.map(Double.init) },
                  format: { $0.map { String(format: "%.1f", $0) } ?? "—" },
                  beforeKey: \.beforeSDNN, duringKey: \.duringSDNN,
                  why: "Overall Variability (SDNN) is the total spread of your beat-to-beat intervals — every rhythm, fast and slow, folded into one number."),
              rollup: { $0.mean[LiveMetric.sdnn.rawValue] },
              color: Theme.ulf, zeroBased: true, fallbackReference: 50.0, trendKey: "sdnn",
              trendWhy: "Overall Variability (SDNN) is the day's total beat-to-beat spread — the classic 24-hour HRV measure, meaningful precisely because it is averaged over the whole day rather than a moment. A rising trend across weeks means broader autonomic range; a sustained fall under steady routine is worth a lighter week."),
    ]

    /// Labels, units, direction and copy are single-sourced from
    /// `activityMetricDefs` so Track and Activities cannot drift.
    private static func def(_ label: String) -> ActivityMetricDef {
        guard let d = activityMetricDefs.first(where: { $0.label == label }) else {
            preconditionFailure("activityMetricDefs is missing \"\(label)\"")
        }
        return d
    }
}
