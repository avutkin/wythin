import SwiftUI
import SwiftData

/// The detail screen for an activating session.
///
/// Leads with the session's shape, then the three axes, then the coach. The
/// nine restorative metrics are still here — unchanged — but behind a
/// disclosure, because for exercise they are raw material rather than a verdict.
struct ExerciseDetailView: View {
    @Environment(\.modelContext) var ctx
    @Environment(\.dismiss) var dismiss
    @Bindable var entry: ActivityLog

    @State private var chartPoints: [MetricsHistoryPoint] = []
    @State private var restingHR: Float = 60
    @State private var ceiling:   Float = 180
    @State private var showRawMetrics = false

    private var windowEnd: Date { entry.endedAt ?? entry.startedAt }

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: entry.startedAt)
    }

    // MARK: - Data

    private func loadChartPoints() {
        let beforeStart = entry.startedAt.addingTimeInterval(-300)
        let afterEnd    = windowEnd.addingTimeInterval(600)
        let predicate = #Predicate<HRVSample> {
            $0.timestamp >= beforeStart && $0.timestamp <= afterEnd
        }
        var desc = FetchDescriptor<HRVSample>(predicate: predicate,
                                             sortBy: [SortDescriptor(\.timestamp)])
        desc.fetchLimit = 10_000
        let samples = (try? ctx.fetch(desc)) ?? []
        chartPoints = MetricsQualityFilter.filter(samples.map { MetricsHistoryPoint(from: $0) })
    }

    /// The same reserve span the stored response was computed against, so the
    /// chart and the numbers above it cannot disagree.
    private func loadReserveSpan() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -180, to: windowEnd) ?? .distantPast
        let predicate = #Predicate<HRVSample> { $0.timestamp >= cutoff }
        var desc = FetchDescriptor<HRVSample>(predicate: predicate)
        desc.fetchLimit = 200_000
        let history = ((try? ctx.fetch(desc)) ?? []).compactMap(\.meanBPM).sorted()
        guard !history.isEmpty else { return }
        restingHR = history[Int(0.05 * Float(history.count - 1))]
        ceiling   = HRCeiling.ceiling(bpm: history, restingHR: restingHR)
    }

    // MARK: - Axis values

    private var suppression: AxisValue {
        guard entry.vsiSlopePer10 != nil else { return .unavailable(reason: "no fit") }
        guard let s = entry.suppressionScore else { return .unavailable(reason: historyProgress) }
        return .score(s, word: ExerciseResponse.word(for: s))
    }

    private var efficiency: AxisValue {
        guard entry.hasExternalWorkSignal else { return .unavailable(reason: "no ext. signal") }
        guard entry.efficiencySlope != nil else { return .unavailable(reason: "no fit") }
        guard let s = entry.efficiencyScore else { return .unavailable(reason: historyProgress) }
        return .score(s, word: ExerciseResponse.word(for: s))
    }

    private var recovery: AxisValue {
        ExerciseResponse.reactivationScore(dcAfter: entry.afterDC.map(Double.init),
                                           dcPre: entry.beforeDC.map(Double.init))
    }

    /// The row chip has room only for "2 of 3"; here there is space to say what
    /// that actually means, so it does.
    private var historyProgress: String {
        let have = (entry.scoreHistoryCount ?? 0) + 1
        let need = ExerciseResponse.minimumHistory
        let remaining = max(need - have, 0)
        guard remaining > 0 else { return "\(have) of \(need)" }
        return remaining == 1
            ? "1 more session to compare"
            : "\(remaining) more sessions to compare"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    sessionCard
                    suppressionCard
                    recoveryCard
                    efficiencyCard
                    coachCard
                    rawMetrics
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
            .background(Theme.bg)
            .navigationTitle(entry.displayName.uppercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        try? ctx.save()
                        dismiss()
                    }
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent)
                }
            }
            .onAppear { loadChartPoints(); loadReserveSpan() }
            .onChange(of: entry.startedAt) { loadChartPoints(); loadReserveSpan() }
            .onChange(of: entry.endedAt)   { loadChartPoints(); loadReserveSpan() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(entry.activityTypeEnum.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: entry.activityTypeEnum.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(entry.activityTypeEnum.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(Theme.mono(16))
                    .foregroundStyle(Theme.text)
                Text(timeStr + " · " + entry.durationString)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            if let load = entry.exerciseLoad {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(load.rounded()))")
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                    Text("LOAD")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SESSION")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            SessionTimelineChart(points: chartPoints,
                                 startedAt: entry.startedAt,
                                 endedAt: windowEnd,
                                 restingHR: restingHR,
                                 ceiling: ceiling,
                                 dcPre: entry.beforeDC)
            IntensityDomainBar(moderateSec: entry.domainModerateSec ?? 0,
                               heavySec: entry.domainHeavySec ?? 0,
                               severeSec: entry.domainSevereSec ?? 0)
        }
        .cardStyle()
    }

    private var suppressionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            axisHeader("SUPPRESSION · VSI", suppression, Theme.hrv)
            if let slope = entry.vsiSlopePer10 {
                readout([("VSI", String(format: "%.2f", slope) + " lnDC / 10 %HRR")])
            }
            Text("How much vagal tone this heart rate cost. Lower is cheaper.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            axisHeader("RECOVERY", recovery, Theme.accent)
            Text("Vagal tone regained ten minutes after you stopped. Six further checkpoints arrive in a later release.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var efficiencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            axisHeader("EFFICIENCY", efficiency, Theme.breathe)
            if let slope = entry.efficiencySlope {
                readout([("per motion", String(format: "%.2f", slope))])
            }
            Text(entry.hasExternalWorkSignal
                 ? "The same question against mechanical work rather than heart rate."
                 : "Chest motion does not measure this kind of work, so there is no denominator to divide by.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var coachCard: some View {
        if let insight = entry.insightText {
            VStack(alignment: .leading, spacing: 12) {
                Text("COACH")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                let parts = insight.split(separator: "\n", maxSplits: 1,
                                          omittingEmptySubsequences: false)
                Text(parts.first.map(String.init) ?? insight)
                    .font(Theme.monoBody.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if parts.count > 1 {
                    Text(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    /// The nine metrics, unchanged, for when you want the underlying numbers.
    private var rawMetrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showRawMetrics.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showRawMetrics ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                    Text("RAW METRICS (9)")
                        .font(Theme.monoLabel)
                    Spacer()
                }
                .foregroundStyle(Theme.dim)
            }

            if showRawMetrics {
                let metrics = activityMetricDefs.map { def in
                    (def: def,
                     stats: ActivityMetricStats(points: chartPoints,
                                                extract: def.extract,
                                                direction: def.direction,
                                                startedAt: entry.startedAt,
                                                endedAt: windowEnd))
                }
                ForEach(metrics, id: \.def.id) { m in
                    MetricProgressRow(def: m.def,
                                      stats: m.stats,
                                      twoMonthValue: nil,
                                      color: entry.activityTypeEnum.color,
                                      points: chartPoints,
                                      startedAt: entry.startedAt,
                                      endedAt: windowEnd)
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Shared pieces

    private func axisHeader(_ name: String, _ value: AxisValue, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
            switch value {
            case let .score(score, word):
                Text("\(score)")
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Spacer()
                Text(word)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            case let .unavailable(reason):
                // No oversized dash here. At 24pt a lone em-dash floats at
                // mid-cap-height beside a 10pt label and reads as a rendering
                // fault rather than an absent value — the reason carries it.
                Spacer()
                Text(reason)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.9))
            }
        }
    }

    private func readout(_ pairs: [(String, String)]) -> some View {
        HStack(spacing: 12) {
            ForEach(pairs, id: \.0) { label, value in
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    Text(value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                }
            }
        }
    }
}
