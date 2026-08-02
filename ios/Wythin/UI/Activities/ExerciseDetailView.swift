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
        ExerciseResponse.reactivationScore(dcAfter: (entry.afterTailDC ?? entry.afterDC).map(Double.init),
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
                    overallCard
                    coachCard
                    sessionCard
                    suppressionCard
                    recoveryCard
                    efficiencyCard
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

    /// The headline. Built from the three axes only — Load is displayed beside
    /// it but never feeds it, so the crown cannot be won by going harder.
    private var overall: AxisValue {
        ExerciseOverallScore.compute(suppression: suppression,
                                     recovery: recovery,
                                     efficiency: efficiency)
    }

    /// Session samples as (work, vagal tone) pairs. Vagal tone is plotted as
    /// lnDC — the same space the slope is fitted in — so the drawn line and the
    /// stored number cannot disagree.
    private var hrCostPoints: [(x: Double, y: Double)] {
        chartPoints.compactMap { pt in
            guard pt.timestamp >= entry.startedAt, pt.timestamp < windowEnd,
                  let hr = pt.meanBPM, let dc = pt.dc, dc > 0 else { return nil }
            if let a = pt.dfa1, ExerciseIntensity.domain(dfa1: Double(a)) == .severe { return nil }
            return (x: ExerciseIntensity.hrReserve(hr: hr, restingHR: restingHR,
                                                   ceiling: ceiling) * 100,
                    y: log(Double(dc)))
        }
    }

    private var motionCostPoints: [(x: Double, y: Double)] {
        chartPoints.compactMap { pt in
            guard pt.timestamp >= entry.startedAt, pt.timestamp < windowEnd,
                  let motion = pt.motion, let dc = pt.dc, dc > 0 else { return nil }
            if let a = pt.dfa1, ExerciseIntensity.domain(dfa1: Double(a)) == .severe { return nil }
            return (x: Double(motion), y: log(Double(dc)))
        }
    }

    /// Load as a share of a heavy hour, for the inner ring. Capped rather than
    /// normalised against history so the ring means the same thing on day one
    /// as it does after a year.
    private var loadFraction: Double? {
        entry.exerciseLoad.map { min($0 / 150, 1) }
    }

    @ViewBuilder
    private var overallCard: some View {
        switch overall {
        case let .score(score, word):
            VStack(spacing: 12) {
                Text("SESSION SCORE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                ExerciseScoreGauge(score: score,
                                   caption: word,
                                   crowned: ExerciseOverallScore.earnsCrown(overall),
                                   loadFraction: loadFraction)
            }
            .cardStyle()
        case let .unavailable(reason):
            VStack(spacing: 6) {
                Text("SESSION SCORE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Text(reason)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity)
            .cardStyle()
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
            if entry.vagalRoseDuring {
                // Yoga and mobility work: the brake came on, not off. Saying
                // "no fit" here described the app's difficulty rather than the
                // person's session.
                unitHeadline("VAGAL BRAKE STAYED ON", "↑",
                             "your vagal tone rose during this session rather than being suppressed — there was no brake released to measure",
                             Theme.accent)
            } else if let brake = brakePerBeat, brake > 0 {
                unitHeadline("VAGAL BRAKE GIVEN UP",
                             String(format: "%.2f", brake),
                             "ms of brake released per extra beat per minute",
                             Theme.hrv)
            } else {
                unitHeadline("VAGAL BRAKE", "—",
                             "not enough heart-rate rise in this session to measure a release against",
                             Theme.dim)
            }
            if !entry.vagalRoseDuring {
                Text("Your heart speeds up mainly by releasing the vagal brake. This is how much brake you gave up for each extra beat — the lower it is, the less of your recovery system the effort had to switch off.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The chart is drawn only where a release was actually measured.
            // Previously it fitted its own line from the dots and drew it even
            // when the score had rejected that fit, so the picture asserted a
            // relationship the header denied.
            if entry.vsiSlopePer10 != nil || entry.vagalRoseDuring {
                CostScatterChart(points: hrCostPoints, xLabel: "heart rate",
                                 tint: entry.vagalRoseDuring ? Theme.accent : Theme.hrv,
                                 baselineSlope: nil)
            }
        }
        .cardStyle()
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case let .score(pct, _) = recovery {
                unitHeadline("VAGAL TONE BACK", "\(pct)%",
                             "of your resting level, measured at the ten-minute mark",
                             Theme.accent)
            } else {
                axisHeader("RECOVERY", recovery, Theme.accent)
            }
            Text("Where your vagal brake had climbed back to ten minutes after stopping, as a share of your resting level. 100% would mean fully restored.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            RecoveryCurveChart(points: chartPoints, startedAt: entry.startedAt,
                               endedAt: windowEnd, dcPre: entry.beforeDC)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var efficiencyCard: some View {
        // Nothing to say without a mechanical signal, so the card is absent
        // rather than present and empty. A dash is not information.
        if entry.hasExternalWorkSignal {
        VStack(alignment: .leading, spacing: 10) {
            axisHeader("EFFICIENCY", efficiency, Theme.breathe)
            Text(entry.hasExternalWorkSignal
                 ? "The same question, against how much you physically moved instead of your heart rate."
                 : "Chest movement does not track this kind of work, so there is nothing to measure the cost against.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            CostScatterChart(points: motionCostPoints, xLabel: "movement",
                             tint: Theme.breathe, baselineSlope: nil)
        }
        .cardStyle()
        }
    }

    /// One deterministic line naming what happened, so the top of the screen
    /// always says something even before the model has written an insight.
    private var summaryLine: String {
        var parts: [String] = []
        if let load = entry.exerciseLoad {
            parts.append("Load \(Int(load.rounded()))")
        }
        let heavy = (entry.domainHeavySec ?? 0) + (entry.domainSevereSec ?? 0)
        if heavy > 60 {
            parts.append("\(Int((heavy / 60).rounded())) min at or above threshold")
        } else if (entry.domainModerateSec ?? 0) > 60 {
            parts.append("held in the moderate domain throughout")
        }
        if case let .score(v, _) = recovery {
            parts.append("\(v)% of vagal tone back at ten minutes")
        }
        return parts.isEmpty ? entry.durationString : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var coachCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SUMMARY")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            Text(summaryLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.border)

            let coach = SessionCoachSummary.build(
                overall: overall, suppression: suppression, recovery: recovery,
                efficiency: efficiency, load: entry.exerciseLoad,
                moderateSec: entry.domainModerateSec ?? 0,
                heavySec: entry.domainHeavySec ?? 0,
                severeSec: entry.domainSevereSec ?? 0,
                loadPercentile: nil)

            bulletGroup("WHAT WENT WELL", coach.strengths, Theme.accent)
            if !coach.improvements.isEmpty {
                bulletGroup("WHAT TO CHANGE NEXT TIME", coach.improvements, Theme.domainHeavy)
            }
            bulletGroup("YOUR NEXT SESSION", [coach.nextSession], Theme.breathe)


        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// One labelled group of coach bullets. The dot carries the group's colour
    /// so praise, correction and prescription are separable at a glance.
    private func bulletGroup(_ title: String, _ lines: [String], _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(tint)
                .tracking(1.1)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A number with its unit spelled out underneath.
    ///
    /// A bare "30" next to a bare "58" is unreadable when one is a percentage
    /// and the other is an effort-time product. Every headline states what it
    /// is measuring in.
    private func unitHeadline(_ title: String, _ value: String,
                              _ unit: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .tracking(1.1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            Text(unit)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var brakePerBeat: Double? {
        ExerciseSuppression.brakePerBeat(dcPre: entry.beforeDC.map(Double.init),
                                         dcDuring: entry.duringDC.map(Double.init),
                                         hrPre: entry.beforeHR.map(Double.init),
                                         hrDuring: entry.duringHR.map(Double.init))
    }

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
