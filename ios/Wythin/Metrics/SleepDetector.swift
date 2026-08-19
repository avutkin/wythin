import Foundation

// MARK: - Thresholds

/// Every gate a night must clear. Deliberately separate from
/// `AnchorThresholds`: the two detectors want opposite things, and sharing
/// constants between them is how the anchor's 04:00 floor would leak back in.
enum SleepThresholds {
    /// Wall-clock hole beyond which two stretches are separate sleeps. Generous
    /// on purpose — a BLE reconnect, a bathroom trip, or a few minutes of the
    /// strap losing contact are all *inside* a night, and splitting on them
    /// would turn one night into three fragments that each fail the length
    /// gate. An evening nap sits hours from the night, so it still separates.
    static let maxGapSec: Double = 20 * 60
    /// Below this a stretch is a nap, not a night. Scoring a 40-minute nap
    /// against an 8-hour need would read as a catastrophic night rather than
    /// as what it is. Naps are a separate construct with their own dose rules.
    static let minNightSec: Double = 3 * 3600

    // MARK: Stage discrimination — values from the published per-stage tables

    /// ACC magnitude SD (mg) at or above which a tick reads as awake. Well
    /// clear of `AnchorThresholds.stillnessSD`, which exists to reject any
    /// movement at all: here turning over must stay inside sleep.
    static let wakeMotionSD: Float = 100
    /// RR↔breath coherence. N3 measures 0.91–0.97, N2 0.81–0.89, REM 0.69–0.82.
    static let quietCoherence: Float = 0.85
    /// LF/HF. SWS 0.51, stage 2 1.11, REM 2.02.
    static let quietLFHF: Float = 1.2
    /// SDNN (ms). SWS 53.8, stage 2 68.5, REM 105.5.
    static let quietSDNN: Float = 75
    /// Shortest run that can stand as its own stage. Sleep changes state on
    /// the scale of minutes; anything briefer is a turn or a dropped estimate,
    /// and leaving it in inflates every count derived from the hypnogram.
    static let minStageRunSec: Double = 180
    /// Regularity is a comparison between days, so it needs at least two.
    /// Published SRI uses a trailing week; two is the floor at which the
    /// number means anything at all, and the UI should say how many it had.
    static let minNightsForSRI: Int = 2
    /// One section is not a night score. Mirrors the exercise model's rule
    /// that a headline needs at least two present components behind it.
    static let minSectionsForOverall: Int = 2
}

// MARK: - Window

/// One night, as measured. Pure value: no persistence, no clock.
struct SleepWindow: Equatable {
    let startedAt: Date
    let endedAt:   Date

    var durationSec: Double { endedAt.timeIntervalSince(startedAt) }

    /// The night of the 20th–21st is the **21st's** night. Filing it under the
    /// start date puts every normal night on the previous day and makes a
    /// "nights this week" count off by one at both ends.
    var day: Date { Calendar.current.startOfDay(for: endedAt) }
}

// MARK: - Detector

/// Finds the night in a span of recorded ticks.
///
/// This is the counterpart to `AnchorDetector`, not a variant of it. The anchor
/// exists to find a *standardized waking rest* and refuses anything starting
/// before `AnchorThresholds.earliestAnchorHour` precisely because an overnight
/// stretch would outscore every waking rest and wreck the hour-tolerance the
/// day score depends on. This detector wants exactly the stretch the anchor
/// throws away.
enum SleepDetector {

    static func detect(_ points: [MetricsHistoryPoint]) -> SleepWindow? {
        let all = points.sorted { $0.timestamp < $1.timestamp }
        let runs = continuousRuns(all)
        guard let night = runs.max(by: { span($0) < span($1) }),
              span(night) >= SleepThresholds.minNightSec,
              let first = night.first, let last = night.last else { return nil }
        return SleepWindow(startedAt: first.timestamp, endedAt: last.timestamp)
    }

    /// Splits on wall-clock holes only. Unlike the anchor's run splitter this
    /// does not break on *stirring*: turning over, or a brief wake, is part of
    /// a night rather than the end of one. Only a hole big enough to mean the
    /// recording actually stopped separates two sleeps.
    private static func continuousRuns(_ all: [MetricsHistoryPoint]) -> [[MetricsHistoryPoint]] {
        var runs: [[MetricsHistoryPoint]] = []
        var current: [MetricsHistoryPoint] = []
        for p in all {
            if let prev = current.last,
               p.timestamp.timeIntervalSince(prev.timestamp) > SleepThresholds.maxGapSec {
                runs.append(current)
                current = []
            }
            current.append(p)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func span(_ run: [MetricsHistoryPoint]) -> Double {
        guard let f = run.first, let l = run.last else { return 0 }
        return l.timestamp.timeIntervalSince(f.timestamp)
    }
}
