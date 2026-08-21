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
        if entry.bounceBackIndex != nil || !recoveryTiles.isEmpty {
            QuestionCard(number: "3", title: "RECOVERED", subtitle: "how fast it came back") {
                // The hero is a TIME, not a score. "Vagal Rebound 11.2 min" is a
                // property of the person; "DC 8.6 ms" is a reading off an
                // instrument. The 0-100 composite still exists — one level down,
                // where a number nobody can feel belongs.
                stableRecoveryHeadline
                profileRows

                if let index = entry.bounceBackIndex, let composite = entry.recoveryComposite {
                    Divider().overlay(Theme.border)
                    IndexHeadline(value: index.value,
                                  label: "recovery · \(composite.firmness.label)",
                                  tint: Theme.accent)
                    checkpointBreakdown(composite)
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
                Tiles(recoveryTiles)

                // Both curves live here, beside the number they explain. They
                // used to sit in separate cards further down the screen, which
                // is how a headline of 0 could sit half a page from a chart
                // showing a fast return without the two ever being compared.
                curve("VAGAL REBOUND", channel: .vagalBrake,
                      outcome: entry.recoveryOutcome,
                      pre: entry.beforeDC, extreme: entry.duringDCTrough,
                      note: dcNote)

                curve("HEART RATE RETURN", channel: .heartRate,
                      outcome: entry.heartRateReturnOutcome,
                      pre: entry.beforeHR, extreme: entry.duringHRPeak,
                      note: hrNote)

                if let hrr = entry.hrr60Bpm, case let .reached(mins) = entry.recoveryOutcome {
                    // The finding neither curve shows alone.
                    Text(String(format: "Your heart rate dropped %d bpm in a minute while your vagal brake took %d minutes to come halfway back. Heart rate settles first; the brake is the slower half of recovery.",
                                Int(hrr.rounded()), Int(mins.rounded())))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Logic("""
                A weighted mean of the checkpoints that have arrived, renormalised over those \
                present — **a checkpoint that has not landed is absent, never zero**, and one on \
                its own never becomes the score. Heart rate is routinely home while vagal tone \
                is still well down, so the two timing channels carry equal weight and the gap \
                between them stays visible rather than being averaged away. Under 12 bpm in the \
                first minute is flagged in the literature, 20–30 healthy, 30–50 well-trained — \
                from standardised treadmill tests, so a band to sit inside rather than a verdict.
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
        return base + " The rebound is timed against how far the brake FELL, so a session that "
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
                       outcome: RecoveryTiming.Outcome,
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
                                   outcome: outcome,
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

    /// The three layers and the one time, from the same samples the curves
    /// below are drawn from — so the header and the pictures cannot disagree.
    private var profile: RecoveryProfile.Result {
        let end = windowEnd
        let after = (recoveryPoints.isEmpty ? points : recoveryPoints)
            .filter { $0.timestamp > end }
            .map { RecoveryProfile.Sample(minutes: $0.timestamp.timeIntervalSince(end) / 60,
                                          hr: $0.meanBPM.map(Double.init),
                                          dc: $0.dc.map(Double.init)) }
        return RecoveryProfile.build(after: after,
                                     restingHR: entry.beforeHR.map(Double.init),
                                     peakHR: entry.duringHRPeak.map(Double.init),
                                     dcPre: entry.beforeDC.map(Double.init),
                                     dcTrough: entry.duringDCTrough.map(Double.init))
    }

    private var expectation: String? {
        RecoveryExpectation.band(moderateSec: entry.domainModerateSec ?? 0,
                                 heavySec: entry.domainHeavySec ?? 0,
                                 severeSec: entry.domainSevereSec ?? 0)
            .map(RecoveryExpectation.sentence(for:))
    }

    /// Minutes until BOTH channels were home together and held.
    ///
    /// It often ends as a bound, which is the honest answer for a hard session
    /// — and a bound is never shown alone. ">34 min" on its own is what made
    /// this screen read as a failure; ">34 min, typical for a heavy session is
    /// 15–45" is a finding.
    @ViewBuilder
    private var stableRecoveryHeadline: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("TIME TO STABLE RECOVERY")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(Theme.dim)

            switch profile.timeToStable {
            case let .reached(minutes):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", minutes))
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .monospacedDigit()
                    Text("min · heart rate home and the brake back together")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            case let .notReached(observed):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(">\(Int(observed.rounded()))")
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.domainHeavy)
                        .monospacedDigit()
                    Text("min · still recalibrating when the recording ended")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            case .notObserved:
                // Two unrelated reasons land on this case, and blaming the
                // strap for the quiet one is how a session that simply did not
                // tax anything reads as a broken recording.
                Text(vagalMoved || heartRateMoved
                     ? "not enough recording after this session"
                     : "this session did not push either channel far enough to have a return to time")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }

            if let expectation {
                Text(expectation)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.85))
            }
        }
    }

    /// Three layers, always all three — the empty one included.
    ///
    /// Physical recovery is invisible to an ECG. Showing the two it can see and
    /// omitting the one it cannot invites "Cardiovascular 92%" to be read as
    /// ready to train, which the measurement does not support.
    @ViewBuilder
    private var profileRows: some View {
        let p = profile
        VStack(alignment: .leading, spacing: 4) {
            layerRow("CARDIOVASCULAR", p.cardiovascular, Theme.rsa, "load came down")
            layerRow("NEURAL", p.neural, Theme.hrv, "regulation came back")
            layerRow("STABILITY", p.stability, Theme.breathe, "came back and stayed")
            HStack(spacing: 6) {
                Text("PHYSICAL")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 92, alignment: .leading)
                Text("—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 34, alignment: .trailing)
                Text("not measurable from ECG")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.7))
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func layerRow(_ name: String, _ value: Int?, _ tint: Color, _ caption: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .frame(width: 92, alignment: .leading)
            Text(value.map { "\($0)%" } ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(value == nil ? Theme.dim : Theme.text)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface).frame(height: 3)
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(value ?? 0) / 100, height: 3)
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 10)
            Text(caption)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.7))
                .frame(width: 108, alignment: .leading)
        }
    }

    /// Every checkpoint that counted, with its own score and its share of the
    /// weight. An index nobody can check is worse than a raw number, and this
    /// one is a weighted mean of five things — so it prints its working.
    private func checkpointBreakdown(_ composite: RecoveryIndex.Result) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(composite.components, id: \.checkpoint) { c in
                HStack(spacing: 6) {
                    Text(c.checkpoint.displayName)
                        .foregroundStyle(Theme.dim)
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

    /// Did the session actually withdraw the vagal brake far enough to ask how
    /// fast it came back? The same rule the score, the chart's dashed bar and
    /// the neural percentage use, so all four agree in one direction.
    private var vagalMoved: Bool {
        RecoveryTiming.Direction.upward.movedEnough(pre: entry.beforeDC,
                                                    extreme: entry.duringDCTrough)
    }

    private var heartRateMoved: Bool {
        RecoveryTiming.Direction.downward.movedEnough(pre: entry.beforeHR,
                                                      extreme: entry.duringHRPeak)
    }

    /// How far the brake actually fell, in words — the number the reader was
    /// being asked to take on trust behind "vagal rebound".
    private var vagalExcursion: String? {
        guard let pre = entry.beforeDC.map(Double.init),
              let low = entry.duringDCTrough.map(Double.init),
              let frac = RecoveryTiming.Direction.upward
                  .drawdownFraction(pre: pre, extreme: low)
        else { return nil }
        return String(format: "%+.0f%% from resting", -frac * 100)
    }

    private var recoveryTiles: [(String, String, String, String)] {
        var out: [(String, String, String, String)] = []
        if let hrr = entry.hrr60Bpm {
            out.append(("Heart rate drop", "\(Int(hrr.rounded()))", "bpm", "first minute"))
        }
        switch entry.recoveryOutcome {
        case let .reached(minutes):
            out.append(("Vagal rebound (DC)", String(format: "%.1f", minutes), "min", "to halfway"))
        case let .notReached(observed):
            out.append(("Vagal rebound (DC)", ">\(Int(observed.rounded()))", "min", "not halfway yet"))
        case .notObserved:
            break
        }
        switch entry.heartRateReturnOutcome {
        case let .reached(minutes):
            out.append(("Heart rate return", String(format: "%.1f", minutes), "min", "to halfway"))
        case let .notReached(observed):
            out.append(("Heart rate return", ">\(Int(observed.rounded()))", "min", "not halfway yet"))
        case .notObserved:
            break
        }
        if let low = entry.duringDCTrough {
            // The level the rebound is measured FROM. Without it the card
            // reported how fast the brake came back from a hole whose depth it
            // never showed — and on a session where that hole was a rounding
            // error, "0.2 min to halfway" read as a perfect recovery.
            out.append(("Brake low point", String(format: "%.1f", Double(low)), "ms",
                        vagalExcursion ?? "during the session"))
        }
        if let tail = entry.afterTailDC {
            out.append(("Brake at 10 min", String(format: "%.1f", Double(tail)), "ms", "where it settled"))
        }
        return out
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
