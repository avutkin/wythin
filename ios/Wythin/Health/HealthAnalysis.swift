import Foundation

struct HealthAnalysis: Codable, Equatable, Sendable {
    enum Window: String, Codable, CaseIterable, Sendable { case before, during, after }
    struct Statistic: Codable, Equatable, Identifiable, Sendable {
        var window: Window
        var metric: HealthMetric
        var source: HealthSourceInfo
        var method: String
        var count: Int
        var mean: Double?
        var minimum: Double?
        var maximum: Double?
        var total: Double?
        var firstAt: Date?
        var lastAt: Date?
        var observedSeconds: Double
        var boundarySamplesOmitted: Int
        var id: String { "\(window.rawValue):\(metric.rawValue):\(source.bundleIdentifier):\(method)" }
    }
    var algorithmVersion: Int = 1
    var computedAt: Date
    var status: String
    var statistics: [Statistic]
    var hrr60: Double?
    var hrrSource: String?
    var stale: Bool? = nil

    static func compute(workout: HealthWorkout, samples: [HealthSample], now: Date = .now) -> Self {
        let unique = Dictionary(samples.filter { $0.value.isFinite && $0.value >= 0 }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var statistics: [Statistic] = []
        for window in Window.allCases {
            let bounds = bounds(window, workout: workout)
            let groups = Dictionary(grouping: unique.values.filter { overlaps($0, bounds: bounds, inclusiveEnd: window == .after) }) {
                "\($0.metric.rawValue)|\($0.source.bundleIdentifier)|\($0.endedAt > $0.startedAt ? "interval" : "point")"
            }
            for key in groups.keys.sorted() {
                let group = groups[key]!.sorted { $0.startedAt < $1.startedAt }
                let first = group[0], cumulative = first.metric.isCumulative
                // A cumulative sample crossing an edge cannot be split honestly without its series.
                let usable = group.filter { !cumulative || ($0.startedAt >= bounds.0 && $0.endedAt <= bounds.1) }
                let intervals = usable.filter { $0.endedAt > $0.startedAt }.map {
                    (max($0.startedAt, bounds.0), min($0.endedAt, bounds.1))
                }
                let duration = unionDuration(intervals)
                let weighted = !intervals.isEmpty && !cumulative
                let weights = usable.map { weighted ? max(0, min($0.endedAt, bounds.1).timeIntervalSince(max($0.startedAt, bounds.0))) : 1 }
                let denominator = weights.reduce(0, +)
                let mean = !cumulative && denominator > 0 ? zip(usable, weights).reduce(0) { $0 + $1.0.value * $1.1 } / denominator : nil
                statistics.append(Statistic(window: window, metric: first.metric, source: first.source,
                    method: cumulative ? "sum_of_contained_samples" : (weighted ? "time_weighted_intervals" : "mean_of_observations"),
                    count: usable.count, mean: mean, minimum: usable.map(\.value).min(), maximum: usable.map(\.value).max(),
                    total: cumulative && !usable.isEmpty ? usable.reduce(0) { $0 + $1.value } : nil,
                    firstAt: usable.first?.startedAt, lastAt: usable.map(\.endedAt).max(), observedSeconds: duration,
                    boundarySamplesOmitted: group.count - usable.count))
            }
        }
        var recovery: Double?, recoverySource: String?
        let hrBySource = Dictionary(grouping: unique.values.filter { $0.metric == .heartRate }) { $0.source.bundleIdentifier }
        for key in hrBySource.keys.sorted() {
            let points = hrBySource[key]!.sorted { $0.startedAt < $1.startedAt }
            if let atEnd = value(points, at: workout.endedAt, tolerance: 10),
               let at60 = value(points, at: workout.endedAt.addingTimeInterval(60), tolerance: 20), atEnd > at60 {
                recovery = atEnd - at60; recoverySource = key; break
            }
        }
        return Self(computedAt: now, status: now < workout.endedAt.addingTimeInterval(600) ? "pending" :
                    (statistics.isEmpty ? "no_data" : "partial"), statistics: statistics, hrr60: recovery, hrrSource: recoverySource)
    }

    static func bounds(_ window: Window, workout: HealthWorkout) -> (Date, Date) {
        switch window {
        case .before: return (workout.startedAt.addingTimeInterval(-300), workout.startedAt)
        case .during: return (workout.startedAt, workout.endedAt)
        case .after: return (workout.endedAt, workout.endedAt.addingTimeInterval(600))
        }
    }
    static func overlaps(_ s: HealthSample, bounds: (Date, Date), inclusiveEnd: Bool = true) -> Bool {
        if s.endedAt == s.startedAt { return s.startedAt >= bounds.0 && (inclusiveEnd ? s.startedAt <= bounds.1 : s.startedAt < bounds.1) }
        return s.startedAt < bounds.1 && s.endedAt > bounds.0
    }
    private static func value(_ samples: [HealthSample], at date: Date, tolerance: Double) -> Double? {
        if let interval = samples.first(where: { $0.startedAt <= date && $0.endedAt > date && $0.endedAt.timeIntervalSince($0.startedAt) <= tolerance }) { return interval.value }
        let near = samples.filter { $0.endedAt.timeIntervalSince($0.startedAt) <= tolerance && abs($0.startedAt.timeIntervalSince(date)) <= tolerance }
        if let exact = near.first(where: { abs($0.startedAt.timeIntervalSince(date)) < 0.001 }) { return exact.value }
        guard let before = near.last(where: { $0.startedAt < date }), let after = near.first(where: { $0.startedAt > date }) else { return nil }
        let fraction = date.timeIntervalSince(before.startedAt) / after.startedAt.timeIntervalSince(before.startedAt)
        return before.value + fraction * (after.value - before.value)
    }
    private static func unionDuration(_ intervals: [(Date, Date)]) -> Double {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        guard var current = sorted.first else { return 0 }
        var seconds = 0.0
        for interval in sorted.dropFirst() {
            if interval.0 <= current.1 { current.1 = max(current.1, interval.1) }
            else { seconds += current.1.timeIntervalSince(current.0); current = interval }
        }
        return seconds + current.1.timeIntervalSince(current.0)
    }
}
