import SwiftUI
import SwiftData
import Charts

struct HealthActivityDetailView: View {
    let activity: ActivityLog
    private let externalId: String?
    @State private var health = HealthSyncCoordinator.shared
    @State private var samples: [HealthSample] = []
    @State private var metric: HealthMetric = .heartRate
    @State private var source = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var showPolar = false
    @State private var linkedActivityID: UUID?
    @State private var manualDetail: ActivityLog?
    @Query(sort: \ActivityLog.startedAt, order: .reverse) private var activities: [ActivityLog]
    private let links = HealthActivityLinks()
    @Environment(\.dismiss) private var dismiss

    init(activity: ActivityLog) { self.activity = activity; self.externalId = activity.externalWorkoutID }

    private var entry: HealthEntry? {
        health.entries.first { $0.workout.id.uuidString == externalId && !$0.deleted }
    }
    private var sources: [HealthSourceInfo] {
        HealthActivityDetailSources.combine(
            observed: samples.filter { $0.metric == metric }.map(\.source),
            saved: entry?.analysis?.statistics.filter { $0.metric == metric }.map(\.source) ?? [])
    }
    private var linkedActivity: ActivityLog? {
        activities.first { $0.id == linkedActivityID && !$0.isHealthImported && $0.endedAt != nil && $0.activityTypeEnum == .exercise }
    }
    private var selectedSamples: [HealthSample] { samples.filter { $0.metric == metric && $0.source.bundleIdentifier == source } }
    private var plottedSamples: [HealthSample] {
        let points = selectedSamples, step = max(1, Int(ceil(Double(points.count) / 2000)))
        return points.enumerated().compactMap { $0.offset % step == 0 || $0.offset == points.count - 1 ? $0.element : nil }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let entry {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title ?? entry.workout.activityName).font(.title2.bold())
                            Text("Apple Health · \(entry.workout.source.name)").foregroundStyle(Theme.breathe)
                            Text(entry.workout.startedAt.formatted()).font(.subheadline).foregroundStyle(Theme.dim)
                            Text("\(Int(entry.workout.activeDurationSeconds / 60)) min active · \(Int(entry.workout.endedAt.timeIntervalSince(entry.workout.startedAt) / 60)) min elapsed")
                            if let distance = entry.workout.distanceMeters { Text(String(format: "%.2f km", distance / 1000)) }
                            if let energy = entry.workout.energyKcal { Text(String(format: "%.0f kcal", energy)) }
                        }
                        Picker("Measurement", selection: $metric) {
                            ForEach(HealthMetric.allCases, id: \.self) { Text($0.label + ($0.isCumulative && $0 != .steps && $0 != .activeEnergy ? " · \($0.rawValue.replacingOccurrences(of: "distance_", with: ""))" : "")).tag($0) }
                        }.pickerStyle(.menu)
                        if !sources.isEmpty {
                            Picker("Source", selection: $source) { ForEach(sources, id: \.bundleIdentifier) { Text($0.name).tag($0.bundleIdentifier) } }.pickerStyle(.menu)
                        }
                        if !selectedSamples.isEmpty {
                            Chart {
                                ForEach(plottedSamples) { point in
                                    if point.endedAt > point.startedAt {
                                        RuleMark(xStart: .value("Start", point.startedAt), xEnd: .value("End", point.endedAt), y: .value(metric.label, point.value))
                                            .foregroundStyle(Theme.breathe)
                                    } else {
                                        PointMark(x: .value("Time", point.startedAt), y: .value(metric.label, point.value))
                                            .foregroundStyle(Theme.breathe).symbolSize(12)
                                    }
                                }
                                RuleMark(x: .value("Start", entry.workout.startedAt)).lineStyle(StrokeStyle(dash: [4])).foregroundStyle(Theme.dim)
                                RuleMark(x: .value("End", entry.workout.endedAt)).lineStyle(StrokeStyle(dash: [4])).foregroundStyle(Theme.dim)
                            }
                            .chartXScale(domain: entry.workout.startedAt.addingTimeInterval(-300)...entry.workout.endedAt.addingTimeInterval(600))
                            .frame(height: 210)
                            Text("Observed values · \(metric.unit). Gaps are not filled.\(selectedSamples.count > 2000 ? " Chart shows a sample of observations; statistics use all data." : "")")
                                .font(.caption).foregroundStyle(Theme.dim)
                        }
                        ForEach(HealthAnalysis.Window.allCases, id: \.self) { window in
                            windowCard(window, entry: entry)
                        }
                        if let hrr = entry.analysis?.hrr60 {
                            Text(String(format: "Heart rate decrease at 60 seconds: %.0f bpm", hrr))
                            Text(entry.analysis?.hrrSource ?? "").font(.caption).foregroundStyle(Theme.dim)
                        }
                        if entry.analysis?.status == "pending" { Text("The after-window is still being collected.").foregroundStyle(Theme.dim) }
                        if entry.analysis?.stale == true { Text("These saved statistics are waiting for updated measurements.").foregroundStyle(Theme.warn) }
                        if !entry.contextPending.isEmpty { Text("Historical measurements are still importing.").foregroundStyle(Theme.dim) }
                        Text("SDNN is shown as recorded by Health. Other HRV metrics require their own measurements.").font(.caption).foregroundStyle(Theme.dim)
                        if activity.beforeHR != nil || activity.duringHR != nil || activity.afterHR != nil {
                            Button("View separately recorded Polar measurements") { showPolar = true }
                        }
                        linkedActivityCard(entry.workout)
                        VStack(alignment: .leading) {
                            Text("Your annotation").font(.headline)
                            TextField("Workout name", text: $title)
                            TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...8)
                            Button("Save annotation") {
                                Task { await health.annotate(entry.workout.id, title: title.isEmpty ? nil : title, notes: notes.isEmpty ? nil : notes) }
                            }
                            if let error = health.lastError { Text(error).font(.caption).foregroundStyle(Theme.warn) }
                        }.padding().background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    }.padding().foregroundStyle(Theme.text)
                } else { Text("This imported workout is no longer available.").padding() }
            }
            .background(Theme.bg).navigationTitle("ACTIVITY").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: entry?.analysis?.computedAt) {
                guard let entry else { return }
                samples = await health.samples(for: entry.workout)
                if !sources.contains(where: { $0.bundleIdentifier == source }) { source = sources.first?.bundleIdentifier ?? "" }
            }
            .onAppear {
                title = entry?.title ?? ""; notes = entry?.notes ?? ""
                if let id = entry?.workout.id { linkedActivityID = links.linkedActivityID(for: id) }
                source = sources.first?.bundleIdentifier ?? ""
            }
            .onChange(of: metric) { _, _ in source = sources.first?.bundleIdentifier ?? "" }
            .sheet(isPresented: $showPolar) { ExerciseDetailView(entry: activity) }
            .sheet(item: $manualDetail) { ExerciseDetailView(entry: $0) }
        }
    }

    @ViewBuilder private func linkedActivityCard(_ workout: HealthWorkout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Existing Wythin activity").font(.headline)
            if let linkedActivity {
                Text("Linked on this device").font(.caption).foregroundStyle(Theme.dim)
                Button { manualDetail = linkedActivity } label: {
                    Label("\(linkedActivity.displayName) · \(linkedActivity.durationString)", systemImage: "link")
                }
                Button("Unlink records") {
                    links.unlink(workout.id)
                    linkedActivityID = nil
                }
            } else if linkedActivityID != nil {
                Text("The linked activity is no longer available.").foregroundStyle(Theme.dim)
                Button("Remove link") { links.unlink(workout.id); linkedActivityID = nil }
            } else {
                let candidates = HealthActivityLinks.candidates(for: workout, among: activities.map(linkRecord)).prefix(3)
                if candidates.isEmpty {
                    Text("No matching finished exercise found.").font(.caption).foregroundStyle(Theme.dim)
                } else {
                    Text("Same workout? Link a matching entry to open its measurements and notes.")
                        .font(.caption).foregroundStyle(Theme.dim)
                    ForEach(Array(candidates)) { candidate in
                        if let manual = activities.first(where: { $0.id == candidate.id }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Button { manualDetail = manual } label: {
                                    Text("\(manual.displayName) · \(manual.durationString)")
                                }
                                Text(manual.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Theme.dim)
                                Button("Link this workout") {
                                    if links.link(workout, to: linkRecord(manual)) { linkedActivityID = manual.id }
                                }
                            }
                        }
                    }
                }
            }
            Text("Links stay on this device. Both entries and their notes remain in your journal.")
                .font(.caption).foregroundStyle(Theme.dim)
        }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func linkRecord(_ value: ActivityLog) -> HealthActivityLinks.Record {
        .init(id: value.id, startedAt: value.startedAt, endedAt: value.endedAt,
              isExercise: value.activityTypeEnum == .exercise, isImported: value.isHealthImported, subtype: value.activitySubtype)
    }
    @ViewBuilder private func windowCard(_ window: HealthAnalysis.Window, entry: HealthEntry) -> some View {
        let bounds = HealthAnalysis.bounds(window, workout: entry.workout)
        let stats = entry.analysis?.statistics.filter { $0.window == window && $0.metric == metric && $0.source.bundleIdentifier == source } ?? []
        VStack(alignment: .leading, spacing: 5) {
            Text(window.rawValue.capitalized).font(.headline)
            Text("\(bounds.0.formatted(date: .omitted, time: .shortened))–\(bounds.1.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(Theme.dim)
            if stats.isEmpty { Text("No measurements available").foregroundStyle(Theme.dim) }
            ForEach(stats) { stat in
                if let value = stat.mean ?? stat.total { Text(String(format: "%.1f %@", value, metric.unit)).font(.title3.monospacedDigit()) }
                Text("\(stat.count) observations · \(stat.method.replacingOccurrences(of: "_", with: " "))").font(.caption).foregroundStyle(Theme.dim)
                if stat.boundarySamplesOmitted > 0 { Text("\(stat.boundarySamplesOmitted) measurements cross this window and cannot be split reliably.").font(.caption).foregroundStyle(Theme.dim) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

enum HealthActivityDetailSources {
    /// Restored analysis remains selectable when raw samples are absent or Health is disconnected.
    static func combine(observed: [HealthSourceInfo], saved: [HealthSourceInfo]) -> [HealthSourceInfo] {
        Dictionary((observed + saved).map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            .values.sorted { $0.name == $1.name ? $0.bundleIdentifier < $1.bundleIdentifier : $0.name < $1.name }
    }
}
