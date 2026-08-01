import SwiftUI
import SwiftData

// MARK: - ActivitySheet

// Single sheet enum — prevents SwiftUI multiple-sheet chaining bug.
// Optional associated values cause type-inference issues in @ViewBuilder;
// use two explicit cases instead.
private enum ActivitySheet: Identifiable {
    case ble
    case start
    case logPast
    case detail(ActivityLog)
    case edit(ActivityLog)

    var id: String {
        switch self {
        case .ble:           return "ble"
        case .start:         return "start"
        case .logPast:       return "logPast"
        case .detail(let e): return "detail-\(e.id)"
        case .edit(let e):   return "edit-\(e.id)"
        }
    }
}

struct ActivitiesView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.modelContext) var ctx
    @Query(sort: \ActivityLog.startedAt, order: .reverse)
    private var allEntries: [ActivityLog]

    @State private var activeSheet:  ActivitySheet?   = nil

    private struct DayGroup: Identifiable {
        let id:      Date
        let label:   String
        let entries: [ActivityLog]
    }

    private var dayGroups: [DayGroup] {
        let cal = Calendar.current
        let history = allEntries.filter { !$0.isActive }
        let grouped = Dictionary(grouping: history) { cal.startOfDay(for: $0.startedAt) }

        return grouped.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day) {
                label = "TODAY"
            } else if cal.isDateInYesterday(day) {
                label = "YESTERDAY"
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d"
                label = fmt.string(from: day).uppercased()
            }
            let entries = (grouped[day] ?? []).sorted { $0.startedAt > $1.startedAt }
            return DayGroup(id: day, label: label, entries: entries)
        }
    }

    private var activeEntry: ActivityLog? {
        allEntries.first(where: { $0.isActive })
    }

    var body: some View {
        NavigationStack {
            logSection
                .navigationTitle("ACTIVITIES")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.bg, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        BLENavButton(state: env.ble.state,
                                     bpm: env.latestTick?.meanBPM) {
                            activeSheet = .ble
                        }
                    }
                }
                .sheet(item: $activeSheet) { sheet in
                    sheetContent(sheet)
                }
        }
    }

    // MARK: - Log Section

    private var logSection: some View {
        List {
            // ── Active banner ─────────────────────────────────────
            if let active = activeEntry {
                ActiveActivityBanner(entry: active, tick: env.latestTick) {
                    endActivity(active)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(.init(top: 8, leading: 16, bottom: 0, trailing: 16))
            }

            // ── Action buttons (hidden while recording) ──
            if activeEntry == nil {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            activeSheet = .start
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("START NOW")
                            }
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.bg)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        Button {
                            activeSheet = .logPast
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("LOG PAST ACTIVITY")
                            }
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(Theme.accent.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5))
                        }
                    }
                    .cardStyle()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 4, trailing: 16))
                }
            }

            // ── Activity history, grouped by day ──────────────────
            ForEach(dayGroups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        ActivityLogRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { activeSheet = .detail(entry) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteEntry(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    activeSheet = .edit(entry)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(Theme.breathe)
                            }
                            .listRowBackground(Theme.card)
                            .listRowSeparator(.hidden)
                            .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
                    Text(group.label)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .textCase(nil)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    // MARK: - Sheet content

    @ViewBuilder
    private func sheetContent(_ sheet: ActivitySheet) -> some View {
        switch sheet {
        case .ble:
            BLEConnectionSheet(ble: env.ble)
        case .start:
            StartActivitySheet(preselected: nil) { type, subtype, name, target in
                ActivityLogging.begin(type: type, subtype: subtype, customName: name,
                                      targetMinutes: target, context: ctx)
            }
        case .logPast:
            LogPastSheet { type, subtype, name, start, end in
                logPast(type: type, subtype: subtype, customName: name,
                        start: start, end: end)
            }
        case .detail(let entry):
            ActivityDetailView(entry: entry)
        case .edit(let entry):
            EditActivitySheet(entry: entry) { ctx in
                entry.computeHRVWindows(context: ctx)
                entry.computeExerciseResponse(context: ctx)
                try? ctx.save()
                Task { await InsightGenerator(client: env.sync.client).generate(for: entry, context: ctx) }
            }
        }
    }

    // MARK: - Activity CRUD

    private func endActivity(_ entry: ActivityLog) {
        ActivityLogging.end(entry, context: ctx, client: env.sync.client)
    }

    private func logPast(type: ActivityType, subtype: String?, customName: String?,
                         start: Date, end: Date) {
        ActivityLogging.logPast(type: type, subtype: subtype, customName: customName,
                                start: start, end: end, context: ctx, client: env.sync.client)
    }

    private func deleteEntry(_ entry: ActivityLog) {
        ctx.delete(entry)
        try? ctx.save()
    }

}

// MARK: - ActiveActivityBanner

private struct ActiveActivityBanner: View {
    let entry:  ActivityLog
    let tick:   MetricsTick?
    let onStop: () -> Void

    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var targetSeconds: TimeInterval? {
        entry.targetMinutes.map { TimeInterval($0) * 60 }
    }
    private var progress: Double? {
        guard let t = targetSeconds, t > 0 else { return nil }
        return min(elapsed / t, 1.0)
    }
    private var reachedTarget: Bool {
        guard let t = targetSeconds else { return false }
        return elapsed >= t
    }
    private var timerColor: Color { reachedTarget ? Theme.accent : Theme.warn }

    private func mmss(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.warn)
                        .frame(width: 6, height: 6)
                        .opacity(0.8)
                    Image(systemName: entry.activityTypeEnum.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(entry.activityTypeEnum.color)
                    Text(entry.displayName.uppercased())
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.text)
                }
                Spacer()
                Text(mmss(elapsed))
                    .font(Theme.mono(18))
                    .foregroundStyle(timerColor)
                    .monospacedDigit()
                if let t = targetSeconds {
                    Text("/ " + mmss(t))
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .monospacedDigit()
                }
            }

            if let p = progress {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surface)
                            Capsule().fill(timerColor)
                                .frame(width: geo.size.width * CGFloat(p))
                        }
                    }
                    .frame(height: 4)
                    if reachedTarget {
                        Text("TARGET REACHED")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            HStack(spacing: 0) {
                MetricPill(label: "HR",  value: MetricFormat.bpm(tick?.meanBPM),  unit: "bpm")
                MetricPill(label: "RSA", value: MetricFormat.ms(tick?.rsaMs),     unit: "ms")
                MetricPill(label: "VTI", value: MetricFormat.ratio(tick?.vti),    unit: "")
            }

            Button(action: onStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("STOP")
                }
                .font(Theme.monoBody)
                .foregroundStyle(Theme.warn)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Theme.warn.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.warn.opacity(0.35), lineWidth: 0.5))
            }
        }
        .cardStyle()
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(Theme.warn.opacity(0.3), lineWidth: 0.5))
        .onReceive(timer) { _ in
            elapsed = Date().timeIntervalSince(entry.startedAt)
        }
        .onAppear {
            elapsed = Date().timeIntervalSince(entry.startedAt)
        }
    }
}

private struct MetricPill: View {
    let label: String
    let value: String
    let unit:  String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ActivityLogRow

private struct ActivityLogRow: View {
    let entry: ActivityLog

    // 3×3 grid of the nine metrics grouped under the row header.
    private let metricCols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let start = fmt.string(from: entry.startedAt)
        if let end = entry.endedAt {
            return "\(start)–\(fmt.string(from: end))"
        }
        return start
    }

    private func deltaColor(_ delta: Double) -> Color {
        if delta > 2  { return Theme.accent }
        if delta < -2 { return Theme.warn }
        return Theme.dim
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: icon + name + time
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(entry.activityTypeEnum.color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: entry.activityTypeEnum.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(entry.activityTypeEnum.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(timeStr)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                        if entry.isActive {
                            Text("LIVE").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.warn)
                        } else {
                            Text(entry.durationString).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                    }
                }

                Spacer()

                if let delta = entry.impactDeltaPct {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "%+.0f%%", delta))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(deltaColor(delta))
                        Text(ActivityImpact.caption(for: delta))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim.opacity(0.4))
            }

            // All nine metrics — during value + benefit-signed difference.
            LazyVGrid(columns: metricCols, spacing: 6) {
                ForEach(activityMetricDefs) { def in
                    LogMetricCell(def: def, entry: entry)
                }
            }
        }
        .padding(.vertical, 7)
    }
}

/// One metric mini-cell in a log row: consumer-friendly name, the % change
/// from the before-average to the during-average (the hero number), and the
/// during value shown small underneath. The % is colored green when the
/// change is a benefit for that metric, red when it isn't.
private struct LogMetricCell: View {
    let def:   ActivityMetricDef
    let entry: ActivityLog

    private var during: Double? { entry[keyPath: def.duringKey].map(Double.init) }
    private var before: Double? { entry[keyPath: def.beforeKey].map(Double.init) }

    /// Benefit-signed change from the before-average to the during-average, so
    /// this cell's number is directly comparable to the row badge above it —
    /// the badge is the mean of these. A falling pulse reads +9%, which is why
    /// the absolute during-value stays printed underneath.
    private var pctChange: Double? {
        def.benefitDelta(current: during, base: before)
    }

    private var deltaColor: Color {
        guard let p = pctChange else { return Theme.dim.opacity(0.4) }
        if abs(p) < 0.05 { return Theme.dim }
        return p > 0 ? Theme.accent : Theme.warn
    }

    private var deltaText: String {
        guard let p = pctChange else { return "—" }
        return (p >= 0 ? "+" : "−") + String(format: "%.0f%%", abs(p))
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(def.label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .frame(minHeight: 22, alignment: .bottom)
            Text(deltaText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(deltaColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(def.format(during))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Theme.surface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
