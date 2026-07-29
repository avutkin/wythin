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

    var id: String { def.label }
}

enum TrackMetrics {

    /// The 7 charted metrics, recovery first and load last. Pulse and Calm
    /// Power are deliberately excluded.
    static let all: [TrackMetricSpec] = [
        .init(def: def("Vagal Tone"),          rollup: { $0.dc },
              color: Theme.accent,  zeroBased: true,  fallbackReference: 6.0,  trendKey: "dc"),
        .init(def: def("Energy Reserve"),      rollup: { $0.rmssd },
              color: Theme.hrv,     zeroBased: true,  fallbackReference: 40.0, trendKey: "rmssd"),
        .init(def: def("Conscious Breathing"), rollup: { $0.rsaMs },
              color: Theme.rsa,     zeroBased: true,  fallbackReference: 40.0, trendKey: "rsa"),
        .init(def: def("Adaptive Capacity"),   rollup: { $0.rcmse },
              color: Theme.ulf,     zeroBased: false, fallbackReference: 1.4,  trendKey: "rcmse"),
        .init(def: def("Harmony"),             rollup: { $0.dfa1 },
              color: Theme.coh,     zeroBased: false, fallbackReference: 1.0,  trendKey: "dfa1"),
        .init(def: def("Inner Noise"),         rollup: { $0.pip },
              color: Theme.breathe, zeroBased: true,  fallbackReference: 55.0, trendKey: "pip"),
        .init(def: def("Stress Balance"),      rollup: { $0.stressBalance },
              color: Theme.warn,    zeroBased: true,  fallbackReference: 50.0, trendKey: "stress_balance"),
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
