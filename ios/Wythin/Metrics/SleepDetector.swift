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

    /// The same two channels, at levels that only count **together**.
    ///
    /// `wakeMotionMultiple` and `wakeHRRise` are each set where one signal is
    /// convincing on its own, which is the right bar for a gate that fires
    /// alone — and it makes the pair of them blind in the middle. A quiet
    /// awakening lifts motion and pulse each a little and neither a lot: it
    /// clears no single-channel gate, so it was scored as sleep. That is the
    /// awakening someone actually remembers having, and the reason a night can
    /// feel broken while the hypnogram shows it unbroken.
    ///
    /// Agreement between two independent channels is the evidence here, which
    /// is why each may be set so much lower. Wake specificity from movement
    /// alone runs 29–52% in the published validations; that is a statement
    /// about single channels, and the remedy for it is corroboration.
    static let stirMotionMultiple: Float = 1.8
    static let stirHRRise: Float = 5
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
    ///
    /// **Do not widen this to admit a longer night.** It is the obvious fix and
    /// it is the wrong one: the window is chosen by lowest median heart rate,
    /// so its width decides which stretch wins, and widening it to 13 h moved
    /// the winner on a real recorded night — the detector ended that night at
    /// 06:24 against a measured 07:30 rise. The ceiling problem is real, but it
    /// belongs to `nightSearchPadSec`, which fixes it without touching the
    /// comparison that locates the night in the first place.
    static let nightSearchSpanSec: Double = 11 * 3600
    /// How far the window slides each step.
    static let nightSearchStepSec: Double = 30 * 60
    /// Room left either side of the chosen window before the trim runs.
    ///
    /// Locating the night and bounding it are two different jobs, and the
    /// search window was silently doing both — whatever it returned was the
    /// widest answer the trim could possibly give, so an eleven-hour window
    /// could not yield an eleven-and-a-half-hour night however clear the data.
    /// The padding separates them: the median-heart-rate comparison still runs
    /// over a fixed 11 h, so it still picks the same stretch it always did, and
    /// only then is the trim handed room to reach a genuine lie-in.
    static let nightSearchPadSec: Double = 75 * 60
    /// Breath-rate spread, as a multiple of this recording's own median spread,
    /// above which breathing reads as unsettled. Awake breathing on a measured
    /// night swings several times the asleep spread, so the separation is
    /// generous.
    static let unsettledBreathMultiple: Float = 2.5
    /// How far either side of a wake bout light sleep is marked N1 — the
    /// descent into sleep, and the settling after an arousal.
    static let n1ReachSec: Double = 5 * 60
    /// Sleep has to persist this long before the night is said to have begun.
    ///
    /// `SleepStages.smooth` already absorbs stage runs under `minStageRunSec`
    /// (three minutes), so anything longer than that survives to the trim — and
    /// six still minutes on the sofa at 17:00 is longer than that. Taking the
    /// first surviving non-wake tick as onset anchored a real night to the
    /// evening it was recorded in: 17:00 → 05:37, of which 7 h 15 m was scored
    /// awake. Ten persistent minutes is the actigraphy convention for onset and
    /// comfortably excludes sitting quietly, while still admitting a genuine
    /// short doze followed by an arousal.
    static let minSustainedSleepSec: Double = 10 * 60
    /// Most a single tick may be credited with. Beyond this the gap is a hole
    /// in the recording, not time asleep.
    static let maxTickCreditSec: Double = 120

    /// Bumped whenever the detector, the classifier or the score changes shape.
    /// A night written by an older version is recomputed rather than left in
    /// place — otherwise the app shows numbers from an algorithm that no longer
    /// exists, with fields the old code never populated rendering as dashes.
    /// Cut points on the depth axis, in z-units of this night's own signal.
    ///
    /// Both replace fixed *shares* (formerly 21% deep, 23% REM), which meant
    /// every night reported the same breakdown no matter what was recorded.
    ///
    /// `remDepth` at zero has a physiological reading rather than an arbitrary
    /// one: the axis is centred on the whole recording, so a tick at or below
    /// zero is one whose autonomic state is no deeper than this person's
    /// night-wide average — and REM is precisely the stage that resembles
    /// wake in heart rate and LF/HF. The comparison is strict, so a recording
    /// with no structure at all (axis identically zero) reports no REM rather
    /// than reporting itself as entirely REM.
    ///
    /// `deepDepth` at 2.2 is calibrated against a real overnight capture,
    /// where it selects the deepest ~22% — inside the typical adult N3 range
    /// of 13–23%. A night with less depth structure now returns less N3,
    /// which is the entire point of the change.
    static let deepDepth: Double = 2.2
    static let remDepth: Double = 0.0

    static let algorithmVersion: Int = 11
    /// Shortest run that can stand as its own stage. Sleep changes state on
    /// the scale of minutes; anything briefer is a turn or a dropped estimate,
    /// and leaving it in inflates every count derived from the hypnogram.
    static let minStageRunSec: Double = 180

    /// The same floor, for WAKE — and deliberately much lower.
    ///
    /// One threshold used to govern both, which meant any awakening shorter
    /// than three minutes was absorbed into the sleep around it and vanished:
    /// out of the hypnogram, out of the awake total, out of the wake-bout count
    /// continuity is scored on. Someone who woke four times for a minute each
    /// was shown an unbroken night.
    ///
    /// Three minutes is right for stage flicker — N2 and N3 trading places for
    /// one tick is noise. It is wrong for wake, which is a different kind of
    /// event: polysomnography scores in 30-second epochs and actigraphy counts
    /// bouts from about a minute, because a brief awakening is real and worth
    /// counting even when a stage flicker is not.
    static let minWakeRunSec: Double = 60

    /// Wake shorter than this does not break a stretch of *persistent* sleep.
    ///
    /// The companion to the above, and it has to exist. Showing 60-second
    /// arousals means they also start splitting the runs `sustainedSleepRuns`
    /// measures, so a stretch that was twelve unbroken minutes becomes two
    /// six-minute pieces and sleep onset slides later — or, on a restless
    /// night, no run clears the bar and the night is not found at all. An
    /// arousal is not the end of persistent sleep; it is an event inside it.
    static let briefArousalSec: Double = 120
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

    /// How long evidence of being **out of bed** must persist before it ends
    /// the night.
    ///
    /// The companion to `settleSec`, and the reason that constant is no longer
    /// trusted on its own. `settleSec` asks only *how long* a wake bout was; it
    /// cannot tell lying awake at 05:00 from getting up for the day. A real
    /// night was cut at 05:08 by exactly that blindness — woken, stayed in bed,
    /// slept again, rose at 08:30 — and the three hours after the gap were
    /// filed as a separate episode and thrown away, along with every awakening
    /// in them.
    ///
    /// Sleep medicine ends the sleep period at the **final awakening**, and
    /// defines that by leaving the sleep opportunity, not by a stopwatch. This
    /// is how long the leaving has to look like leaving.
    ///
    /// **Twenty minutes, not five.** Five was the first number here and it
    /// would have recreated the very complaint this work exists to fix. A chest
    /// strap cannot tell sitting up in bed from standing in the kitchen — both
    /// read `upright` — so a five-minute bar ends the night on a trip to make
    /// coffee, and the sleep after it becomes a separate episode and is thrown
    /// away. Getting up briefly and coming back to bed is ordinary, and it must
    /// survive. Twenty continuous minutes is the difference between a trip and
    /// a morning, and it still clears every case that should end a night: the
    /// recorded morning-doze night is up for three and a half hours.
    static let outOfBedSec: Double = 20 * 60

    /// Motion, as a multiple of this recording's own median, that means moving
    /// about rather than lying awake.
    ///
    /// Deliberately far above `wakeMotionMultiple` (3×, which turning over
    /// clears) because it is answering a different question. That gate asks
    /// "is this person awake"; this one asks "is this person on their feet",
    /// and the two have very different costs when wrong. Measured on this
    /// hardware: 3.9 mg asleep, 12.6 mg awake and sitting, 30 mg at the morning
    /// rise — so eight times the asleep median sits above sitting up and below
    /// walking about.
    static let outOfBedMotionMultiple: Float = 8.0

    /// Hard ceiling on a wake bout that may still sit *inside* one night.
    ///
    /// The backstop for nights with no usable position channel: everything
    /// recorded before `bodyPosition` existed, and any stretch where the strap
    /// could not resolve gravity. Without it, a missing channel means no
    /// out-of-bed evidence can ever be found, and an evening doze would merge
    /// with the following morning's sleep into a single fourteen-hour "night".
    /// Three hours is longer than any plausible in-bed awakening and far short
    /// of the gap between two genuinely separate sleeps.
    static let maxInBedWakeSec: Double = 3 * 3600
    /// How far back a poll looks. Long enough to catch a night the app slept
    /// through recording, short enough that stale history cannot resurface as
    /// "last night" the first time the detector ever runs.
    static let lookbackSec: Double = 21 * 24 * 3600
    /// Ceiling on one pass, so a first run over weeks of history cannot spin.
    static let maxNightsPerPass: Int = 25
    /// Hour of the evening a night slice opens, and the hour of the next day it
    /// closes. Wide enough for a late night and a long lie-in.
    static let nightSliceFromHour: Double = 17
    static let nightSliceToHour: Double = 12
    /// The circadian trough a night must cover, and by how much. Local hours
    /// on the WAKE date.
    static let troughFromHour: Double = 1
    static let troughToHour: Double = 5
    static let minTroughOverlapSec: Double = 2 * 3600
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

    /// Every night in a long recording, one pass.
    ///
    /// Slicing by calendar first is what makes this affordable. Running the
    /// single-night search across three weeks of samples is quadratic — the
    /// window scan filters the whole array at every step, and the caller then
    /// repeats it once per night found. On a real store of 90,000 samples that
    /// pinned the main thread for minutes. A night lives between one evening
    /// and the next midday, so cutting there first bounds every inner search to
    /// about eighteen hours of data.
    static func detectAll(_ points: [MetricsHistoryPoint]) -> [SleepWindow] {
        let all = points.sorted { $0.timestamp < $1.timestamp }
        guard let first = all.first, let last = all.last else { return [] }

        let cal = Calendar.current
        var found: [SleepWindow] = []
        var dayStart = cal.startOfDay(for: first.timestamp)

        while dayStart <= last.timestamp {
            // Evening through to the following midday: wide enough for a late
            // night and a long lie-in, narrow enough to hold exactly one.
            let from = dayStart.addingTimeInterval(SleepThresholds.nightSliceFromHour * 3600)
            let to = dayStart.addingTimeInterval((24 + SleepThresholds.nightSliceToHour) * 3600)
            let slice = all.filter { $0.timestamp >= from && $0.timestamp <= to }
            if slice.count > 20, let night = detect(slice), spansTheCircadianTrough(night) {
                // The slices overlap by design, so the same night can surface
                // twice; keep one per wake date.
                if !found.contains(where: { $0.day == night.day }) { found.append(night) }
            }
            dayStart = cal.date(byAdding: .day, value: 1, to: dayStart) ?? last.timestamp.addingTimeInterval(1)
        }
        return found
    }

    /// Whether a candidate covers the hours a night has to cover.
    ///
    /// Without this the backfill invents nights out of daytime. On days the
    /// strap was not worn overnight the search still returns the quietest
    /// stretch it can find in the slice, which produced entries like
    /// 06:45–11:44 and 17:00–21:12 — real quiet periods, but a late lie-in and
    /// an evening on the sofa, not sleep. Human sleep is anchored to the
    /// circadian trough; something that misses 01:00–05:00 entirely is a rest,
    /// and rests belong to the anchor, not here.
    static func spansTheCircadianTrough(_ window: SleepWindow) -> Bool {
        let cal = Calendar.current
        let day = cal.startOfDay(for: window.endedAt)
        let troughStart = day.addingTimeInterval(SleepThresholds.troughFromHour * 3600)
        let troughEnd = day.addingTimeInterval(SleepThresholds.troughToHour * 3600)
        let overlap = min(window.endedAt, troughEnd).timeIntervalSince(max(window.startedAt, troughStart))
        return overlap >= SleepThresholds.minTroughOverlapSec
    }

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
        // Two moving indices rather than a filter per step: filtering the run
        // at every window position is quadratic, and on a long recording that
        // is the difference between milliseconds and minutes.
        var best: (score: Float, lo: Int, hi: Int)?
        var lo = 0, hi = 0
        var start = first.timestamp
        while start.addingTimeInterval(width) <= last.timestamp {
            let end = start.addingTimeInterval(width)
            while lo < run.count && run[lo].timestamp < start { lo += 1 }
            if hi < lo { hi = lo }
            while hi < run.count && run[hi].timestamp <= end { hi += 1 }
            if hi > lo, let score = medianHR(Array(run[lo..<hi])) {
                if best == nil || score < best!.score { best = (score, lo, hi) }
            }
            start = start.addingTimeInterval(SleepThresholds.nightSearchStepSec)
        }
        guard let best else { return run }
        let pad = SleepThresholds.nightSearchPadSec
        var from = best.lo, to = best.hi
        let earliest = run[best.lo].timestamp.addingTimeInterval(-pad)
        let latest = run[best.hi - 1].timestamp.addingTimeInterval(pad)
        while from > 0 && run[from - 1].timestamp >= earliest { from -= 1 }
        while to < run.count && run[to].timestamp <= latest { to += 1 }
        return Array(run[from..<to])
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
    /// **Sustained is the operative word, and it used not to be enforced.** The
    /// bounds came from `firstIndex(where: { $0 != .wake })`, which is the first
    /// non-wake tick of any duration. Smoothing removes runs under three
    /// minutes, so a quiet six-minute spell early in the evening survives it and
    /// became the start of the night — one real capture opened at 17:00 and
    /// reported 7 h 15 m of a 12 h 37 m "night" as awake, because six hours of
    /// evening sat inside the window. Onset now needs
    /// `minSustainedSleepSec` of persistent sleep, and so does the final wake.
    ///
    /// Interior wake is deliberately kept. Being up for eight minutes at 03:00
    /// is a wake bout inside one night, not the end of it — and those bouts are
    /// what the continuity section is there to count.
    private static func trimmedToSleep(_ run: [MetricsHistoryPoint]) -> [MetricsHistoryPoint]? {
        let motions = run.compactMap(\.motion).sorted()
        let medianMotion = motions.isEmpty ? nil : motions[motions.count / 2]
        if let medianMotion, medianMotion > SleepThresholds.impossibleSleepMotion { return nil }
        let stages = SleepStages.classify(run)
        let sustained = sustainedSleepRuns(stages, points: run)
        guard let episode = mainSleepEpisode(sustained, points: run,
                                             medianMotion: medianMotion ?? 0) else { return nil }
        return Array(run[episode])
    }

    /// Index where sleep picks up again after a wake stretch starting at
    /// `from`, provided that stretch is shorter than `briefArousalSec`.
    /// Nil when the wake is long enough to genuinely end the run.
    private static func sleepResumes(_ from: Int,
                                     _ stages: [SleepStage],
                                     _ points: [MetricsHistoryPoint]) -> Int? {
        var k = from
        while k < stages.count && stages[k] == .wake { k += 1 }
        guard k < stages.count else { return nil }
        let gap = points[k].timestamp.timeIntervalSince(points[from].timestamp)
        return gap < SleepThresholds.briefArousalSec ? k : nil
    }

    /// The night, out of everything in this run that qualifies as sleep.
    ///
    /// Requiring the boundaries to be *sustained* sleep fixed the night that
    /// opened at 17:00, but it only asks whether a boundary is real sleep — never
    /// whether that sleep belongs to the same night. A fifteen-minute doze at
    /// 07:30, hours after getting up, passes the sustained test and dragged the
    /// window out with it: one recorded night ran 8 h 26 m and called 3 h 31 m of
    /// it awake, nearly all of it a morning nobody was in bed for.
    ///
    /// Sleep medicine does not define the night as first sleep to last sleep. The
    /// sleep period runs from onset to the FINAL AWAKENING, and it is terminated
    /// by a wake bout long enough to mean the person got up for the day; sleep
    /// after that is a separate episode. `settleSec` is already this codebase's
    /// name for that threshold — it decides when a night may be written down —
    /// and the trim simply never consulted it.
    ///
    /// So: group sustained sleep into episodes separated by a **final
    /// awakening**, and keep the one holding the most sleep. Interior bouts
    /// stay inside the night, which is what the continuity section counts.
    ///
    /// **What a final awakening is, is the part that was wrong.** It was read
    /// as `settleSec` of wake and nothing else — a stopwatch — so any long
    /// awakening ended the night by definition. Someone who woke at 05:08, lay
    /// in bed, slept again and got up at 08:30 had the second half of their
    /// night split off and discarded: 8 h 11 m in bed reported against a
    /// 11 h 34 m opportunity, with every morning awakening outside the window
    /// and therefore uncounted. See `nightEnds(between:and:points:medianMotion:)`
    /// for the test that replaced it.
    private static func mainSleepEpisode(_ sustained: [ClosedRange<Int>],
                                         points: [MetricsHistoryPoint],
                                         medianMotion: Float) -> ClosedRange<Int>? {
        guard !sustained.isEmpty else { return nil }

        var episodes: [[ClosedRange<Int>]] = [[sustained[0]]]
        for run in sustained.dropFirst() {
            let previousEnd = episodes[episodes.count - 1].last!.upperBound
            if nightEnds(between: previousEnd, and: run.lowerBound,
                         points: points, medianMotion: medianMotion) {
                episodes.append([run])
            } else {
                episodes[episodes.count - 1].append(run)
            }
        }

        // Most sleep, not the longest span: a span would let an episode win on
        // the strength of the wake bouts inside it.
        let best = episodes.max { a, b in asleepSeconds(a, points) < asleepSeconds(b, points) }
        guard let best, let lo = best.first?.lowerBound, let hi = best.last?.upperBound else {
            return nil
        }
        return lo...hi
    }

    private static func asleepSeconds(_ runs: [ClosedRange<Int>],
                                      _ points: [MetricsHistoryPoint]) -> Double {
        runs.reduce(0) { total, r in
            total + points[r.upperBound].timestamp.timeIntervalSince(points[r.lowerBound].timestamp)
        }
    }

    /// Whether the wake stretch between two sustained sleep runs is the end of
    /// the night, or a wake bout inside it.
    ///
    /// Three tests, in order of how much they are trusted:
    ///
    /// 1. **Past `maxInBedWakeSec`** — separate sleeps, whatever the sensors
    ///    say. The backstop for recordings with no position channel at all.
    /// 2. **Under `settleSec`** — an awakening, whatever the sensors say. Nobody
    ///    starts a new night forty minutes after ending the last one, and
    ///    letting evidence override this would split a night on a trip to the
    ///    bathroom.
    /// 3. **In between** — ask the accelerometer. This is the band the old
    ///    stopwatch got wrong in both directions, and the only band where the
    ///    answer was ever in doubt.
    private static func nightEnds(between previousEnd: Int,
                                  and nextStart: Int,
                                  points: [MetricsHistoryPoint],
                                  medianMotion: Float) -> Bool {
        let gap = points[nextStart].timestamp.timeIntervalSince(points[previousEnd].timestamp)
        if gap >= SleepThresholds.maxInBedWakeSec { return true }
        guard gap >= SleepThresholds.settleSec else { return false }
        return leftTheBed(previousEnd...nextStart, points: points, medianMotion: medianMotion)
    }

    /// Sustained evidence, inside a wake stretch, that the person got up.
    ///
    /// Two channels, either sufficient, because neither is reliably present.
    /// Posture is the stronger signal — `upright` is not a position anyone
    /// sleeps in, and it is the one cue that distinguishes *out of bed* from
    /// *awake in bed* rather than merely restating that the person is awake.
    /// But `bodyPosition` resolves only when the strap can read gravity
    /// cleanly, and it is nil for every night recorded before it existed, so
    /// gross motion stands in when it is missing.
    ///
    /// Requiring the evidence to *persist* for `outOfBedSec` is what keeps
    /// this from firing on the thing it most resembles: sitting up to drink
    /// water and lying back down reads as upright for a tick or two, and would
    /// otherwise end a night at 03:00.
    static func leftTheBed(_ range: ClosedRange<Int>,
                           points: [MetricsHistoryPoint],
                           medianMotion: Float) -> Bool {
        var runStart: Int?
        for i in range where i < points.count {
            let upright = points[i].bodyPosition == .upright
            let moving = medianMotion > 0
                && (points[i].motion ?? 0) >= medianMotion * SleepThresholds.outOfBedMotionMultiple
            guard upright || moving else { runStart = nil; continue }
            let start = runStart ?? i
            runStart = start
            if points[i].timestamp.timeIntervalSince(points[start].timestamp)
                >= SleepThresholds.outOfBedSec { return true }
        }
        return false
    }

    /// Index ranges of unbroken sleep lasting at least `minSustainedSleepSec`.
    ///
    /// Closed ranges over `stages`, measured on the clock rather than in ticks —
    /// the cadence changes between foreground and background recording, so a
    /// tick count is not a duration.
    private static func sustainedSleepRuns(_ stages: [SleepStage],
                                           points: [MetricsHistoryPoint]) -> [ClosedRange<Int>] {
        guard stages.count == points.count, !stages.isEmpty else { return [] }
        var out: [ClosedRange<Int>] = []
        var i = 0
        while i < stages.count {
            guard stages[i] != .wake else { i += 1; continue }
            var j = i
            while j + 1 < stages.count {
                if stages[j + 1] != .wake { j += 1; continue }
                // A brief arousal does not end persistent sleep. Step over it
                // if sleep resumes on the far side quickly enough; otherwise
                // this run really has ended.
                guard let resume = sleepResumes(j + 1, stages, points) else { break }
                j = resume - 1
            }
            // Credit the run up to the next tick, so a stretch that ends at the
            // last sample still has the width its samples actually cover.
            let end = j + 1 < points.count ? points[j + 1].timestamp : points[j].timestamp
            if end.timeIntervalSince(points[i].timestamp) >= SleepThresholds.minSustainedSleepSec {
                out.append(i...j)
            }
            i = j + 1
        }
        return out
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

// MARK: - Naps

/// Every gate a stretch of *daytime* sleep has to clear.
///
/// Deliberately its own set, and deliberately not `SleepThresholds`. The night
/// detector's gates are all relative to a recording that is mostly one thing —
/// a night — and a nap is the opposite case by construction: a short quiet
/// island in a long noisy day. Sharing constants between the two would drag the
/// night's assumptions somewhere they are false, which is the same mistake
/// `SleepThresholds` documents about `AnchorThresholds`.
enum NapThresholds {
    /// Shortest daytime sleep worth recording. Ten minutes is the actigraphy
    /// floor for a scored nap, and it is also about where the restorative
    /// literature starts finding an effect — a ten-minute nap improves alertness
    /// measurably, a five-minute one barely does.
    static let minNapSec: Double = 10 * 60

    /// Longest. Above this it is not a nap and this detector must not claim it:
    /// `SleepDetector` owns anything that long, and two detectors both writing
    /// the same stretch is how one afternoon becomes two entries.
    static let maxNapSec: Double = SleepThresholds.minNightSec

    /// How far below **quiet waking** the pulse has to sit, in bpm.
    ///
    /// The discriminator, and low motion is not: sitting still, reading,
    /// watching something and meditating are all as motionless as sleep. What
    /// separates sleep is that the pulse drops below where it sits at rest.
    ///
    /// **Against rest — not against the day.** The first version of this
    /// compared to the day's median heart rate and shipped, and it was wrong in
    /// a way that made the gate meaningless: a day's median is lifted by every
    /// minute spent walking about, so simply sitting down puts a person five to
    /// fifteen beats under it without being remotely asleep. It reported a
    /// "Power Nap" for an afternoon at a desk. The comparison has to be against
    /// quiet wakefulness, which is the state a nap actually has to be
    /// distinguished from.
    static let hrDropBPM: Float = 4

    /// Motion ceiling, as a share of the surrounding day's median. This is what
    /// proposes a candidate; `hrDropBPM` is what decides it. Stillness is
    /// necessary for sleep and nowhere near sufficient, and the two jobs are
    /// kept apart deliberately.
    static let motionFraction: Float = 0.75

    /// Ticks quiet enough to stand for "at rest but awake", as a share of the
    /// day's median motion. The pool `hrDropBPM` is measured against.
    static let restingMotionFraction: Float = 1.0

    /// Fewest resting ticks outside a candidate before the comparison means
    /// anything. Under this there is no honest baseline and no nap is claimed —
    /// silence beats a guess.
    static let minRestingTicks: Int = 60

    /// A brief stir does not end a nap, for the same reason it does not end a
    /// night — see `SleepThresholds.briefArousalSec`. Shorter here because the
    /// whole event is shorter: two minutes is a fifth of the smallest nap this
    /// will report, where it is a rounding error in a night.
    static let briefStirSec: Double = 2 * 60

    /// How far a nap must sit clear of a recorded night. Guards the boundary
    /// where the night detector's trim let go — the quiet half hour after the
    /// final awakening is the tail of the night, not a nap at breakfast.
    static let nightClearanceSec: Double = 30 * 60

    /// How much waking data is needed before the day's own baseline means
    /// anything. Without a floor, a recording that is *only* a nap makes that
    /// nap its own baseline, finds no drop against itself, and reports nothing —
    /// or worse, on a slightly longer one, reports the surrounding minutes as
    /// the nap. Three hours of day is enough to know what this person's day
    /// looks like.
    static let minWakingSpanSec: Double = 3 * 3600

    /// Bumped whenever nap detection changes shape, so stored naps are rebuilt
    /// rather than left behind by a pipeline that no longer exists.
    static let algorithmVersion: Int = 2
}

/// Finds sleep that happened during the day.
///
/// The counterpart to `SleepDetector`, not a variant of it. That detector
/// searches for the single quietest night-length stretch and throws away
/// everything shorter than three hours — which is correct for its job and means
/// a nap has never been visible to this app at all, however plainly it is
/// written in the trace.
enum NapDetector {

    /// Every nap in a span of recorded ticks, oldest first.
    ///
    /// - Parameters:
    ///   - points: tick history; sorted here, so order in is irrelevant.
    ///   - nights: already-detected nights, which are excluded along with a
    ///     clearance either side. Pass what the night detector found, not what
    ///     is stored, or the first run finds naps inside every night.
    static func detect(_ points: [MetricsHistoryPoint],
                       excluding nights: [SleepWindow]) -> [SleepWindow] {
        let all = points.sorted { $0.timestamp < $1.timestamp }
        let waking = all.filter { p in
            !nights.contains { night in
                p.timestamp >= night.startedAt.addingTimeInterval(-NapThresholds.nightClearanceSec)
                    && p.timestamp <= night.endedAt.addingTimeInterval(NapThresholds.nightClearanceSec)
            }
        }
        // One day at a time, because "the surrounding day" is the entire
        // comparison this detector makes. Handed three weeks of history in one
        // array — which is exactly what the recorder's lookback provides — the
        // baseline becomes a three-week median rather than today's, and
        // `minWakingSpanSec` compares the first tick to the last across the
        // whole span and therefore always passes, which is the opposite of
        // what it is for.
        let cal = Calendar.current
        return Dictionary(grouping: waking) { cal.startOfDay(for: $0.timestamp) }
            .sorted { $0.key < $1.key }
            .flatMap { napsWithin($0.value) }
    }

    /// The naps inside a single day, judged against that day's own signal.
    private static func napsWithin(_ waking: [MetricsHistoryPoint]) -> [SleepWindow] {
        guard let first = waking.first, let last = waking.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= NapThresholds.minWakingSpanSec,
              median(waking.compactMap(\.meanBPM)) != nil,
              let dayMotion = median(waking.compactMap(\.motion)) else { return [] }

        // Stillness proposes; the pulse disposes. Motion alone picks the
        // candidates — every nap is still, so nothing asleep is missed here —
        // and each candidate then has to show a real fall in heart rate before
        // it is called sleep.
        let still = waking.map { p -> Bool in
            guard let motion = p.motion else { return true }
            return motion <= dayMotion * NapThresholds.motionFraction
        }
        // Everything quiet, as the pool that stands for "at rest but awake".
        let restingIdx = waking.indices.filter { i in
            (waking[i].motion ?? 0) <= dayMotion * NapThresholds.restingMotionFraction
                && waking[i].meanBPM != nil
        }

        return runs(of: still, in: waking)
            .filter { span(waking, $0) >= NapThresholds.minNapSec }
            .filter { span(waking, $0) <= NapThresholds.maxNapSec }
            .filter { asleepByPulse($0, waking, resting: restingIdx) }
            .map { SleepWindow(startedAt: waking[$0.lowerBound].timestamp,
                               endedAt: waking[$0.upperBound].timestamp) }
    }

    /// Whether a still stretch is actually *asleep*, judged by pulse.
    ///
    /// The baseline is built from the day's other quiet minutes — explicitly
    /// **excluding the candidate itself**. Including it is self-defeating: a
    /// long nap is a large share of the day's quiet time, so it drags the very
    /// median it is being compared against down towards itself, and the deeper
    /// the sleep the more it hides. Comparing a stretch to everything except
    /// that stretch is the only version of this question that is well posed.
    private static func asleepByPulse(_ run: ClosedRange<Int>,
                                      _ waking: [MetricsHistoryPoint],
                                      resting: [Int]) -> Bool {
        let outside = resting.filter { !run.contains($0) }.compactMap { waking[$0].meanBPM }
        guard outside.count >= NapThresholds.minRestingTicks,
              let restingHR = median(outside),
              let napHR = median(waking[run].compactMap(\.meanBPM)) else { return false }
        return napHR <= restingHR - NapThresholds.hrDropBPM
    }

    /// Index ranges of sustained daytime sleep, stepping over brief stirs.
    private static func runs(of asleep: [Bool],
                             in points: [MetricsHistoryPoint]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var i = 0
        while i < asleep.count {
            guard asleep[i] else { i += 1; continue }
            var j = i
            while j + 1 < asleep.count {
                if asleep[j + 1] { j += 1; continue }
                guard let resume = resumes(after: j + 1, asleep, points) else { break }
                j = resume - 1
            }
            out.append(i...j)
            i = j + 1
        }
        return out
    }

    /// Where sleep picks up again after a stir starting at `from`, provided the
    /// stir is brief enough not to have ended the nap.
    private static func resumes(after from: Int,
                                _ asleep: [Bool],
                                _ points: [MetricsHistoryPoint]) -> Int? {
        var k = from
        while k < asleep.count && !asleep[k] { k += 1 }
        guard k < asleep.count else { return nil }
        let gap = points[k].timestamp.timeIntervalSince(points[from].timestamp)
        return gap < NapThresholds.briefStirSec ? k : nil
    }

    private static func span(_ points: [MetricsHistoryPoint], _ r: ClosedRange<Int>) -> Double {
        points[r.upperBound].timestamp.timeIntervalSince(points[r.lowerBound].timestamp)
    }

    private static func median(_ v: [Float]) -> Float? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[s.count / 2]
    }
}
