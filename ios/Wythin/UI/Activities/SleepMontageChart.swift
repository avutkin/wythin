import Charts
import SwiftUI

/// The night, channel by channel, on one shared clock axis.
///
/// Laid out as a sleep-study montage because that is the instrument's own
/// vernacular — but every channel here is one a chest ECG plus a sternum
/// accelerometer can actually produce. Nothing is inferred from a sensor this
/// strap does not have.
///
/// The hypnogram is a lane ribbon rather than a fill-to-baseline shape: depth
/// is vertical POSITION, and every state carries equal visual mass. Filling
/// each block down to the floor instead makes the deepest state the shortest
/// bar, and since one state usually occupies most of a night, that collapses
/// the whole chart into a flat strip with the variation invisible.
struct SleepMontageChart: View {

    let points: [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt: Date

    // MARK: - Derived

    private struct StageRun: Identifiable {
        let id = UUID()
        let stage: SleepStageDetail
        let from: Date
        let to: Date
    }

    private var stages: [SleepStageDetail] { SleepStages.detailed(points) }

    /// Contiguous runs, so the ribbon draws one rectangle per stretch rather
    /// than one per tick.
    private var runs: [StageRun] {
        let s = stages
        guard s.count == points.count, !s.isEmpty else { return [] }
        var out: [StageRun] = []
        var start = 0
        for i in 1...s.count {
            if i == s.count || s[i] != s[start] {
                out.append(StageRun(stage: s[start],
                                    from: points[start].timestamp,
                                    to: points[min(i, points.count - 1)].timestamp))
                start = i
            }
        }
        return out
    }

    /// Awake on top, then increasing depth downward — the convention every
    /// hypnogram uses, and the one that makes the staircase readable.
    private func lane(_ stage: SleepStageDetail) -> Double {
        switch stage {
        case .wake:  return 3
        case .rem:   return 2
        case .light: return 1
        case .deep:  return 0
        }
    }

    private func colour(_ stage: SleepStageDetail) -> Color {
        switch stage {
        // Wake is not a depth, so it takes a neutral rather than a rung on the
        // same ramp as the three sleep stages.
        case .wake:  return Theme.dim.opacity(0.55)
        case .rem:   return ActivityType.sleep.color.opacity(0.35)
        case .light: return ActivityType.sleep.color.opacity(0.62)
        case .deep:  return ActivityType.sleep.color
        }
    }

    private var nadir: (Date, Float)? {
        let hrs = points.compactMap { p -> (Date, Float)? in
            p.meanBPM.map { (p.timestamp, $0) }
        }
        return hrs.min { $0.1 < $1.1 }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hypnogram
            trace("HEART RATE", unit: "bpm", value: { $0.meanBPM }, annotateNadir: true)
            trace("HRV RMSSD", unit: "ms", value: { $0.rmssd })
            trace("BREATHING", unit: "br/min", value: { $0.breathBPM })
            movement
            legend
        }
    }

    private var hypnogram: some View {
        VStack(alignment: .leading, spacing: 4) {
            channelLabel("SLEEP", unit: nil)
            Chart(runs) { run in
                RectangleMark(
                    xStart: .value("from", run.from),
                    xEnd: .value("to", run.to),
                    yStart: .value("lo", lane(run.stage) + 0.12),
                    yEnd: .value("hi", lane(run.stage) + 0.88)
                )
                .foregroundStyle(colour(run.stage))
            }
            .chartYScale(domain: 0...4)
            .chartXScale(domain: startedAt...endedAt)
            .chartYAxis {
                AxisMarks(values: [0.5, 1.5, 2.5, 3.5]) { v in
                    AxisValueLabel {
                        Text(["DEEP", "LIGHT", "REM", "AWAKE"][Int((v.as(Double.self) ?? 0.5) - 0.5)])
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                    AxisGridLine().foregroundStyle(Theme.dim.opacity(0.15))
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 104)
        }
    }

    private func trace(_ name: String,
                       unit: String,
                       value: @escaping (MetricsHistoryPoint) -> Float?,
                       annotateNadir: Bool = false) -> some View {
        let series = points.compactMap { p -> (Date, Double)? in
            value(p).map { (p.timestamp, Double($0)) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            channelLabel(name, unit: unit)
            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                    LineMark(x: .value("t", s.0), y: .value(name, s.1))
                        .foregroundStyle(ActivityType.sleep.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.monotone)
                }
                if annotateNadir, let (t, hr) = nadir {
                    PointMark(x: .value("t", t), y: .value(name, Double(hr)))
                        .foregroundStyle(ActivityType.sleep.color)
                        .symbolSize(28)
                        .annotation(position: .top, alignment: .center) {
                            Text("nadir \(Int(hr))")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                }
            }
            .chartXScale(domain: startedAt...endedAt)
            .chartXAxis(name == "BREATHING" ? .automatic : .hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in
                    AxisValueLabel().font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    AxisGridLine().foregroundStyle(Theme.dim.opacity(0.12))
                }
            }
            .frame(height: 56)
        }
    }

    private var movement: some View {
        let series = points.compactMap { p -> (Date, Double)? in
            p.motion.map { (p.timestamp, Double($0)) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            channelLabel("MOVEMENT", unit: "mg")
            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                    BarMark(x: .value("t", s.0), y: .value("motion", s.1), width: 1)
                        .foregroundStyle(Theme.dim.opacity(0.7))
                }
            }
            .chartXScale(domain: startedAt...endedAt)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 34)
        }
    }

    private func channelLabel(_ name: String, unit: String?) -> some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.6)
            if let unit {
                Text(unit).font(.system(size: 8, design: .monospaced))
            }
        }
        .foregroundStyle(Theme.dim)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([SleepStageDetail.deep, .light, .rem, .wake], id: \.self) { s in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colour(s))
                        .frame(width: 12, height: 8)
                    Text(s.label)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }
}
