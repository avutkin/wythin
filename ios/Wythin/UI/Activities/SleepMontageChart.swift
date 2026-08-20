import SwiftUI

// MARK: - The clock

/// The single time axis every channel of the montage is drawn against.
///
/// This exists because the montage previously had *two* clocks and neither was
/// right. The metric traces were Swift Charts, each laying out its own x axis
/// inside its own plot area; the hypnogram below them had a hand-rolled axis
/// built from an `HStack` of labels separated by equal `Spacer()`s. Equal
/// spacers give equal width to unequal durations, so on a 17:00→05:37 night the
/// one-hour gap 17:00→18:00 was drawn as wide as the two-hour gap 18:00→20:00 —
/// every label on the chart was in the wrong place, and the traces above
/// disagreed with all of them.
///
/// One value type, used by every channel, is what makes "one shared clock axis"
/// true rather than aspirational.
struct MontageRuler: Equatable {

    let startedAt: Date
    let endedAt: Date

    /// Hour labels nearer than this to either end are dropped: that space
    /// belongs to the ASLEEP and WOKE markers, and a collision there costs the
    /// two most important times on the chart.
    static let edgeClearanceSec: Double = 40 * 60

    /// Guarded so a degenerate window cannot divide by zero.
    var span: Double { max(1, endedAt.timeIntervalSince(startedAt)) }

    /// Where a moment falls, in points, across a plot of the given width.
    /// Clamped: a sample outside the window belongs at the edge, not off it.
    func x(_ t: Date, width: Double) -> Double {
        guard endedAt > startedAt else { return 0 }
        return width * min(1, max(0, t.timeIntervalSince(startedAt) / span))
    }

    /// Tick density follows the span, so a four-hour nap is not labelled as
    /// sparsely as a sixteen-hour wear.
    var tickStepHours: Int {
        switch span {
        case ..<(6 * 3600):  return 1
        case ..<(12 * 3600): return 2
        default:             return 3
        }
    }

    /// Whole hours, strictly inside the window and clear of both end markers.
    var ticks: [Date] {
        guard endedAt > startedAt else { return [] }
        let cal = Calendar.current
        let step = tickStepHours
        // Matched on minute AND second, so a night that began at 23:04:37 does
        // not produce ticks at 00:00:37 — the gridline would be off the hour by
        // however many seconds the first sample happened to carry.
        guard var t = cal.nextDate(after: startedAt,
                                   matching: DateComponents(minute: 0, second: 0),
                                   matchingPolicy: .nextTime) else { return [] }

        var out: [Date] = []
        while t < endedAt {
            let clearOfStart = t.timeIntervalSince(startedAt) >= Self.edgeClearanceSec
            let clearOfEnd = endedAt.timeIntervalSince(t) >= Self.edgeClearanceSec
            if clearOfStart, clearOfEnd, cal.component(.hour, from: t) % step == 0 {
                out.append(t)
            }
            t = t.addingTimeInterval(3600)
        }
        return out
    }
}

// MARK: - The montage

/// The night, channel by channel, on one shared clock axis.
///
/// Laid out as a sleep-study montage because that is the instrument's own
/// vernacular — and because every channel here is one a chest ECG plus a
/// sternum accelerometer can actually produce.
///
/// **The hypnogram is a lane ribbon, not a fill-to-baseline shape.** Depth is
/// vertical POSITION and every state carries equal visual mass. Filling each
/// block down to the floor instead makes the deepest state the shortest bar,
/// and since one state usually occupies most of a night, that collapses the
/// chart into a flat strip with the variation invisible. That shape was tried:
/// it was justified on the grounds that with five levels "awake reads as a tall
/// thin spike", which holds only while awake is small. On a night where the
/// detector had swallowed six hours of evening, Awake was 58% of the window AND
/// the full-height bar — a grey slab with the architecture buried under it.
/// The ribbon does not have that failure mode at any distribution.
///
/// **Every channel is drawn against `MontageRuler`, in Canvas, at full width.**
/// Not for the drawing style — for the guarantee. Swift Charts lays out each
/// chart's plot area inside its own frame, and a y-axis label one character
/// wider silently shifts that chart's time origin relative to its neighbour, so
/// "the same clock" becomes an aspiration rather than a fact. Sharing one x
/// mapping and one full-bleed plot width makes the alignment structural. It
/// also preserves the reason this file moved to Canvas in the first place: a
/// night is ~19,000 samples and nine Swift Charts over it is what made the
/// screen hang.
struct SleepMontageChart: View {

    private let night: PreparedNight
    private let ruler: MontageRuler

    init(night: PreparedNight, startedAt: Date, endedAt: Date) {
        self.night = night
        self.ruler = MontageRuler(startedAt: startedAt, endedAt: endedAt)
    }

    // MARK: - Palette

    /// A sequential depth ramp, plus one neutral that sits outside it.
    ///
    /// The four sleep stages are one hue with monotonic lightness, ~0.15 apart
    /// in OKLab (0.43 / 0.59 / 0.73 / 0.88), worst adjacent pair ΔE 14.4 in
    /// normal vision and 14.4 under protan simulation. Depth is additionally
    /// carried by lane position and by the labelled legend below, so colour is
    /// never the only thing separating two stages.
    private func colour(_ s: SleepStageDetail) -> Color {
        switch s {
        // Awake is not a depth, so it sits outside the blue ramp entirely.
        case .wake: return Color(hex: "#6B6B6B")
        case .rem:  return Color(hex: "#BCDCF7")
        case .n1:   return Color(hex: "#74AEE4")
        case .n2:   return Color(hex: "#3F7CC0")
        case .n3:   return Color(hex: "#22508F")
        }
    }

    private func colour(_ def: ActivityMetricDef) -> Color {
        switch def.techLabel {
        case "HR":     return Theme.warn
        case "RSA":    return Theme.rsa
        case "DC":     return Theme.coh
        case "DFA α1": return Theme.ulf
        case "SNS %":  return Theme.domainHeavy
        case "PIP":    return Theme.breathe
        default:       return Theme.hrv
        }
    }

    /// Supine is the one that carries a clinical meaning — it is the position
    /// the upper airway is most collapsible in — so it is the one that stands
    /// out. The rest are deliberately quiet.
    private func positionColour(_ p: BodyPosition) -> Color {
        switch p {
        case .supine:  return Color(hex: "#4A5568")
        case .prone:   return Color(hex: "#3A4250")
        default:       return Color(white: 0.80)
        }
    }

    private func labelColour(_ p: BodyPosition) -> Color {
        switch p {
        case .supine, .prone: return Color(white: 0.96)
        default:              return Color(white: 0.25)
        }
    }

    // MARK: - Numbers

    private func minutes(_ s: SleepStageDetail) -> Int { night.stageMinutes[s] ?? 0 }

    private var asleepMinutes: Int {
        SleepStageDetail.allCases.filter(\.isAsleep).reduce(0) { $0 + minutes($1) }
    }

    private func hm(_ m: Int) -> String { "\(m / 60)h \(String(format: "%02d", m % 60))m" }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bounds
            sleepChannel
            ForEach(activityMetricDefs) { def in
                traceChannel(def)
            }
            movementChannel
            positionChannel
            axis
            stageLegend
            positionDetail
        }
    }

    // MARK: - The two times that matter

    /// Sleep onset and final wake, named rather than implied.
    ///
    /// These used to be two bare `HH:mm` chips at the ends of the axis, which
    /// says *when the chart starts* and not *what happened then*. Since the
    /// detector trims the window to sustained sleep, these two moments are the
    /// night's boundaries by construction — so they are the right thing to
    /// label, and labelling them is also what makes a mis-detected window
    /// obvious instead of mysterious.
    private var bounds: some View {
        HStack(alignment: .bottom, spacing: 12) {
            boundMarker("ASLEEP", clock(ruler.startedAt), alignment: .leading)
            Spacer(minLength: 8)
            boundMarker("WOKE", clock(ruler.endedAt), alignment: .trailing)
        }
        .padding(.bottom, 10)
    }

    private func boundMarker(_ caption: String,
                             _ time: String,
                             alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(caption)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Theme.dim)
            Text(time)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
        }
    }

    // MARK: - Shared ink

    /// The hour gridlines, plus a rule down each end of the window.
    ///
    /// Drawn into every channel from the same `ruler`, which is what lets the
    /// eye carry a moment vertically from the hypnogram down to breathing
    /// without the two charts quietly disagreeing about where 03:00 is.
    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        for t in ruler.ticks {
            let x = ruler.x(t, width: size.width)
            ctx.stroke(rule(x: x, height: size.height),
                       with: .color(Theme.dim.opacity(0.16)), lineWidth: 0.5)
        }
        for x in [0.0, size.width] {
            ctx.stroke(rule(x: x, height: size.height),
                       with: .color(Theme.dim.opacity(0.45)), lineWidth: 1)
        }
    }

    private func rule(x: Double, height: Double) -> Path {
        Path { p in
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: height))
        }
    }

    /// Awake, behind the trace. Recessive on purpose — it is context for the
    /// line, not a mark competing with it.
    private func drawWakeBands(_ ctx: inout GraphicsContext, _ size: CGSize) {
        for band in night.wakeBands {
            let x0 = ruler.x(band.start, width: size.width)
            let x1 = ruler.x(band.end, width: size.width)
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(0.5, x1 - x0), height: size.height)),
                     with: .color(Color(white: 0.62).opacity(0.16)))
        }
    }

    private func channelHeader(_ name: String, tech: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(tech)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
        }
    }

    // MARK: - SLEEP

    private var sleepChannel: some View {
        VStack(alignment: .leading, spacing: 5) {
            channelHeader("Sleep", tech: "hypnogram", value: "\(hm(asleepMinutes)) asleep")
            Canvas { ctx, size in
                drawGrid(&ctx, size)
                drawRibbon(&ctx, size)
            }
            .frame(height: 120)
            Text("Lanes run Awake at the top to N3 at the bottom; every stage has the same height, so depth is position rather than mass.")
                .font(.system(size: 9))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }

    private func drawRibbon(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let stages = night.stages
        let points = night.points
        guard stages.count == points.count, !points.isEmpty else { return }

        let laneCount = Double(SleepStageDetail.allCases.count)
        let laneHeight = size.height / laneCount
        let inset = min(3.0, laneHeight * 0.16)

        // Faint lane separators, so the five rungs are readable even where a
        // lane happens to be empty for hours.
        for i in 1..<Int(laneCount) {
            let y = Double(i) * laneHeight
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
            }, with: .color(Theme.dim.opacity(0.10)), lineWidth: 0.5)
        }

        var start = 0
        for i in 1...stages.count {
            guard i == stages.count || stages[i] != stages[start] else { continue }
            let x0 = ruler.x(points[start].timestamp, width: size.width)
            let x1 = i < points.count
                ? ruler.x(points[i].timestamp, width: size.width)
                : size.width
            // `SleepStageDetail` is declared wake=0 … n3=4, which is already
            // top-to-bottom hypnogram order — the lane index IS the raw value.
            let top = Double(stages[start].rawValue) * laneHeight + inset
            let rect = CGRect(x: x0, y: top,
                              width: max(1.2, x1 - x0),
                              height: laneHeight - inset * 2)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                     with: .color(colour(stages[start])))
            start = i
        }
    }

    // MARK: - Metric traces

    private func traceChannel(_ def: ActivityMetricDef) -> some View {
        let samples = night.series[def.id] ?? []
        let average = night.averages[def.id]
        let unit = def.unit.isEmpty ? "" : " \(def.unit)"
        return VStack(alignment: .leading, spacing: 4) {
            channelHeader(def.label,
                          tech: def.techFull.isEmpty ? def.techLabel : def.techFull,
                          value: average.map { "\(def.format($0))\(unit)" } ?? "—")
            Canvas { ctx, size in
                drawWakeBands(&ctx, size)
                drawGrid(&ctx, size)
                drawTrace(&ctx, size, samples: samples, average: average, def: def)
            }
            .frame(height: 48)
            .overlay(alignment: .leading) {
                if samples.isEmpty {
                    Text("not measured")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.bottom, 14)
    }

    private func drawTrace(_ ctx: inout GraphicsContext,
                           _ size: CGSize,
                           samples: [PreparedNight.Sample],
                           average: Double?,
                           def: ActivityMetricDef) {
        guard samples.count > 1 else { return }
        let values = samples.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return }
        // A flat channel is a real result, not a divide-by-zero: give it a
        // nominal range so the line lands mid-height instead of at an edge.
        let range = hi - lo > 1e-9 ? hi - lo : 1
        let pad = 5.0
        func y(_ v: Double) -> Double {
            size.height - pad - (v - lo) / range * (size.height - pad * 2)
        }

        if let average, average >= lo, average <= hi {
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: y(average)))
                p.addLine(to: CGPoint(x: size.width, y: y(average)))
            }, with: .color(Theme.dim.opacity(0.55)),
               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        var path = Path()
        for (i, s) in samples.enumerated() {
            let point = CGPoint(x: ruler.x(s.date, width: size.width), y: y(s.value))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        ctx.stroke(path, with: .color(colour(def)),
                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

        // The nadir, on the pulse channel only. How far heart rate falls and
        // WHEN it bottoms out is the single most readable thing in a night's
        // autonomic trace, and it was annotated in the agreed montage before
        // the traces were split off into their own card and lost it.
        guard def.techLabel == "HR",
              let bottom = samples.min(by: { $0.value < $1.value }) else { return }
        let at = CGPoint(x: ruler.x(bottom.date, width: size.width), y: y(bottom.value))
        ctx.fill(Path(ellipseIn: CGRect(x: at.x - 2.5, y: at.y - 2.5, width: 5, height: 5)),
                 with: .color(colour(def)))
        ctx.draw(Text("nadir \(def.format(bottom.value)) · \(clock(bottom.date))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim),
                 at: CGPoint(x: min(max(at.x, 52), size.width - 52), y: max(at.y - 8, 6)),
                 anchor: .bottom)
    }

    // MARK: - MOVEMENT

    private var movementChannel: some View {
        VStack(alignment: .leading, spacing: 4) {
            channelHeader("Movement", tech: "accelerometer", value: "")
            Canvas { ctx, size in
                drawGrid(&ctx, size)
                let mid = size.height / 2
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: mid))
                    p.addLine(to: CGPoint(x: size.width, y: mid))
                }, with: .color(Theme.dim.opacity(0.25)), lineWidth: 1)

                // Only movement that stands out from this night's own stillness
                // is worth a tick; drawing every sample would be a grey wash.
                // The threshold needs a median of the whole night, so it is
                // computed upstream — doing it here ran it on every redraw.
                let threshold = night.motionThreshold
                guard threshold < .greatestFiniteMagnitude else { return }
                for p in night.points {
                    guard let m = p.motion, m > threshold else { continue }
                    let x = ruler.x(p.timestamp, width: size.width)
                    let scale = min(1, Double(m / (threshold * 4)))
                    let h = 6 + scale * (mid - 4)
                    ctx.fill(Path(CGRect(x: x, y: mid - h / 2, width: 1.6, height: h)),
                             with: .color(Color(white: 0.78).opacity(0.5 + scale * 0.5)))
                }
            }
            .frame(height: 44)
        }
        .padding(.bottom, 14)
    }

    // MARK: - POSITION

    /// Which way the body was facing, as bands across the same time axis.
    ///
    /// **The header is unconditional, and that is the point.** This used to
    /// render nothing at all when there were no bands, which on a night
    /// recorded before position was stored looked exactly like the feature not
    /// existing — the same blank a missing implementation leaves. A night that
    /// cannot show position has to say so, in the place the strip would be.
    ///
    /// Two different silences, never merged: no ticks carried an orientation
    /// (the night predates storage, and the three axes were collapsed to a
    /// rotation-invariant magnitude before reaching disk, so it can never be
    /// rebuilt), or orientation was measured and no stretch of it survived the
    /// two-minute floor.
    private var positionChannel: some View {
        VStack(alignment: .leading, spacing: 4) {
            channelHeader("Position", tech: "gravity vector", value: "")
            if night.positionBands.isEmpty {
                Text(night.positionTicks == 0
                     ? "Not recorded on this night. The strap stored only the strength of movement, not its direction, so which way you lay was never on disk — it cannot be recovered by re-reading the night."
                     : "Measured, but you never held one position for two minutes together, so there is no stretch long enough to draw.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                Canvas { ctx, size in
                    drawGrid(&ctx, size)
                    for band in night.positionBands {
                        let x0 = ruler.x(band.start, width: size.width)
                        let x1 = ruler.x(band.end, width: size.width)
                        let w = max(2, x1 - x0)
                        let rect = CGRect(x: x0, y: 3, width: w, height: size.height - 6)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 4),
                                 with: .color(positionColour(band.position)))
                        // Only label a band with room for the word; a clipped
                        // "SUPI" is worse than no label — the list below names
                        // every band anyway.
                        guard w > 74 else { continue }
                        ctx.draw(Text(band.position.label.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(labelColour(band.position)),
                                 at: CGPoint(x: x0 + w / 2, y: size.height / 2),
                                 anchor: .center)
                    }
                }
                .frame(height: 28)
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - The axis

    /// One ruler, drawn once, under every channel it governs.
    private var axis: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(ruler.ticks, id: \.self) { t in
                    Text(clock(t))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        // Centred ON the gridline it belongs to, which is the
                        // whole point: the old axis spaced labels evenly and
                        // let them land wherever that happened to put them.
                        .position(x: ruler.x(t, width: geo.size.width), y: 9)
                }
            }
        }
        .frame(height: 20)
        .padding(.bottom, 16)
    }

    // MARK: - Legends

    private var stageLegend: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([SleepStageDetail.wake, .rem, .n1, .n2, .n3], id: \.self) { s in
                let mins = minutes(s)
                if mins > 0 || s == .wake {
                    HStack(spacing: 12) {
                        Capsule()
                            .fill(colour(s))
                            .frame(width: 78, height: 9)
                        Text(s.label)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.text)
                        Text(hm(mins))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.text)
                        if s.isAsleep, asleepMinutes > 0 {
                            Text("\(Int(round(Double(mins) / Double(asleepMinutes) * 100)))%")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.dim)
                        }
                        Spacer()
                    }
                }
            }
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.62).opacity(0.16))
                    .frame(width: 22, height: 11)
                Text("awake, behind every trace")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                Text("·  dashed line is the night average")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            }
            .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    /// The minutes behind the position bands, and then the bands themselves.
    ///
    /// The strip shows *when*; a person asking "how much of the night was I on
    /// my back" is asking something the strip alone cannot answer, and supine
    /// share is the one number here with a recommendation attached to it. The
    /// per-band list answers the other half — which turn happened when, and how
    /// long it lasted — for the bands too narrow to carry their own label.
    @ViewBuilder
    private var positionDetail: some View {
        if !night.positionBands.isEmpty {
            let known = night.positionMinutes.values.reduce(0, +)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(BodyPosition.allCases, id: \.rawValue) { pos in
                    if let mins = night.positionMinutes[pos], mins > 0 {
                        HStack(spacing: 12) {
                            Capsule()
                                .fill(positionColour(pos))
                                .frame(width: 78, height: 9)
                            Text(pos.label)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.text)
                            Text(hm(mins))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.text)
                            if known > 0 {
                                Text("\(Int((Double(mins) / Double(known) * 100).rounded()))%")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.dim)
                            }
                            Spacer()
                        }
                    }
                }

                Text("EVERY TURN")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 6)

                ForEach(Array(night.positionBands.enumerated()), id: \.offset) { _, band in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(positionColour(band.position))
                            .frame(width: 10, height: 10)
                        Text("\(clock(band.start)) → \(clock(band.end))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                        Text(band.position.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 6)
                        Text(hm(Int((band.end.timeIntervalSince(band.start) / 60).rounded())))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                    }
                }

                // Percentages are of the time a position was known, not of the
                // night — the gaps are stretches spent turning over, and
                // dividing by them would understate every position.
                Text("Shares are of the time a position was readable; the gaps between turns are the rolls themselves. Left and right depend on which way round the strap was fastened; on your back, front and upright do not.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 22)
        }
    }
}
