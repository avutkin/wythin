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
    }
}
