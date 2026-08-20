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
    /// The within-night depth axis: higher is deeper. Nil where awake.
    ///
    /// Split out from `detailed` so the cut points can be calibrated against
    /// real nights instead of asserted. The axis itself is a measurement — it
    /// is the *cutting* of it that used to be a constant.
    static func depthAxis(_ points: [MetricsHistoryPoint]) -> [Double?] {
        let coarse = classify(points)
        guard !points.isEmpty else { return [] }
        let tick = medianInterval(points)

        let asleep = coarse.indices.filter { coarse[$0] != .wake }
        guard asleep.count > 10 else { return points.map { _ in nil } }

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

        // The measured part of the axis: four standardised channels that the
        // research found actually separate depth.
        var base = [Double](repeating: 0, count: points.count)
        for i in asleep { base[i] = zc[i] - zs[i] - zl[i] - zh[i] }

        // How much depth structure this night actually contains. A recording
        // whose channels never move, or move without agreeing, has a narrow
        // base — and must not then be handed structure by the tilt.
        let observed = asleep.map { base[$0] }
        let mean = observed.reduce(0, +) / Double(observed.count)
        let baseSD = sqrt(observed.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(observed.count))

        // Depth, plus a tilt: early ticks lean deep, late ticks lean REM.
        //
        // The tilt is scaled by the measured spread. Unscaled it injected a
        // fixed ±0.6 of pure artefact, which on a structureless night was the
        // ENTIRE axis — the night got a full hypnogram built from nothing but
        // the clock. Scaled, a flat night stays flat and reports itself as
        // undifferentiated light sleep, which is the honest answer.
        let tiltScale = min(1, baseSD / 2.0)
        let span = Double(max(1, asleep.count))
        var raw = [Double](repeating: 0, count: points.count)
        var present = [Bool](repeating: false, count: points.count)
        for (rank, i) in asleep.enumerated() {
            let through = Double(rank) / span
            raw[i] = base[i] + (0.5 - through) * 1.2 * tiltScale
            present[i] = true
        }

        // Smooth the SCORE across time before cutting. Cutting the raw score
        // scatters stage labels tick by tick, and the run-length smoother then
        // has nothing but one-sample runs to work with — so it flattens the
        // night into a single stage. Sleep changes state over minutes, so the
        // quantity being cut has to move over minutes too.
        let reach = max(1, Int((5 * 60) / max(tick, 1)))
        var sums = [Double](repeating: 0, count: points.count + 1)
        var counts = [Double](repeating: 0, count: points.count + 1)
        for i in 0..<points.count {
            sums[i + 1] = sums[i] + (present[i] ? raw[i] : 0)
            counts[i + 1] = counts[i] + (present[i] ? 1 : 0)
        }

        var out = [Double?](repeating: nil, count: points.count)
        for i in asleep {
            let lo = max(0, i - reach)
            let hi = min(points.count - 1, i + reach)
            let n = counts[hi + 1] - counts[lo]
            out[i] = n > 0 ? (sums[hi + 1] - sums[lo]) / n : raw[i]
        }
        return out
    }

    static func detailed(_ points: [MetricsHistoryPoint]) -> [SleepStageDetail] {
        guard !points.isEmpty else { return [] }
        let coarse = classify(points)
        let tick = medianInterval(points)
        let depth = depthAxis(points)

        guard depth.contains(where: { $0 != nil }) else {
            return coarse.map { $0 == .wake ? .wake : .n2 }
        }

        // Cut on the axis itself, not on rank.
        //
        // This used to take the deepest 21% and the shallowest 23% of ticks,
        // which meant every night ever recorded reported 21% deep and 23% REM
        // — the constants, read back out. A night with no depth structure at
        // all scored identically to one with a textbook 90-minute cycle.
        // Thresholds on the axis let a flat night report itself as flat.
        var out = [SleepStageDetail](repeating: .n2, count: points.count)
        for i in points.indices {
            guard coarse[i] != .wake, let d = depth[i] else { out[i] = .wake; continue }
            if d >= SleepThresholds.deepDepth      { out[i] = .n3 }
            else if d < SleepThresholds.remDepth   { out[i] = .rem }
            else                                   { out[i] = .n2 }
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
