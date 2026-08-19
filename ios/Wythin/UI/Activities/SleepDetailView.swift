import SwiftData
import SwiftUI

/// One night in full — the same structure as the Night Trace review console:
/// the honest duration pair, a transparent score with its arithmetic and the
/// points each section contributed, the five sections with their weights, and
/// the montage.
struct SleepDetailView: View {

    let entry: ActivityLog
    @Environment(\.modelContext) private var ctx

    @State private var points: [MetricsHistoryPoint] = []

    private func hm(_ minutes: Int) -> String {
        "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    private var asleepMinutes: Int? { entry.sleepAsleepMinutes }

    private var inBedMinutes: Int? {
        entry.endedAt.map { Int($0.timeIntervalSince(entry.startedAt) / 60) }
    }

    private var window: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        guard let end = entry.endedAt else { return f.string(from: entry.startedAt) }
        return "\(f.string(from: entry.startedAt)) → \(f.string(from: end))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if entry.sleepScore != nil { arithmetic }
                sections
                if !points.isEmpty, let end = entry.endedAt {
                    card("THE NIGHT, CHANNEL BY CHANNEL") {
                        SleepMontageChart(points: points,
                                          startedAt: entry.startedAt,
                                          endedAt: end)
                    }
                }
                measurementNote
            }
            .padding(18)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { load() }
    }

    // MARK: - Pieces

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ActivityType.sleep.icon)
                    .foregroundStyle(ActivityType.sleep.color)
                Text("SLEEP")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.9)
                Spacer()
                Text(window).font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(Theme.dim)

            Text("TIME ASLEEP")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.dim)
            Text(asleepMinutes.map(hm) ?? "—")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
            // The pair, not the single number. The gap between them is the part
            // of the night spent awake, which is the disclosure most sleep UIs
            // quietly drop.
            if let inBed = inBedMinutes {
                Text("Total duration \(hm(inBed))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
            if let stages = entry.sleepStageSummary {
                Text(stages)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 2)
            }
        }
    }

    private var arithmetic: some View {
        card("HOW THIS NUMBER WAS MADE") {
            VStack(alignment: .leading, spacing: 10) {
                if let line = entry.sleepScoreArithmetic {
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let present = contributions
                if !present.isEmpty, let maxPts = present.map(\.1).max(), maxPts > 0 {
                    ForEach(present, id: \.0) { name, pts in
                        HStack(spacing: 8) {
                            Text(name)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.dim)
                                .frame(width: 74, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(ActivityType.sleep.color)
                                    .frame(width: geo.size.width * (pts / maxPts), height: 5)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 8)
                            Text(String(format: "%.1f", pts))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                Text("Weights are fixed and visible, so the number is checkable. Every section is scored against your own baseline, never a population threshold — sleep need varies between people by about ±0.7 h.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    /// Points each section put into the headline — weight × its score.
    private var contributions: [(String, Double)] {
        let scores: [(SleepSection, Int?)] = [
            (.timing, entry.sleepTiming), (.duration, entry.sleepDuration),
            (.continuity, entry.sleepContinuity), (.autonomic, entry.sleepAutonomic),
            (.breathing, entry.sleepBreathing),
        ]
        return scores.compactMap { section, value in
            value.map { (section.name, section.weight * Double($0)) }
        }
    }

    private var sections: some View {
        card("SECTIONS") {
            VStack(spacing: 0) {
                ForEach(Array(entry.indexSlots.enumerated()), id: \.offset) { _, slot in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slot.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text(slot.index?.detail ?? slot.whenEmpty)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.dim)
                        }
                        Spacer()
                        if let index = slot.index {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(index.value)")
                                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.text)
                                Text(index.verdict)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.dim)
                            }
                        } else {
                            // Absent, not zero. A section with no input has not
                            // been measured; showing 0 would read as a verdict.
                            Text("not measured")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .padding(.vertical, 9)
                    Divider().opacity(0.25)
                }
            }
        }
    }

    private var measurementNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOW THIS WAS MEASURED")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
            Text("Three states, not four. The light/deep boundary is the one a cardiac signal places worst, so it is not claimed. Wake is the least reliable channel any wearable has — treat the awake minutes as approximate.")
                .font(.system(size: 11))
            if entry.sleepBreathing == nil {
                Text("Breathing steadiness needs the respiratory-effort channel from the chest accelerometer, which is not built yet — so that section is absent rather than scored.")
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(Theme.dim)
    }

    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.dim)
            content()
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Data

    private func load() {
        guard let end = entry.endedAt else { return }
        let start = entry.startedAt
        var desc = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        // Sized from the span, not a constant: a night at the foreground
        // cadence runs past any fixed limit and the fetch sorts ascending, so
        // a short limit silently drops the END of the night.
        desc.fetchLimit = Int(end.timeIntervalSince(start) / ActivityLog.minTickIntervalSec) + 1_000
        let samples = (try? ctx.fetch(desc)) ?? []
        points = samples.map(MetricsHistoryPoint.init(from:))
    }
}
