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

        let horizon = now.addingTimeInterval(-SleepThresholds.lookbackSec)
        var desc = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= horizon },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        desc.fetchLimit = Int(SleepThresholds.lookbackSec / ActivityLog.minTickIntervalSec) + 1_000

        guard let samples = try? context.fetch(desc), !samples.isEmpty else { return }
        let points = samples.map(MetricsHistoryPoint.init(from:))
        let current = sleepLogs.filter {
            ($0.sleepAlgorithmVersion ?? 0) >= SleepThresholds.algorithmVersion
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
        var written: [ActivityLog] = []
        for night in SleepSessionizer.nightsToRecord(from: points,
                                                     now: now,
                                                     recordedDays: recordedDays)
        where written.count < SleepThresholds.maxNightsPerPass {
            written.append(record(night, from: points,
                                  existing: current + written, context: context))
        }
        // Naps last, and only once the nights are known: the exclusion they
        // need is the set of nights, and detecting a nap inside one would
        // report the same sleep twice under two names.
        recordNaps(points: points,
                   nights: priorWindows(current + written),
                   existing: existing + written,
                   now: now,
                   context: context)
        commit(context)
    }

    // MARK: - Naps

    /// Writes down the daytime sleep in this window.
    ///
    /// Kept deliberately thinner than `record(_:from:existing:context:)`. A
    /// night gets a five-section score; a nap gets its duration and the metrics
    /// every activity gets, and nothing more. The sleep score's sections are
    /// calibrated against a night — a regularity index over wake dates, a
    /// duration judged against a nightly need, a continuity built from wake
    /// bouts — and none of them mean anything about twenty-five minutes after
    /// lunch. Scoring a nap on them would put a number on the screen that looks
    /// like the night score and is not comparable to it.
    private static func recordNaps(points: [MetricsHistoryPoint],
                                   nights: [SleepWindow],
                                   existing: [ActivityLog],
                                   now: Date,
                                   context: ModelContext) {
        // A nap written by an older pipeline is rebuilt, exactly as a night is.
        // Only the ones this detector wrote: a nap the user logged by hand is
        // theirs, and deleting it because a threshold moved would be destroying
        // data the app was merely storing.
        let stale = existing.filter {
            $0.activityType == ActivityType.nap.rawValue
                && !$0.isManual
                && ($0.sleepAlgorithmVersion ?? 0) < NapThresholds.algorithmVersion
        }
        for log in stale { context.delete(log) }

        // Everything still on the timeline over these minutes, of any kind —
        // not just other naps. Nights are already excluded by window, so they
        // are dropped here to avoid vetoing on the clearance either side.
        let discarded = Set(stale.map(ObjectIdentifier.init))
        let occupied = existing.filter {
            !discarded.contains(ObjectIdentifier($0))
                && $0.activityType != ActivityType.sleep.rawValue
        }

        for nap in NapDetector.detect(points, excluding: nights) {
            // Settled, for the same reason a night must be: the detector trims
            // to the last sleeping tick, so a nap still in progress ends at
            // roughly now. Writing it then records half a nap and — being
            // idempotent afterwards — never corrects itself.
            guard now.timeIntervalSince(nap.endedAt) >= SleepThresholds.settleSec else { continue }
            // Anything already on the timeline over these minutes wins, of any
            // kind. A logged meditation is the false positive this detector
            // cannot separate on signal alone — it is still, and the pulse
            // drops, which is the whole of what a nap looks like from a chest
            // strap. The difference is that the user already said what it was,
            // and re-filing it as sleep would overwrite their word with a
            // guess. The same guard makes the pass idempotent: a nap this
            // detector wrote on an earlier run occupies its own minutes.
            guard !occupied.contains(where: { overlaps($0, nap) }) else { continue }

            let log = ActivityLog(activityType: ActivityType.nap.rawValue,
                                  startedAt: nap.startedAt)
            log.endedAt = nap.endedAt
            log.isManual = false
            log.sleepAlgorithmVersion = NapThresholds.algorithmVersion
            log.sleepAsleepMinutes = Int(nap.durationSec / 60)
            // The two shapes the literature separates, and the two this type
            // already offers: a short nap taken before deep sleep begins, and
            // one long enough to come back around through a full cycle.
            log.activitySubtype = nap.durationSec <= 30 * 60 ? "Power Nap" : "Full Cycle"
            context.insert(log)
            log.computeHRVWindows(context: context)
        }
    }

    /// Whether a stored entry covers any of the same minutes as a candidate.
    private static func overlaps(_ log: ActivityLog, _ nap: SleepWindow) -> Bool {
        guard let end = log.endedAt else { return false }
        return log.startedAt < nap.endedAt && nap.startedAt < end
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
        apply(stages: SleepStages.classify(nightPoints), to: log, points: nightPoints, tickSec: tick)
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
        let stages = SleepStages.classify(points)
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
