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

    /// Every unfinished activity, not just the newest. Showing one was how an
    /// orphan from an earlier build could sit in the log with no end time and no
    /// way to stop it — the history list filters active entries out, so the
    /// banner is the only place they can appear.
    private var activeEntries: [ActivityLog] {
        ActivityLogging.activeEntries(in: allEntries)
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
            // ── Active banners ────────────────────────────────────
            ForEach(activeEntries) { active in
                ActiveActivityBanner(entry: active, tick: env.latestTick) {
                    endActivity(active)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(.init(top: 8, leading: 16, bottom: 0, trailing: 16))
            }

            // ── Action buttons (hidden while recording) ──
            if activeEntries.isEmpty {
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
                        Group {
                            switch entry.measuredClass {
                            case .activating:  ExerciseLogRow(entry: entry)
                            case .restorative: ActivityLogRow(entry: entry)
                            }
                        }
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
                                      targetMinutes: target, context: ctx,
                                      client: env.sync.client)
            }
        case .logPast:
            LogPastSheet { type, subtype, name, start, end in
                logPast(type: type, subtype: subtype, customName: name,
                        start: start, end: end)
            }
        case .detail(let entry):
            switch entry.measuredClass {
            case .activating:  ExerciseDetailView(entry: entry)
            case .restorative: ActivityDetailView(entry: entry)
            }
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

// MARK: - Still-recording card

/// Shown at the top of a detail screen for an activity that has not finished.
///
/// Without it the screen simply had no end data — every window collapsed to
/// `endedAt ?? startedAt`, a zero-length span — and offered no way to finish the
/// activity, so the only route to stopping it was finding it again in the
/// Activities list.
struct StillRecordingCard: View {
    @Bindable var entry: ActivityLog
    let onFinish: () -> Void

    @State private var now = Date.now
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.warn).frame(width: 6, height: 6)
                Text("STILL RECORDING")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.warn)
                Spacer()
                Text(mmss(now.timeIntervalSince(entry.startedAt)))
                    .font(Theme.mono(18))
                    .foregroundStyle(Theme.warn)
                    .monospacedDigit()
            }

            Text("This activity has no end time yet, so its before/during/after windows can't be worked out.")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onFinish) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("FINISH NOW")
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
            .buttonStyle(.plain)
        }
        .cardStyle()
        .onReceive(ticker) { now = $0 }
    }

    private func mmss(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
