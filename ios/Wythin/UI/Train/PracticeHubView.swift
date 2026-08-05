import SwiftUI
import SwiftData

// MARK: - Practices Hub
//
// Replaces the old single-screen Train view. Browse teacher-led practices by
// category, open one to Log it, or start a live biofeedback session (Resonance
// pacer / workout feedback). Content is served from the static PracticeCatalog.

struct PracticeHubView: View {
    @Environment(AppEnvironment.self) var env

    @Query(sort: \TrainSession.startedAt, order: .reverse) private var trainSessions: [TrainSession]

    @State private var filter:   PracticeState? = nil        // nil = All
    @State private var selected: Practice?      = nil
    @State private var showBLESheet             = false

    // 3-up grid of practice tiles.
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    /// Practices for the current filter. When unfiltered, Resonance is pulled
    /// out into the featured card so it isn't listed twice.
    private var visiblePractices: [Practice] {
        let all = filter.map { PracticeCatalog.practices(for: $0) } ?? PracticeCatalog.practices
        return filter == nil ? all.filter { !$0.isStarred } : all
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    categoryBar

                    if filter == nil, let resonance = PracticeCatalog.starred.first {
                        FeaturedPracticeCard(practice: resonance) { selected = resonance }
                    }

                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                        ForEach(visiblePractices) { practice in
                            Button { selected = practice } label: {
                                PracticeGridTile(practice: practice)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    teachersStrip

                    trainHistory
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("PRACTICE")
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

    // MARK: Teachers strip

    private var teachersStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TEACHERS")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(PracticeCatalog.teachers) { teacher in
                        TeacherChip(teacher: teacher)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Train history

    @ViewBuilder
    private var trainHistory: some View {
        if !trainSessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("HISTORY")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                VStack(spacing: 0) {
                    ForEach(trainSessions) { session in
                        TrainSessionRow(session: session)
                        if session.id != trainSessions.last?.id {
                            Divider().background(Theme.border).padding(.horizontal, 12)
                        }
                    }
                }
                .cardStyle()
            }
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

// MARK: - Art thumbnail

/// The shared SF-symbol-over-gradient tile used for practices and teachers.
struct ArtThumb: View {
    let art:  PracticeArt
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(art.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: art.symbol)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
            )
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
                    Image(systemName: practice.art.symbol)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                )
                .overlay(alignment: .topTrailing) { badge }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))

            Text(practice.title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(practice.defaultDurationMins) min")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
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
                        Image(systemName: practice.art.symbol)
                            .font(.system(size: 50, weight: .light))
                            .foregroundStyle(.white.opacity(0.85))
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

// MARK: - Teacher chip

private struct TeacherChip: View {
    let teacher: Teacher

    var body: some View {
        VStack(spacing: 8) {
            ArtThumb(art: teacher.art, size: 56)
            Text(teacher.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(teacher.title)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 96)
    }
}

// MARK: - Train session row

private struct TrainSessionRow: View {
    let session: TrainSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(session.durationString)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            HStack(spacing: 16) {
                Label("\(session.setCount) sets", systemImage: "bolt")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.warn)
                if session.avgRecoveryMin > 0 {
                    Label(String(format: "%.1f min avg recovery", session.avgRecoveryMin),
                          systemImage: "arrow.down.heart")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.rsa)
                }
            }

            HStack(spacing: 16) {
                Text(String(format: "SNS %.2f", session.avgSNSIndex))
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.warn.opacity(0.8))
                Text(String(format: "PNS %.2f", session.avgPNSIndex))
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent.opacity(0.8))
            }

            let recs = session.recoveryMinArray
            if !recs.isEmpty {
                Text("Sets: " + recs.map { String(format: "%.1f", $0) }.joined(separator: " → ") + " min")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}
