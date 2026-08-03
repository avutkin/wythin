import SwiftUI
import SwiftData

// MARK: - ActivityDetailView

struct ActivityDetailView: View {
    @Environment(\.modelContext) var ctx
    @Environment(\.dismiss) var dismiss
    @Bindable var entry: ActivityLog

    @State private var chartPoints: [MetricsHistoryPoint] = []
    @State private var twoMonthAvg: [String: Double] = [:]      // avg absolute during-value

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: entry.startedAt)
    }

    /// Average absolute "during" value per metric across the OTHER completed
    /// sessions of the same activity type in the past ~2 months (the current
    /// session is excluded so it can be compared against this baseline).
    /// Keyed by metric id.
    private func loadTwoMonthAverages() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .distantPast
        let type   = entry.activityType
        let predicate = #Predicate<ActivityLog> {
            $0.activityType == type && $0.startedAt >= cutoff && $0.endedAt != nil
        }
        let sessions = ((try? ctx.fetch(FetchDescriptor<ActivityLog>(predicate: predicate))) ?? [])
            .filter { $0.id != entry.id }

        var absResult: [String: Double] = [:]
        for def in activityMetricDefs {
            // Average absolute during-value.
            let vals = sessions.compactMap { $0[keyPath: def.duringKey].map(Double.init) }
            if !vals.isEmpty {
                absResult[def.id] = vals.reduce(0, +) / Double(vals.count)
            }
        }
        twoMonthAvg = absResult
    }

    private func loadChartPoints() {
        let beforeStart = entry.startedAt.addingTimeInterval(-300)
        let afterEnd    = (entry.endedAt ?? entry.startedAt).addingTimeInterval(600)
        let predicate = #Predicate<HRVSample> {
            $0.timestamp >= beforeStart && $0.timestamp <= afterEnd
        }
        var desc = FetchDescriptor<HRVSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        desc.fetchLimit = 10_000
        let samples = (try? ctx.fetch(desc)) ?? []
        chartPoints = MetricsQualityFilter.filter(samples.map { MetricsHistoryPoint(from: $0) })
    }

    /// Renders the coach insight with its first line (the headline) emphasised
    /// and the rest — the read plus the "Next session:" line — in the body style.
    @ViewBuilder
    private func coachInsight(_ text: String) -> some View {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let headline = parts.first.map(String.init) ?? text
        let rest = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(Theme.monoBody.weight(.semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if !rest.isEmpty {
                Text(rest)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // Header
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
                        }

                        // Compute peak/uplift/recovery once per metric, shared
                        // by the gauge, the rows and the recommendations so
                        // they can't drift.
                        let windowEnd = entry.endedAt ?? entry.startedAt
                        let metrics = activityMetricDefs.map { def in
                            (def: def,
                             stats: ActivityMetricStats(points: chartPoints,
                                                        extract: def.extract,
                                                        direction: def.direction,
                                                        startedAt: entry.startedAt,
                                                        endedAt: windowEnd))
                        }
                        // Overall practice impact — same value the row badge
                        // shows: the mean before→during benefit-signed delta,
                        // literally the average of the rows below.
                        let uplifts = metrics.map { $0.stats.avgUpliftPct }
                        let counts  = RestorativeScore.improvedCount(uplifts: uplifts)

                        if let score = RestorativeScore.score(uplifts: uplifts) {
                            VStack(spacing: 12) {
                                Text("PRACTICE SCORE")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                // The same dial exercise uses. A signed meter
                                // centred on zero made a session that merely
                                // held steady look mid-range; it is the bottom.
                                ExerciseScoreGauge(score: score,
                                                   caption: RestorativeScore.caption(score),
                                                   crowned: score >= ExerciseOverallScore.crownThreshold)
                                // The count alone read as though 9 of 9 should
                                // mean 100. The score is the average *size* of
                                // the improvements, so it says so and shows the
                                // average it came from.
                                VStack(spacing: 3) {
                                    if let mean = RestorativeScore.meanImprovement(uplifts: uplifts) {
                                        Text(String(format: "Average improvement %+.0f%% — full marks is +%.0f%% on a metric.",
                                                    mean, RestorativeScore.fullMarks))
                                            .foregroundStyle(Theme.text.opacity(0.75))
                                    }
                                    Text("\(counts.improved) of \(counts.measured) metrics moved the right way\(RestorativeScore.cappedCount(uplifts: uplifts) > 0 ? ", \(RestorativeScore.cappedCount(uplifts: uplifts)) already at full marks" : "").")
                                        .foregroundStyle(Theme.dim)
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .cardStyle()
                        }

                        // Summary and reflection sits above the detail, so the
                        // read comes before the evidence rather than after it.
                        RestorativeSummaryCard(
                            entry: entry,
                            uplifts: uplifts,
                            labels: metrics.map { $0.def.label },
                            vsAverage: metrics.map { m in
                                m.def.benefitDelta(current: m.stats.duringMean,
                                                   base: twoMonthAvg[m.def.id])
                            })

                        // Per-metric progressive disclosure — tap a row to open
                        // its before/during/after chart and why-it-matters note.

                        ForEach(metrics, id: \.def.id) { m in
                            MetricProgressRow(def: m.def,
                                              stats: m.stats,
                                              twoMonthValue: twoMonthAvg[m.def.id],
                                              color: entry.activityTypeEnum.color,
                                              points: chartPoints,
                                              startedAt: entry.startedAt,
                                              endedAt: windowEnd)
                        }

                        // Combined COACH card: the AI coach's read on top, then the
                        // one factual trend line below as supporting evidence.
                        let trend: String? = nil   // now carried by the summary card
                        if entry.insightText != nil || trend != nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("COACH")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)

                                if let insight = entry.insightText {
                                    coachInsight(insight)
                                }

                                if entry.insightText != nil && trend != nil {
                                    Divider().overlay(Theme.border)
                                }

                                if let trend {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "chart.line.uptrend.xyaxis")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.dim)
                                            .frame(width: 16)
                                        Text(trend)
                                            .font(Theme.monoBody)
                                            .foregroundStyle(Theme.text)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .cardStyle()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 30)
                }
            }
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
            .onAppear {
                loadChartPoints()
                loadTwoMonthAverages()
            }
            // If the activity's timing is edited, reload the sample series so the
            // charts and stats follow the new window (not just on next reopen).
            .onChange(of: entry.startedAt) { loadChartPoints(); loadTwoMonthAverages() }
            .onChange(of: entry.endedAt)   { loadChartPoints(); loadTwoMonthAverages() }
        }
    }
