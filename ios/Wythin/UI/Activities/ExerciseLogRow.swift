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

    /// The three axes, read entirely from values stored at session end.
    ///
    /// Nothing is computed here and nothing is fetched: the scores are
    /// percentiles against same-subtype history, which was resolved once when
    /// the session ended rather than once per row on every scroll.
    private var axes: [(String, AxisValue, Color)] {
        [
            ("SUPPRESSION", suppression, Theme.hrv),
            ("RECOVERY",
             ExerciseResponse.reactivationScore(dcAfter: entry.afterDC.map(Double.init),
                                                dcPre: entry.beforeDC.map(Double.init)),
             Theme.accent),
            ("EFFICIENCY", efficiency, Theme.breathe),
        ]
    }

    private var suppression: AxisValue {
        guard entry.vsiSlopePer10 != nil else { return .unavailable(reason: "no fit") }
        guard let score = entry.suppressionScore else { return .unavailable(reason: historyProgress) }
        return .score(score, word: ExerciseResponse.word(for: score))
    }

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

            if let load = entry.exerciseLoad {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(load.rounded()))")
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                    Text("LOAD")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim.opacity(0.4))
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(axes, id: \.0) { name, value, tint in
                AxisChip(name: name, value: value, tint: tint)
            }
        }
    }
}

// MARK: - AxisChip

/// One axis in the row. An unavailable axis shows an em dash and its reason —
/// never a zero, which would be indistinguishable from a real result.
struct AxisChip: View {
    let name:  String
    let value: AxisValue
    let tint:  Color

    var body: some View {
        VStack(spacing: 3) {
            Text(name)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            switch value {
            case let .score(score, word):
                Text("\(score)")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Text(word)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

            case let .unavailable(reason):
                Text("—")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text(reason)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
