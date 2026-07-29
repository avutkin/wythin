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
    case custom       = "Custom"

    /// The nine tiles shown in the picker grid — Custom is offered separately
    /// beneath it so it stays reachable without spending a tile.
    static var pickerCases: [ActivityType] { allCases.filter { $0 != .custom } }

    /// Resolves a stored `activityType` string, including types that have
    /// since been merged into a broader one. Old entries keep their own
    /// subtype ("Tempo Run", "Espresso"), so nothing is lost — only the tile
    /// they group under changed.
    static func fromStored(_ raw: String) -> ActivityType {
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
        case .custom:            return Theme.dim
        }
    }

    var subtypes: [String] {
        switch self {
        case .exercise:
            return ["Easy Run", "Tempo Run", "Intervals", "Long Run", "Trail Run",
                    "Yoga", "HIIT", "Power Lifting", "Pilates", "Cycling",
                    "Swimming", "Stretching", "CrossFit", "Boxing",
                    "Rowing", "Climbing", "Martial Arts"]
        case .walk:
            return ["Nature Walk", "City Walk", "Hiking", "Treadmill"]
        case .meditation:
            return ["Vipassana", "Guided", "Body Scan", "Loving-Kindness",
                    "Transcendental", "Zen", "Mantra", "Open Awareness", "Yoga Nidra"]
        case .breathwork:
            return ["Resonance", "Wim Hof", "Box Breathing", "4-7-8", "Holotropic",
                    "Pranayama", "Coherent Breathing", "Tummo", "Nadi Shodhana"]
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
        case .custom:
            return []
        }
    }
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
    static func backfillMissingWindows(context: ModelContext) {
        // Bump when the stored metric set changes. v2 adds DC / DFA1 / RCMSE / PIP,
        // which the original nil-Stress guard never backfilled — so older entries
        // showed "—" for e.g. Vagal Tone in the row while the detail (which
        // recomputes live) still had the value. On a version bump we recompute
        // every finished entry once from the samples still in store, then fall back
        // to the cheap ongoing guard.
        let currentVersion = 2
        let versionKey = "activityBackfillVersion"
        let migrating = UserDefaults.standard.integer(forKey: versionKey) < currentVersion

        guard let all = try? context.fetch(FetchDescriptor<ActivityLog>()) else { return }
        let needsFill = all.filter { entry in
            guard entry.endedAt != nil else { return false }
            if migrating { return true }
            return entry.duringStress == nil
        }
        if !needsFill.isEmpty {
            for entry in needsFill {
                entry.computeHRVWindows(context: context)
            }
            try? context.save()
        }
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    // MARK: HRV window computation

    /// Queries HRVSample records for the three windows around this activity
    /// and stores per-metric averages. Call after setting `endedAt`.
    func computeHRVWindows(context: ModelContext) {
        guard let end = endedAt else { return }
        let beforeStart = startedAt.addingTimeInterval(-300)   // 5 min before
        let afterEnd    = end.addingTimeInterval(600)           // 10 min after

        let allPredicate = #Predicate<HRVSample> {
            $0.timestamp >= beforeStart && $0.timestamp <= afterEnd
        }
        var desc = FetchDescriptor<HRVSample>(
            predicate: allPredicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        desc.fetchLimit = 10_000   // match the detail chart's fetch so long sessions aren't truncated
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
}
