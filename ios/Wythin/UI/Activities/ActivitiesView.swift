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
        let id:      String
        let label:   String
        let entries: [ActivityLog]
    }

    private var dayGroups: [DayGroup] {
        func dayKey(_ date: Date, calendar: Calendar) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let currentCalendar = Calendar.autoupdatingCurrent
        let todayKey = dayKey(.now, calendar: currentCalendar)
        let yesterdayKey = currentCalendar.date(byAdding: .day, value: -1, to: .now)
            .map { dayKey($0, calendar: currentCalendar) }
        let grouped = Dictionary(grouping: ActivityLogging.historyEntries(in: allEntries)) { entry in
            dayKey(entry.startedAt, calendar: entry.recordedCalendar)
        }

        return grouped.keys.sorted(by: >).map { key in
            let entries = (grouped[key] ?? []).sorted { $0.startedAt > $1.startedAt }
            let cal = entries[0].recordedCalendar
            let day = cal.startOfDay(for: entries[0].startedAt)
            let label: String
            if key == todayKey {
                label = "TODAY"
            } else if key == yesterdayKey {
                label = "YESTERDAY"
            } else {
                let fmt = DateFormatter()
                fmt.timeZone = cal.timeZone
                fmt.dateFormat = "MMM d"
                label = fmt.string(from: day).uppercased()
            }
            return DayGroup(id: key, label: label, entries: entries)
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
                // Live readings use the incoming tick directly. Only finished
                // sessions need their after-window summaries refreshed here.
                .onChange(of: env.latestTick?.timestamp) { _, _ in
                    ActivityLogging.refreshLive(entries: ActivityLogging.historyEntries(in: allEntries), context: ctx)
                }
        }
    }

    // MARK: - Log Section

    private var logSection: some View {
        List {
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
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("activity.start")

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
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("activity.logPast")
                    }
                    .cardStyle()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 4, trailing: 16))
                }
            }

            if !activeEntries.isEmpty {
                Section {
                    ForEach(activeEntries) { entry in
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            LiveActivityCard(entry: entry, now: timeline.date,
                                point: LiveActivityPresentation.currentPoint(
                                    env.latestTick.map { MetricsHistoryPoint(from: $0) },
                                    // A measurement can arrive after the last clock
                                    // tick. Judge freshness against wall time.
                                    startedAt: entry.startedAt, now: .now,
                                    signalAvailable: env.ble.rrIntervalsLive),
                                onFinish: { endActivity(entry) })
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(.init(top: 4, leading: 16, bottom: 12, trailing: 16))
                    }
                } header: {
                    Text("LIVE ACTIVITY")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.accent)
                        .textCase(nil)
                }
                .listSectionSeparator(.hidden)
            }

            // ── Activity history, grouped by day ──────────────────
            ForEach(dayGroups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        LiveActivityFrame(entry: entry, onStop: { endActivity(entry) }) {
                            // Sleep first: it is restorative by class, but the
                            // practice row would score it on a before-window
                            // that does not exist for a night.
                            if entry.isHealthImported {
                                HealthActivityRow(entry: entry)
                            } else if entry.isSleep {
                                SleepLogRow(entry: entry,
                                            onEdit: { activeSheet = .edit(entry) },
                                            onDelete: { deleteEntry(entry) })
                            } else {
                            switch entry.measuredClass {
                            case .activating:  ExerciseLogRow(entry: entry,
                                                              onEdit: { activeSheet = .edit(entry) },
                                                              onDelete: { deleteEntry(entry) })
                            case .restorative: ActivityLogRow(entry: entry,
                                                              onEdit: { activeSheet = .edit(entry) },
                                                              onDelete: { deleteEntry(entry) })
                            }
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
                                    activeSheet = entry.isHealthImported ? .detail(entry) : .edit(entry)
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
            if entry.isHealthImported {
                HealthActivityDetailView(activity: entry)
            } else if entry.isSleep {
                SleepDetailView(entry: entry)
            } else {
                switch entry.measuredClass {
                case .activating:  ExerciseDetailView(entry: entry)
                case .restorative: ActivityDetailView(entry: entry)
                }
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
        if entry.isHealthImported, let id = entry.externalWorkoutID.flatMap(UUID.init(uuidString:)) {
            Task { await HealthSyncCoordinator.shared.hide(id) }; return
        }
        ctx.delete(entry)
        try? ctx.save()
    }

}

// MARK: - Ongoing activity

/// Current readings and elapsed time only. Completed scores belong in history
/// after Finish, not in the recording control.
struct LiveActivityCard: View {
    let entry: ActivityLog
    let now: Date
    let point: MetricsHistoryPoint?
    let onFinish: () -> Void

    private var startTime: String {
        let format = DateFormatter()
        format.timeZone = entry.recordedCalendar.timeZone
        format.dateFormat = "HH:mm"
        return format.string(from: entry.startedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: entry.activityTypeEnum.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(entry.activityTypeEnum.color)
                    .frame(width: 42, height: 42)
                    .background(entry.activityTypeEnum.color.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(Theme.mono(17))
                        .foregroundStyle(Theme.text)
                    Text("Started \(startTime)")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                HStack(spacing: 5) {
                    PulsingDot(color: Theme.accent)
                    Text("LIVE").font(Theme.monoLabel)
                }
                .foregroundStyle(Theme.accent)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(LiveActivityPresentation.clock(startedAt: entry.startedAt, now: now))
                    .font(.system(size: 40, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .accessibilityLabel("Elapsed time")
                    .accessibilityIdentifier("activity.live.elapsed")
                Spacer()
                Text("ELAPSED")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            Rectangle().fill(Theme.border).frame(height: 0.5)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(Theme.accent)
                Text(MetricFormat.bpm(value(.hr)))
                    .font(.system(size: 54, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("activity.live.pulse")
                Text("bpm")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text("PULSE NOW")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                reading("Calm Power", value: MetricFormat.ms(value(.rmssd)), unit: "ms")
                reading("Stress Balance", value: MetricFormat.bpm(value(.stressBalance)), unit: "/ 100")
                reading("Breath Rate", value: MetricFormat.ms(value(.breathBPM)), unit: "br/min")
                reading("Vagal Tone", value: MetricFormat.ms(value(.dc)), unit: "ms")
            }

            Text(point == nil
                 ? "Waiting for fresh sensor data. Your timer is still running."
                 : "Live readings · updated as measurements arrive.")
                .font(Theme.monoLabel)
                .foregroundStyle(point == nil ? Theme.warn : Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("activity.live.signal")

            Button(action: onFinish) {
                Label("FINISH", systemImage: "stop.fill")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activity.live.finish")
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("activity.live.card")
    }

    private func value(_ metric: LiveMetric) -> Float? {
        LiveActivityPresentation.value(metric, point: point)
    }

    private func reading(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.monoLabel).foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(Theme.mono(22))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                Text(unit).font(Theme.monoLabel).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - LiveActivityFrame

/// Wraps a row whose numbers are still moving.
///
/// While the session records it carries the clock, the target, a STOP, and the
/// three windows the app measures — the five minutes before, the session, the
/// ten minutes after — with the one in progress marked. When the session stops
/// the frame stays for the after-window, counting it down, so the person can
/// see the recovery numbers underneath arrive rather than wondering why the
/// row is not changing. Then it goes, and the row is an ordinary entry.
struct LiveActivityFrame<Content: View>: View {
    let entry:  ActivityLog
    let onStop: () -> Void
    @ViewBuilder var content: Content

    @State private var now = Date.now
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var phase: ActivityLivePhase? {
        ActivityLivePhase.of(startedAt: entry.startedAt, endedAt: entry.endedAt,
                             now: now, isManual: entry.isManual)
    }

    private var targetSeconds: TimeInterval? {
        entry.targetMinutes.map { TimeInterval($0) * 60 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let phase {
                header(phase)
                    .padding(12)
                    .background(Theme.warn.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Theme.warn.opacity(0.35), lineWidth: 0.5))
                    .padding(.top, 5)
            }
            content
        }
        .onReceive(ticker) { now = $0 }
        .onAppear { now = .now }
    }

    @ViewBuilder
    private func header(_ phase: ActivityLivePhase) -> some View {
        VStack(spacing: 10) {
            switch phase {
            case let .live(elapsed):
                clockRow(title: "RECORDING", clock: elapsed, tint: reached(elapsed) ? Theme.accent : Theme.warn)
                if let t = targetSeconds, t > 0 {
                    bar(fraction: min(elapsed / t, 1), tint: reached(elapsed) ? Theme.accent : Theme.warn)
                }
                phaseStrip(during: .active(mmss(elapsed)), after: .pending)
                stopButton
            case let .settling(remaining):
                clockRow(title: "SETTLING", clock: remaining, tint: Theme.accent,
                         suffix: "left in the after window")
                bar(fraction: 1 - remaining / ActivityLog.afterWindowSeconds, tint: Theme.accent)
                phaseStrip(during: .done(entry.durationString),
                           after: .active(mmss(ActivityLog.afterWindowSeconds - remaining)))
            }
        }
    }

    private func reached(_ elapsed: TimeInterval) -> Bool {
        guard let t = targetSeconds else { return false }
        return elapsed >= t
    }

    private func clockRow(title: String, clock: TimeInterval, tint: Color,
                          suffix: String? = nil) -> some View {
        HStack(spacing: 8) {
            PulsingDot(color: tint)
            Text(title)
                .font(Theme.monoLabel)
                .foregroundStyle(tint)
            if let suffix {
                Text(suffix)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            Text(mmss(clock))
                .font(Theme.mono(18))
                .foregroundStyle(tint)
                .monospacedDigit()
            if let t = targetSeconds, case .live = phase {
                Text("/ " + mmss(t))
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .monospacedDigit()
            }
        }
    }

    private func bar(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * CGFloat(max(0, min(fraction, 1))))
            }
        }
        .frame(height: 4)
    }

    /// The three windows, in order, with the live one marked. Before is
    /// always done by the time there is a row: it is the five minutes that
    /// were already recorded when the session began.
    private func phaseStrip(during: PhaseState, after: PhaseState) -> some View {
        HStack(spacing: 6) {
            PhaseCell(name: "BEFORE", detail: "5 min", state: .done("captured"))
            PhaseCell(name: "DURING", detail: "session", state: during)
            PhaseCell(name: "AFTER", detail: "10 min", state: after)
        }
    }

    private var stopButton: some View {
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
        .buttonStyle(.plain)
    }

    private func mmss(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// One of the three windows in the live frame's strip.
enum PhaseState: Equatable {
    case done(String)
    case active(String)
    case pending
}

private struct PhaseCell: View {
    let name:   String
    let detail: String
    let state:  PhaseState

    private var tint: Color {
        switch state {
        case .done:    return Theme.accent
        case .active:  return Theme.warn
        case .pending: return Theme.dim.opacity(0.6)
        }
    }

    private var caption: String {
        switch state {
        case let .done(s):   return s
        case let .active(s): return s
        case .pending:       return "not yet"
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                switch state {
                case .done:    Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
                case .active:  PulsingDot(color: tint)
                case .pending: Circle().strokeBorder(tint, lineWidth: 1).frame(width: 6, height: 6)
                }
                Text(name)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
            }
            .foregroundStyle(tint)
            Text(caption)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(state == .pending ? Theme.dim.opacity(0.6) : Theme.text.opacity(0.85))
                .monospacedDigit()
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(tint.opacity(state == .pending ? 0.04 : 0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A dot that breathes, so "live" reads as live without a word.
struct PulsingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
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
