import SwiftUI

// MARK: - Practices Hub
//
// Browse practices by the state they serve, and open one to start it. Content is
// served from the static PracticeCatalog.

struct PracticeHubView: View {
    @Environment(AppEnvironment.self) var env

    @State private var filter:   PracticeState? = nil        // nil = All
    @State private var selected: Practice?      = nil
    @State private var showBLESheet             = false

    // 3-up grid of practice tiles.
    // .top so a two-line title doesn't push its neighbour's art down the row.
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    /// Practices for the current filter. When unfiltered, Resonance is pulled
    /// out into the featured card so it isn't listed twice.
    private var visiblePractices: [Practice] {
        let all = filter.map { PracticeCatalog.practices(for: $0) } ?? PracticeCatalog.practices
        return filter == nil ? all.filter { !$0.isStarred } : all
    }

    /// The visible practices under their mechanism, in the order a protocol
    /// would run them: the control first, then by how well established the
    /// mechanism is, with the two that need care last.
    private var groupedPractices: [(mechanism: BreathMechanism, practices: [Practice])] {
        Dictionary(grouping: visiblePractices, by: { $0.passport.mechanism })
            .map { (mechanism: $0.key, practices: $0.value) }
            .sorted { $0.mechanism.rank < $1.mechanism.rank }
    }

    private func mechanismHeader(_ mechanism: BreathMechanism) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(mechanism.label.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Theme.text)
                if mechanism == .co2Accumulation || mechanism == .hyperventilation {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.warn)
                }
                Spacer(minLength: 0)
            }
            Text(mechanism.summary)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    categoryBar

                    if filter == nil, let resonance = PracticeCatalog.starred.first {
                        FeaturedPracticeCard(practice: resonance) { selected = resonance }
                    }

                    // Grouped by what the practice DOES, not by the state it is
                    // sold for. An undifferentiated grid of eighteen tiles put
                    // Coherent Breathing next to 4-7-8 with nothing to say that
                    // one runs at six cycles a minute on an open airway and the
                    // other at three with a seven-count hold — different
                    // mechanisms, filed together because both read as "calm".
                    ForEach(groupedPractices, id: \.mechanism) { group in
                        VStack(alignment: .leading, spacing: 9) {
                            mechanismHeader(group.mechanism)
                            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                                ForEach(group.practices) { practice in
                                    Button { selected = practice } label: {
                                        PracticeGridTile(practice: practice)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("LIBRARY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BLENavButton(state: env.ble.state,
                                 bpm: env.latestTick?.meanBPM) {
                        showBLESheet = true
                    }
                }
            }
            .sheet(isPresented: $showBLESheet) {
                BLEConnectionSheet(ble: env.ble)
            }
            .sheet(item: $selected) { practice in
                PracticeDetailView(practice: practice)
            }
        }
    }

    // MARK: Category bar

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryCapsule(label: "All", isSelected: filter == nil) { filter = nil }
                ForEach(PracticeState.allCases) { state in
                    CategoryCapsule(label: state.chip, isSelected: filter == state) {
                        filter = (filter == state) ? nil : state
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

}

// MARK: - Category capsule

private struct CategoryCapsule: View {
    let label:      String
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(Theme.monoLabel)
                .foregroundStyle(isSelected ? Theme.bg : Theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.card)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Practice grid tile

/// Compact tile for the 3-up practices grid: a square gradient art thumbnail
/// (with a ★ / biofeedback badge) above a two-line title and duration.
private struct PracticeGridTile: View {
    let practice: Practice

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            practice.art.gradient
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    practice.art.glyph(size: 26)
                )
                .overlay(alignment: .topTrailing) { badge }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))

            Text(practice.title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                // Both lines always reserved, so the duration under a one-line
                // title still sits level with its neighbours'.
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            // Minutes, then the rate. The rate is the one that decides what
            // this practice can honestly be compared with.
            Text("\(practice.defaultDurationMins) min")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Text(practice.passport.rate.label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.breathe.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var badge: some View {
        if practice.isStarred {
            badgeIcon("star.fill", Theme.accent)
        } else if practice.isBiofeedback {
            badgeIcon("waveform.path.ecg", Theme.breathe)
        } else if practice.breathPattern != nil {
            badgeIcon("metronome", Theme.breathe)
        } else if practice.holdProtocol != nil {
            badgeIcon("timer", Theme.warn)
        }
    }

    private func badgeIcon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(color.opacity(0.9), in: Circle())
            .padding(6)
    }
}

// MARK: - Featured card

private struct FeaturedPracticeCard: View {
    let practice: Practice
    let action:   () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                practice.art.gradient
                    .overlay(
                        practice.art.glyph(size: 50, opacity: 0.85)
                    )
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill").font(.system(size: 10))
                            Text("FEATURED").font(Theme.monoLabel)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.25), in: Capsule())
                        .padding(12)
                    }
                    .frame(height: 118)
                    .frame(maxWidth: .infinity)
                    .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(practice.title)
                        .font(Theme.mono(18))
                        .foregroundStyle(Theme.text)
                    Text(practice.subtitle)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.dim)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
