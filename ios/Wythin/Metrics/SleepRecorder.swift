import Foundation
import SwiftData

/// Turns a detected night into an `ActivityLog` the user can actually see.
///
/// This is the piece that was missing: the detector, the classifier, the
/// regularity index and the score were all pure functions nothing ever called,
/// so a measured night existed in the sample store and nowhere else.
///
/// Poll-shaped and idempotent, mirroring `AppEnvironment.detectAnchorIfDue`.
/// Safe to call as often as the tick loop likes.
enum SleepRecorder {

    /// Runs the pipeline off the main thread.
    ///
    /// The work is bounded but not small — three weeks of samples on a first
    /// run — and it must never sit between a tap and the screen redrawing. A
    /// background `ModelContext` is created on the calling thread and used only
    /// there, which is the supported pattern; the main context picks the rows
    /// up on its next fetch.
    ///
    /// `onRecorded` fires with the number of nights written, and only when
    /// that is more than zero. The activity upload runs once at launch, in
    /// parallel with this pass, and is usually finished before the rebuilt
    /// nights exist — so without a second flush a rebuilt night sat on the
    /// phone until the next cold start. The caller decides what to do with the
    /// news; the recorder knows nothing about the network.
    static func recordInBackground(container: ModelContainer, now: Date = .now,
                                   onRecorded: (@Sendable (Int) -> Void)? = nil) {
        guard claimRun() else { return }
        Task.detached(priority: .utility) {
            defer { releaseRun() }
            let context = ModelContext(container)
            let written = recordIfDue(context: context, now: now)
            if written > 0 { onRecorded?(written) }
        }
    }

    /// Guards against a second pass starting while the first is still going —
    /// two passes would each see no record yet and write the same night twice.
    /// Claimed on the caller's thread and released on the background one, so
    /// the flag needs a lock rather than a bare `var`.
    nonisolated(unsafe) private static var isRunning = false
    private static let runLock = NSLock()

    private static func claimRun() -> Bool {
        runLock.lock()
        defer { runLock.unlock() }
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    private static func releaseRun() {
        runLock.lock()
        isRunning = false
        runLock.unlock()
    }

    /// Returns how many nights this pass wrote.
    @discardableResult
    static func recordIfDue(context: ModelContext, now: Date = .now) -> Int {
        // Everything the sessionizer needs, and nothing older. The lookback is
        // generous enough to catch a night the app was not running for.
        // Purge first, and independently of whether there are samples.
        //
        // This used to sit *after* a `guard !samples.isEmpty else { return }`,
        // so a store with no recent ticks kept nights written by a pipeline
        // that no longer exists — the version field is there precisely to stop
        // that, and it was being skipped in the one case it mattered most.
        //
        // A fetch that threw is not "no nights recorded". Reading it as one and
        // inserting would duplicate a night that already exists — the same
        // failure `detectAnchorIfDue` guards against, and there is no unique
        // constraint here either.
        let existing: [ActivityLog]
        do { existing = try context.fetch(FetchDescriptor<ActivityLog>()) }
        catch {
            print("❌ SleepRecorder: activity fetch — \(error)")
            return 0
        }
        // A night written by an older pipeline is deleted so it can be rebuilt.
        // Leaving it would show numbers from an algorithm that no longer exists,
        // with every field the old version never wrote rendering as a dash.
        let sleepLogs = existing.filter { $0.activityType == ActivityType.sleep.rawValue }
        var purged = 0
        for stale in sleepLogs
        where (stale.sleepAlgorithmVersion ?? 0) < SleepThresholds.algorithmVersion {
            context.delete(stale)
            purged += 1
        }
        if purged > 0 {
            print("🌙 SleepRecorder: purged \(purged) night(s) from an older algorithm")
            commit(context)
        }
        // Here, beside the stale-night purge, and for the same reason it sits
        // before the early return below: a store with no recent ticks must
        // still have its leftovers cleaned up. Withdrawn entries do not stop
        // being wrong just because the strap has been off for a week.
        purgeDetectedNaps(existing, context: context)
        // A night that no longer matches its correction is deleted so the pass
        // below rebuilds it. Without this the correction is inert: the night is
        // already recorded, so `nightsToRecord` filters its date out and the
        // drag has no visible effect until the next algorithm bump happens to
        // purge it for unrelated reasons.
        // Only the ones that survived the version purge above — `sleepLogs`
        // still holds the entries just deleted, and handing a deleted model
        // back to `context.delete` is not a thing to find out about in the
        // field.
        let rebuilt = purgeCorrectedNights(
            sleepLogs.filter { ($0.sleepAlgorithmVersion ?? 0) >= SleepThresholds.algorithmVersion },
            corrections(in: context), context: context)
        commit(context)

        let horizon = now.addingTimeInterval(-SleepThresholds.lookbackSec)
        var desc = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= horizon },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        desc.fetchLimit = Int(SleepThresholds.lookbackSec / ActivityLog.minTickIntervalSec) + 1_000

        guard let samples = try? context.fetch(desc), !samples.isEmpty else { return 0 }
        let points = samples.map(MetricsHistoryPoint.init(from:))
        // `sleepLogs` is a snapshot taken before both purges, so anything just
        // deleted is still in it. Left in, its date stays in `recordedDays`,
        // `nightsToRecord` filters that night out as already-recorded, and the
        // correction deletes the night without ever rebuilding it.
        let current = sleepLogs.filter {
            ($0.sleepAlgorithmVersion ?? 0) >= SleepThresholds.algorithmVersion
                && !rebuilt.contains(ObjectIdentifier($0))
        }
        // Every unrecorded night in the window, not just the most recent.
        //
        // Regularity is a comparison between days and needs at least two, so
        // recording one night at a time leaves the Timing section permanently
        // absent on a fresh install — while weeks of samples sit in the store
        // unused. Each pass records the best remaining night and then looks
        // again, so a first run backfills the history in one go.
        // Accumulated as we go, so each night's regularity index sees the ones
        // written moments earlier in the same pass — otherwise a first run
        // backfills three weeks and every single night still reports "needs a
        // second night".
        // Corrections the sleeper has made, keyed by wake date. Fetched once
        // and applied to every night written in this pass — including the ones
        // being rebuilt after an algorithm bump, which is the case the whole
        // model exists for.
        let overrides = corrections(in: context)

        // A stored night that the samples now say ran longer is rebuilt. A
        // night written early — by a build that sealed on the stopwatch, or
        // simply before the sleeper's last return to sleep — used to stand
        // forever: its date was "already recorded", so every later pass
        // skipped it, and the sleep that came after it was never counted.
        let settled = SleepSessionizer.settledNights(from: points, now: now)
        let outgrown = purgeOutgrownNights(current, detected: settled,
                                           corrections: overrides, context: context)
        let standing = current.filter { !outgrown.contains(ObjectIdentifier($0)) }
        let recordedDays = Set(
            standing.compactMap { $0.endedAt.map { Calendar.current.startOfDay(for: $0) } }
        )

        var written: [ActivityLog] = []
        for detected in settled
        where !recordedDays.contains(detected.day)
            && written.count < SleepThresholds.maxNightsPerPass {
            let correction = overrides[detected.day]
            let night = correction?.applied(to: detected) ?? detected
            written.append(record(night, from: points,
                                  existing: standing + written, context: context,
                                  detected: detected, correction: correction))
        }
        commit(context)
        return written.count
    }

    /// Deletes stored nights whose window the detector now finds to be
    /// longer, so the pass rebuilds them from everything the night turned out
    /// to hold. Nights the sleeper has corrected are left alone: a correction
    /// is their word over the detector's, and finding more sleep is exactly
    /// the disagreement it exists to win.
    ///
    /// Compared to the minute, like `purgeCorrectedNights`, and only ever in
    /// the growing direction — a detector that shrank a night on a later pass
    /// would be reporting noise, not a discovery.
    private static func purgeOutgrownNights(_ nights: [ActivityLog],
                                            detected: [SleepWindow],
                                            corrections: [Date: SleepWindowOverride],
                                            context: ModelContext) -> Set<ObjectIdentifier> {
        let byDay = Dictionary(detected.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        var removed: Set<ObjectIdentifier> = []
        for log in nights {
            guard let end = log.endedAt else { continue }
            let day = Calendar.current.startOfDay(for: end)
            guard corrections[day] == nil, let found = byDay[day] else { continue }
            let endsLater = found.endedAt.timeIntervalSince(end) >= 60
            let startsEarlier = log.startedAt.timeIntervalSince(found.startedAt) >= 60
            guard endsLater || startsEarlier else { continue }
            removed.insert(ObjectIdentifier(log))
            context.delete(log)
        }
        if !removed.isEmpty {
            print("🌙 SleepRecorder: rebuilding \(removed.count) night(s) that turned out to run longer")
        }
        return removed
    }

    // MARK: - Naps

    /// Deletes naps this app detected on its own.
    ///
    /// Automatic nap detection shipped and was withdrawn: it was built to
    /// answer a question about *sleep* accuracy that it turned out not to
    /// answer, and it was wrong besides — it compared heart rate to the day's
    /// median, which every minute of walking about lifts, so an afternoon at a
    /// desk sat far enough under it to be filed as a "Power Nap".
    ///
    /// Removing the detector is not enough on its own. The entries it already
    /// wrote are in the store, and nothing else would ever revisit them, so
    /// they would sit on the timeline permanently — a withdrawn feature's
    /// leftovers, indistinguishable to the reader from something the app still
    /// believes.
    ///
    /// **Only the ones it detected.** `isManual` naps are the user's own
    /// entries, and deleting those because the app changed its mind about a
    /// feature would be destroying data the app was merely holding.
    private static func purgeDetectedNaps(_ existing: [ActivityLog],
                                          context: ModelContext) {
        let detected = existing.filter {
            $0.activityType == ActivityType.nap.rawValue && !$0.isManual
        }
        guard !detected.isEmpty else { return }
        for log in detected { context.delete(log) }
        print("🌙 SleepRecorder: removed \(detected.count) auto-detected nap(s)")
    }

    /// Deletes stored nights whose boundaries disagree with the sleeper's
    /// correction for that date, so they are rebuilt from the correction.
    ///
    /// Compared to the minute. The stored window comes back through SwiftData
    /// and the correction was written from a drag, so exact equality on `Date`
    /// is the wrong test — a sub-second difference is not a disagreement, and
    /// treating it as one would delete and rewrite every corrected night on
    /// every pass, forever.
    @discardableResult
    private static func purgeCorrectedNights(_ nights: [ActivityLog],
                                             _ corrections: [Date: SleepWindowOverride],
                                             context: ModelContext) -> Set<ObjectIdentifier> {
        guard !corrections.isEmpty else { return [] }
        let cal = Calendar.current
        var removed: Set<ObjectIdentifier> = []
        for log in nights {
            guard let end = log.endedAt else { continue }
            let day = cal.startOfDay(for: end)
            guard let want = corrections[day] else { continue }
            let corrected = want.applied(to: SleepWindow(startedAt: log.startedAt, endedAt: end))
            let sameStart = abs(corrected.startedAt.timeIntervalSince(log.startedAt)) < 60
            let sameEnd = abs(corrected.endedAt.timeIntervalSince(end)) < 60
            guard !(sameStart && sameEnd) else { continue }
            removed.insert(ObjectIdentifier(log))
            context.delete(log)
        }
        if !removed.isEmpty {
            print("🌙 SleepRecorder: rebuilding \(removed.count) night(s) from the sleeper's correction")
        }
        return removed
    }

    /// Every stored correction, by the wake date it belongs to.
    ///
    /// Latest wins where there is more than one for a night — a sleeper who
    /// drags a handle twice means the second drag, and nothing guarantees only
    /// one row per day at the storage layer.
    private static func corrections(in context: ModelContext) -> [Date: SleepWindowOverride] {
        let rows = (try? context.fetch(FetchDescriptor<SleepWindowOverride>())) ?? []
        var out: [Date: SleepWindowOverride] = [:]
        for row in rows {
            if let existing = out[row.day], existing.correctedAt >= row.correctedAt { continue }
            out[row.day] = row
        }
        return out
    }

    /// Commits pending work, and says so when it cannot.
    ///
    /// The save used to be `if !written.isEmpty { try? context.save() }`, which
    /// was harmless while this ran on `container.mainContext` — that context
    /// autosaves. A hand-made `ModelContext` does not, so anything it did that
    /// was not an insert of a new night was thrown away when the context went
    /// out of scope, silently.
    private static func commit(_ context: ModelContext) {
        guard context.hasChanges else { return }
        do { try context.save() }
        catch { print("❌ SleepRecorder: save — \(error)") }
    }

    @discardableResult
    private static func record(_ night: SleepWindow,
                               from points: [MetricsHistoryPoint],
                               existing: [ActivityLog],
                               context: ModelContext,
                               detected: SleepWindow? = nil,
                               correction: SleepWindowOverride? = nil) -> ActivityLog {
        let nightPoints = points.filter {
            $0.timestamp >= night.startedAt && $0.timestamp <= night.endedAt
        }

        let log = ActivityLog(activityType: ActivityType.sleep.rawValue,
                              startedAt: night.startedAt)
        log.endedAt = night.endedAt
        log.isManual = false
        log.sleepAlgorithmVersion = SleepThresholds.algorithmVersion
        // Only when the correction actually moved something. A correction that
        // restates the boundaries the detector already had is not an error to
        // learn from, and recording it as one would count agreement as a miss.
        if let detected, let correction,
           detected.startedAt != night.startedAt || detected.endedAt != night.endedAt {
            log.sleepDetectedStart = detected.startedAt
            log.sleepDetectedEnd   = detected.endedAt
            log.sleepCorrectedAt   = correction.correctedAt
        }

        let tick = tickSeconds(nightPoints)
        let detailed = SleepStages.detailed(nightPoints)
        let coarse = SleepStages.withinSleep(nightPoints)
        // Stored, not just scored: the next night's autonomic section is a
        // ratio against this sleeper's own recent values, so tonight has to
        // leave one behind.
        log.sleepQuietRMSSD = Self.quietMedian(nightPoints, coarse, \.rmssd)
        log.sleepQuietDC    = Self.quietMedian(nightPoints, coarse, \.dc)
        apply(stages: coarse, to: log, points: nightPoints, tickSec: tick)
        apply(detail: detailed, to: log, points: nightPoints, tickSec: tick)
        let scored = score(night: night, points: nightPoints, existing: existing)
        apply(score: scored.score, to: log)
        log.sleepPartsJSON = scored.score.partsJSON
        log.sleepBedtimeSDMin = BedtimeConsistency.onsetSDMinutes(of: priorWindows(existing) + [night])
        log.sleepDetailJSON = SleepNightDetail(points: nightPoints, stages: detailed,
                                               continuity: scored.continuity).json

        context.insert(log)
        // Window averages last: it queries the store, so the log must be in it.
        log.computeHRVWindows(context: context)
        // A rebuilt night has a new id and an old `endedAt`. The uploader only
        // sends rows that ended after its watermark, so without this the
        // server keeps the night the app just deleted and never sees the one
        // that replaced it.
        ActivityUploadWatermark.rewind(before: night.endedAt)
        return log
    }

    private static func priorWindows(_ existing: [ActivityLog]) -> [SleepWindow] {
        existing
            .filter { $0.activityType == ActivityType.sleep.rawValue }
            .compactMap { log in log.endedAt.map { SleepWindow(startedAt: log.startedAt, endedAt: $0) } }
    }

    /// Elapsed seconds covered by the ticks where `mask` is true.
    ///
    /// Counting samples and multiplying by a median interval overcounts badly
    /// when the cadence changes: a night that is mostly 30 s background ticks
    /// with a stretch of 2 s foreground ones has fifteen times the samples per
    /// minute in that stretch. On a real record that put quiet + active + awake
    /// at 10 h 55 m inside a 10 h 10 m window — 45 minutes of sleep that never
    /// happened. Each tick is worth the gap to the next one instead, capped so
    /// a recording hole is not credited as sleep.
    static func seconds(where mask: [Bool], points: [MetricsHistoryPoint]) -> Double {
        guard mask.count == points.count, points.count > 1 else { return 0 }
        var total: Double = 0
        for i in points.indices where mask[i] {
            let next = i + 1 < points.count
                ? points[i + 1].timestamp.timeIntervalSince(points[i].timestamp)
                : points[i].timestamp.timeIntervalSince(points[i - 1].timestamp)
            total += min(max(next, 0), SleepThresholds.maxTickCreditSec)
        }
        return total
    }

    /// The longest unbroken run of `mask`, in the same gap-credited seconds
    /// `seconds(where:)` counts — so a run and the total it is part of can
    /// never disagree about how long a minute is.
    static func longestRunSeconds(where mask: [Bool], points: [MetricsHistoryPoint]) -> Double {
        guard mask.count == points.count, points.count > 1 else { return 0 }
        var best = 0.0, run = 0.0
        for i in points.indices {
            guard mask[i] else { run = 0; continue }
            let next = i + 1 < points.count
                ? points[i + 1].timestamp.timeIntervalSince(points[i].timestamp)
                : points[i].timestamp.timeIntervalSince(points[i - 1].timestamp)
            run += min(max(next, 0), SleepThresholds.maxTickCreditSec)
            best = max(best, run)
        }
        return best
    }

    // MARK: - Pieces

    private static func tickSeconds(_ points: [MetricsHistoryPoint]) -> Double {
        guard points.count > 1 else { return 30 }
        let deltas = zip(points, points.dropFirst())
            .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .sorted()
        return deltas[deltas.count / 2]
    }

    private static func apply(stages: [SleepStage], to log: ActivityLog,
                              points: [MetricsHistoryPoint], tickSec: Double) {
        guard !stages.isEmpty else { return }
        func minutes(_ s: SleepStage) -> Int {
            Int((SleepRecorder.seconds(where: stages.map { $0 == s }, points: points) / 60).rounded())
        }
        func hm(_ m: Int) -> String { "\(m / 60)h \(String(format: "%02d", m % 60))m" }

        let asleep = minutes(.quiet) + minutes(.active)
        log.sleepAsleepMinutes = asleep
        log.sleepStageSummary = "\(hm(minutes(.quiet))) quiet · "
            + "\(hm(minutes(.active))) active · \(hm(minutes(.wake))) awake"
    }

    private static func apply(detail: [SleepStageDetail], to log: ActivityLog,
                              points: [MetricsHistoryPoint], tickSec: Double) {
        guard !detail.isEmpty else { return }
        func minutes(_ s: SleepStageDetail) -> Int {
            Int((SleepRecorder.seconds(where: detail.map { $0 == s }, points: points) / 60).rounded())
        }
        log.sleepDeepMinutes = minutes(.n3)
        log.sleepLightMinutes = minutes(.n2)
        log.sleepN1Minutes = minutes(.n1)
        log.sleepREMMinutes = minutes(.rem)
        log.sleepAwakeMinutes = minutes(.wake)
    }

    /// What the Continuity section was actually scored on, kept beside the
    /// score so the stored night can be audited against its own arithmetic.
    struct ContinuityInputs: Equatable {
        var wakeBouts: Int
        var longestUnbrokenSec: Double
        var longestWakeSec: Double
    }

    /// Median of `value` over the ticks classified as quiet sleep.
    ///
    /// Nil below `minQuietTicks`: a handful of quiet ticks is not a reading of
    /// the night's vagal tone, and reporting one would put a number on noise.
    static func quietMedian(_ points: [MetricsHistoryPoint],
                            _ stages: [SleepStage],
                            _ value: KeyPath<MetricsHistoryPoint, Float?>) -> Float? {
        guard stages.count == points.count else { return nil }
        let quiet = points.indices
            .filter { stages[$0] == .quiet }
            .compactMap { points[$0][keyPath: value] }
        guard quiet.count >= minQuietTicks else { return nil }
        return median(quiet)
    }

    /// Enough quiet sleep to describe. At the 30 s background cadence this is
    /// about ten minutes of it.
    static let minQuietTicks = 20

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func score(night: SleepWindow,
                              points: [MetricsHistoryPoint],
                              existing: [ActivityLog]) -> (score: SleepScore, continuity: ContinuityInputs) {
        let hrs = points.compactMap { $0.meanBPM }
        // The same interior rule the reported minutes use. Continuity is scored
        // on wake bouts, so scoring it from a different classification than the
        // one displayed would print a continuity that contradicts the awake
        // total printed beside it.
        let stages = SleepStages.withinSleep(points)
        let tick = tickSeconds(points)

        // Nadir depth and placement — the shape evening load actually moves.
        var dip: Float?
        var nadirAt: Double?
        if hrs.count > 10, let low = hrs.min() {
            let onsetSlice = hrs.prefix(max(1, hrs.count / 20))
            let onset = onsetSlice.reduce(0, +) / Float(onsetSlice.count)
            dip = onset - low
            if let idx = hrs.firstIndex(of: low) {
                nadirAt = Double(idx) / Double(max(1, hrs.count - 1))
            }
        }

        // Vagal tone from quiet sleep only. Averaging it across the night
        // averages over REM, where it is meant to be low — see
        // `ActivityLog.sleepQuietRMSSD`. Median rather than mean: one artefact
        // tick should not move a night's autonomic reading.
        let quietRMSSD = Self.quietMedian(points, stages, \.rmssd)
        let quietDC    = Self.quietMedian(points, stages, \.dc)

        // This sleeper's own recent nights, which is what the ratio is against.
        let priorRMSSD = Self.median(existing.compactMap(\.sleepQuietRMSSD))
        let priorDC    = Self.median(existing.compactMap(\.sleepQuietDC))

        // Continuity, from the hypnogram rather than from wall clock.
        var bouts = 0
        for i in stages.indices where i > 0 {
            if stages[i] == .wake && stages[i - 1] != .wake { bouts += 1 }
        }
        // In gap-credited seconds, the clock every minute on the night screen
        // is counted in — not ticks × the median interval. That read 116
        // minutes of wake inside a night with 87 awake in total, because the
        // bout fell in a stretch sampled fifteen times denser than the
        // night's median tick, and it fed the Continuity score the same way.
        let longestUnbrokenSec = longestRunSeconds(where: stages.map { $0 != .wake }, points: points)
        let longestWakeSec     = longestRunSeconds(where: stages.map { $0 == .wake }, points: points)

        let asleepSec = seconds(where: stages.map { $0 != .wake }, points: points)

        // Regularity over this night plus the nights already recorded.
        let priorWindows: [SleepWindow] = existing
            .filter { $0.activityType == ActivityType.sleep.rawValue }
            .compactMap { log in log.endedAt.map { SleepWindow(startedAt: log.startedAt, endedAt: $0) } }

        let input = SleepScoreInput(
            bedtimeSDMin: BedtimeConsistency.onsetSDMinutes(of: priorWindows + [night]),
            bedtimeOutsideMin: BedtimePlacement.minutesOutside(night.startedAt),
            asleepSec: asleepSec,
            needSec: SleepThresholds.defaultNeedSec,
            wakeBouts: bouts,
            longestUnbrokenSec: longestUnbrokenSec,
            hrNadirDip: dip,
            hrNadirFraction: nadirAt,
            quietRMSSD: quietRMSSD,
            quietRMSSDBaseline: priorRMSSD,
            quietDC: quietDC,
            quietDCBaseline: priorDC,
            steadyFraction: SleepBreathing.steadyFraction(points)
        )
        return (SleepScore.compute(input),
                ContinuityInputs(wakeBouts: bouts,
                                 longestUnbrokenSec: longestUnbrokenSec,
                                 longestWakeSec: longestWakeSec))
    }

    private static func apply(score: SleepScore, to log: ActivityLog) {
        log.sleepScore = score.overall
        log.sleepScoreArithmetic = score.arithmetic
        // Absent stays absent — never coerced to zero on the way to disk.
        log.sleepTiming = score.sections[.timing]
        log.sleepDuration = score.sections[.duration]
        log.sleepContinuity = score.sections[.continuity]
        log.sleepAutonomic = score.sections[.autonomic]
    }
}

// MARK: - The rest of the night, stored

/// What a night needs beyond the row's own columns for someone to draw it —
/// the hypnogram as runs, the position bands, the wake bouts, the nadir.
///
/// Stored on `ActivityLog.sleepDetailJSON` and sent up inside the activity
/// upload. The wire names are the insight payload's (`SleepNightPayload`), so
/// the night has one vocabulary rather than two.
struct SleepNightDetail: Codable, Equatable {

    struct Run: Codable, Equatable {
        /// `wake`, `rem`, `n1`, `n2`, `n3`.
        let stage: String
        let start: String
        let end:   String
    }

    struct PositionBand: Codable, Equatable {
        /// `BodyPosition.label` — "Supine", "Left side", …
        let position: String
        let start:    String
        let end:      String
    }

    struct PositionShare: Codable, Equatable {
        let position: String
        let minutes:  Int
    }

    let wakeBouts:          Int
    let longestUnbrokenMin: Int
    let longestWakeMin:     Int
    let lowestHR:           Double?
    let lowestHRAt:         String?
    /// False means the strap stored no orientation on this night — NOT that
    /// the person never lay on their back.
    let positionRecorded:   Bool
    let positions:          [PositionShare]
    let positionBands:      [PositionBand]
    let stageRuns:          [Run]

    enum CodingKeys: String, CodingKey {
        case positions
        case wakeBouts          = "wake_bouts"
        case longestUnbrokenMin = "longest_unbroken_min"
        case longestWakeMin     = "longest_wake_min"
        case lowestHR           = "lowest_hr"
        case lowestHRAt         = "lowest_hr_at"
        case positionRecorded   = "position_recorded"
        case positionBands      = "position_bands"
        case stageRuns          = "stage_runs"
    }

    /// Field-by-field, for a restore: the custom initialisers above suppress
    /// the synthesised one.
    init(wakeBouts: Int, longestUnbrokenMin: Int, longestWakeMin: Int,
         lowestHR: Double?, lowestHRAt: String?, positionRecorded: Bool,
         positions: [PositionShare], positionBands: [PositionBand], stageRuns: [Run]) {
        self.wakeBouts = wakeBouts
        self.longestUnbrokenMin = longestUnbrokenMin
        self.longestWakeMin = longestWakeMin
        self.lowestHR = lowestHR
        self.lowestHRAt = lowestHRAt
        self.positionRecorded = positionRecorded
        self.positions = positions
        self.positionBands = positionBands
        self.stageRuns = stageRuns
    }

    /// The heart-rate low is read off five-minute means, not off single
    /// ticks: one tick's minimum is one noisy beat window, and the question
    /// is when the body bottomed out, which is a stretch of the night.
    static let nadirBinSec: Double = 300

    init(points: [MetricsHistoryPoint],
         stages: [SleepStageDetail],
         continuity: SleepRecorder.ContinuityInputs) {
        let iso = ISO8601DateFormatter()

        wakeBouts          = continuity.wakeBouts
        longestUnbrokenMin = Int((continuity.longestUnbrokenSec / 60).rounded())
        longestWakeMin     = Int((continuity.longestWakeSec / 60).rounded())

        // Hypnogram, run-length encoded. A run ends where the next one begins,
        // so the ribbon has no gaps of its own; the last run ends on its last
        // tick.
        var runs: [Run] = []
        if stages.count == points.count, !points.isEmpty {
            var start = 0
            for i in 1...stages.count where i == stages.count || stages[i] != stages[start] {
                let end = i < points.count ? points[i].timestamp : points[points.count - 1].timestamp
                runs.append(Run(stage: Self.name(stages[start]),
                                start: iso.string(from: points[start].timestamp),
                                end: iso.string(from: max(end, points[start].timestamp))))
                start = i
            }
        }
        stageRuns = runs

        let bands = PreparedNight.positionBands(points)
        positionBands = bands.map {
            PositionBand(position: $0.position.label,
                         start: iso.string(from: $0.start), end: iso.string(from: $0.end))
        }
        var minutes: [BodyPosition: Int] = [:]
        for band in bands {
            minutes[band.position, default: 0] += Int((band.end.timeIntervalSince(band.start) / 60).rounded())
        }
        // Longest first: the read leads with whichever dominated the night.
        positions = minutes.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { PositionShare(position: $0.key.label, minutes: $0.value) }
        positionRecorded = points.contains { $0.bodyPosition != nil }

        if let low = Self.nadir(points) {
            lowestHR = low.value
            lowestHRAt = iso.string(from: low.at)
        } else {
            lowestHR = nil
            lowestHRAt = nil
        }
    }

    private static func name(_ s: SleepStageDetail) -> String {
        switch s {
        case .wake: return "wake"
        case .rem:  return "rem"
        case .n1:   return "n1"
        case .n2:   return "n2"
        case .n3:   return "n3"
        }
    }

    private static func nadir(_ points: [MetricsHistoryPoint]) -> (value: Double, at: Date)? {
        guard let first = points.first?.timestamp else { return nil }
        var bins: [Int: (sum: Double, n: Int, at: Date)] = [:]
        for p in points {
            guard let hr = p.meanBPM else { continue }
            let bin = Int(p.timestamp.timeIntervalSince(first) / nadirBinSec)
            let cur = bins[bin] ?? (0, 0, p.timestamp)
            bins[bin] = (cur.sum + Double(hr), cur.n + 1, cur.at)
        }
        guard let low = bins.values.min(by: { $0.sum / Double($0.n) < $1.sum / Double($1.n) }) else { return nil }
        return ((low.sum / Double(low.n)).rounded(), low.at)
    }

    var json: String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    init?(json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SleepNightDetail.self, from: data) else { return nil }
        self = decoded
    }
}
