import Foundation

/// The four-stage breakdown: awake, REM, light, deep.
///
/// **Read the caveat before reading the minutes.** Three states is what a
/// cardiac signal supports honestly, and it remains what the score is built
/// on. This is the finer split, provided because it is the vocabulary everyone
/// knows and because seeing the night's shape is worth something — but
/// independent validation puts consumer four-stage agreement with
/// polysomnography at κ 0.21–0.53, and the light/deep boundary is the one a
/// chest strap places worst.
///
/// Two honest limits specific to this implementation:
///
/// 1. **N1 is not reported.** It is roughly 5% of a night, human scorers agree
///    on it at κ 0.24 — worse than any other stage — and no cardiac method in
///    the literature recovers it. It is folded into light.
/// 2. **The proportions are imposed, not discovered.** Ticks are ranked on a
///    depth axis and cut at typical adult shares. That means the *ordering* is
///    measured and the *totals* are assumed, so a night with unusually little
///    deep sleep will still be reported near the typical share. Trust the
///    shape; do not read the minutes as a measurement.
enum SleepStageDetail: Int, CaseIterable {
    case wake = 0, rem = 1, n1 = 2, n2 = 3, n3 = 4

    var label: String {
        switch self {
        case .wake: return "Awake"
        case .rem:  return "REM"
        case .n1:   return "N1"
        case .n2:   return "N2 (light)"
        case .n3:   return "N3 (deep)"
        }
    }

    /// Whether this stage is asleep at all.
    var isAsleep: Bool { self != .wake }
}

extension SleepStages {

    /// Typical adult shares of *sleep* time, used as the cut points.
    private static let deepShare = 0.21
    private static let remShare = 0.23

    /// Splits a night into four stages.
    ///
    /// The axis is a within-night depth score: coherence up, SDNN down, LF/HF
    /// down, heart rate down — each standardised against this night, because
    /// the absolute values from the literature do not transfer to this app's
    /// signal definitions. A time term tilts the axis across the night, since
    /// deep sleep is front-loaded and REM lengthens toward morning; without it
    /// the two ends of the axis are only "calm" and "not calm", with no way to
    /// tell early light sleep from late REM.
    static func detailed(_ points: [MetricsHistoryPoint]) -> [SleepStageDetail] {
        let coarse = classify(points)
        guard !points.isEmpty else { return [] }

        // Once. `medianInterval` sorts every gap in the night, and this pass
        // used to ask for it three times over.
        let tick = medianInterval(points)

        let asleep = coarse.indices.filter { coarse[$0] != .wake }
        guard asleep.count > 10 else {
            return coarse.map { $0 == .wake ? .wake : .n2 }
        }

        func z(_ values: [Float?]) -> [Double] {
            let present = values.compactMap { $0 }.map(Double.init)
            guard present.count > 1 else { return values.map { _ in 0 } }
            let mean = present.reduce(0, +) / Double(present.count)
            let sd = sqrt(present.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(present.count))
            guard sd > 0 else { return values.map { _ in 0 } }
            return values.map { $0.map { (Double($0) - mean) / sd } ?? 0 }
        }

        let zc = z(points.map(\.coherence))
        let zs = z(points.map(\.sdnn))
        let zl = z(points.map(\.lfHF))
        let zh = z(points.map(\.meanBPM))

        // Depth, plus a tilt: early ticks lean deep, late ticks lean REM.
        let span = Double(max(1, asleep.count))
        // Dense arrays rather than a dictionary keyed by index. The smoother
        // below reads a five-minute window around every asleep tick, which at
        // the 2 s foreground cadence is ~300 reads each — five million
        // dictionary lookups over a ten-hour night, and the single largest
        // cost in the whole screen.
        var raw = [Double](repeating: 0, count: points.count)
        var present = [Bool](repeating: false, count: points.count)
        for (rank, i) in asleep.enumerated() {
            let through = Double(rank) / span
            let tilt = (0.5 - through) * 1.2
            raw[i] = zc[i] - zs[i] - zl[i] - zh[i] + tilt
            present[i] = true
        }

        // Smooth the SCORE across time before ranking. Ranking the raw score
        // scatters stage labels tick by tick, and the run-length smoother then
        // has nothing but one-sample runs to work with — so it flattens the
        // night into a single stage. Sleep changes state over minutes, so the
        // quantity being ranked has to move over minutes too.
        let reach = max(1, Int((5 * 60) / max(tick, 1)))

        // Running sums, so each window is two subtractions instead of a walk.
        // Same arithmetic as before — the mask keeps the mean over *asleep*
        // ticks only, exactly as the dictionary lookup did.
        var sums = [Double](repeating: 0, count: points.count + 1)
        var counts = [Double](repeating: 0, count: points.count + 1)
        for i in 0..<points.count {
            sums[i + 1] = sums[i] + (present[i] ? raw[i] : 0)
            counts[i + 1] = counts[i] + (present[i] ? 1 : 0)
        }

        var scored: [(index: Int, depth: Double)] = []
        scored.reserveCapacity(asleep.count)
        for i in asleep {
            let lo = max(0, i - reach)
            let hi = min(points.count - 1, i + reach)
            let n = counts[hi + 1] - counts[lo]
            let sum = sums[hi + 1] - sums[lo]
            scored.append((i, n > 0 ? sum / n : raw[i]))
        }

        let byDepth = scored.sorted { $0.depth > $1.depth }
        let deepCount = Int(Double(byDepth.count) * deepShare)
        let remCount = Int(Double(byDepth.count) * remShare)

        var out = [SleepStageDetail](repeating: .n2, count: points.count)
        for i in coarse.indices where coarse[i] == .wake { out[i] = .wake }
        for (n, entry) in byDepth.enumerated() {
            if n < deepCount { out[entry.index] = .n3 }
            else if n >= byDepth.count - remCount { out[entry.index] = .rem }
            else { out[entry.index] = .n2 }
        }
        out = smoothDetail(out, points: points, tick: tick)
        return markN1(out, points: points, tick: tick)
    }

    /// Same run-length rule as the coarse pass: a stage briefer than a few
    /// minutes is a transition or a dropped estimate, not a stage.
    private static func smoothDetail(_ raw: [SleepStageDetail],
                                     points: [MetricsHistoryPoint],
                                     tick: Double? = nil) -> [SleepStageDetail] {
        guard raw.count > 2, points.count == raw.count else { return raw }
        // Median, never the first interval. A night that opens with a stretch
        // of 2 s foreground ticks before settling to the 30 s background
        // cadence made `minRun` fifteen times too large — 45 minutes of real
        // time — and the smoother then absorbed every stage into whichever one
        // happened to be adjacent. The whole night came back as REM.
        let tick = tick ?? medianInterval(points)
        let minRun = max(1, Int(SleepThresholds.minStageRunSec / max(tick, 1)))
        var out = raw
        for _ in 0..<4 {
            var changed = false
            var i = 0
            while i < out.count {
                var j = i
                while j + 1 < out.count && out[j + 1] == out[i] { j += 1 }
                if (j - i + 1) < minRun {
                    let before: SleepStageDetail? = i > 0 ? out[i - 1] : nil
                    let after: SleepStageDetail? = j + 1 < out.count ? out[j + 1] : nil
                    if let replacement = before ?? after, replacement != out[i] {
                        for k in i...j { out[k] = replacement }
                        changed = true
                    }
                }
                i = j + 1
            }
            if !changed { break }
        }
        return out
    }
}


extension SleepStages {

    /// Median gap between ticks. The cadence switches between 2 s foreground
    /// and 30 s background inside a single night, so any single interval is a
    /// bad estimate of the recording's rate.
    static func medianInterval(_ points: [MetricsHistoryPoint]) -> Double {
        guard points.count > 1 else { return 30 }
        let gaps = zip(points, points.dropFirst())
            .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .sorted()
        return max(1, gaps[gaps.count / 2])
    }

    /// Marks the light epochs bordering wake as N1.
    ///
    /// N1 is the descent into sleep and the minutes after an arousal, and that
    /// is the only handle a cardiac signal gives on it — position relative to
    /// wake, not a signature of its own. Labelled as such wherever it is shown.
    static func markN1(_ stages: [SleepStageDetail],
                       points: [MetricsHistoryPoint],
                       tick: Double? = nil) -> [SleepStageDetail] {
        guard stages.count == points.count, points.count > 1 else { return stages }
        let reach = max(1, Int(SleepThresholds.n1ReachSec / (tick ?? medianInterval(points))))
        var out = stages
        for i in stages.indices where stages[i] == .wake {
            for step in 1...reach {
                if i + step < out.count, out[i + step] == .n2 { out[i + step] = .n1 }
                if i - step >= 0, out[i - step] == .n2 { out[i - step] = .n1 }
            }
        }
        return out
    }
}
