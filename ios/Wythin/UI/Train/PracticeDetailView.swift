import SwiftUI

// MARK: - Practice Detail
//
// Opened from the hub. Shows the practice hero, meta and description, then
// dispatches actions on the practice's kind:
//   .content                 → Log it (prefilled)
//   .pacer                   → Start the guided breath session + Log it
//   .biofeedback(.resonance) → Start Resonance pacer  + Log it
//   .biofeedback(.workout)   → Start live workout feedback + Log it

struct PracticeDetailView: View {
    let practice: Practice

    @Environment(\.modelContext) var ctx
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss

    @State private var showLogSheet    = false
    @State private var showResonance   = false
    @State private var showBiofeedback = false
    @State private var showPacer       = false
    @State private var showHold        = false
    @State private var showScripted    = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    metaRow
                    if !practice.states.isEmpty { stateRow }
                    if !practice.tags.isEmpty { tagRow }
                    Text(practice.description)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 10) { actions }
                        .padding(.top, 4)

                    if !practice.howItWorks.isEmpty { howItWorks }
                    if !practice.evidence.isEmpty   { evidence }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .sheet(isPresented: $showLogSheet) {
            LogPastSheet(prefill: ActivityPrefill(type: practice.activityType,
                                                  subtype: practice.subtype,
                                                  durationMins: Double(practice.defaultDurationMins))) {
                type, subtype, name, start, end in
                ActivityLogging.logPast(type: type, subtype: subtype, customName: name,
                                        start: start, end: end,
                                        context: ctx, client: env.sync.client)
            }
        }
        .fullScreenCover(isPresented: $showResonance) {
            ResonanceSessionView()
        }
        .fullScreenCover(isPresented: $showBiofeedback) {
            BiofeedbackSessionView(activityType: practice.activityType,
                                   subtype: practice.subtype)
        }
        .fullScreenCover(isPresented: $showPacer) {
            BoxBreathingSessionView(practice: practice)
        }
        .fullScreenCover(isPresented: $showHold) {
            HoldSessionView(practice: practice)
        }
        .fullScreenCover(isPresented: $showScripted) {
            ScriptedBreathSessionView(practice: practice)
        }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            practice.art.gradient
                .overlay(
                    practice.art.glyph(size: 60, opacity: 0.85)
                )
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .center, endPoint: .bottom)
                )

            VStack(alignment: .leading, spacing: 5) {
                if practice.isStarred {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill").font(.system(size: 10))
                        Text("FEATURED").font(Theme.monoLabel)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.25), in: Capsule())
                }
                Text(practice.title)
                    .font(Theme.display(26))
                    .foregroundStyle(.white)
                Text(practice.subtitle)
                    .font(Theme.monoBody)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Meta + tags

    private var metaRow: some View {
        HStack(spacing: 16) {
            metaItem(icon: "clock", text: "\(practice.defaultDurationMins) min")
            metaItem(icon: practice.activityType.icon,
                     text: practice.subtype ?? practice.activityType.rawValue)
            metaItem(icon: "square.grid.2x2", text: practice.category.label)
            Spacer()
        }
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.accent)
            Text(text).font(Theme.monoLabel).foregroundStyle(Theme.dim)
        }
    }

    /// What this practice is *for*. The hub filters on these, so they belong on
    /// the detail screen too — otherwise the reason a practice showed up under a
    /// state is invisible once you open it.
    private var stateRow: some View {
        HStack(spacing: 8) {
            ForEach(practice.states) { state in
                HStack(spacing: 5) {
                    Image(systemName: state.icon).font(.system(size: 10))
                    Text(state.label)
                }
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.accent.opacity(0.12))
                .clipShape(Capsule())
            }
            Spacer()
        }
    }

    private var tagRow: some View {
        HStack(spacing: 8) {
            ForEach(practice.tags, id: \.self) { tag in
                Text(tag)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.breathe)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.breathe.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch practice.kind {
        case .content:
            actionButton(title: "Log it", icon: "checkmark.circle", filled: true) {
                showLogSheet = true
            }
        case .biofeedback(.resonance):
            actionButton(title: "Start Resonance", icon: "sparkles", filled: true) {
                showResonance = true
            }
            actionButton(title: "Log it", icon: "checkmark.circle", filled: false) {
                showLogSheet = true
            }
        case .biofeedback(.workout):
            actionButton(title: "Start Session", icon: "waveform.path.ecg", filled: true) {
                showBiofeedback = true
            }
            actionButton(title: "Log it", icon: "checkmark.circle", filled: false) {
                showLogSheet = true
            }
        case .pacer:
            actionButton(title: "Start \(practice.title)", icon: "play.fill", filled: true) {
                showPacer = true
            }
            actionButton(title: "Log it", icon: "checkmark.circle", filled: false) {
                showLogSheet = true
            }
        case .scripted:
            actionButton(title: "Start \(practice.title)", icon: "play.fill", filled: true) {
                showScripted = true
            }
            actionButton(title: "Log it", icon: "checkmark.circle", filled: false) {
                showLogSheet = true
            }
        case .holdTrainer:
            actionButton(title: "Set up \(practice.title)", icon: "timer", filled: true) {
                showHold = true
            }
            actionButton(title: "Log it", icon: "checkmark.circle", filled: false) {
                showLogSheet = true
            }
        }
    }

    private func actionButton(title: String, icon: String, filled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(Theme.mono(15))
            .fontWeight(.medium)
            .foregroundStyle(filled ? Theme.bg : Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(filled ? Theme.accent : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(filled ? Color.clear : Theme.accent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: How it works

    /// The mechanism, above the papers. Someone deciding whether to spend ten
    /// minutes on this wants to know what it does to them before they want a
    /// citation list.
    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("HOW IT WORKS", icon: "waveform.path.ecg")

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(practice.howItWorks.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(Theme.accent.opacity(0.7))
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(line)
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
        }
        .padding(.top, 8)
    }

    // MARK: Evidence

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("EVIDENCE", icon: "text.document")

            VStack(spacing: 10) {
                ForEach(practice.evidence) { study in
                    EvidenceCard(study: study)
                }
            }

            Text("Findings are summarised as reported. Tap a study to read it in full.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .tracking(1)
        }
    }
}

// MARK: - Evidence card

/// One study, tappable through to the paper at its DOI.
///
/// The coloured monogram stands in for the journal's own mark — publisher logos
/// are their trademarks, and shipping them would be borrowing someone's badge to
/// vouch for us.
private struct EvidenceCard: View {
    let study: PracticeEvidence

    var body: some View {
        Link(destination: study.url) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Text(study.mark)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color(hex: study.tint).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(study.journal)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("\(study.authors) · \(String(study.year))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.dim)
                }

                Text(study.title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                Text(study.finding)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
