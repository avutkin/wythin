import SwiftUI
import SwiftData

// MARK: - StartActivitySheet

struct StartActivitySheet: View {
    var preselected: ActivityType? = nil
    let onStart: (ActivityType, String?, String?, Int?) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var selected:         ActivityType
    @State private var selectedSubtype:  String?      = nil
    @State private var customName:       String       = ""
    @State private var showCustom:       Bool         = false
    @State private var targetMinutes:    Double?      = nil
    /// "now" is captured when the sheet appears rather than read on every
    /// render, so the projected end time does not creep forward while the sheet
    /// is open and the user is still choosing.
    @State private var openedAt:         Date         = .now

    init(preselected: ActivityType? = nil, onStart: @escaping (ActivityType, String?, String?, Int?) -> Void) {
        self.preselected = preselected
        self.onStart     = onStart
        _selected  = State(initialValue: preselected ?? .meditation)
        _showCustom = State(initialValue: preselected == .custom)
    }

    /// The end time, projected from the target and writing back a duration.
    ///
    /// Deliberately not stored: an independent end-time value would drift out
    /// of agreement with the target it is supposed to describe.
    private var endByBinding: Binding<Date> {
        Binding(
            get: { ActivityTimeMath.end(start: openedAt, minutes: targetMinutes ?? 20) },
            set: { targetMinutes = ActivityTimeMath.minutes(start: openedAt, end: $0) }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ActivityPickerSection(selected: $selected,
                                          selectedSubtype: $selectedSubtype,
                                          customName: $customName,
                                          showCustom: $showCustom)

                    DurationPresetRow(minutes: $targetMinutes, title: "TARGET (OPTIONAL)",
                                      valueLabel: ActivityTimeMath.endLabel(start: openedAt,
                                                                            minutes: targetMinutes)
                                          .map { "ends \($0)" } ?? "")
                        .padding(.horizontal)

                    // Choosing an end sets the target; choosing a preset moves
                    // the shown end. One value underneath, two ways in.
                    if targetMinutes != nil {
                        HStack {
                            Text("END BY")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                            Spacer()
                            DatePicker("", selection: endByBinding,
                                       displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                        }
                        .padding(.horizontal)
                    }

                }
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .background(Theme.bg)
            // Pinned, so START is reachable without scrolling whatever the
            // subtype list does to the content height.
            .safeAreaInset(edge: .bottom) {
                Button {
                    let name = selected == .custom && !customName.isEmpty ? customName : nil
                    onStart(selected, selectedSubtype, name, targetMinutes.map { Int($0) })
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("START ACTIVITY")
                    }
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.bg)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(selected == .custom && customName.isEmpty)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .background(Theme.bg)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(height: 0.5)
                }
            }
            .onAppear { openedAt = .now }
            .navigationTitle("START ACTIVITY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }
}

// MARK: - LogPastSheet

struct LogPastSheet: View {
    let onSave: (ActivityType, String?, String?, Date, Date) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var selected:        ActivityType
    @State private var selectedSubtype: String?
    @State private var customName:      String       = ""
    @State private var showCustom:      Bool         = false
    @State private var startDate:       Date         = .now
    @State private var durationMins:    Double

    /// Blank sheet (Activities "LOG PAST ACTIVITY"): defaults to Meditation / 30 min.
    init(onSave: @escaping (ActivityType, String?, String?, Date, Date) -> Void) {
        self.onSave = onSave
        _selected        = State(initialValue: .meditation)
        _selectedSubtype = State(initialValue: nil)
        _durationMins    = State(initialValue: 30)
    }

    /// Prefilled from a Practice ("Log it"): seeds type / subtype / duration.
    init(prefill: ActivityPrefill,
         onSave: @escaping (ActivityType, String?, String?, Date, Date) -> Void) {
        self.onSave = onSave
        _selected        = State(initialValue: prefill.type)
        _selectedSubtype = State(initialValue: prefill.subtype)
        _customName      = State(initialValue: "")
        _showCustom      = State(initialValue: prefill.type == .custom)
        _durationMins    = State(initialValue: prefill.durationMins ?? 30)
    }

    private var endDate: Date { startDate.addingTimeInterval(durationMins * 60) }

    /// Bridges the non-optional slider value to the preset row's optional
    /// binding. Writing nil is a no-op — the duration always has a value here.
    private var presetBinding: Binding<Double?> {
        Binding(get: { durationMins },
                set: { if let v = $0 { durationMins = v } })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    ActivityPickerSection(selected: $selected,
                                          selectedSubtype: $selectedSubtype,
                                          customName: $customName,
                                          showCustom: $showCustom)

                    VStack(spacing: 12) {
                        DatePicker("START TIME", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                            .tint(Theme.accent)

                        VStack(alignment: .leading, spacing: 8) {
                            DurationPresetRow(minutes: presetBinding,
                                              valueLabel: "\(Int(durationMins)) min")
                            Slider(value: $durationMins, in: 1...180, step: 1)
                                .tint(Theme.accent)
                        }
                    }
                    .cardStyle()
                    .padding(.horizontal)

                }
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom) {
                Button {
                    let name = selected == .custom && !customName.isEmpty ? customName : nil
                    onSave(selected, selectedSubtype, name, startDate, endDate)
                    dismiss()
                } label: {
                    Text("SAVE")
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.bg)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(selected == .custom && customName.isEmpty)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .background(Theme.bg)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(height: 0.5)
                }
            }
            .navigationTitle("LOG PAST ACTIVITY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }
}

// MARK: - DurationPresetRow

/// Quick-pick minute chips. A shortcut over whatever control sits beside it,
/// never a mode: selection is derived purely from the bound value, so dragging
/// a slider to a non-preset number clears the highlight with no extra state.
struct DurationPresetRow: View {
    static let presets = [5, 10, 15, 20, 30]

    @Binding var minutes: Double?
    var title: String = "DURATION"
    /// Trailing text shown at the row's right edge (e.g. "15 min"). Empty hides it.
    var valueLabel: String = ""

    static func isSelected(_ preset: Int, minutes: Double?) -> Bool {
        guard let m = minutes else { return false }
        return m == Double(preset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                if !valueLabel.isEmpty {
                    Text(valueLabel)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.accent)
                } else if minutes != nil {
                    Button("clear") { minutes = nil }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.5))
                }
            }

            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.self) { p in
                    let on = Self.isSelected(p, minutes: minutes)
                    Button {
                        minutes = Double(p)
                    } label: {
                        Text("\(p)")
                            .font(Theme.monoLabel)
                            .foregroundStyle(on ? Theme.bg : Theme.accent)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(on ? Theme.accent : Theme.accent.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(on ? .clear : Theme.accent.opacity(0.25), lineWidth: 0.5))
                    }
                }
            }
        }
    }
}

// MARK: - ActivityPickerSection

/// The type grid + subtype picker + custom-name field shared by the Start,
/// Log Past and Edit sheets. Owns no state — the host sheet holds it, because
/// each sheet seeds it differently.
struct ActivityPickerSection: View {
    @Binding var selected:        ActivityType
    @Binding var selectedSubtype: String?
    @Binding var customName:      String
    @Binding var showCustom:      Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 16) {
            Text("SELECT ACTIVITY")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            // Nine tiles, exactly three rows — the grid and the action button
            // both fit on one screen without scrolling.
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ActivityType.pickerCases, id: \.self) { type in
                    ActivityTypeCell(type: type, isSelected: selected == type) {
                        selected = type
                        selectedSubtype = nil
                        showCustom = false
                    }
                }
            }
            .padding(.horizontal)

            // Custom sits below the grid rather than spending a tile.
            Button {
                selected = .custom
                selectedSubtype = nil
                showCustom = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("CUSTOM")
                }
                .font(Theme.monoLabel)
                .foregroundStyle(selected == .custom ? Theme.bg : Theme.dim)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(selected == .custom ? Theme.accent : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected == .custom ? .clear : Theme.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            SubtypePicker(type: selected, selected: $selectedSubtype)
                .id(selected)
                .padding(.horizontal)

            if showCustom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CUSTOM NAME")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    TextField("e.g. Ice bath", text: $customName)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text)
                        .padding(10)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.border, lineWidth: 0.5))
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - SubtypeMemory

/// Remembered custom subtypes, derived from logged history rather than stored
/// separately. Every ActivityLog already persists its subtype, so there is
/// nothing extra to write, migrate or clean up — deleting the last entry that
/// used a subtype stops it being offered.
enum SubtypeMemory {
    static func remembered(type: ActivityType, entries: [ActivityLog], limit: Int = 6) -> [String] {
        let builtIn = Set(type.subtypes)
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries where entry.activityType == type.rawValue {
            guard let raw = entry.activitySubtype else { continue }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !builtIn.contains(name), !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
            if out.count == limit { break }
        }
        return out
    }
}

// MARK: - SubtypePicker

struct SubtypePicker: View {
    let type: ActivityType
    @Binding var selected: String?

    @Query(sort: \ActivityLog.startedAt, order: .reverse)
    private var allEntries: [ActivityLog]

    @State private var showCustomField = false
    @State private var customSubtype   = ""
    @FocusState private var fieldFocused: Bool

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var remembered: [String] {
        SubtypeMemory.remembered(type: type, entries: allEntries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SUBTYPE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                if selected != nil {
                    Button("clear") {
                        selected = nil
                        showCustomField = false
                        customSubtype = ""
                    }
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim.opacity(0.5))
                }
            }

            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(type.subtypes + remembered, id: \.self) { sub in
                    chip(label: sub, isOn: selected == sub) {
                        selected = selected == sub ? nil : sub
                        showCustomField = false
                        customSubtype = ""
                    }
                }
                chip(label: "+ Custom", isOn: showCustomField) {
                    showCustomField.toggle()
                    if showCustomField {
                        customSubtype = ""
                        fieldFocused = true
                    }
                }
            }

            if showCustomField {
                TextField("e.g. Kettlebells", text: $customSubtype)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .padding(10)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.border, lineWidth: 0.5))
                    .onChange(of: customSubtype) { _, new in
                        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                        selected = trimmed.isEmpty ? nil : trimmed
                    }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func chip(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(isOn ? Theme.bg : type.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(isOn ? type.color : type.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn ? .clear : type.color.opacity(0.25), lineWidth: 0.5))
        }
    }
}

// MARK: - ActivityTypeCell

struct ActivityTypeCell: View {
    let type:       ActivityType
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isSelected ? type.color : type.color.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: type.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? Theme.bg : type.color)
                }
                Text(type == .custom ? "Custom" : type.rawValue)
                    .font(Theme.monoLabel)
                    .foregroundStyle(isSelected ? Theme.text : Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(isSelected ? type.color.opacity(0.15) : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? type.color.opacity(0.5) : Theme.border, lineWidth: 0.5))
        }
    }
}

// MARK: - EditActivitySheet

struct EditActivitySheet: View {
    @Bindable var entry: ActivityLog
    let onSave: (ModelContext) -> Void

    @Environment(\.modelContext) var ctx
    @Environment(\.dismiss) var dismiss

    @State private var selected:        ActivityType
    @State private var selectedSubtype: String?
    @State private var customName:      String
    @State private var showCustom:      Bool
    @State private var startDate:       Date
    @State private var durationMins:    Double

    private var endDate: Date { startDate.addingTimeInterval(durationMins * 60) }

    /// Bridges the non-optional slider value to the preset row's optional
    /// binding. Writing nil is a no-op — the duration always has a value here.
    private var presetBinding: Binding<Double?> {
        Binding(get: { durationMins },
                set: { if let v = $0 { durationMins = v } })
    }

    init(entry: ActivityLog, onSave: @escaping (ModelContext) -> Void) {
        self.entry  = entry
        self.onSave = onSave
        // fromStored, not rawValue — an entry logged under a since-merged type
        // ("Run", "Sauna", "Coffee") must open on its new tile, not Custom.
        let typeEnum = ActivityType.fromStored(entry.activityType)
        _selected        = State(initialValue: typeEnum)
        _selectedSubtype = State(initialValue: entry.activitySubtype)
        _customName      = State(initialValue: entry.customName ?? "")
        _showCustom      = State(initialValue: typeEnum == .custom)
        _startDate       = State(initialValue: entry.startedAt)
        let dur = entry.endedAt.map { $0.timeIntervalSince(entry.startedAt) / 60 } ?? 30
        _durationMins    = State(initialValue: max(1, min(180, dur)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    ActivityPickerSection(selected: $selected,
                                          selectedSubtype: $selectedSubtype,
                                          customName: $customName,
                                          showCustom: $showCustom)

                    VStack(spacing: 12) {
                        DatePicker("START TIME", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                            .tint(Theme.accent)

                        VStack(alignment: .leading, spacing: 8) {
                            DurationPresetRow(minutes: presetBinding,
                                              valueLabel: "\(Int(durationMins)) min")
                            Slider(value: $durationMins, in: 1...180, step: 1)
                                .tint(Theme.accent)
                        }
                    }
                    .cardStyle()
                    .padding(.horizontal)

                }
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    entry.activityType    = selected.rawValue
                    entry.activitySubtype = selectedSubtype
                    entry.customName      = (selected == .custom && !customName.isEmpty) ? customName : nil
                    entry.startedAt       = startDate
                    entry.endedAt         = endDate
                    entry.isManual        = true
                    onSave(ctx)
                    dismiss()
                } label: {
                    Text("SAVE CHANGES")
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.bg)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(selected == .custom && customName.isEmpty)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .background(Theme.bg)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(height: 0.5)
                }
            }
            .background(Theme.bg)
            .navigationTitle("EDIT ACTIVITY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }
}
