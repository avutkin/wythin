import Foundation
import SwiftUI
import SwiftData

// MARK: - ActivityType

enum ActivityType: String, CaseIterable, Codable {
    case exercise     = "Exercise"
    case walk         = "Walk"
    case meditation   = "Meditation"
    case breathwork   = "Breathwork"
    case meal         = "Meal"
    case nap          = "Nap"
    case thermal      = "Thermal"
    case drinks       = "Drinks"
    case work         = "Work"
    /// Measured, never started by hand — see `SleepRecorder`.
    case sleep        = "Sleep"
    case custom       = "Custom"

    /// The eight tiles shown in the picker grid — Custom is offered separately
    /// beneath it so it stays reachable without spending a tile, and Walk has
    /// folded into Exercise (its subtypes moved across).
    /// Sleep is deliberately absent: it is the one type nobody starts by hand.
    /// It appears because the strap measured it, and a tile offering to "start
    /// sleeping" would be both useless and a lie about how it is produced.
    static var pickerCases: [ActivityType] {
        allCases.filter { $0 != .custom && $0 != .walk && $0 != .sleep }
    }

    /// Resolves a stored `activityType` string, including types that have
    /// since been merged into a broader one. Old entries keep their own
    /// subtype ("Tempo Run", "Espresso"), so nothing is lost — only the tile
    /// they group under changed.
    static func fromStored(_ raw: String) -> ActivityType {
        // Checked before the rawValue lookup, because "Walk" still parses as
        // `.walk` — the case is retained for entries already in flight, but it
        // is no longer a tile and must present as Exercise.
        if raw == ActivityType.walk.rawValue { return .exercise }
        if let type = ActivityType(rawValue: raw) { return type }
        switch raw {
        case "Run":                      return .exercise
        case "Cold Exposure", "Sauna":   return .thermal
        case "Coffee", "Alcohol":        return .drinks
        default:                         return .custom
        }
    }

    var icon: String {
        switch self {
        case .exercise:     return "figure.run"
        case .walk:         return "figure.walk"
        case .meditation:   return "brain.head.profile"
        case .breathwork:   return "lungs"
        case .meal:         return "fork.knife"
        case .nap:          return "moon.zzz"
        case .thermal:      return "thermometer.snowflake"
        case .drinks:       return "cup.and.saucer.fill"
        case .work:         return "laptopcomputer"
        case .sleep:        return "bed.double.fill"
        case .custom:       return "pencil.circle"
        }
    }

    var color: Color {
        switch self {
        case .exercise:          return Theme.warn
        case .walk:              return Theme.accent
        case .meditation:        return Theme.hrv
        case .breathwork:        return Theme.breathe
        case .meal:              return Theme.rsa
        case .nap:               return Theme.ulf
        case .thermal:           return Color(hex: "#67E8F9")
        case .drinks:            return Color(hex: "#C89F6B")
        case .work:              return Theme.ulf
        case .sleep:             return Theme.hrv
        case .custom:            return Theme.dim
        }
    }

    var subtypes: [String] {
        switch self {
        case .exercise:
            // The last four came across when Walk merged in. Everything with a
            // potential activation belongs on one tile — a walk is simply a
            // low-load, low-suppression session of the same kind.
            return ["Easy Run", "Tempo Run", "Intervals", "Long Run", "Trail Run",
                    "Yoga", "HIIT", "Power Lifting", "Pilates", "Cycling",
                    "Swimming", "Stretching", "CrossFit", "Boxing",
                    "Rowing", "Climbing", "Martial Arts",
                    "Nature Walk", "City Walk", "Hiking", "Treadmill"]
        case .walk:
            return ["Nature Walk", "City Walk", "Hiking", "Treadmill"]
        case .meditation:
            return ["Vipassana", "Guided", "Body Scan", "Loving-Kindness",
                    "Transcendental", "Zen", "Mantra", "Open Awareness", "Yoga Nidra"]
        case .breathwork:
            return ["Resonance", "Wim Hof", "Box Breathing", "4-7-8", "Holotropic",
                    "Pranayama", "Coherent Breathing", "Tummo", "Nadi Shodhana",
                    "Breath Hold"]
        case .meal:
            return ["Breakfast", "Lunch", "Dinner", "Snack", "Fast Breaking"]
        case .nap:
            return ["Power Nap", "Full Cycle"]
        case .thermal:
            return ["Cold Shower", "Ice Bath", "Cold Plunge", "Cryotherapy",
                    "Sauna", "Infrared Sauna", "Steam Room"]
        case .drinks:
            return ["Espresso", "Filter Coffee", "Latte", "Cold Brew", "Decaf",
                    "Beer", "Wine", "Spirits", "Cocktail"]
        case .work:
            return ["Deep Work", "Meetings", "Email", "Creative", "Reading"]
        case .sleep:
            return []
        case .custom:
            return []
        }
    }
}

/// How much of the nine-metric grid reached the headline average, and what kept
/// the rest out.
struct ImpactCoverage: Equatable {
    struct Gap: Equatable {
        let label:  String
        let reason: String
    }

    let counted: Int
    let total:   Int
    let missing: [Gap]

    var isComplete: Bool { counted == total }

    /// "avg of 8/9 metrics" — printed under the headline so the denominator is
    /// never implicit.
    var summary: String { "avg of \(counted)/\(total) metrics" }
}

// MARK: - ActivityLog

/// One logged activity entry (live-tracked or retrospective).
@Model
final class ActivityLog {

    @Attribute(.unique) var id: UUID
    var activityType:    String   // ActivityType.rawValue; "Custom" uses customName
    var activitySubtype: String? // optional subtype, e.g. "Yoga" for Exercise
    var customName:      String? // only set when activityType == "Custom"
    var startedAt:       Date
    var endedAt:         Date?
    var notes:           String?
    var isManual:        Bool    // true = retrospective entry

    /// Optional intended duration for a live activity, in minutes. Drives the
    /// banner's progress display only — nothing ever stops an activity on a
    /// timer. Always nil for retrospective entries.
    var targetMinutes: Int?

    /// OpenAI-generated interpretation + recommendation for this activity's
    /// HRV response. `nil` means "not yet generated" — eligible for retry
    /// by `InsightGenerator.flushPending`.
    var insightText:     String?

    // HRV averages: 5-min before / during / 10-min after
    var beforeHR:    Float?;  var duringHR:    Float?;  var afterHR:    Float?
    var beforeSDNN:  Float?;  var duringSDNN:  Float?;  var afterSDNN:  Float?
    var beforeRSA:   Float?;  var duringRSA:   Float?;  var afterRSA:   Float?
    var beforeVTI:   Float?;  var duringVTI:   Float?;  var afterVTI:   Float?
    var beforeLFHF:  Float?;  var duringLFHF:  Float?;  var afterLFHF:  Float?
    // Stress Balance as the Live view shows it: the breathing-robust 0–100
    // autonomic dial (SNS %), not the raw LF/HF ratio.
    var beforeStress: Float?;  var duringStress: Float?;  var afterStress: Float?
    var beforeRMSSD: Float?;  var duringRMSSD: Float?;  var afterRMSSD: Float?
    var beforeRCMSE: Float?;  var duringRCMSE: Float?;  var afterRCMSE: Float?
    var beforePIP:   Float?;  var duringPIP:   Float?;  var afterPIP:   Float?
    var beforeDC:    Float?;  var duringDC:    Float?;  var afterDC:    Float?
    var beforeDFA1:  Float?;  var duringDFA1:  Float?;  var afterDFA1:  Float?

    // MARK: Sleep
    //
    // Written by `SleepRecorder` for measured nights only. Stored rather than
    // recomputed because the list row holds no sample series, exactly as the
    // exercise-response fields are.

    /// Transparent 0–100 composed from the five sections. Nil when fewer than
    /// two sections were present — one section is not a night score.
    var sleepScore: Int?
    /// The arithmetic behind `sleepScore`, printed so it stays checkable.
    var sleepScoreArithmetic: String?
    /// "6h 02m quiet · 1h 20m active · 0h 30m awake" — the three states, in the
    /// order the hypnogram reads them.
    var sleepStageSummary: String?
    /// Minutes asleep, which is not the same as the window length.
    var sleepAsleepMinutes: Int?
    /// Sleep Regularity Index over the trailing nights available at record
    /// time. Nil until there are at least two nights to compare.
    var sleepRegularity: Float?

    /// The five sections, stored individually so the row can render them
    /// without recomputing, and so an ABSENT section stays absent. A section
    /// with no input must never be persisted as 0 — "we did not measure your
    /// breathing" and "your breathing was terrible" are different sentences.
    var sleepTiming: Int?
    var sleepDuration: Int?
    var sleepContinuity: Int?
    var sleepAutonomic: Int?
    var sleepBreathing: Int?

    /// Four-stage minutes. Stored so the row and detail can show them without
    /// re-deriving, and kept separate from the coarse three-state summary the
    /// SCORE is built on — the score does not use these, deliberately.
    var sleepDeepMinutes: Int?
    var sleepLightMinutes: Int?
    var sleepREMMinutes: Int?
    var sleepAwakeMinutes: Int?
    /// N1 — transitional, marked by position beside wake rather than measured.
    var sleepN1Minutes: Int?

    // MARK: Exercise response
    //
    // Written by `computeExerciseResponse` for activating entries only, and
    // left nil for restorative ones. Stored rather than computed because the
    // list row holds no sample series — only the window averages above — while
    // the VSI slope needs the whole series to be fitted. All optional, so
    // SwiftData migrates without a schema version bump.

    /// How you arrived, 0–100, against your own recent pre-session windows.
    /// Stored because the row has no context to fetch peers with.
    var readinessScore:        Int?
    /// How many peers that score was drawn from — the caption quotes it.
    var readinessPeerCount:    Int?
    /// HR-reserve impulse with Banister weighting. Unitless magnitude.
    var exerciseLoad:          Double?
    /// Slope of lnDC against %HRR, per 10 %HRR. Negative = vagal tone falls
    /// with intensity, as it should.
    var vsiSlopePer10:         Double?
    /// Slope of lnDC against motion impulse, for motion-bearing subtypes only.
    var efficiencySlope:       Double?
    /// Whether this subtype's motion is a fair proxy for mechanical work. False
    /// for lifting, yoga, cycling and swimming — see ExerciseIntensity.
    var hasExternalWorkSignal: Bool = false
    /// Seconds in each DFA α1 domain across the during-window.
    var domainModerateSec:     Double?
    var domainHeavySec:        Double?
    var domainSevereSec:       Double?

    /// 0–100 axis scores, resolved against same-subtype history at session end.
    ///
    /// Stored rather than derived in the view: the scores are percentiles
    /// against other sessions, and a List row cannot fetch that history once
    /// per row without a query storm. nil means "not enough history yet" —
    /// distinct from the slope itself being absent.
    /// Mean DC over the final two minutes of the after-window.
    ///
    /// Recovery is quoted "at ten minutes", which means the level reached by
    /// then — not the average of the ten minutes it took to get there. Using
    /// the whole-window mean folded in the deepest moments right after
    /// stopping and reported a recovery materially lower than the one the
    /// person actually had.
    var afterTailDC:           Float?

    /// Lowest vagal tone reached during the session — the bottom of the hole
    /// recovery is measured as climbing out of. A 10th percentile rather than a
    /// true minimum, so one artifact sample cannot define it.
    var duringDCTrough:        Float?

    /// Beats per minute lost in the first sixty seconds after stopping, and the
    /// short-term decay constant of the first thirty. Both from heart rate
    /// alone, so they survive the sessions where DC cannot be computed at all.
    var hrr60Bpm:              Double?
    var t30Seconds:            Double?

    /// Highest heart rate reached during the session — a 90th percentile rather
    /// than a true maximum, so one artifact beat cannot define the session's
    /// amplitude. Used to judge whether it ended hard enough for a fall in heart
    /// rate to be recovery rather than drift.
    var duringHRPeak:          Float?

    /// Seconds in each of the five heart-rate zones. Stored flat rather than as
    /// a dictionary because SwiftData persists scalars, and five fields is
    /// cheaper than a codable blob to query and to migrate.
    var zone1Sec:              Double?
    var zone2Sec:              Double?
    var zone3Sec:              Double?
    var zone4Sec:              Double?
    var zone5Sec:              Double?

    /// Minutes after the session ended until the vagal brake first came halfway
    /// back to its pre-session level and held there. `nil` means it did not —
    /// see `recoveryObservedMinutes` for how long we watched before saying so.
    var halfRecoveryMinutes:   Double?
    /// How much recording there was after the session, in minutes.
    var recoveryObservedMinutes: Double?

    /// Vagal tone rose with heart rate rather than falling — yoga, mobility,
    /// anything where the brake comes on. Not a failure to measure.
    var vagalRoseDuring:       Bool = false
    var suppressionScore:      Int?
    var efficiencyScore:       Int?
    /// How many same-subtype sessions the scores above were ranked against,
    /// so the row can say "2 of 3" rather than simply going blank.
    var scoreHistoryCount:     Int?

    /// Mean benefit-signed change from the before-window to the during-window
    /// across the nine metrics — literally the average of the per-metric
    /// numbers shown on the rows below the meter, so the two agree to within
    /// rounding at the displayed whole-percent precision. (The one residual
    /// source of drift: VTI is deliberately computed as ln(mean(RMSSD)), not
    /// mean(ln(RMSSD)), so its window average and a point-by-point mean of
    /// per-sample VTI can differ slightly — see the comment on vtiFromRMSSD.)
    /// Computed, never cached: the stored window averages and the detail
    /// view's ActivityMetricStats both derive from the same quality-filtered
    /// samples, so there is nothing to keep in sync.
    var impactDeltaPct: Double? {
        let deltas = activityMetricDefs.compactMap { def in
            def.benefitDelta(current: self[keyPath: def.duringKey].map(Double.init),
                             base:    self[keyPath: def.beforeKey].map(Double.init))
        }
        guard !deltas.isEmpty else { return nil }
        return deltas.reduce(0, +) / Double(deltas.count)
    }

    /// Which metrics actually reached the mean above, and why the rest didn't.
    ///
    /// The mean silently averages however many metrics happened to have both a
    /// before and a during value — eight of nine is common, because Vagal Tone
    /// needs the longest run of clean beats and is the first to drop out of a
    /// five-minute pre-session window. A headline built on a moving denominator
    /// has to show that denominator, or two sessions look comparable when they
    /// are not.
    var impactCoverage: ImpactCoverage {
        var missing: [ImpactCoverage.Gap] = []
        var counted = 0

        for def in activityMetricDefs {
            let during = self[keyPath: def.duringKey].map(Double.init)
            let before = self[keyPath: def.beforeKey].map(Double.init)
            if def.benefitDelta(current: during, base: before) != nil {
                counted += 1
                continue
            }
            missing.append(ImpactCoverage.Gap(label: def.label,
                                              reason: Self.gapReason(def, during: during, before: before)))
        }
        return ImpactCoverage(counted: counted,
                              total: activityMetricDefs.count,
                              missing: missing)
    }

    private static func gapReason(_ def: ActivityMetricDef,
                                  during: Double?, before: Double?) -> String {
        let warmUp = def.warmUp.map { " It needs \($0) of steady signal before it can be computed at all." } ?? ""
        switch (before, during) {
        case (nil, nil):
            return "No reading either before or during the session.\(warmUp)"
        case (nil, _):
            return "No baseline in the five minutes before you started, so there is nothing to compare against.\(warmUp)"
        case (_, nil):
            return "No reading during the session itself."
        default:
            // Both present, so benefitDelta bailed on a zero baseline: the
            // percentage would be a division by zero.
            return "The baseline was zero, so a percentage change is undefined."
        }
    }

    init(activityType:    String,
         activitySubtype: String? = nil,
         customName:      String? = nil,
         startedAt:       Date    = .now,
         endedAt:         Date?   = nil,
         isManual:        Bool    = false,
         targetMinutes:   Int?    = nil) {
        self.id              = UUID()
        self.activityType    = activityType
        self.activitySubtype = activitySubtype
        self.customName      = customName
        self.startedAt       = startedAt
        self.endedAt         = endedAt
        self.isManual        = isManual
        self.targetMinutes   = targetMinutes
    }

    var isActive: Bool { endedAt == nil && !isManual }

    var displayName: String {
        if let sub = activitySubtype { return sub }
        if activityType == ActivityType.custom.rawValue { return customName ?? "Custom" }
        return activityType
    }

    /// The parent type label (e.g. "Exercise" even when displayName is "Yoga")
    var typeLabel: String {
        activityType == ActivityType.custom.rawValue ? (customName ?? "Custom") : activityType
    }

    var activityTypeEnum: ActivityType {
        ActivityType.fromStored(activityType)
    }

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var durationString: String {
        guard let d = duration else { return "—" }
        let mins = Int((d / 60).rounded())
        return mins < 60 ? "\(mins) min" : String(format: "%d h %02d min", mins / 60, mins % 60)
    }

    /// RSA delta during practice (during − before). Positive = nervous system activated/improved.
    var rsaDelta: Float? {
        guard let a = duringRSA, let b = beforeRSA else { return nil }
        return a - b
    }

    var vtiDelta: Float? {
        guard let a = duringVTI, let b = beforeVTI else { return nil }
        return a - b
    }

    var sdnnDelta: Float? {
        guard let a = duringSDNN, let b = beforeSDNN else { return nil }
        return a - b
    }

    /// RSA recovery delta (after − before).
    var rsaRecoveryDelta: Float? {
        guard let a = afterRSA, let b = beforeRSA else { return nil }
        return a - b
    }

    // MARK: Backfill

    /// One-time backfill for sessions logged before a metric field existed
    /// (e.g. the Stress Balance dial, added later). For every finished,
    /// non-manual entry whose `duringStress` is still nil, recomputes all HRV
    /// windows from the `HRVSample` records still in the store. Idempotent —
    /// entries with no samples in range simply stay nil, and re-running
    /// produces the same values for entries already filled.
    /// How long after a session the after-window closes.
    static let afterWindowSeconds: TimeInterval = 600

    /// How long to keep retrying an after-window that never filled. Past this,
    /// a still-empty window means the strap was off, and no amount of relaunching
    /// will conjure samples that were never recorded.
    static let afterWindowRetryCutoff: TimeInterval = 48 * 3600

    /// Whether this entry's stored windows should be recomputed now.
    ///
    /// The after-window is ten minutes that begin when the session ends, so at
    /// the moment `ActivityLogging.end` runs, none of it has happened yet and
    /// every after field is necessarily nil. Something has to come back for it
    /// later; this decides when. Waiting for the full ten minutes matters —
    /// filling it early would store a partial window and, because the guard then
    /// sees a non-nil value, never correct it.
    func needsWindowRefresh(now: Date = .now) -> Bool {
        guard let end = endedAt else { return false }        // still recording
        if duringStress == nil { return true }               // never computed at all
        guard afterStress == nil else { return false }       // already has one
        guard now >= end.addingTimeInterval(ActivityLog.afterWindowSeconds) else {
            return false                                     // the window is still filling
        }
        return now.timeIntervalSince(end) < ActivityLog.afterWindowRetryCutoff
    }

    static func backfillMissingWindows(context: ModelContext) {
        // Bump when the stored metric set changes. v2 adds DC / DFA1 / RCMSE / PIP,
        // which the original nil-Stress guard never backfilled — so older entries
        // showed "—" for e.g. Vagal Tone in the row while the detail (which
        // recomputes live) still had the value. On a version bump we recompute
        // every finished entry once from the samples still in store, then fall back
        // to the cheap ongoing guard.
        // BUMP THIS whenever a stored field is added or its computation changes.
        // Nothing recomputes an existing entry except a bump, so a new field
        // added without one is invisible on every session already logged — the
        // code looks correct and the screen shows stale storage.
        //
        // v3  the exercise response: Load, VSI slope, efficiency slope, domains.
        // v4  recovery as a time (halfRecoveryMinutes, recoveryObservedMinutes,
        //     afterTailDC), vagalRoseDuring, the axis scores, and the corrected
        //     resting heart rate — which changes Load and the VSI slope on every
        //     entry already stored under v3.
        // v5  heart-rate recovery (HRR60, T30), the session's HR peak, and the
        //     trough that the halfway bar is now measured from.
        // v6  heart-rate zone seconds.
        // v7  classification now follows measured heart-rate rise, so entries
        //     stored under the old label-based rule must be re-evaluated.
        // v8  readinessScore/readinessPeerCount — how you arrived, scored
        //     against your own recent pre-session windows.
        let currentVersion = 8
        let versionKey = "activityBackfillVersion"
        let migrating = UserDefaults.standard.integer(forKey: versionKey) < currentVersion

        guard let all = try? context.fetch(FetchDescriptor<ActivityLog>()) else { return }
        let needsFill = all.filter { entry in
            guard entry.endedAt != nil else { return false }
            if migrating { return true }
            return entry.needsWindowRefresh()
        }
        if !needsFill.isEmpty {
            for entry in needsFill {
                entry.computeHRVWindows(context: context)
                entry.computeExerciseResponse(context: context)
            }
            try? context.save()
        }
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    // MARK: HRV window computation

    /// Fastest cadence the tick loop ever records at (foreground). Background
    /// runs at 30 s, so this is the worst case for sample count.
    static let minTickIntervalSec: Double = 2
    /// Hard ceiling so a corrupt end date cannot ask the store for everything.
    static let windowFetchCeiling: Int = 200_000

    /// Queries HRVSample records for the three windows around this activity
    /// and stores per-metric averages. Call after setting `endedAt`.
    func computeHRVWindows(context: ModelContext) {
        guard let end = endedAt else { return }
        let beforeStart = startedAt.addingTimeInterval(-300)   // 5 min before
        let afterEnd    = end.addingTimeInterval(ActivityLog.afterWindowSeconds)

        let allPredicate = #Predicate<HRVSample> {
            $0.timestamp >= beforeStart && $0.timestamp <= afterEnd
        }
        var desc = FetchDescriptor<HRVSample>(
            predicate: allPredicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        // Sized from the window itself, not a constant. The fetch sorts
        // ascending, so a limit smaller than the window drops its TAIL — the
        // end of the session — and every average below is then computed over a
        // prefix while looking exactly like a whole-session number. A fixed
        // 10,000 covered any workout but silently truncated an 8-hour night to
        // its first 5.5 hours at the 2 s foreground cadence.
        let spanSec = afterEnd.timeIntervalSince(beforeStart)
        let maxTicks = Int(spanSec / ActivityLog.minTickIntervalSec) + 1_000
        desc.fetchLimit = min(maxTicks, ActivityLog.windowFetchCeiling)
        guard let rawSamples = try? context.fetch(desc) else { return }
        // Gate samples through the same wear/artifact quality filter the Live
        // view and the activity detail charts use, so these stored window
        // averages match what those screens show. Without this, strap-off and
        // noisy beats (SDNN≈0) pull HRV/SDNN below the filtered live values.
        let samples = rawSamples.filter { MetricsQualityFilter.isValid(MetricsHistoryPoint(from: $0)) }

        // During/after boundary is half-open at `end` — [startedAt, end) / [end, afterEnd] —
        // matching ActivityMetricStats' partition exactly, so these stored window
        // averages and the detail view's per-metric stats agree on which sample
        // owns the boundary timestamp.
        let before = samples.filter { $0.timestamp >= beforeStart && $0.timestamp < startedAt }
        let during = samples.filter { $0.timestamp >= startedAt   && $0.timestamp < end        }
        let after  = samples.filter { $0.timestamp >= end         && $0.timestamp <= afterEnd  }

        func avg(_ arr: [HRVSample], _ kp: KeyPath<HRVSample, Float?>) -> Float? {
            let vals = arr.compactMap { $0[keyPath: kp] }
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Float(vals.count)
        }

        // VTI must be computed as ln(mean(RMSSD)), NOT mean(ln(RMSSD)),
        // to preserve the nonlinear relationship between VTI and RMSSD.
        func vtiFromRMSSD(_ arr: [HRVSample]) -> Float? {
            guard let meanRMSSD = avg(arr, \.rmssd), meanRMSSD > 0 else { return nil }
            return log(meanRMSSD)
        }

        // Stress Balance dial (0–100 SNS %), matching the Live view: compute the
        // breathing-robust balance per sample, then average over the window.
        func stressDial(_ arr: [HRVSample]) -> Float? {
            let vals = arr.compactMap { s in
                AutonomicCompute.balance(rmssd: s.rmssd, lf: s.lfPower, hf: s.hfPower,
                                         breathBPM: s.breathBPM, meanBPM: s.meanBPM,
                                         baselineRmssd: nil).map { $0.sns * 100 }
            }
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Float(vals.count)
        }

        beforeHR    = avg(before, \.meanBPM);   duringHR    = avg(during, \.meanBPM);   afterHR    = avg(after, \.meanBPM)
        beforeSDNN  = avg(before, \.sdnn);       duringSDNN  = avg(during, \.sdnn);       afterSDNN  = avg(after, \.sdnn)
        beforeRSA   = avg(before, \.rsaMs);      duringRSA   = avg(during, \.rsaMs);      afterRSA   = avg(after, \.rsaMs)
        beforeVTI   = vtiFromRMSSD(before);      duringVTI   = vtiFromRMSSD(during);      afterVTI   = vtiFromRMSSD(after)
        beforeLFHF  = avg(before, \.lfHF);       duringLFHF  = avg(during, \.lfHF);       afterLFHF  = avg(after, \.lfHF)
        beforeStress = stressDial(before);       duringStress = stressDial(during);       afterStress = stressDial(after)
        beforeRMSSD = avg(before, \.rmssd);      duringRMSSD = avg(during, \.rmssd);      afterRMSSD = avg(after, \.rmssd)
        beforeRCMSE = avg(before, \.rcmse);      duringRCMSE = avg(during, \.rcmse);      afterRCMSE = avg(after, \.rcmse)
        beforePIP   = avg(before, \.pip);        duringPIP   = avg(during, \.pip);        afterPIP   = avg(after, \.pip)
        beforeDC    = avg(before, \.dc);         duringDC    = avg(during, \.dc);         afterDC    = avg(after, \.dc)
        beforeDFA1  = avg(before, \.dfa1);       duringDFA1  = avg(during, \.dfa1);       afterDFA1  = avg(after, \.dfa1)
    }

    // MARK: Exercise response computation

    /// Computes Load, the VSI slope, the Efficiency slope and the intensity
    /// domain split for an activating entry, and stores them.
    ///
    /// A no-op for restorative entries: they keep the nine-metric benefit-delta
    /// model untouched, and must not acquire exercise fields even accidentally.
    /// Call after `computeHRVWindows`, which supplies the DC baseline.
    /// How you arrived, scored against your own recent pre-session windows.
    ///
    /// Peers are the *before* windows of earlier activating sessions, not the
    /// whole history: the state five minutes before a lift is a different
    /// population from the state five minutes before a meditation, and mixing
    /// them would make every workout look under-recovered.
    func computeReadiness(context: ModelContext) {
        let start = startedAt
        let predicate = #Predicate<ActivityLog> { $0.startedAt < start }
        var desc = FetchDescriptor<ActivityLog>(predicate: predicate,
                                                sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        desc.fetchLimit = 60
        let peers = ((try? context.fetch(desc)) ?? [])
            .filter { $0.measuredClass == .activating }

        let components: [ReadinessScore.Component] = [
            beforeRMSSD.map { today in
                ReadinessScore.Component(today: Double(today),
                                         peers: peers.compactMap { $0.beforeRMSSD.map(Double.init) },
                                         higherIsBetter: true)
            },
            beforeHR.map { today in
                ReadinessScore.Component(today: Double(today),
                                         peers: peers.compactMap { $0.beforeHR.map(Double.init) },
                                         higherIsBetter: false)
            },
            beforeDC.map { today in
                ReadinessScore.Component(today: Double(today),
                                         peers: peers.compactMap { $0.beforeDC.map(Double.init) },
                                         higherIsBetter: true)
            },
        ].compactMap { $0 }

        readinessScore = ReadinessScore.score(components)
        readinessPeerCount = readinessScore == nil ? nil : peers.count
    }

    func computeExerciseResponse(context: ModelContext) {
        // Computed from the measurement, not the label — but the windows must
        // exist first, so this runs after computeHRVWindows has filled them.
        guard measuredClass == .activating else { return }
        guard let end = endedAt else { return }

        computeReadiness(context: context)

        // Same window, quality gate and half-open [startedAt, end) partition as
        // computeHRVWindows, so the two never disagree about which sample is in.
        let predicate = #Predicate<HRVSample> {
            $0.timestamp >= startedAt && $0.timestamp < end
        }
        var desc = FetchDescriptor<HRVSample>(predicate: predicate,
                                              sortBy: [SortDescriptor(\.timestamp)])
        desc.fetchLimit = 10_000
        guard let raw = try? context.fetch(desc) else { return }
        let during = raw.filter { MetricsQualityFilter.isValid(MetricsHistoryPoint(from: $0)) }
        guard !during.isEmpty else { return }

        let span    = reserveSpan(context: context)
        let resting = span.restingHR
        let ceiling = span.ceiling

        // Load
        let hrSamples = during.compactMap { s -> (date: Date, hr: Float)? in
            guard let hr = s.meanBPM else { return nil }
            return (date: s.timestamp, hr: hr)
        }
        exerciseLoad = ExerciseIntensity.load(samples: hrSamples,
                                              restingHR: resting, ceiling: ceiling)

        // Intensity domains
        let dfaSamples = during.compactMap { s -> (date: Date, dfa1: Double)? in
            guard let a = s.dfa1 else { return nil }
            return (date: s.timestamp, dfa1: Double(a))
        }
        // Heart-rate zones, from the same samples and the same gap rule as the
        // domains, so the two accounts of the session cover the same minutes.
        let zoneSamples = during.compactMap { s -> (date: Date, hrReserve: Double)? in
            guard let hr = s.meanBPM else { return nil }
            return (s.timestamp, ExerciseIntensity.hrReserve(hr: hr, restingHR: resting,
                                                             ceiling: ceiling))
        }
        let zones = HeartRateZones.split(samples: zoneSamples)
        zone1Sec = zones[.z1]; zone2Sec = zones[.z2]; zone3Sec = zones[.z3]
        zone4Sec = zones[.z4]; zone5Sec = zones[.z5]

        let split = ExerciseIntensity.domainSplit(samples: dfaSamples)
        domainModerateSec = split[.moderate]
        domainHeavySec    = split[.heavy]
        domainSevereSec   = split[.severe]

        // Suppression — lnDC against %HRR
        let vsiSamples = during.compactMap { s -> (hrrPct: Double, dc: Double, dfa1: Double?)? in
            guard let hr = s.meanBPM, let dc = s.dc else { return nil }
            let hrr = ExerciseIntensity.hrReserve(hr: hr, restingHR: resting, ceiling: ceiling)
            return (hrrPct: hrr * 100, dc: Double(dc), dfa1: s.dfa1.map(Double.init))
        }
        let vsiFit = ExerciseSuppression.vsi(samples: vsiSamples)
        // A session where vagal tone rose is not a suppression session, so it
        // stores no slope to be ranked — but `vagalRose` is worth saying out loud.
        vsiSlopePer10 = (vsiFit?.vagalRose == true) ? nil : vsiFit?.slopePer10
        vagalRoseDuring = vsiFit?.vagalRose ?? false

        // Efficiency — lnDC against motion impulse, and only where motion is a
        // fair proxy for mechanical work.
        hasExternalWorkSignal = ExerciseIntensity.hasExternalWorkSignal(
            subtype: activitySubtype,
            motion: during.compactMap(\.motion))
        if hasExternalWorkSignal {
            let workSamples = during.compactMap { s -> (hrrPct: Double, dc: Double, dfa1: Double?)? in
                guard let motion = s.motion, let dc = s.dc else { return nil }
                // Reuses the VSI fitter: the regressor is motion rather than
                // %HRR, which is the whole difference between the two axes.
                return (hrrPct: Double(motion), dc: Double(dc), dfa1: s.dfa1.map(Double.init))
            }
            // Judged in milli-g, not in %HRR, and — as with Suppression — a fit
            // where vagal tone rose is not an economy measurement, so it stores
            // nothing to be ranked rather than being scored as excellent.
            let workFit = ExerciseSuppression.vsi(
                samples: workSamples,
                minimumSpan: ExerciseSuppression.minimumMotionSpan)
            efficiencySlope = (workFit?.vagalRose == true) ? nil : workFit?.slopePer10
        } else {
            efficiencySlope = nil
        }

        // The trough must exist before the timing, which measures against it.
        let dcDuring = during.compactMap(\.dc).sorted()
        duringDCTrough = dcDuring.isEmpty ? nil : dcDuring[Int(0.10 * Double(dcDuring.count - 1))]
        let hrDuring = during.compactMap(\.meanBPM).sorted()
        duringHRPeak = hrDuring.isEmpty ? nil : hrDuring[Int(0.90 * Double(hrDuring.count - 1))]

        computeHeartRateRecovery(context: context)
        computeRecoveryTail(context: context)
        computeRecoveryTiming(context: context)
        scoreSlopesAgainstHistory(context: context)
    }

    /// Mean DC across the last two minutes of the after-window — the level
    /// recovery actually reached, rather than its average on the way there.
    private func computeRecoveryTail(context: ModelContext) {
        guard let end = endedAt else { return }
        let windowEnd  = end.addingTimeInterval(600)
        let tailStart  = end.addingTimeInterval(480)
        let predicate = #Predicate<HRVSample> {
            $0.timestamp >= tailStart && $0.timestamp <= windowEnd
        }
        let raw = (try? context.fetch(FetchDescriptor<HRVSample>(predicate: predicate))) ?? []
        let vals = raw
            .filter { MetricsQualityFilter.isValid(MetricsHistoryPoint(from: $0)) }
            .compactMap(\.dc)
        // Falls back to the window mean when the strap came off before the tail,
        // so a short recording degrades rather than going blank.
        afterTailDC = vals.isEmpty ? afterDC : vals.reduce(0, +) / Float(vals.count)
    }

    /// How fast heart rate fell once the session ended.
    ///
    /// Separate from the vagal measures on purpose: it needs only heart rate,
    /// so it produces a number on the resistance sessions where DC cannot be
    /// computed and every vagal measure goes blank.
    private func computeHeartRateRecovery(context: ModelContext) {
        guard let end = endedAt else { return }
        let horizon = end.addingTimeInterval(300)
        let predicate = #Predicate<HRVSample> {
            $0.timestamp >= end && $0.timestamp <= horizon
        }
        var desc = FetchDescriptor<HRVSample>(predicate: predicate,
                                              sortBy: [SortDescriptor(\.timestamp)])
        desc.fetchLimit = 5_000
        let after = ((try? context.fetch(desc)) ?? [])
            .filter { MetricsQualityFilter.isValid(MetricsHistoryPoint(from: $0)) }
            .compactMap { s -> (seconds: Double, hr: Double)? in
                guard let hr = s.meanBPM else { return nil }
                return (s.timestamp.timeIntervalSince(end), Double(hr))
            }

        let resting = beforeHR.map(Double.init)
        let peak    = duringHRPeak.map(Double.init) ?? duringHR.map(Double.init)
        hrr60Bpm = HeartRateRecovery.hrr60(after: after,
                                           hrAtEnd: after.first?.hr ?? duringHR.map(Double.init),
                                           restingHR: resting, peakHR: peak)
        t30Seconds = HeartRateRecovery.t30(after: after, restingHR: resting, peakHR: peak)
    }

    /// Time for the vagal brake to come halfway back, which is what "recovery"
    /// actually means. A level at a fixed moment could not distinguish a session
    /// climbing back from one still falling.
    private func computeRecoveryTiming(context: ModelContext) {
        guard let end = endedAt else { return }
        // Looks past the stored 10-minute window: recovery that takes longer is
        // exactly the case worth reporting, and cutting it off at ten minutes
        // would report "never" for a session that came back at twelve.
        let horizon = end.addingTimeInterval(4 * 3600)
        let predicate = #Predicate<HRVSample> {
            $0.timestamp >= end && $0.timestamp <= horizon
        }
        var desc = FetchDescriptor<HRVSample>(predicate: predicate,
                                              sortBy: [SortDescriptor(\.timestamp)])
        desc.fetchLimit = 20_000
        let raw = (try? context.fetch(desc)) ?? []
        let after = raw
            .filter { MetricsQualityFilter.isValid(MetricsHistoryPoint(from: $0)) }
            .compactMap { s -> (minutes: Double, dc: Double)? in
                guard let dc = s.dc else { return nil }
                return (s.timestamp.timeIntervalSince(end) / 60, Double(dc))
            }

        let outcome = RecoveryTiming.halfRecovery(after: after,
                                                  dcPre: beforeDC.map(Double.init),
                                                  dcTrough: duringDCTrough.map(Double.init))
        switch outcome {
        case let .reached(minutes):
            halfRecoveryMinutes = minutes
            recoveryObservedMinutes = after.last?.minutes
        case let .notReached(observed):
            halfRecoveryMinutes = nil
            recoveryObservedMinutes = observed
        case .notObserved:
            halfRecoveryMinutes = nil
            recoveryObservedMinutes = nil
        }
    }

    /// Which model this session is read with, from what the heart actually did.
    ///
    /// Every screen branches on this rather than on the activity type, so a
    /// practice that raised the pulse gets the activation reading and the fuller
    /// recovery analysis whatever tile it was logged under.
    var measuredClass: ActivityClass {
        // The measurement decides only WITHIN the exercise family. A breathwork
        // round or a meditation that raises the pulse is still that practice —
        // promoting it to the load-and-recovery model told people their
        // breathing exercise was a workout. Exercises go the other way: they
        // are judged by the measured rise, and one that never lifted the pulse
        // reads as the restorative session it physiologically was.
        // By type, both ways: exercises are always the pulse-rose category —
        // a gentle session still gets the load-and-recovery read, with the
        // measured rise stated on the chip — and restorative practices never
        // are. The measurement informs; the label decides.
        activityTypeEnum.activityClass
    }

    /// ΔDC per extra bpm — the index in its own units, always available from the
    /// stored window averages.
    var brakePerBeat: Double? {
        ExerciseSuppression.brakePerBeat(dcPre: beforeDC.map(Double.init),
                                         dcDuring: duringDC.map(Double.init),
                                         hrPre: beforeHR.map(Double.init),
                                         hrDuring: duringHR.map(Double.init))
    }

    /// Suppression as an axis value.
    ///
    /// Scored from the index against fixed anchors so it exists from the first
    /// session. The history percentile, when there is history, becomes the
    /// wording rather than the number — "cheaper than usual" is a comparison,
    /// and a comparison cannot be the score when there is nothing to compare to.
    var suppressionAxis: AxisValue {
        if vagalRoseDuring { return .unavailable(reason: "vagal tone rose — nothing suppressed") }
        // The same case by another route: vagalRoseDuring needs a VSI fit, which
        // sparse or restored samples may not support — but a non-positive
        // brake-per-beat says the same thing directly. DC held or rose, nothing
        // was released, and clamping it to a perfect 100 dressed a gentle yoga
        // as flawless suppression.
        if let perBeat = brakePerBeat, perBeat <= 0 {
            return .unavailable(reason: "vagal tone held — nothing released")
        }
        guard let score = ExerciseSuppression.economyScore(brakePerBeat: brakePerBeat) else {
            return .unavailable(reason: "not enough heart-rate rise to measure")
        }
        let word = suppressionScore.map(ExerciseResponse.word(for:))
            ?? ExerciseResponse.word(for: score)
        return .score(score, word: word)
    }

    /// The stored zone seconds, back in the shape the chart consumes.
    var zoneSplit: [HeartRateZone: TimeInterval] {
        var out: [HeartRateZone: TimeInterval] = [:]
        if let v = zone1Sec { out[.z1] = v }
        if let v = zone2Sec { out[.z2] = v }
        if let v = zone3Sec { out[.z3] = v }
        if let v = zone4Sec { out[.z4] = v }
        if let v = zone5Sec { out[.z5] = v }
        return out
    }

    /// Heart-rate recovery as an axis value.
    ///
    /// Kept separate from the vagal rebound rather than folded into one
    /// "recovery" number: heart rate is routinely home while vagal tone is
    /// still well down, and the distance between them is the difference between
    /// looking recovered and being recovered.
    var heartRateRecoveryAxis: AxisValue {
        guard let score = HeartRateRecovery.score(hrr60: hrr60Bpm) else {
            return .unavailable(reason: "ended too easy to measure a fall")
        }
        return .score(score, word: ExerciseResponse.word(for: score))
    }

    /// Recovery as an axis value, scored from how long it took rather than from
    /// a level — so a session still falling can never score as partly recovered.
    var recoveryAxis: AxisValue {
        let outcome = recoveryOutcome
        guard let score = RecoveryTiming.score(outcome) else {
            return .unavailable(reason: "not enough recording after")
        }
        return .score(score, word: ExerciseResponse.word(for: score))
    }

    /// The stored timing, back in the shape the views and the score consume.
    var recoveryOutcome: RecoveryTiming.Outcome {
        if let m = halfRecoveryMinutes { return .reached(minutes: m) }
        if let o = recoveryObservedMinutes,
           o >= RecoveryTiming.minimumObservationMinutes { return .notReached(observedMinutes: o) }
        return .notObserved
    }

    /// What this session is compared against: its subtype when it has one,
    /// otherwise its type. Sessions are usually logged without a subtype, so
    /// keying strictly on subtype leaves them with no peers at all.
    var scoreGroupKey: String {
        activitySubtype ?? typeLabel
    }

    /// Ranks this session's slopes against other completed sessions in the same
    /// group, and stores the resulting 0–100 scores.
    ///
    /// Done here, where a context is already in hand, so the list row can render
    /// from stored values instead of issuing a fetch per row.
    private func scoreSlopesAgainstHistory(context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: startedAt) ?? .distantPast
        let myID   = id
        let predicate = #Predicate<ActivityLog> {
            $0.startedAt >= cutoff && $0.endedAt != nil && $0.id != myID
        }
        let all = (try? context.fetch(FetchDescriptor<ActivityLog>(predicate: predicate))) ?? []
        // Compare like with like, but never at the cost of comparing with
        // nothing: most sessions carry no subtype, and keying strictly on one
        // left almost every real session with an empty peer set. Falls back to
        // the activity type, which is a coarser but honest grouping.
        let key = scoreGroupKey
        let peers = all.filter { $0.activityTypeEnum.activityClass == .activating
                                  && $0.scoreGroupKey == key }
        // Count peers that can actually be ranked against, not peers that
        // merely exist. Three sessions whose own slope never fitted contribute
        // nothing, and counting them produced the nonsense "4 of 3": three
        // peers present, an empty comparison set, and a progress line claiming
        // to have overshot a threshold it had not reached.
        scoreHistoryCount = peers.filter { $0.vsiSlopePer10 != nil }.count

        if let slope = vsiSlopePer10 {
            suppressionScore = ExerciseResponse.percentileScore(
                value: slope,
                history: peers.compactMap(\.vsiSlopePer10),
                lowerIsBetter: false)
        } else {
            suppressionScore = nil
        }

        if hasExternalWorkSignal, let slope = efficiencySlope {
            efficiencyScore = ExerciseResponse.percentileScore(
                value: slope,
                history: peers.compactMap(\.efficiencySlope),
                lowerIsBetter: false)
        } else {
            efficiencyScore = nil
        }
    }

    /// The resting-to-ceiling span this session's intensity is measured against.
    ///
    /// Shared with the detail view so the chart and the stored numbers cannot
    /// disagree about what 50 %HRR means.
    func reserveSpan(context: ModelContext) -> ReserveSpan {
        let cutoff = Calendar.current.date(byAdding: .day, value: -180, to: endedAt ?? .now)
            ?? .distantPast

        let anchorPredicate = #Predicate<DailyAnchor> { $0.day >= cutoff }
        let anchors = ((try? context.fetch(FetchDescriptor<DailyAnchor>(predicate: anchorPredicate))) ?? [])
            .map(\.restingHR)

        let predicate = #Predicate<HRVSample> { $0.timestamp >= cutoff }
        var desc = FetchDescriptor<HRVSample>(predicate: predicate)
        desc.fetchLimit = 200_000
        let samples = (try? context.fetch(desc)) ?? []

        return ReserveSpan.build(anchorRestingHRs: anchors,
                                 bpm: samples.compactMap(\.meanBPM),
                                 motion: samples.map(\.motion))
    }
}
