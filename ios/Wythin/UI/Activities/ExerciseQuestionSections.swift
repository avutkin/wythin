import SwiftUI

/// The activating session read as five questions in the order they happened.
///
/// Grouping by question rather than listing metrics alphabetically is what
/// makes the screen an account of the session instead of an inventory of it:
/// how you arrived, how fast you switched on, where the work sat, how quickly
/// it came back, and what it cost.
struct ExerciseQuestionSections: View {

    let entry: ActivityLog

    /// The session's samples, so the recovery curves can be drawn where the
    /// recovery number lives rather than in a card further down the page.
    let points: [MetricsHistoryPoint]
    /// The recovery card's window — four hours past the end, the span the
    /// stored vagal rebound was scored over. Falls back to `points` when it has
    /// not loaded yet, so the card never renders off a window narrower than the
    /// number printed above it.
    var recoveryPoints: [MetricsHistoryPoint] = []
    let windowEnd: Date

    var body: some View {
        VStack(spacing: 12) {
            ready
            mobilised
            sustained
            recovered
            cost
        }
    }

    // MARK: ⓪ Ready

    @ViewBuilder
    private var ready: some View {
        if let index = entry.readinessIndex {
            QuestionCard(number: "0", title: "READY", subtitle: "how you arrived") {
                IndexHeadline(value: index.value, label: "readiness", tint: Theme.hrv)
                Logic("""
                Scored from the five minutes before you started — your beat-to-beat \
                variability, resting pulse and vagal brake — each against where it sits \
                in your own recent range, then averaged. \(index.detail). It is the only \
                reading on this screen you could still have acted on.
                """)
                Callout(readyWords(index.value))
            }
        }
    }

    private func readyWords(_ value: Int) -> String {
        switch IndexBand.of(value) {
        case .keep:    return "You arrived **prepared** — near the top of your own range. What follows is about the work, not about how you turned up."
        case .improve: return "You arrived in your **usual** state. Nothing here explains the session away either direction."
        case .act:     return "You arrived **under-recovered** for you. Read the rest with that in mind: a costly session on a day like this is expected, not a warning."
        }
    }

    // MARK: ① Mobilised

    @ViewBuilder
    private var mobilised: some View {
        if let peak = entry.duringHRPeak, let before = entry.beforeHR {
            QuestionCard(number: "1", title: "MOBILISED", subtitle: "how fast, how far") {
                if let idx = entry.mobilizedIndex {
                    IndexHeadline(value: idx.value, label: "mobilization", tint: Theme.accent)
                }
                Tiles([
                    ("Pulse rise", "\(Int((Double(peak) - Double(before)).rounded()))", "bpm", "over resting"),
                    ("Peak", "\(Int(Double(peak).rounded()))", "bpm", "highest reached"),
                    ("Resting", "\(Int(Double(before).rounded()))", "bpm", "before you began"),
                ])
                Logic("""
                Scored on how far you rose to meet the load: a 15 bpm rise — the floor for \
                counting as exercise — is 0, a full 60 bpm mobilization is 100. Upgrades to \
                true onset SPEED once the beat-by-beat series is stored.
                """)
            }
        }
    }

    // MARK: ② Sustained

    @ViewBuilder
    private var sustained: some View {
        if !entry.zoneSplit.isEmpty || entry.duringDFA1 != nil {
            QuestionCard(number: "2", title: "SUSTAINED", subtitle: "where the work sat") {
                if let idx = entry.sustainedIndex {
                    IndexHeadline(value: idx.value, label: "sustained — systems agree", tint: Theme.accent)
                }
                Text("HOW MUCH you did stays ungraded — this scores how COHERENTLY you held it")
                    .font(.system(size: 7.5, design: .monospaced)).tracking(0.5)
                    .foregroundStyle(Theme.dim)
                if !entry.zoneSplit.isEmpty {
                    HeartRateZoneBar(split: entry.zoneSplit)
                }
                if let dfa = entry.duringDFA1 {
                    Logic("""
                    DFA alpha-1 held at **\(String(format: "%.2f", dfa))** through the work. \
                    Under 0.50 is the severe domain, 0.50 to 0.75 heavy, above 0.75 moderate — \
                    a read on which system was taxed, which is a different question from how \
                    hard your heart was beating.
                    """)
                }
            }
        }
    }

    // MARK: ③ Recovered

    @ViewBuilder
    private var recovered: some View {
        // The card no longer depends on there being a score. A session with one
        // checkpoint has no number the app can defend, but it still has curves
        // worth looking at — and hiding the whole section would take the
        // evidence away along with the verdict.
        if entry.bounceBackIndex != nil || heartRateMoved || vagalMoved {
            QuestionCard(number: "3", title: "RECOVERED", subtitle: "how fast it came back") {
                // Top-down: the verdict, the two times behind it, the picture of
                // each time, then the working. The hero used to be a time —
                // minutes until both channels were home together — with the
                // 0–100 index a level down; that put three definitions of
                // "recovered" above the score, and the reader had to find it.
                if let index = entry.bounceBackIndex, let composite = entry.recoveryComposite {
                    IndexHeadline(value: index.value,
                                  label: "recovery · \(composite.firmness.label)",
                                  tint: Theme.accent)
                } else {
                    Text("NOT ENOUGH CHECKPOINTS YET TO SCORE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Theme.domainHeavy)
                    Text("Recovery is read from several checkpoints arriving over the hour after you stop. One on its own is a reading, not a score — so the measurements are below and the number waits.")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                returnRows

                // Heart rate first, the brake second — the order they come
                // home in, so the two curves read as the story the sentence
                // under them tells.
                curve("HEART RATE", channel: .heartRate,
                      returned: heartRateHome,
                      pre: entry.beforeHR, extreme: entry.duringHRPeak,
                      note: hrNote)

                curve("VAGAL BRAKE", channel: .vagalBrake,
                      returned: vagalHome,
                      pre: entry.beforeDC, extreme: entry.duringDCTrough,
                      note: dcNote)

                if let finding = gapSentence {
                    // The finding neither curve shows alone.
                    Text(finding)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let composite = entry.recoveryComposite {
                    Divider().overlay(Theme.border)
                    checkpointBreakdown(composite)
                }

                Logic("""
                The score is a weighted mean of the checkpoints that have arrived, renormalised \
                over those present — **a checkpoint that has not landed is absent, never zero**, \
                and one on its own never becomes the score. The two timing checkpoints are scored \
                at halfway back, because a full return often falls outside the recording; the \
                times above and the curves are the full return, to within a tenth of resting. \
                Heart rate is routinely home while vagal tone is still well down, so the two \
                channels carry equal weight and the gap between them stays visible rather than \
                being averaged away. Under 12 bpm in the first minute is flagged in the \
                literature, 20–30 healthy, 30–50 well-trained — from standardised treadmill \
                tests, so a band to sit inside rather than a verdict. Autonomic recovery only: \
                muscular recovery is not visible to a chest strap.
                """)
            }
        }
    }

    /// Deceleration Capacity, named — the card used to say "vagal rebound" and
    /// leave the reader to guess whether that meant RMSSD or DC.
    private var dcNote: String {
        let base = "Deceleration Capacity (DC), in milliseconds — not RMSSD. DC is the vagal brake "
        + "measured by phase-rectified signal averaging (Bauer, Lancet 2006); after exercise it "
        + "reactivates over minutes to hours, which is why this is reported as a TIME rather than "
        + "a level (Stanley, Peake & Buchheit, Sports Medicine 2013)."
        guard !vagalMoved else { return base }
        return base + " The return is timed against how far the brake FELL, so a session that "
        + "barely dipped it is left unscored rather than credited with an instant recovery."
    }

    private var hrNote: String {
        "The same arc, in heart rate. It needs only heart rate, so it works on sessions where "
        + "vagal tone cannot be measured at all — and it is the better validated of the two, "
        + "with test-retest ICC up to 0.99."
    }

    /// One labelled recovery curve. Absent rather than empty when the level it
    /// would be measured against was never established.
    @ViewBuilder
    private func curve(_ title: String,
                       channel: RecoveryCurveChart.Channel,
                       returned: RecoveryTiming.Outcome,
                       pre: Float?,
                       extreme: Float?,
                       note: String) -> some View {
        let curvePoints = recoveryPoints.isEmpty ? points : recoveryPoints
        if pre != nil, extreme != nil, !curvePoints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Theme.dim)
                RecoveryCurveChart(points: curvePoints,
                                   startedAt: entry.startedAt,
                                   endedAt: windowEnd,
                                   channel: channel,
                                   returned: returned,
                                   dcPre: pre,
                                   extreme: extreme)
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    // MARK: Back to resting

    /// One channel after the session, in minutes since it ended — the same
    /// samples the curve is drawn from, so the time and the picture cannot
    /// disagree.
    private func after(_ channel: KeyPath<MetricsHistoryPoint, Float?>)
        -> [(minutes: Double, value: Double)] {
        (recoveryPoints.isEmpty ? points : recoveryPoints)
            .filter { $0.timestamp > windowEnd }
            .compactMap { p in
                p[keyPath: channel].map {
                    (minutes: p.timestamp.timeIntervalSince(windowEnd) / 60, value: Double($0))
                }
            }
    }

    /// Minutes until heart rate was back inside a tenth of resting.
    private var heartRateHome: RecoveryTiming.Outcome {
        RecoveryTiming.returnToResting(after(\.meanBPM),
                                       pre: entry.beforeHR.map(Double.init),
                                       extreme: entry.duringHRPeak.map(Double.init),
                                       direction: .downward)
    }

    /// Minutes until the vagal brake was back inside a tenth of resting.
    private var vagalHome: RecoveryTiming.Outcome {
        RecoveryTiming.returnToResting(after(\.dc),
                                       pre: entry.beforeDC.map(Double.init),
                                       extreme: entry.duringDCTrough.map(Double.init),
                                       direction: .upward)
    }

    /// The two times the score is an account of: heart rate coming down, the
    /// brake coming back up. Each with where it went and where it returned to,
    /// so the time is never read without the excursion it was timed across.
    @ViewBuilder
    private var returnRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            returnRow("HEART RATE", verb: "came down", outcome: heartRateHome,
                      moved: heartRateMoved,
                      from: entry.duringHRPeak, to: entry.beforeHR, unit: "bpm", decimals: 0)
            returnRow("VAGAL BRAKE", verb: "came back", outcome: vagalHome,
                      moved: vagalMoved,
                      from: entry.duringDCTrough, to: entry.beforeDC, unit: "ms", decimals: 1)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func returnRow(_ name: String, verb: String,
                           outcome: RecoveryTiming.Outcome, moved: Bool,
                           from: Float?, to: Float?, unit: String, decimals: Int) -> some View {
        let excursion: String? = {
            guard let from, let to else { return nil }
            return String(format: "%.\(decimals)f \u{2192} %.\(decimals)f \(unit)",
                          Double(from), Double(to))
        }()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .frame(width: 84, alignment: .leading)
            switch outcome {
            case let .reached(minutes):
                returnValue(String(format: "%.1f", minutes), unit: "min", tint: Theme.accent)
                returnCaption("\(verb) to resting" + (excursion.map { " · \($0)" } ?? ""))
            case let .notReached(observed):
                returnValue(">\(Int(observed.rounded()))", unit: "min", tint: Theme.domainHeavy)
                returnCaption("not back to resting when the recording ended"
                              + (excursion.map { " · \($0)" } ?? ""))
            case .notObserved:
                returnValue("—", unit: "", tint: Theme.dim)
                returnCaption(moved ? "not enough recording after this session"
                                    : "did not move far enough to have a return to time")
            }
        }
    }

    private func returnValue(_ value: String, unit: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .monospacedDigit()
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(width: 78, alignment: .leading)
    }

    private func returnCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Heart rate settles first; the brake is the slower half. Said only when
    /// both times are known, since the sentence is about the gap between them.
    private var gapSentence: String? {
        guard case let .reached(hr) = heartRateHome else { return nil }
        switch vagalHome {
        case let .reached(dc) where dc > hr:
            return String(format: "Your heart rate was back at resting %d minutes after you stopped; your vagal brake took %d. Heart rate settles first; the brake is the slower half of recovery.",
                          Int(hr.rounded()), Int(dc.rounded()))
        case let .notReached(observed):
            return String(format: "Your heart rate was back at resting %d minutes after you stopped; your vagal brake was still short of it %d minutes in. Heart rate settles first; the brake is the slower half of recovery.",
                          Int(hr.rounded()), Int(observed.rounded()))
        default:
            return nil
        }
    }

    // MARK: Working

    /// Every checkpoint that counted, with what it measured, its own score and
    /// its share of the weight. An index nobody can check is worse than a raw
    /// number, and this one is a weighted mean of five things — so it prints
    /// its working.
    private func checkpointBreakdown(_ composite: RecoveryIndex.Result) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("HOW THE SCORE WAS BUILT")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Theme.dim)
                .padding(.bottom, 2)
            ForEach(composite.components, id: \.checkpoint) { c in
                HStack(spacing: 6) {
                    Text(c.checkpoint.displayName)
                        .foregroundStyle(Theme.dim)
                    if let detail = checkpointDetail(c.checkpoint) {
                        Text(detail)
                            .foregroundStyle(Theme.dim.opacity(0.7))
                    }
                    Spacer(minLength: 6)
                    Text("\(c.score)")
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .monospacedDigit()
                    Text("× \(String(format: "%.2f", c.weight))")
                        .foregroundStyle(Theme.dim.opacity(0.7))
                }
                .font(.system(size: 8.5, design: .monospaced))
            }
        }
        .padding(.top, 2)
    }

    /// The measurement behind a checkpoint's score, so the row reads as
    /// evidence rather than as a number that arrived from nowhere.
    private func checkpointDetail(_ checkpoint: RecoveryIndex.Checkpoint) -> String? {
        func halfway(_ o: RecoveryTiming.Outcome) -> String? {
            switch o {
            case let .reached(m):      return String(format: "%.1f min to halfway", m)
            case let .notReached(obs): return ">\(Int(obs.rounded())) min, not halfway"
            case .notObserved:         return nil
            }
        }
        switch checkpoint {
        case .hrr60:
            return entry.hrr60Bpm.map { "\(Int($0.rounded())) bpm in the first minute" }
        case .t30:
            return entry.t30Seconds.map { "\(Int($0.rounded())) s" }
        case .rmssdReactivation:
            guard let before = entry.beforeRMSSD, before > 0, let after = entry.afterRMSSD
            else { return nil }
            return "\(Int((Double(after) / Double(before) * 100).rounded()))% of before"
        case .vagalRebound:
            return halfway(entry.recoveryOutcome)
        case .heartRateReturn:
            return halfway(entry.heartRateReturnOutcome)
        }
    }

    /// Did the session actually withdraw the vagal brake far enough to ask how
    /// fast it came back? The same rule the score, the chart's dashed bar and
    /// the return row use, so all of them agree in one direction.
    private var vagalMoved: Bool {
        RecoveryTiming.Direction.upward.movedEnough(pre: entry.beforeDC,
                                                    extreme: entry.duringDCTrough)
    }

    private var heartRateMoved: Bool {
        RecoveryTiming.Direction.downward.movedEnough(pre: entry.beforeHR,
                                                      extreme: entry.duringHRPeak)
    }

    // MARK: ④ Cost

    @ViewBuilder
    private var cost: some View {
        if entry.exerciseLoad != nil || entry.brakeReleaseIndex != nil {
            QuestionCard(number: "4", title: "COST", subtitle: "what you paid for it") {
                if case let .score(value, _) = entry.suppressionAxis {
                    IndexHeadline(value: value, label: "cost — economy of effort", tint: Color(hex: "#FFC01F"))
                }
                Tiles(costTiles)
                Logic("""
                Load is how big the session was; brake release is what it cost your calming \
                system to do it. They are shown together and never combined — a large session \
                bought cheaply and a small one bought dearly are different results, and one \
                blended number would call them the same.
                """)
            }
        }
    }

    private var costTiles: [(String, String, String, String)] {
        var out: [(String, String, String, String)] = []
        if let load = entry.exerciseLoad {
            out.append(("Load", "\(Int(load.rounded()))", "", "effort × time"))
        }
        if let brake = ExerciseSuppression.brakePerBeat(dcPre: entry.beforeDC.map(Double.init),
                                                        dcDuring: entry.duringDC.map(Double.init),
                                                        hrPre: entry.beforeHR.map(Double.init),
                                                        hrDuring: entry.duringHR.map(Double.init)) {
            out.append(("Autonomic cost", String(format: "%.2f", brake), "ms/beat", "per extra bpm"))
        }
        if let trough = entry.duringDCTrough {
            out.append(("Brake floor", String(format: "%.1f", Double(trough)), "ms", "deepest point"))
        }
        return out
    }
}

// MARK: - Pieces

/// One numbered question, with everything that answers it inside.
private struct QuestionCard<Content: View>: View {
    let number: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(number)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Theme.dim.opacity(0.35), lineWidth: 0.5))
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Theme.accent)
                Text("— \(subtitle)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The headline number for a question, with its scale spelled out.
private struct IndexHeadline: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(value)")
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text("/ 100 · \(label)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
    }
}

/// How the number above it was arrived at.
///
/// An index nobody can check is worse than a raw number, so every headline
/// carries the arithmetic that produced it.
private struct Logic: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(.init(text))
            .font(.system(size: 8.5, design: .monospaced))
            .lineSpacing(2)
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 9)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: 2)
            }
    }
}

private struct Callout: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(.init(text))
            .font(.system(size: 9, design: .monospaced))
            .lineSpacing(2)
            .foregroundStyle(Theme.text.opacity(0.95))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent.opacity(0.2), lineWidth: 0.5))
    }
}

/// Up to three supporting readings. Every one carries its unit — a bare 34
/// beside a bare 9 is unreadable when one is beats and the other minutes.
private struct Tiles: View {
    let items: [(String, String, String, String)]
    init(_ items: [(String, String, String, String)]) { self.items = items }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { name, value, unit, caption in
                VStack(spacing: 3) {
                    Text(name)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 22)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .monospacedDigit()
                        if !unit.isEmpty {
                            Text(unit)
                                .font(.system(size: 7.5, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    Text(caption)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 4)
                .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
