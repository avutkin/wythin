import Foundation

// MARK: - Stage

/// Three states, not four.
///
/// The four-stage breakdown every consumer product displays agrees with
/// polysomnography at roughly κ 0.21–0.53, and the boundary it places worst is
/// exactly the light/deep one. Merging those two into `quiet` reports what a
/// cardiac signal can actually support and drops the boundary it cannot.
enum SleepStage: Int, Codable, CaseIterable {
    case wake = 0, active = 1, quiet = 2

    var label: String {
        switch self {
        case .wake:   return "Awake"
        case .active: return "Active sleep"
        case .quiet:  return "Quiet sleep"
        }
    }
}

// MARK: - Classifier

/// Labels each tick of a night.
///
/// The discriminators are the ones that survived §6 of the sleep research, and
/// they are deliberately **not** the ones a product would reach for first:
/// RMSSD and HF power barely separate deep sleep from REM (1167 vs 1322 ms²,
/// 67 vs 80 ms) and are useless here, however good they are as trend metrics.
/// What does separate them is cardiorespiratory coherence — the single
/// strongest published separator, N3 0.91–0.97 against REM 0.69–0.82 — backed
/// by LF/HF (0.51 vs 2.02) and SDNN (53.8 vs 105.5), each roughly a 2–4×
/// difference.
enum SleepStages {

    static func classify(_ points: [MetricsHistoryPoint]) -> [SleepStage] {
        let base = Baseline(points)
        // Unsettled breathing is the third wake cue, and on a real night it is
        // the decisive one: heart rate sat in the low sixties for three
        // quarters of an hour after this person stopped being awake, while
        // breath rate was still swinging between 6.7 and 20.1.
        let unsettled = SleepBreathing.unsettled(points)
        let raw = points.indices.map { i -> SleepStage in
            if isWake(points[i], base) || unsettled[i] { return .wake }
            return quietVotes(points[i], base) >= 2 ? .quiet : .active
        }
        return smooth(raw, points: points)
    }

    /// Classification for *reporting*, inside a window already known to be
    /// sleep. This is what the hypnogram and the awake total are built from.
    ///
    /// `classify` is tuned to find the edges of a night, and it has to be
    /// generous to do that: heart rate alone, or breathing alone, is enough to
    /// call a tick awake, because lying awake before sleep shows up in nothing
    /// else — motion is already at sleeping levels, and if those channels did
    /// not count on their own the night would open hours too early.
    ///
    /// **The same generosity is wrong once the edges are known**, and it was
    /// being used for both. Heart rate and breathing are precisely the two
    /// channels REM imitates: this file already records that RMSSD and HF
    /// "barely separate deep sleep from REM", and REM is the stage whose pulse
    /// and breathing look awake. REM is a fifth to a quarter of a night. Scored
    /// by those two channels alone it reads as wake, and the night comes back
    /// with hours of awake in it that the sleeper did not experience.
    ///
    /// What separates REM from wake is **movement**. REM has muscle atonia —
    /// the body does not move — while being awake for any length of time
    /// involves shifting. So inside the night a wake bout has to be
    /// corroborated by the accelerometer or by posture; heart rate and
    /// breathing may raise the question and no longer settle it alone.
    ///
    /// Deliberately not applied by `SleepDetector`, which still needs the
    /// generous rule to find the boundaries in the first place.
    static func withinSleep(_ points: [MetricsHistoryPoint]) -> [SleepStage] {
        let raw = classify(points)
        let base = Baseline(points)
        var out = raw
        for run in runs(of: raw) where raw[run[0]] == .wake && !moved(run, points, base) {
            // Not "asleep" by fiat — re-asked as the sleep question it now is.
            for i in run { out[i] = quietVotes(points[i], base) >= 2 ? .quiet : .active }
        }
        return out
    }

    /// Whether anything in this run actually moved.
    ///
    /// A low bar on purpose — `stirMotionMultiple`, not `wakeMotionMultiple`.
    /// The question is not "was this vigorous", it is "did the body move at
    /// all", because the state being excluded is one in which it cannot.
    private static func moved(_ run: [Int],
                              _ points: [MetricsHistoryPoint],
                              _ base: Baseline) -> Bool {
        run.contains { i in
        // The accelerometer only. Posture used to corroborate here too, which
        // quietly disabled this entire rule: a channel reporting `upright` for
        // a quarter of the night corroborates nearly every bout it is asked
        // about, so nothing was ever downgraded and REM stayed scored as wake.
            guard base.motion > 0, let motion = points[i].motion else { return false }
            return motion >= base.motion * SleepThresholds.stirMotionMultiple
        }
    }

    /// What this recording's own signal looks like.
    ///
    /// The published per-stage tables do not transfer. Measured against one
    /// real night on this hardware: coherence sat at 0.60 asleep where the
    /// literature reports 0.91–0.97 for deep sleep, LF/HF at 4.5 against a
    /// reported 0.51, and SDNN ran *higher* asleep than awake — the opposite
    /// direction. Those numbers come from research pipelines, not from this
    /// app's own definitions of coherence, LF/HF and motion.
    ///
    /// What did transfer is the *structure*: coherence peaks every 90–105
    /// minutes across the night, and SDNN runs low exactly where coherence runs
    /// high, which is the relationship the literature describes. So the
    /// discriminators are right and only their scale was wrong — which is the
    /// same conclusion the research reached about population thresholds
    /// generally, applied one level further down.
    struct Baseline {
        let motion: Float
        let hr: Float
        let coherence: Float
        let lfHF: Float
        let sdnn: Float

        init(_ points: [MetricsHistoryPoint]) {
            motion = Self.median(points.compactMap(\.motion)) ?? 0
            hr = Self.median(points.compactMap(\.meanBPM)) ?? 0
            coherence = Self.median(points.compactMap(\.coherence)) ?? 0
            lfHF = Self.median(points.compactMap(\.lfHF)) ?? 0
            sdnn = Self.median(points.compactMap(\.sdnn)) ?? 0
        }

        private static func median(_ v: [Float]) -> Float? {
            guard !v.isEmpty else { return nil }
            let s = v.sorted()
            return s[s.count / 2]
        }
    }

    /// Absorbs runs too short to be a real stage into their neighbours.
    ///
    /// Sleep changes state on the scale of minutes; a single tick that differs
    /// from the ten minutes around it is a turn, a swallow, or a dropped
    /// estimate. Without this a night renders as confetti and every count
    /// derived from it — wake bouts, longest unbroken stretch — is inflated by
    /// noise rather than measuring anything.
    private static func smooth(_ raw: [SleepStage],
                               points: [MetricsHistoryPoint]) -> [SleepStage] {
        guard raw.count > 2 else { return raw }
        // Hoisted. `runSeconds` used to ask for this itself, which meant
        // sorting every gap in the night once per run per pass — thousands of
        // sorts over an eighteen-thousand-sample night, and virtually the
        // entire cost of classifying one.
        let tick = medianInterval(points)
        var out = raw
        // Bounded passes: absorbing one short run can leave its neighbours
        // adjacent and mergeable, but this must always terminate.
        for _ in 0..<4 {
            var changed = false
            for run in runs(of: out)
            where runSeconds(run, points: points, tick: tick) < floor(for: out, run) {
                guard let replacement = neighbour(of: run, in: out) else { continue }
                for i in run { out[i] = replacement }
                changed = true
            }
            if !changed { break }
        }
        return out
    }

    /// Wake gets its own, much lower floor. A brief awakening is a real event
    /// worth counting; a brief stage flicker is not. Sharing one threshold
    /// erased every awakening under three minutes.
    private static func floor(for stages: [SleepStage], _ run: [Int]) -> Double {
        guard let first = run.first else { return SleepThresholds.minStageRunSec }
        return stages[first] == .wake
            ? SleepThresholds.minWakeRunSec
            : SleepThresholds.minStageRunSec
    }

    private static func runs(of stages: [SleepStage]) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = [0]
        for i in 1..<stages.count {
            if stages[i] == stages[i - 1] { current.append(i) }
            else { result.append(current); current = [i] }
        }
        result.append(current)
        return result
    }

    private static func runSeconds(_ run: [Int],
                                   points: [MetricsHistoryPoint],
                                   tick: Double) -> Double {
        guard let f = run.first, let l = run.last, l < points.count else { return 0 }
        // One tick's own interval counts, so a lone sample is not zero-length.
        return points[l].timestamp.timeIntervalSince(points[f].timestamp) + tick
    }

    /// Prefers the longer neighbour, so a short run between two different
    /// stages joins the one that actually dominates around it.
    private static func neighbour(of run: [Int], in stages: [SleepStage]) -> SleepStage? {
        guard let f = run.first, let l = run.last else { return nil }
        let before: SleepStage? = f > 0 ? stages[f - 1] : nil
        let after: SleepStage? = l < stages.count - 1 ? stages[l + 1] : nil
        switch (before, after) {
        case let (b?, a?):
            if b == a { return b }
            return runLength(endingAt: f - 1, in: stages) >= runLength(startingAt: l + 1, in: stages) ? b : a
        case let (b?, nil): return b
        case let (nil, a?): return a
        default: return nil
        }
    }

    private static func runLength(endingAt i: Int, in stages: [SleepStage]) -> Int {
        var n = 0, k = i
        while k >= 0 && stages[k] == stages[i] { n += 1; k -= 1 }
        return n
    }

    private static func runLength(startingAt i: Int, in stages: [SleepStage]) -> Int {
        var n = 0, k = i
        while k < stages.count && stages[k] == stages[i] { n += 1; k += 1 }
        return n
    }

    /// Movement is the honest wake signal on this hardware. It is also the
    /// weakest channel any wearable has — published wake specificity runs
    /// 29–52% — so anything built on this must carry that uncertainty forward
    /// rather than presenting a wake count as fact.
    private static func isWake(_ p: MetricsHistoryPoint, _ base: Baseline) -> Bool {
        // Posture is deliberately NOT consulted here, and the reason is
        // measured. Wiring `upright` in as a wake cue looked unarguable —
        // nobody sleeps standing up — and on a real night it reported the
        // sleeper upright for 1 h 42 m, a quarter of the night, with prone at
        // another 37 %. Those shares do not describe anyone's night in bed;
        // they describe a classifier that cannot tell which way up a chest
        // strap is. Fed into wake detection they produced 4 h 37 m of "awake"
        // out of 11 h in bed.
        //
        // The channel may well be recoverable — the left/right axis is already
        // known to need calibration, and this looks like the same fault along a
        // different axis. Until it is calibrated it does not get a vote, and
        // certainly not a casting one.
        // Either channel alone is enough, and that is deliberate. Getting up
        // shows as motion; lying awake in bed before sleep shows only as an
        // elevated heart rate, with motion no higher than during sleep.
        // Requiring both misses the second case entirely, which is the one
        // that decides where the night starts.
        if let motion = p.motion, base.motion > 0,
           motion >= base.motion * SleepThresholds.wakeMotionMultiple { return true }
        if let hr = p.meanBPM, base.hr > 0,
           hr >= base.hr + SleepThresholds.wakeHRRise { return true }
        // Neither channel clears its own bar, but both are raised at once.
        // Two independent signals agreeing is its own evidence, and it is the
        // only thing that catches the quiet awakening that moves each of them
        // a little and neither a lot.
        if let motion = p.motion, let hr = p.meanBPM, base.motion > 0, base.hr > 0,
           motion >= base.motion * SleepThresholds.stirMotionMultiple,
           hr >= base.hr + SleepThresholds.stirHRRise { return true }
        return false
    }

    /// Two of three, so no single channel can carry the call on its own — a
    /// dropped coherence estimate should not silently reclassify half a night.
    /// Each vote is against this recording's own median, not a fixed number,
    /// so the split follows the night that was actually measured.
    ///
    /// Inclusive on the quiet side. A median is itself an observed value, so
    /// with strict comparisons every tick sitting exactly on it loses its vote
    /// — and when one state occupies more than half the night, the median IS
    /// that state's value and the whole state scores zero.
    private static func quietVotes(_ p: MetricsHistoryPoint, _ base: Baseline) -> Int {
        var votes = 0
        if let c = p.coherence, c >= base.coherence { votes += 1 }
        if let r = p.lfHF, r <= base.lfHF { votes += 1 }
        if let s = p.sdnn, s <= base.sdnn { votes += 1 }
        return votes
    }
}
