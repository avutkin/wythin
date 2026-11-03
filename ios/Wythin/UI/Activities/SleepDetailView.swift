import SwiftData
import SwiftUI

/// One night in full — the same structure as the Night Trace review console:
/// the honest duration pair, a transparent score with its arithmetic and the
/// points each section contributed, the five sections with their weights, and
/// the montage.
struct SleepDetailView: View {

    let entry: ActivityLog
    @Environment(\.modelContext) private var ctx
    @Environment(AppEnvironment.self) private var env

    /// Where the written read has got to. Distinct from "there is no text":
    /// a night still being read and a night whose read failed look the same on
    /// screen otherwise, and only one of them is worth waiting for.
    private enum ReadState { case idle, reading, failed }
    @State private var readState: ReadState = .idle

    /// Nil until the background load lands. The rest of the screen — the hero,
    /// the arithmetic, the sections — comes straight off the stored record and
    /// draws immediately; only the sample-derived parts wait.
    @State private var night: PreparedNight?
    /// One instant across every channel on the screen — the hypnogram, the
    /// movement strip and each section's traces. Owned here now that they are
    /// separate views rather than one montage.
    @State private var selectedX: Date?
    /// Which section rows are open. Closed by default.
    @State private var expanded: Set<SleepSection> = []

    /// The score's own working, as it was stored on the night.
    private var storedParts: [SleepSection: [SleepScore.Part]] {
        SleepScore.parts(fromJSON: entry.sleepPartsJSON)
    }

    private func hm(_ minutes: Int) -> String {
        "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    private var asleepMinutes: Int? { entry.sleepAsleepMinutes }

    private var inBedMinutes: Int? {
        entry.endedAt.map { Int($0.timeIntervalSince(entry.startedAt) / 60) }
    }

    private var window: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        guard let end = entry.endedAt else { return f.string(from: entry.startedAt) }
        return "\(f.string(from: entry.startedAt)) → \(f.string(from: end))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if let night {
                    let items = SleepHighlights.of(night, entry: entry)
                    if !items.isEmpty {
                        card("HIGHLIGHTS FROM YOUR NIGHT") {
                            SleepHighlightsCard(items: items)
                        }
                    }
                }
                nightRead
                if entry.sleepScore != nil { arithmetic }
                sections
                if let night, !night.points.isEmpty, let end = entry.endedAt {
                    // Top-down: the shape of the night, then the body that
                    // moved through it, then each section with the traces it is
                    // actually made of. The nine metrics used to sit in one
                    // strip in declaration order, which put deceleration
                    // capacity nine scrolls from the score built on it.
                    card("THE NIGHT — STAGES & MOVEMENT") {
                        SleepMontageChart(night: night,
                                          startedAt: entry.startedAt,
                                          endedAt: end,
                                          selectedX: $selectedX,
                                          showsMetrics: false)
                    }
                    stageCaveat
                    ForEach(SleepSection.allCases, id: \.self) { section in
                        if !SleepSectionCharts.metrics(for: section).isEmpty {
                            card(section.name.uppercased()) {
                                SleepSectionChartGroup(night: night, section: section,
                                                       startedAt: entry.startedAt,
                                                       endedAt: end,
                                                       selectedX: $selectedX)
                            }
                        }
                    }
                    if !SleepSectionCharts.unscored.isEmpty {
                        card("OTHER CHANNELS") {
                            VStack(alignment: .leading, spacing: 10) {
                                SleepNote("WHY THESE ARE HERE",
                                          "Recorded through the night and not scored. They are here to be read, not to move the number.")
                                SleepMetricTraces(night: night,
                                                  labels: SleepSectionCharts.unscored,
                                                  startedAt: entry.startedAt, endedAt: end,
                                                  selectedX: $selectedX)
                            }
                        }
                    }
                }
                measurementNote
            }
            .padding(18)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task {
            guard night == nil, let end = entry.endedAt else { return }
            let prepared = await PreparedNight.load(container: ctx.container,
                                                    from: entry.startedAt,
                                                    to: end)
            night = prepared
            await read(prepared)
        }
    }

    // MARK: - The written read

    /// The night in words: what it shows, and what to change tonight.
    ///
    /// Generated once and stored on the entry, so re-opening a night does not
    /// re-ask the model and cannot produce a different reading of the same
    /// numbers. The read waits for `PreparedNight` because everything worth
    /// saying — where vagal tone climbed, when Pulse bottomed out, how the
    /// night was spent lying — lives in the prepared night, not in the stored
    /// summary row.
    @ViewBuilder
    private var nightRead: some View {
        if let text = entry.sleepReadText {
            card("WHAT THIS NIGHT SHOWS") { readBody(text) }
        } else if readState == .reading {
            card("WHAT THIS NIGHT SHOWS") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the night…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
            }
        } else if readState == .failed {
            card("WHAT THIS NIGHT SHOWS") {
                Text(OnboardingConsent.aiInsights()
                     ? "Couldn't reach the coach. Open this night again when you're back online."
                     : "AI guidance is off, so this night has not been read. Turn it on in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A headline, then bullets, then the actions.
    ///
    /// The '→' lines are the point of the whole card — they are the only part
    /// a person can act on tonight — so they are set apart from the findings
    /// rather than running on as more prose.
    private func readBody(_ text: String) -> some View {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let headline = lines.first { !$0.hasPrefix("•") && !$0.hasPrefix("→") }
        let bullets  = lines.filter { $0.hasPrefix("•") }
        let actions  = lines.filter { $0.hasPrefix("→") }

        return VStack(alignment: .leading, spacing: 10) {
            if let headline {
                Text(headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(bullets, id: \.self) { line in
                // The same one-bold-span-per-bullet convention the live read
                // and the macro read use, through the same renderer.
                Text(MarkdownBullet.styled(line))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !actions.isEmpty {
                Divider().opacity(0.25).padding(.vertical, 2)
                ForEach(actions, id: \.self) { line in
                    Text(MarkdownBullet.styled(line))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ActivityType.sleep.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func read(_ prepared: PreparedNight) async {
        guard entry.sleepReadText == nil, entry.endedAt != nil else { return }
        readState = .reading
        await InsightGenerator(client: env.sync.client)
            .generate(for: entry, night: prepared, context: ctx)
        readState = entry.sleepReadText == nil ? .failed : .idle
    }

    // MARK: - Pieces

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ActivityType.sleep.icon)
                    .foregroundStyle(ActivityType.sleep.color)
                Text("SLEEP")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.9)
                Spacer()
                Text(window).font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(Theme.dim)

            Text("TIME ASLEEP")
                .font(.system(size: 13, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.dim)
            // Big number, small units — the reference's proportions.
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\((asleepMinutes ?? 0) / 60)")
                    .font(.system(size: 46, weight: .regular))
                Text("h").font(.system(size: 24, weight: .regular)).foregroundStyle(Theme.dim)
                Text(" \(String(format: "%02d", (asleepMinutes ?? 0) % 60))")
                    .font(.system(size: 46, weight: .regular))
                Text("m").font(.system(size: 24, weight: .regular)).foregroundStyle(Theme.dim)
            }
            .foregroundStyle(Theme.text)
            // The pair, not the single number. The gap between them is the part
            // of the night spent awake, which is the disclosure most sleep UIs
            // quietly drop.
            if let inBed = inBedMinutes {
                Text("Total duration \(hm(inBed))")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.dim)
            }
            if let stages = entry.sleepStageSummary {
                Text(stages)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 2)
            }
        }
    }

    /// The night score, and the four numbers it is the sum of.
    ///
    /// The arithmetic used to be one monospaced sentence with the weights
    /// inlined — readable only by someone already willing to parse it, and the
    /// score itself was nowhere on the screen at a size that said "this is the
    /// headline". Now the total is the biggest thing in the card and each
    /// section shows its own score, its weight beside it, and the points that
    /// multiplication actually contributed. The sum of the right-hand column
    /// is the number at the top, which is the whole claim being made.
    private var arithmetic: some View {
        card("THE NIGHT SCORE") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(entry.sleepScore ?? 0)")
                        .font(.system(size: 56, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text("/ 100")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.dim)
                    Spacer()
                }
                Text("Four sections, each worth a quarter. Every one is scored against your own baseline, never a population threshold.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 9) { contributionRows }

                if let line = entry.sleepScoreArithmetic {
                    SleepNote("THE ARITHMETIC", line)
                }
            }
        }
    }

    /// One row per section: its score, its weight, its bar and its points.
    @ViewBuilder
    private var contributionRows: some View {
        let rows = sectionRows
        ForEach(rows, id: \.section) { row in
            HStack(spacing: 8) {
                Text(row.section.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 76, alignment: .leading)
                // The section's own score, with its weight underneath rather
                // than beside it — the two are different kinds of number and
                // running them together on one line reads as one.
                VStack(alignment: .trailing, spacing: 0) {
                    Text(row.score.map { "\($0)" } ?? "—")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text("×\(Int(row.section.weight * 100))%")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.8))
                }
                .frame(width: 34, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface).frame(height: 6)
                        Capsule()
                            .fill(ActivityType.sleep.color)
                            .frame(width: geo.size.width * (Double(row.score ?? 0) / 100),
                                   height: 6)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 10)
                Text(row.score.map { String(format: "%.1f", row.section.weight * Double($0)) } ?? "—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    private var sectionRows: [(section: SleepSection, score: Int?)] {
        [(.timing, entry.sleepTiming), (.duration, entry.sleepDuration),
         (.continuity, entry.sleepContinuity), (.autonomic, entry.sleepAutonomic)]
    }

    /// Each row opens to say what it measures, what the evidence for weighting
    /// it is, and where it is weak. Closed by default: the score is the answer,
    /// and five paragraphs above it would bury the thing being explained.
    private var sections: some View {
        card("SECTIONS") {
            VStack(spacing: 0) {
                ForEach(Array(zip(entry.indexSlots, SleepSection.allCases)), id: \.1) { slot, section in
                    sectionRow(slot, section)
                    Divider().opacity(0.25)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionRow(_ slot: (name: String, index: ScoredIndex?, whenEmpty: String),
                            _ section: SleepSection) -> some View {
        let open = expanded.contains(section)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if open { expanded.remove(section) } else { expanded.insert(section) }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(slot.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.dim)
                                .rotationEffect(.degrees(open ? 180 : 0))
                        }
                        Text(slot.index?.detail ?? slot.whenEmpty)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    if let index = slot.index {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(index.value)")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.text)
                            Text(index.verdict)
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.dim)
                        }
                    } else {
                        // Absent, not zero. A section with no input has not
                        // been measured; showing 0 would read as a verdict.
                        Text("not measured")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 12) {
                    let parts = storedParts[section] ?? []
                    if parts.isEmpty {
                        explainRow("MEASURES", section.explanation.measures)
                    } else {
                        // The measurements first: what was measured, the range
                        // it is read against, and where tonight sat. "Why 26?"
                        // is answered by the picture, not by the paragraph.
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                                SleepPartBar(part: p)
                            }
                        }
                    }
                    explainRow("WHERE IT IS WEAK", section.explanation.limit)
                }
                .padding(.bottom, 14)
            }
        }
    }

    private func explainRow(_ label: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Theme.dim.opacity(0.8))
            Text(body)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stageCaveat: some View {
        SleepNote("HOW THE STAGES WERE READ", "N2 and N3 are measured — the depth axis is coherence, variability and heart rate, ranked within this night. N1 is positional: it marks the light sleep either side of a wake bout, which is what N1 physiologically is. ECG quality is not the limit here (86% of ticks top-tier, invalid-RR 0.0); N1 simply has no cardiac signature — human scorers reading EEG agree on it at κ 0.24. Stage totals are cut at typical adult shares, so read the shape rather than the minutes.")
    }

    private var measurementNote: some View {
        SleepNote("HOW THIS WAS MEASURED",
                  "Three states, not four. The light/deep boundary is the one a cardiac signal places worst, so it is not claimed. Wake is the least reliable channel any wearable has — treat the awake minutes as approximate.\n\n"
                  + "Breathing steadiness comes from how tightly your breath rate holds its own rhythm, measured on a rolling five-minute window. It is not an apnea index and carries no event rate.\n\n"
                  + "Body position is read from the direction of gravity in the strap's accelerometer, and appears on nights recorded from now on. Earlier nights collapsed the three axes to a rotation-invariant magnitude before storing, so supine and on-your-side were literally identical on disk and cannot be recovered. Left versus right depends on which way round the strap was fastened; supine, prone and upright do not.")
    }

    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.dim)
            content()
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

}
