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
        case waitingForStillness            // no rested window yet today
        case firstMorning                   // anchor found, nothing to compare it to
        case scored(provisional: Bool)      // provisional = baseline still mostly prior
        case notComparable                  // anchor found, but not against this baseline

        /// Pure, so the headline can be tested without a context or an
        /// environment. The order matters: a missing anchor outranks a missing
        /// baseline, which outranks an anchor that could not be scored.
        static func derive(anchor: AnchorReading?,
                           baseline: AnchorBaseline?,
                           result: PotentialResult?) -> State {
            guard anchor != nil          else { return .waitingForStillness }
            guard let baseline           else { return .firstMorning }
            guard result != nil          else { return .notComparable }
            return .scored(provisional: baseline.provisional)
        }

        var showsScore: Bool {
            if case .scored = self { return true }
            return false
        }

        func headline(band: PotentialBand?) -> String {
            switch self {
            case .waitingForStillness:
                return "TODAY'S POTENTIAL · WAITING FOR A STILL MOMENT"
            case .firstMorning:
                return "MORNING READ · FIRST ONE LOGGED"
            case .notComparable:
                return "LATER READ · NOT COMPARABLE TODAY"
            case .scored(let provisional):
                let base = "TODAY'S POTENTIAL · \((band?.label ?? "").uppercased())"
                return provisional ? base + " · EARLY DAYS" : base
            }
        }
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
            // Awaited, not fired and forgotten: the anchors read below are the
            // ones it rewrites. It does its work on its own background context,
            // so the await is a hand-off rather than a main-thread stall.
            await AnchorBackfill.runIfNeeded(container: env.modelContainer)
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
            state    = .derive(anchor: nil, baseline: nil, result: nil)
            result   = nil
            recent   = []
            loadLine = nil
            return
        }

        updateLoadLine(env: env, anchor: todayAnchor)

        // 3. Baseline and score. One prior anchor is enough — the baseline
        // blends toward a prior until the user's own spread is established, so
        // an early score is conservative rather than absent.
        let past = history.filter { $0.day < today }
        let baseline = AnchorBaseline.build(history: past, todayHour: todayAnchor.hour)
        result = baseline.flatMap { PotentialScore.evaluate(anchor: todayAnchor, baseline: $0) }
        state  = .derive(anchor: todayAnchor, baseline: baseline, result: result)

        // Recent scores for the sparkline — past anchors scored against the
        // same baseline, so the bars are comparable with today's.
        if let baseline, result != nil {
            var recentScores = past.suffix(6).compactMap {
                PotentialScore.evaluate(anchor: $0, baseline: baseline)?.score
            }
            if let todayScore = result?.score { recentScores.append(todayScore) }
            recent = recentScores
        } else {
            recent = []
        }

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
            baselineTarget: AnchorBaseline.firmAnchors,
            // A baseline now exists from one anchor, so its presence no longer
            // means it is trustworthy — `provisional` is what carries that.
            baselineSufficient: !(baseline?.provisional ?? true),
            provisional: baseline?.provisional ?? false,
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
