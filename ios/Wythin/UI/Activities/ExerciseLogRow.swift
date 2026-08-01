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
    /// Only axes that actually have something to report.
    ///
    /// Two dashes out of three told the reader nothing except that the app was
    /// unsure, so an axis with no value is now left out rather than displayed
    /// empty. Every surviving chip carries its unit: a bare "30" beside a bare
    /// "58" is unreadable when one is a percentage and the other is not.
    private var axes: [(title: String, value: String, unit: String, tint: Color)] {
        var out: [(String, String, String, Color)] = []

        if let brake = brakePerBeat {
            out.append(("VAGAL BRAKE GIVEN UP", String(format: "%.2f", brake),
                        "ms per extra bpm", Theme.hrv))
        }
        if let pct = recoveryPercent {
            out.append(("VAGAL TONE BACK", "\(pct)%", "of resting, at 10 min", Theme.accent))
        }
        if let load = entry.exerciseLoad {
            out.append(("LOAD", "\(Int(load.rounded()))", "effort × time", Theme.rsa))
        }
        return out.map { ($0.0, $0.1, $0.2, $0.3) }
    }

    /// ΔDC per extra bpm — the index itself, in units, rather than a percentile.
    private var brakePerBeat: Double? {
        ExerciseSuppression.brakePerBeat(dcPre: entry.beforeDC.map(Double.init),
                                         dcDuring: entry.duringDC.map(Double.init),
                                         hrPre: entry.beforeHR.map(Double.init),
                                         hrDuring: entry.duringHR.map(Double.init))
    }

    private var recoveryPercent: Int? {
        guard let after = entry.afterDC.map(Double.init),
              let pre = entry.beforeDC.map(Double.init), pre > 0 else { return nil }
        return Int((min(max(after / pre * 100, 0), 100)).rounded())
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

    /// The headline score, from the three axes only — never from Load.
    private var overall: AxisValue {
        ExerciseOverallScore.compute(suppression: suppression,
                                     recovery: ExerciseResponse.reactivationScore(
                                        dcAfter: entry.afterDC.map(Double.init),
                                        dcPre: entry.beforeDC.map(Double.init)),
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

    @ViewBuilder
    private var chips: some View {
        let items = axes
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.title) { item in
                    AxisChip(name: item.title, value: item.value,
                             unit: item.unit, tint: item.tint)
                }
            }
        }
    }
}

// MARK: - AxisChip

/// One axis in the row. An unavailable axis shows an em dash and its reason —
/// never a zero, which would be indistinguishable from a real result.
struct AxisChip: View {
    let name:  String
    let value: String
    let unit:  String
    let tint:  Color

    var body: some View {
        VStack(spacing: 3) {
            Text(name)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(unit)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
