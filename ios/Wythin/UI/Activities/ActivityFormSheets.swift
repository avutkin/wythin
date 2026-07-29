import SwiftUI
import SwiftData

// MARK: - StartActivitySheet

struct StartActivitySheet: View {
    var preselected: ActivityType? = nil
    let onStart: (ActivityType, String?, String?) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var selected:         ActivityType
    @State private var selectedSubtype:  String?      = nil
    @State private var customName:       String       = ""
    @State private var showCustom:       Bool         = false

    init(preselected: ActivityType? = nil, onStart: @escaping (ActivityType, String?, String?) -> Void) {
        self.preselected = preselected
        self.onStart     = onStart
        _selected  = State(initialValue: preselected ?? .meditation)
        _showCustom = State(initialValue: preselected == .custom)
    }

    private var startLabel: String {
        if let sub = selectedSubtype { return sub.uppercased() }
        if selected == .custom { return customName.isEmpty ? "CUSTOM" : customName.uppercased() }
        return selected.rawValue.uppercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ActivityPickerSection(selected: $selected,
                                          selectedSubtype: $selectedSubtype,
                                          customName: $customName,
                                          showCustom: $showCustom)

                    Button {
                        let name = selected == .custom && !customName.isEmpty ? customName : nil
                        onStart(selected, selectedSubtype, name)
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("START \(startLabel)")
                        }
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.bg)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal)
                    .disabled(selected == .custom && customName.isEmpty)
                }
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
            .background(Theme.bg)
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
        _durationMins    = State(initialValue: prefill.durationMins ?? 30)
    }

    private var endDate: Date { startDate.addingTimeInterval(durationMins * 60) }

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

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("DURATION")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                Spacer()
                                Text("\(Int(durationMins)) min")
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.accent)
                            }
                            Slider(value: $durationMins, in: 1...180, step: 1)
                                .tint(Theme.accent)
                        }
                    }
                    .cardStyle()
                    .padding(.horizontal)

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
                    .padding(.horizontal)
                    .disabled(selected == .custom && customName.isEmpty)
                }
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
            .background(Theme.bg)
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

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ActivityType.allCases, id: \.self) { type in
                    ActivityTypeCell(type: type, isSelected: selected == type) {
                        selected = type
                        selectedSubtype = nil
                        showCustom = (type == .custom)
                    }
                }
            }
            .padding(.horizontal)

            SubtypePicker(type: selected, selected: $selectedSubtype)
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

// MARK: - SubtypePicker

struct SubtypePicker: View {
    let type:     ActivityType
    @Binding var selected: String?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SUBTYPE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                if selected != nil {
                    Button("clear") { selected = nil }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.5))
                }
            }

            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(type.subtypes, id: \.self) { sub in
                    Button {
                        selected = selected == sub ? nil : sub
                    } label: {
                        Text(sub)
                            .font(Theme.monoLabel)
                            .foregroundStyle(selected == sub ? Theme.bg : type.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(selected == sub ? type.color : type.color.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selected == sub ? .clear : type.color.opacity(0.25), lineWidth: 0.5))
                    }
                }
            }
        }
        .cardStyle()
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

    init(entry: ActivityLog, onSave: @escaping (ModelContext) -> Void) {
        self.entry  = entry
        self.onSave = onSave
        let typeEnum = ActivityType(rawValue: entry.activityType) ?? .custom
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

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("DURATION")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                Spacer()
                                Text("\(Int(durationMins)) min")
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.accent)
                            }
                            Slider(value: $durationMins, in: 1...180, step: 1)
                                .tint(Theme.accent)
                        }
                    }
                    .cardStyle()
                    .padding(.horizontal)

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
                    .padding(.horizontal)
                    .disabled(selected == .custom && customName.isEmpty)
                }
                .padding(.top, 16)
                .padding(.bottom, 30)
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
