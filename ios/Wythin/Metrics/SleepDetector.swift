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

    /// Motion, as a multiple of this recording's own median. Measured on a
    /// real night: 3.9 mg asleep against 12.6 awake and 30 at the morning
    /// rise, so the separation is a ratio rather than a level — an absolute
    /// gate set from published figures (100 mg) never fired at all, and the
    /// whole waking day read as sleep.
    static let wakeMotionMultiple: Float = 3.0
    /// Heart rate above this recording's median, in bpm. Catches lying awake
    /// before sleep, where motion is as low as during sleep and only the pulse
    /// gives it away — 68 bpm at 21:30 against a 56 bpm night.
    static let wakeHRRise: Float = 10
    /// Median motion (mg) above which a candidate is not sleep at all,
    /// whatever its internal structure. The relative gates above compare a
    /// tick to its own recording, so a uniformly thrashing one has no contrast
    /// for them to find — this is the floor that catches it. Set well clear of
    /// both measured levels: 3.9 mg asleep, 12.6 mg awake and sitting.
    static let impossibleSleepMotion: Float = 40

    // MARK: Finding a night inside all-day wear

    /// Beyond this, a run is too long to be one night and gets searched rather
    /// than trimmed. Comfortably above the longest plausible night so an
    /// ordinary evening-to-morning recording is never carved up.
    static let searchWhenLongerThanSec: Double = 14 * 3600
    /// Width of the search window. Wide enough to hold a long night with room
    /// at both ends for the trim to find the real boundaries.
    static let nightSearchSpanSec: Double = 11 * 3600
    /// How far the window slides each step.
    static let nightSearchStepSec: Double = 30 * 60
    /// Breath-rate spread, as a multiple of this recording's own median spread,
    /// above which breathing reads as unsettled. Awake breathing on a measured
    /// night swings several times the asleep spread, so the separation is
    /// generous.
    static let unsettledBreathMultiple: Float = 2.5
    /// How far either side of a wake bout light sleep is marked N1 — the
    /// descent into sleep, and the settling after an arousal.
    static let n1ReachSec: Double = 5 * 60
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

    // MARK: Sessionizing — when the app may write a night down

    /// How long after the last sustained sleep before a night counts as over.
    /// Must comfortably exceed a bathroom trip: five minutes of quiet is not
    /// proof the night ended, and sealing on it truncates the rest of the
    /// night away permanently. 45 minutes awake is someone up for the day.
    static let settleSec: Double = 45 * 60
    /// How far back a poll looks. Long enough to catch a night the app slept
    /// through recording, short enough that stale history cannot resurface as
    /// "last night" the first time the detector ever runs.
    static let lookbackSec: Double = 36 * 3600
    /// Sleep need until the app learns this person's own. A placeholder, and
    /// labelled as one: the experimental between-subject SD for sleep need is
    /// about 0.7 h, so a population figure is the wrong tool and only stands in
    /// until enough nights exist to estimate an individual one.
    static let defaultNeedSec: Double = 7.75 * 3600
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
        let candidates = continuousRuns(all)
            .map(quietestNightWindow)
            .compactMap(trimmedToSleep)
        guard let night = candidates.max(by: { span($0) < span($1) }),
              span(night) >= SleepThresholds.minNightSec,
              let first = night.first, let last = night.last else { return nil }
        return SleepWindow(startedAt: first.timestamp, endedAt: last.timestamp)
    }

    /// Narrows an all-day run to the quietest night-length stretch inside it.
    ///
    /// The stage gates are relative to the recording's own medians, which only
    /// works while that recording is mostly one thing. A strap worn from lunch
    /// through to the next morning gives a 21-hour run whose median heart rate
    /// sits squarely between the waking 76 and the sleeping 55 — so neither
    /// reads as a departure, no tick is called wake, and the trim below has
    /// nothing to cut. Measured on a real capture, that produced a 20 h 35 m
    /// "night" starting at 12:55.
    ///
    /// So find the night first, by the thing that actually distinguishes it:
    /// sustained low heart rate. Then the baseline is a night's, and the gates
    /// mean what they were calibrated to mean.
    private static func quietestNightWindow(_ run: [MetricsHistoryPoint]) -> [MetricsHistoryPoint] {
        guard let first = run.first, let last = run.last else { return run }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span > SleepThresholds.searchWhenLongerThanSec else { return run }

        let width = SleepThresholds.nightSearchSpanSec
        var best: (score: Float, window: [MetricsHistoryPoint])?
        var start = first.timestamp
        while start.addingTimeInterval(width) <= last.timestamp {
            let end = start.addingTimeInterval(width)
            let window = run.filter { $0.timestamp >= start && $0.timestamp <= end }
            if let score = medianHR(window) {
                if best == nil || score < best!.score { best = (score, window) }
            }
            start = start.addingTimeInterval(SleepThresholds.nightSearchStepSec)
        }
        return best?.window ?? run
    }

    private static func medianHR(_ points: [MetricsHistoryPoint]) -> Float? {
        let hrs = points.compactMap(\.meanBPM).sorted()
        guard !hrs.isEmpty else { return nil }
        return hrs[hrs.count / 2]
    }

    /// Cuts the waking hours off both ends of a run.
    ///
    /// Recording continuity is not sleep continuity. Worn from 21:00 through to
    /// 09:00 the strap never disconnects, so gap-splitting alone yields one
    /// twelve-hour run and would report the evening and the morning as part of
    /// the night. The night is the *asleep* part: from the first sustained
    /// sleep to the last.
    ///
    /// Interior wake is deliberately kept. Being up for eight minutes at 03:00
    /// is a wake bout inside one night, not the end of it — and those bouts are
    /// what the continuity section is there to count.
    private static func trimmedToSleep(_ run: [MetricsHistoryPoint]) -> [MetricsHistoryPoint]? {
        let motions = run.compactMap(\.motion).sorted()
        if let median = motions.isEmpty ? nil : motions[motions.count / 2],
           median > SleepThresholds.impossibleSleepMotion { return nil }
        let stages = SleepStages.classify(run)
        guard let first = stages.firstIndex(where: { $0 != .wake }),
              let last = stages.lastIndex(where: { $0 != .wake }) else { return nil }
        return Array(run[first...last])
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
