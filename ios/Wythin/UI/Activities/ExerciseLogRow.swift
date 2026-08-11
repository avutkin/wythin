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

    /// Laurels above half marks, not at the crown threshold of 85.
    ///
    /// More than half the available improvement is a genuinely good session and
    /// should feel like one; 85 is a top-sixth day, which would mean the frame
    /// almost never appears and stops reading as a reward at all. Same rule the
    /// restorative row uses, so the two celebrate in the same place.
    static let laurelThreshold = 50

    private var crowned: Bool {
        // Laurels need the score to be worth framing AND settled: a single-axis
        // 100 captioned "based on recovery alone so far" celebrating at full
        // volume is the row overpromising on one reading.
        if case let .score(value, word) = overall {
            return value >= Self.laurelThreshold && !word.contains("alone")
        }
        return false
    }


    /// The measured rise that put this session in the activating model.
    private var pulseRise: Int? {
        guard let before = beforeHR, let during = duringHR, during > before else { return nil }
        return Int((during - before).rounded())
    }

    private var beforeHR: Double? { entry.beforeHR.map(Double.init) }
    private var duringHR: Double? { entry.duringHRPeak.map(Double.init) ?? entry.duringHR.map(Double.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            hero
            SessionIndexSlotGrid(slots: entry.indexSlots, doses: entry.ungradedDoses)
            if let advice = SessionRecommendation.advice(for: entry.scoredIndices) {
                RecommendationCard(advice: advice)
            }
            viewFullSession
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

            // Which model this session got, and the measurement that decided it.
            // Two scoring systems in one list look arbitrary without it.
            if let rise = pulseRise {
                Text("PULSE ROSE \(rise) BPM")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(Color(hex: "#FFC01F"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(hex: "#FFC01F").opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    /// The score gets the room it deserves: centred, large, and framed by
    /// laurels above the threshold rather than shouted at with a crown.
    @ViewBuilder
    private var hero: some View {
        if case let .score(score, word) = overall {
            VStack(spacing: 3) {
                HStack(spacing: 10) {
                    if crowned { laurel("laurel.leading") }
                    VStack(spacing: 0) {
                        Text("\(score)")
                            .font(.system(size: 52, weight: .light, design: .rounded))
                            .foregroundStyle(crowned ? Theme.accent : Theme.text)
                            .monospacedDigit()
                        Text("SCORE / 100")
                            .font(.system(size: 8, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Theme.dim)
                    }
                    if crowned { laurel("laurel.trailing") }
                }
                Text(word)
                    .font(.system(size: 11, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(crowned ? Theme.accent : Theme.dim)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func laurel(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 44, weight: .ultraLight))
            .foregroundStyle(Theme.dim.opacity(0.55))
    }

    private var viewFullSession: some View {
        HStack(spacing: 7) {
            Text("VIEW FULL SESSION")
                .font(.system(size: 11, design: .monospaced))
                .tracking(1.2)
            Image(systemName: "chevron.right").font(.system(size: 9))
        }
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.accent.opacity(0.32), lineWidth: 0.5))
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

