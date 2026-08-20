import Foundation
import SwiftData

/// Everything the night detail screen needs, computed once and off the main
/// thread.
///
/// The screen used to do all of this inline: a synchronous fetch of every
/// sample in the window — a ten-hour night at the foreground cadence is roughly
/// nineteen thousand rows — then staging over all of them inside a view
/// initialiser, then nine more passes for the metric averages, then another
/// pass per draw for the movement threshold. All of it on the main thread,
/// between the tap and the first frame. That is why a night would not open.
///
/// None of this work depends on layout, so none of it belongs in a `body`.
struct PreparedNight: Sendable {

    let points: [MetricsHistoryPoint]
    let stages: [SleepStageDetail]
    let stageMinutes: [SleepStageDetail: Int]

    /// Metric id → night average. Precomputed because the averages grid asks
    /// for nine of these and each one walks the night.
    let averages: [String: Double]

    /// Movement ticks are drawn only where motion stands out from this night's
    /// own stillness, which needs a median — once, not once per draw.
    let motionThreshold: Float

    /// One bucketed line per metric, keyed by `ActivityMetricDef.id`.
    ///
    /// A night average is a single number for eight hours, which hides the
    /// only thing worth seeing: *where* vagal tone climbed, *where* it fell
    /// away, and whether either lines up with being awake. The average stays —
    /// as the header on its own chart — but the line is what you read.
    let series: [String: [Sample]]

    /// The stretches spent awake, so every metric can be read against the
    /// night's architecture rather than against a bare clock.
    let wakeBands: [Band]

    struct Sample: Sendable, Equatable {
        let date: Date
        let value: Double
    }

    struct Band: Sendable, Equatable {
        let start: Date
        let end: Date
    }

    /// One unbroken stretch of a single stage, with the clock times it covers.
    ///
    /// Precomputed because the chart rebuilt these from ~19,000 stage labels on
    /// EVERY redraw, and the tracker re-evaluates the view continuously while a
    /// finger is down. Runs are a property of the night, not of a frame.
    struct StageRun: Sendable, Equatable {
        let stage: SleepStageDetail
        let start: Date
        let end: Date
    }

    /// A movement tick worth drawing, with its height already scaled 0...1.
    ///
    /// Same reason: the movement strip filtered all ~19,000 samples against the
    /// threshold and recomputed each tick's height every frame.
    struct MotionTick: Sendable, Equatable {
        let date: Date
        let scale: Double
    }

    struct PositionBand: Sendable, Equatable {
        let position: BodyPosition
        let start: Date
        let end: Date
    }

    /// Stretches the body held one orientation.
    let positionBands: [PositionBand]

    let stageRuns: [StageRun]
    let motionTicks: [MotionTick]

    /// How many ticks carried an orientation at all.
    ///
    /// This is the difference between the two ways a night ends up with no
    /// bands, and the screen must not conflate them: zero means the night
    /// predates position storage and can never show it, non-zero with no bands
    /// means orientation WAS measured but was never held past the two-minute
    /// floor. "Not recorded" is true of the first and false of the second.
    let positionTicks: Int

    /// Minutes in each position, from the bands. A position never held is
    /// absent rather than zero — absent and zero are different claims.
    let positionMinutes: [BodyPosition: Int]

    /// Supine as a share of the time a position was *known*, not of the night.
    ///
    /// The gaps are stretches the sensor was moving through, and dividing by
    /// them would understate every position by however long the person spent
    /// turning over. Nil when no position was ever held.
    var supineSharePct: Int? {
        let total = positionMinutes.values.reduce(0, +)
        guard total > 0 else { return nil }
        return Int((Double(positionMinutes[.supine] ?? 0) / Double(total) * 100).rounded())
    }

    /// A posture must hold for at least this long to count as a turn rather
    /// than a wobble in the gravity estimate.
    static let minPositionRunSec: Double = 120

    /// Target resolution for a metric line. The chart is a few hundred points
    /// wide and the night is ~18,000 samples, so drawing every tick is both
    /// wasted work and an unreadable smear.
    static let seriesBuckets = 120

    /// Reads the night out of the store on a background context and does the
    /// whole computation there.
    ///
    /// The context is created inside the task and used only there, which is the
    /// supported SwiftData pattern; nothing model-backed crosses back, only
    /// value types.
    static func load(container: ModelContainer,
                     from start: Date,
                     to end: Date) async -> PreparedNight {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            var desc = FetchDescriptor<HRVSample>(
                predicate: #Predicate<HRVSample> { $0.timestamp >= start && $0.timestamp <= end },
                sortBy: [SortDescriptor(\.timestamp)]
            )
            // Sized from the span, not a constant: a night at the foreground
            // cadence runs past any fixed limit and the fetch sorts ascending,
            // so a short limit silently drops the END of the night.
            desc.fetchLimit = Int(end.timeIntervalSince(start) / ActivityLog.minTickIntervalSec) + 1_000
            let samples = (try? context.fetch(desc)) ?? []
            return PreparedNight(points: samples.map(MetricsHistoryPoint.init(from:)))
        }.value
    }

    init(points: [MetricsHistoryPoint]) {
        self.points = points

        let stages = SleepStages.detailed(points)
        self.stages = stages

        self.stageMinutes = Dictionary(uniqueKeysWithValues:
            SleepStageDetail.allCases.map { stage in
                let secs = SleepRecorder.seconds(where: stages.map { $0 == stage },
                                                 points: points)
                return (stage, Int((secs / 60).rounded()))
            })

        self.averages = Dictionary(uniqueKeysWithValues:
            activityMetricDefs.compactMap { def -> (String, Double)? in
                let values = points.compactMap { def.extract($0) }
                guard !values.isEmpty else { return nil }
                return (def.id, values.reduce(0, +) / Double(values.count))
            })

        let motions = points.compactMap(\.motion).sorted()
        self.motionThreshold = motions.isEmpty
            ? .greatestFiniteMagnitude
            : max(motions[motions.count / 2] * 2, 8)

        self.stageRuns = Self.buildStageRuns(stages, points: points)
        self.motionTicks = Self.buildMotionTicks(points, threshold: self.motionThreshold)
        self.series = Self.buildSeries(points)
        self.wakeBands = Self.buildWakeBands(stages, points: points)
        let bands = Self.positionBands(points)
        self.positionBands = bands
        self.positionTicks = points.reduce(0) { $0 + ($1.bodyPosition == nil ? 0 : 1) }
        self.positionMinutes = bands.reduce(into: [:]) { out, band in
            out[band.position, default: 0] +=
                Int((band.end.timeIntervalSince(band.start) / 60).rounded())
        }
    }

    /// Contiguous runs of one body position.
    ///
    /// Nil is not a posture — it means the sensor was moving, and a window
    /// spanning a roll averages two orientations into one the body never held.
    /// Those stretches stay gaps rather than being absorbed into a neighbour,
    /// because "we do not know" and "still supine" are different claims.
    static func positionBands(_ points: [MetricsHistoryPoint]) -> [PositionBand] {
        guard !points.isEmpty else { return [] }
        var runs: [PositionBand] = []
        var i = 0
        while i < points.count {
            guard let pos = points[i].bodyPosition else { i += 1; continue }
            var j = i
            while j + 1 < points.count, points[j + 1].bodyPosition == pos { j += 1 }
            let end = j + 1 < points.count ? points[j + 1].timestamp : points[j].timestamp
            runs.append(PositionBand(position: pos, start: points[i].timestamp, end: end))
            i = j + 1
        }

        // Drop flickers, then merge neighbours the flicker had separated.
        let kept = runs.filter { $0.end.timeIntervalSince($0.start) >= minPositionRunSec }
        var merged: [PositionBand] = []
        for band in kept {
            // Across a short gap too: dropping a flicker leaves one, and the
            // two sides of it are the same unbroken stretch.
            if let last = merged.last, last.position == band.position,
               band.start.timeIntervalSince(last.end) <= minPositionRunSec {
                merged[merged.count - 1] = PositionBand(position: last.position,
                                                        start: last.start, end: band.end)
            } else {
                merged.append(band)
            }
        }
        return merged
    }

    private static func buildStageRuns(_ stages: [SleepStageDetail],
                                       points: [MetricsHistoryPoint]) -> [StageRun] {
        guard stages.count == points.count, !points.isEmpty else { return [] }
        var out: [StageRun] = []
        var start = 0
        for i in 1...stages.count {
            guard i == stages.count || stages[i] != stages[start] else { continue }
            let end = i < points.count ? points[i].timestamp : points[points.count - 1].timestamp
            out.append(StageRun(stage: stages[start],
                                start: points[start].timestamp,
                                end: max(end, points[start].timestamp)))
            start = i
        }
        return out
    }

    /// Ticks that stand out from this night's own stillness, thinned so the
    /// strip cannot cost more than a few hundred draws whatever the cadence.
    static let maxMotionTicks = 900

    private static func buildMotionTicks(_ points: [MetricsHistoryPoint],
                                         threshold: Float) -> [MotionTick] {
        guard threshold < .greatestFiniteMagnitude else { return [] }
        let hits = points.compactMap { p -> MotionTick? in
            guard let m = p.motion, m > threshold else { return nil }
            return MotionTick(date: p.timestamp,
                              scale: min(1, Double(m / (threshold * 4))))
        }
        guard hits.count > maxMotionTicks else { return hits }
        // Keep the loudest in each slot rather than every nth — thinning by
        // position would drop the very movements the strip exists to show.
        let stride = Double(hits.count) / Double(maxMotionTicks)
        var out: [MotionTick] = []
        for slot in 0..<maxMotionTicks {
            let lo = Int(Double(slot) * stride)
            let hi = min(hits.count, Int(Double(slot + 1) * stride))
            guard lo < hi else { continue }
            if let loudest = hits[lo..<hi].max(by: { $0.scale < $1.scale }) {
                out.append(loudest)
            }
        }
        return out
    }

    // MARK: - Lines

    private static func buildSeries(_ points: [MetricsHistoryPoint]) -> [String: [Sample]] {
        guard let first = points.first, let last = points.last else { return [:] }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span > 0 else { return [:] }
        let bucketSec = span / Double(seriesBuckets)

        var out: [String: [Sample]] = [:]
        for def in activityMetricDefs {
            var sums: [Int: Double] = [:]
            var counts: [Int: Int] = [:]
            for p in points {
                guard let v = def.extract(p) else { continue }
                let k = min(seriesBuckets - 1,
                            Int(p.timestamp.timeIntervalSince(first.timestamp) / bucketSec))
                sums[k, default: 0] += v
                counts[k, default: 0] += 1
            }
            guard !sums.isEmpty else { continue }
            out[def.id] = sums.keys.sorted().map { k in
                Sample(date: first.timestamp.addingTimeInterval(Double(k) * bucketSec + bucketSec / 2),
                       value: sums[k]! / Double(counts[k]!))
            }
        }
        return out
    }

    /// Contiguous runs of wake, as time ranges. Merged rather than per-tick, so
    /// the chart shades a handful of bands instead of thousands of hairlines.
    private static func buildWakeBands(_ stages: [SleepStageDetail],
                                       points: [MetricsHistoryPoint]) -> [Band] {
        guard stages.count == points.count, !points.isEmpty else { return [] }
        var bands: [Band] = []
        var i = 0
        while i < stages.count {
            guard stages[i] == .wake else { i += 1; continue }
            var j = i
            while j + 1 < stages.count && stages[j + 1] == .wake { j += 1 }
            // A single-tick bout still has width: extend to the next sample so
            // the band is drawable rather than zero-wide.
            let end = j + 1 < points.count ? points[j + 1].timestamp : points[j].timestamp
            if end > points[i].timestamp {
                bands.append(Band(start: points[i].timestamp, end: end))
            }
            i = j + 1
        }
        return bands
    }
}
