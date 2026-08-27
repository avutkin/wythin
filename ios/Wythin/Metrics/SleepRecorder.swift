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
    static func recordInBackground(container: ModelContainer, now: Date = .now) {
        guard claimRun() else { return }
        Task.detached(priority: .utility) {
            defer { releaseRun() }
            let context = ModelContext(container)
            recordIfDue(context: context, now: now)
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

    static func recordIfDue(context: ModelContext, now: Date = .now) {
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
            return
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

        guard let samples = try? context.fetch(desc), !samples.isEmpty else { return }
        let points = samples.map(MetricsHistoryPoint.init(from:))
        // `sleepLogs` is a snapshot taken before both purges, so anything just
        // deleted is still in it. Left in, its date stays in `recordedDays`,
        // `nightsToRecord` filters that night out as already-recorded, and the
        // correction deletes the night without ever rebuilding it.
        let current = sleepLogs.filter {
            ($0.sleepAlgorithmVersion ?? 0) >= SleepThresholds.algorithmVersion
                && !rebuilt.contains(ObjectIdentifier($0))
        }
        let recordedDays = Set(
            current.compactMap { $0.endedAt.map { Calendar.current.startOfDay(for: $0) } }
        )

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

        var written: [ActivityLog] = []
        for detected in SleepSessionizer.nightsToRecord(from: points,
                                                        now: now,
                                                        recordedDays: recordedDays)
        where written.count < SleepThresholds.maxNightsPerPass {
            let night = overrides[detected.day]?.applied(to: detected) ?? detected
            written.append(record(night, from: points,
                                  existing: current + written, context: context))
        }
        commit(context)
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
                               context: ModelContext) -> ActivityLog {
        let nightPoints = points.filter {
            $0.timestamp >= night.startedAt && $0.timestamp <= night.endedAt
        }

        let log = ActivityLog(activityType: ActivityType.sleep.rawValue,
                              startedAt: night.startedAt)
        log.endedAt = night.endedAt
        log.isManual = false
        log.sleepAlgorithmVersion = SleepThresholds.algorithmVersion

        let tick = tickSeconds(nightPoints)
        apply(stages: SleepStages.withinSleep(nightPoints), to: log, points: nightPoints, tickSec: tick)
        apply(detail: SleepStages.detailed(nightPoints), to: log, points: nightPoints, tickSec: tick)
        let scored = score(night: night, points: nightPoints, existing: existing)
        apply(score: scored, to: log)
        log.sleepRegularity = SleepRegularity.index(of: priorWindows(existing) + [night])

        context.insert(log)
        // Window averages last: it queries the store, so the log must be in it.
        log.computeHRVWindows(context: context)
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

    private static func score(night: SleepWindow,
                              points: [MetricsHistoryPoint],
                              existing: [ActivityLog]) -> SleepScore {
        let hrs = points.compactMap { $0.meanBPM }
        let rmssds = points.compactMap { $0.rmssd }
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

        // Continuity, from the hypnogram rather than from wall clock.
        var bouts = 0
        for i in stages.indices where i > 0 {
            if stages[i] == .wake && stages[i - 1] != .wake { bouts += 1 }
        }
        var longest = 0, run = 0
        for s in stages {
            if s == .wake { run = 0 } else { run += 1; longest = max(longest, run) }
        }

        let asleepSec = seconds(where: stages.map { $0 != .wake }, points: points)

        // Regularity over this night plus the nights already recorded.
        let priorWindows: [SleepWindow] = existing
            .filter { $0.activityType == ActivityType.sleep.rawValue }
            .compactMap { log in log.endedAt.map { SleepWindow(startedAt: log.startedAt, endedAt: $0) } }

        let input = SleepScoreInput(
            regularityIndex: SleepRegularity.index(of: priorWindows + [night]),
            asleepSec: asleepSec,
            needSec: SleepThresholds.defaultNeedSec,
            wakeBouts: bouts,
            longestUnbrokenSec: Double(longest) * tick,
            hrNadirDip: dip,
            hrNadirFraction: nadirAt,
            meanRMSSD: rmssds.isEmpty ? nil : rmssds.reduce(0, +) / Float(rmssds.count),
            steadyFraction: SleepBreathing.steadyFraction(points)
        )
        return SleepScore.compute(input)
    }

    private static func apply(score: SleepScore, to log: ActivityLog) {
        log.sleepScore = score.overall
        log.sleepScoreArithmetic = score.arithmetic
        // Absent stays absent — never coerced to zero on the way to disk.
        log.sleepTiming = score.sections[.timing]
        log.sleepDuration = score.sections[.duration]
        log.sleepContinuity = score.sections[.continuity]
        log.sleepAutonomic = score.sections[.autonomic]
        log.sleepBreathing = score.sections[.breathing]
    }
}
