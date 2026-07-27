import Foundation
import SwiftData

/// Owns the day's anchor, its score, the streak, and the once-daily
/// narrative.
///
/// The score is computed on-device, so it renders even when the network is
/// down — only the prose depends on the API. The anchor is frozen once found,
/// which is what keeps the number stable as the day goes on.
@MainActor
@Observable
final class DayPotentialStore {

    enum State: Equatable {
        case waitingForStillness      // no rested window yet today
        case baselineBuilding(Int)    // n anchors so far, below the minimum
        case scored
    }

    private(set) var anchor:     AnchorReading?
    private(set) var result:     PotentialResult?
    private(set) var streak:     StreakResult?
    private(set) var loggedDays: Set<Date> = []
    private(set) var recent:     [Int] = []
    private(set) var state:      State = .waitingForStillness
    var insight:  String?
    var loadLine: String?

    private var generatedForDay: Date?
    private var inFlight = false
    private var backfilled = false

    /// Finds or loads today's anchor, scores it, refreshes the streak and the
    /// local load line, and generates the narrative once per day.
    func refresh(env: AppEnvironment, force: Bool = false) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let context = env.modelContext
        let today   = Calendar.current.startOfDay(for: Date())

        if !backfilled {
            AnchorBackfill.runIfNeeded(context: context)
            backfilled = true
        }

        // 1. Today's anchor — load if stored, otherwise try to detect one.
        var stored = (try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []
        var todayAnchor = stored.first { $0.day == today }?.reading

        if todayAnchor == nil {
            let todayPoints = MetricsQualityFilter.filter(
                env.tickHistory.filter { $0.timestamp >= today })
            if let detected = AnchorDetector.detect(todayPoints) {
                context.insert(DailyAnchor(from: detected))
                try? context.save()
                stored = (try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []
                todayAnchor = detected
            }
        }
        anchor = todayAnchor

        // 2. Streak from all stored anchors.
        let history = stored.map { $0.reading }
        loggedDays = Set(history.map { $0.day })
        streak = StreakCompute.evaluate(days: loggedDays, today: today)

        guard let todayAnchor else {
            state = .waitingForStillness
            loadLine = nil
            return
        }

        updateLoadLine(env: env, anchor: todayAnchor)

        // 3. Baseline and score. Below the minimum anchor count there is no
        // SD, so no score — day-over-day language only.
        let past = history.filter { $0.day < today }
        guard let baseline = AnchorBaseline.build(history: past, todayHour: todayAnchor.hour) else {
            state = .baselineBuilding(past.count + 1)
            result = nil
            recent = []
            await generate(env: env, baseline: nil, force: force)
            return
        }

        result = PotentialScore.evaluate(anchor: todayAnchor, baseline: baseline)
        state  = result == nil ? .waitingForStillness : .scored

        // Recent scores for the sparkline — past anchors scored against the
        // same baseline, so the bars are comparable with today's.
        var recentScores = past.suffix(6).compactMap {
            PotentialScore.evaluate(anchor: $0, baseline: baseline)?.score
        }
        if let todayScore = result?.score { recentScores.append(todayScore) }
        recent = recentScores

        await generate(env: env, baseline: baseline, force: force)
    }

    // MARK: - Narrative (once per day)

    private func generate(env: AppEnvironment, baseline: AnchorBaseline?, force: Bool) async {
        let today = Calendar.current.startOfDay(for: Date())
        guard force || generatedForDay != today || insight == nil else { return }
        guard let anchor else { return }

        var components: [String: MetricComponentPayload] = [:]
        var modifiers:  [String: Float] = [:]
        if let r = result {
            components["recovery_capacity"] = MetricComponentPayload(
                z: r.components.lnRMSSDz, level: Self.level(r.components.lnRMSSDz))
            components["resting_pace"] = MetricComponentPayload(
                z: r.components.restingHRz, level: Self.level(r.components.restingHRz))
            if let dcZ = r.components.dcZ {
                components["settling_depth"] = MetricComponentPayload(
                    z: dcZ, level: Self.level(dcZ))
            }
            modifiers["stability"]     = r.penalties.stability
            modifiers["fragmentation"] = r.penalties.fragmentation
            modifiers["organization"]  = r.penalties.organization
        }

        let payload = DayPotentialPayload(
            score: result?.score,
            band: result?.band.rawValue,
            anchorHour: anchor.hour,
            anchorDurationMin: Int((anchor.durationSec / 60).rounded()),
            late: anchor.late,
            confidence: anchor.confidence.rawValue,
            components: components,
            modifiers: modifiers,
            baselineAnchors: baseline?.anchorCount ?? loggedDays.count,
            baselineTarget: AnchorBaseline.windowDays,
            baselineSufficient: baseline != nil,
            recent: recent,
            streakCurrent: streak?.current ?? 0,
            streakBest: streak?.best ?? 0,
            graceUsed: streak?.graceUsed ?? false)

        if let response = try? await env.sync.client.generateDayPotentialInsight(payload) {
            insight = response.text
            generatedForDay = today
        }
    }

    /// The only place today's running average is used — capacity stays frozen.
    private func updateLoadLine(env: AppEnvironment, anchor: AnchorReading) {
        let today = Calendar.current.startOfDay(for: Date())
        let todayPoints = MetricsQualityFilter.filter(
            env.tickHistory.filter { $0.timestamp >= today })
        let vtis = todayPoints.compactMap { $0.vti }
        let dayMean = vtis.isEmpty ? nil : vtis.reduce(0, +) / Float(vtis.count)
        loadLine = DayLoadSummary.text(
            anchorLnRMSSD: anchor.lnRMSSD,
            dayMeanLnRMSSD: dayMean,
            hoursElapsed: Date().timeIntervalSince(anchor.startedAt) / 3600)
    }

    private static func level(_ z: Float) -> String {
        switch z {
        case 1.0...:         return "well above their usual"
        case 0.35..<1.0:     return "above their usual"
        case -0.35..<0.35:   return "right around their usual"
        case -1.0 ..< -0.35: return "below their usual"
        default:             return "well below their usual"
        }
    }
}
