import SwiftUI

// MARK: - ExerciseLogRow

/// One activating session in the Activities list.
///
/// Where a restorative row shows nine benefit percentages, an exercise row
/// shows Load — the size of the stimulus — and three axes that each point the
/// same way. There is no overall percentage, because averaging the axes is
/// exactly what made a hard session read as a bad one.
struct ExerciseLogRow: View {
    let entry: ActivityLog

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let start = fmt.string(from: entry.startedAt)
        if let end = entry.endedAt {
            return "\(start)–\(fmt.string(from: end))"
        }
        return start
    }

    private var suppression: AxisValue { entry.suppressionAxis }

    private var efficiency: AxisValue {
        // The absence that matters most: chest motion does not measure barbell
        // work, so lifting and yoga say so rather than borrowing heart rate —
        // which would print Suppression's number twice under a second name.
        guard entry.hasExternalWorkSignal else { return .unavailable(reason: "no ext. signal") }
        guard entry.efficiencySlope != nil else { return .unavailable(reason: "no fit") }
        guard let score = entry.efficiencyScore else { return .unavailable(reason: historyProgress) }
        return .score(score, word: ExerciseResponse.word(for: score))
    }

    /// "2 of 3" — how close this subtype is to having a comparable baseline.
    private var historyProgress: String {
        "\((entry.scoreHistoryCount ?? 0) + 1) of \(ExerciseResponse.minimumHistory)"
    }

    /// The headline score, from the three axes only — never from Load.
    private var overall: AxisValue {
        ExerciseOverallScore.compute(suppression: suppression,
                                     recovery: entry.recoveryAxis,
                                     efficiency: efficiency)
    }

    private var crowned: Bool { ExerciseOverallScore.earnsCrown(overall) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            chips
        }
        .padding(.vertical, 7)
    }

    private var header: some View {
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
                        Text("LIVE")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.warn)
                    } else {
                        Text(entry.durationString)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }

            Spacer()

            if case let .score(score, _) = overall {
                // Labelled, like everything else on this row. An unlabelled
                // number beside three labelled ones reads as a fourth unit.
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(spacing: 3) {
                        if crowned {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: "#FFC01F"))
                        }
                        Text("\(score)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(crowned ? Color(hex: "#FFC01F") : Theme.text)
                            .monospacedDigit()
                    }
                    Text("SCORE / 100")
                        .font(.system(size: 7.5, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim.opacity(0.4))
        }
    }

    /// The scored grid replaced the chip strip. The chips carried each reading
    /// in its own unit, so a reader had to already know whether 0.09 ms/beat
    /// was good; an index on one scale, with a band and a verdict, says so.
    @ViewBuilder
    private var chips: some View {
        let scored = entry.scoredIndices
        if !scored.isEmpty {
            SessionIndexGrid(indices: scored, doses: entry.ungradedDoses)
            if let advice = SessionRecommendation.advice(for: scored) {
                RecommendationCard(advice: advice)
            }
        }
    }
}

// MARK: - RecommendationCard

/// One thing to do next time, derived from the weakest index.
///
/// The action leads and the reasoning follows. The coach card this replaces
/// opened with a diagnosis and buried the instruction — and, being generated,
/// could contradict the score printed beside it. This cannot: it is a pure
/// function of the numbers above it.
struct RecommendationCard: View {

    let advice: SessionRecommendation.Advice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(advice.action)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)
            Text(advice.because)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.9))
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.accent.opacity(0.2), lineWidth: 0.5))
    }
}

