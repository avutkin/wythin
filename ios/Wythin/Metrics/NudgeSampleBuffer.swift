import Foundation

/// Short rolling window of quality-passing ticks, kept for the nudge engine.
///
/// The engine cannot use `AppEnvironment.tickHistory`: that is appended only
/// inside the `if inForeground` branch, so a backgrounded app — the case nudges
/// exist for — never fills it. This buffer is appended on every tick in both
/// modes instead.
///
/// Deliberately not persisted. A cold launch costs a warm-up rather than
/// letting a nudge fire on data from before the process died.
struct NudgeSampleBuffer {

    /// Longest window any rule reads (30 min) plus headroom for gaps and
    /// hysteresis lookback.
    static let retentionSeconds: Double = 45 * 60

    /// Guard against degenerate timestamps only — retention normally bounds the
    /// buffer far below this (45 min at the 2 s foreground cadence is 1350).
    static let capacity  = 1600
    /// Trim in batches so the O(n) shift is amortised, mirroring `tickHistory`.
    static let trimBatch = 200

    /// Longer than this between consecutive samples and the run is broken:
    /// sustain counters reset and the window must refill.
    static let maxGapSeconds: Double = 300

    private(set) var points: [MetricsHistoryPoint] = []

    init() {}

    /// Appends when the tick passes the wear/quality filter. A rejected tick
    /// never enters, so it reads downstream as a gap rather than as bad data.
    mutating func append(_ point: MetricsHistoryPoint, now: Date = .now) {
        guard MetricsQualityFilter.isValid(point) else { return }
        points.append(point)

        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        if let first = points.first, first.timestamp < cutoff {
            points.removeAll { $0.timestamp < cutoff }
        }
        if points.count > Self.capacity + Self.trimBatch {
            points.removeFirst(Self.trimBatch)
        }
    }

    /// True when any two consecutive samples inside the lookback are further
    /// apart than `maxGapSeconds`.
    func hasGap(inLast seconds: Double, now: Date = .now) -> Bool {
        let cutoff = now.addingTimeInterval(-seconds)
        let recent = points.filter { $0.timestamp >= cutoff }
        guard recent.count >= 2 else { return false }
        return zip(recent, recent.dropFirst()).contains {
            $1.timestamp.timeIntervalSince($0.timestamp) > Self.maxGapSeconds
        }
    }

    /// Observed tick spacing — ~2 s in foreground, ~30 s in background. The
    /// engine derives its minimum-point bar from this rather than hardcoding a
    /// cadence, so the same rules hold in both modes.
    var medianCadenceSeconds: Double? {
        guard points.count >= 2 else { return nil }
        let deltas = zip(points, points.dropFirst())
            .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .sorted()
        let mid = deltas.count / 2
        return deltas.count.isMultiple(of: 2)
            ? (deltas[mid - 1] + deltas[mid]) / 2
            : deltas[mid]
    }

    /// Points required before a window of `windowMinutes` may be summarized.
    /// 60 % coverage tolerates ordinary dropout without accepting a window that
    /// is mostly hole; the floor keeps very short windows evaluable.
    static func requiredPoints(windowMinutes: Int, cadenceSeconds: Double) -> Int {
        guard cadenceSeconds > 0 else { return 6 }
        return max(6, Int(0.6 * Double(windowMinutes) * 60 / cadenceSeconds))
    }
}
