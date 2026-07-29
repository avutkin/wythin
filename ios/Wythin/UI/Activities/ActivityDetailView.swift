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

    private func impactCaption(_ score: Int) -> String {
        ActivityImpact.caption(for: score)
    }

    private func recIcon(_ kind: ActivityRecommendation.Kind) -> String {
        switch kind {
        case .keep:  return "checkmark.circle"
        case .watch: return "eye"
        case .trend: return "chart.line.uptrend.xyaxis"
        }
    }

    private func recColor(_ kind: ActivityRecommendation.Kind) -> Color {
        switch kind {
        case .keep:  return Theme.accent
        case .watch: return Theme.warn
        case .trend: return Theme.dim
        }
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
                        // shows (precise when stored at capture, else a cheap
                        // estimate) so the two always agree.
                        if let score = entry.displayImpactScore {
                            VStack(spacing: 14) {
                                Text("OVERALL PRACTICE IMPACT")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                PracticeImpactGauge(score: score, caption: impactCaption(score))
                            }
                            .cardStyle()
                        }

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
                        // rule-based quick-stat bullets below as supporting evidence.
                        let recs = ActivityImpact.recommendations(metrics.map { m in
                            MetricMovement(name: m.def.label,
                                           uplift: m.stats.avgUpliftPct,
                                           vs2mo: m.def.benefitDelta(current: m.stats.duringMean,
                                                                     base: twoMonthAvg[m.def.id]))
                        })
                        if entry.insightText != nil || !recs.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("COACH")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)

                                if let insight = entry.insightText {
                                    coachInsight(insight)
                                }

                                if entry.insightText != nil && !recs.isEmpty {
                                    Divider().overlay(Theme.border)
                                }

                                ForEach(recs) { rec in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: recIcon(rec.kind))
                                            .font(.system(size: 12))
                                            .foregroundStyle(recColor(rec.kind))
                                            .frame(width: 16)
                                        Text(rec.text)
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
