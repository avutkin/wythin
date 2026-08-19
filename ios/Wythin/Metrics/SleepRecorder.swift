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

    static func recordIfDue(context: ModelContext, now: Date = .now) {
        // Everything the sessionizer needs, and nothing older. The lookback is
        // generous enough to catch a night the app was not running for.
        let horizon = now.addingTimeInterval(-SleepThresholds.lookbackSec)
        var desc = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= horizon },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        desc.fetchLimit = Int(SleepThresholds.lookbackSec / ActivityLog.minTickIntervalSec) + 1_000

        guard let samples = try? context.fetch(desc), !samples.isEmpty else { return }
        let points = samples.map(MetricsHistoryPoint.init(from:))

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
        let recordedDays = Set(
            existing
                .filter { $0.activityType == ActivityType.sleep.rawValue }
                .compactMap { $0.endedAt.map { Calendar.current.startOfDay(for: $0) } }
        )

        guard let night = SleepSessionizer.nightToRecord(from: points,
                                                         now: now,
                                                         recordedDays: recordedDays)
        else { return }

        let nightPoints = points.filter {
            $0.timestamp >= night.startedAt && $0.timestamp <= night.endedAt
        }

        let log = ActivityLog(activityType: ActivityType.sleep.rawValue,
                              startedAt: night.startedAt)
        log.endedAt = night.endedAt
        log.isManual = false

        let tick = tickSeconds(nightPoints)
        apply(stages: SleepStages.classify(nightPoints), to: log, tickSec: tick)
        apply(detail: SleepStages.detailed(nightPoints), to: log, tickSec: tick)
        let scored = score(night: night, points: nightPoints, existing: existing)
        apply(score: scored, to: log)
        log.sleepRegularity = SleepRegularity.index(of: priorWindows(existing) + [night])

        context.insert(log)
        // Window averages last: it queries the store, so the log must be in it.
        log.computeHRVWindows(context: context)
        try? context.save()
    }

    private static func priorWindows(_ existing: [ActivityLog]) -> [SleepWindow] {
        existing
            .filter { $0.activityType == ActivityType.sleep.rawValue }
            .compactMap { log in log.endedAt.map { SleepWindow(startedAt: log.startedAt, endedAt: $0) } }
    }

    // MARK: - Pieces

    private static func tickSeconds(_ points: [MetricsHistoryPoint]) -> Double {
        guard points.count > 1 else { return 30 }
        let deltas = zip(points, points.dropFirst())
            .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .sorted()
        return deltas[deltas.count / 2]
    }

    private static func apply(stages: [SleepStage], to log: ActivityLog, tickSec: Double) {
        guard !stages.isEmpty else { return }
        func minutes(_ s: SleepStage) -> Int {
            Int((Double(stages.filter { $0 == s }.count) * tickSec / 60).rounded())
        }
        func hm(_ m: Int) -> String { "\(m / 60)h \(String(format: "%02d", m % 60))m" }

        let asleep = minutes(.quiet) + minutes(.active)
        log.sleepAsleepMinutes = asleep
        log.sleepStageSummary = "\(hm(minutes(.quiet))) quiet · "
            + "\(hm(minutes(.active))) active · \(hm(minutes(.wake))) awake"
    }

    private static func apply(detail: [SleepStageDetail], to log: ActivityLog, tickSec: Double) {
        guard !detail.isEmpty else { return }
        func minutes(_ s: SleepStageDetail) -> Int {
            Int((Double(detail.filter { $0 == s }.count) * tickSec / 60).rounded())
        }
        log.sleepDeepMinutes = minutes(.deep)
        log.sleepLightMinutes = minutes(.light)
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

        let asleepSec = Double(stages.filter { $0 != .wake }.count) * tick

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
