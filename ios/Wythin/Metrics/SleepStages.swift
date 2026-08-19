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
        let raw = points.map { p -> SleepStage in
            if isWake(p) { return .wake }
            return quietVotes(p) >= 2 ? .quiet : .active
        }
        return smooth(raw, points: points)
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
        var out = raw
        // Bounded passes: absorbing one short run can leave its neighbours
        // adjacent and mergeable, but this must always terminate.
        for _ in 0..<4 {
            var changed = false
            for run in runs(of: out) where runSeconds(run, points: points) < SleepThresholds.minStageRunSec {
                guard let replacement = neighbour(of: run, in: out) else { continue }
                for i in run { out[i] = replacement }
                changed = true
            }
            if !changed { break }
        }
        return out
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

    private static func runSeconds(_ run: [Int], points: [MetricsHistoryPoint]) -> Double {
        guard let f = run.first, let l = run.last, l < points.count else { return 0 }
        // One tick's own interval counts, so a lone sample is not zero-length.
        let tick = points.count > 1
            ? points[1].timestamp.timeIntervalSince(points[0].timestamp)
            : 0
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
    private static func isWake(_ p: MetricsHistoryPoint) -> Bool {
        guard let motion = p.motion else { return false }
        return motion >= SleepThresholds.wakeMotionSD
    }

    /// Two of three, so no single channel can carry the call on its own — a
    /// dropped coherence estimate should not silently reclassify half a night.
    private static func quietVotes(_ p: MetricsHistoryPoint) -> Int {
        var votes = 0
        if let c = p.coherence, c >= SleepThresholds.quietCoherence { votes += 1 }
        if let r = p.lfHF, r <= SleepThresholds.quietLFHF { votes += 1 }
        if let s = p.sdnn, s <= SleepThresholds.quietSDNN { votes += 1 }
        return votes
    }
}
