import Foundation
import SwiftData

/// One day's rested-window reading, written once and never recomputed —
/// the freeze is what keeps the day's potential score stable while the day
/// goes on around it.
@Model
final class DailyAnchor {
    /// Start of the local day this anchor belongs to. One row per day.
    var day:         Date
    var startedAt:   Date
    var durationSec: Double
    var hour:        Double
    var lnRMSSD:     Float
    var dc:          Float?
    var restingHR:   Float
    var pip:         Float?
    var dfa1:        Float?
    var breathBPM:   Float?
    var late:        Bool
    var motionKnown: Bool
    /// `AnchorConfidence.rawValue`
    var confidenceRaw: String

    init(from r: AnchorReading) {
        self.day           = r.day
        self.startedAt     = r.startedAt
        self.durationSec   = r.durationSec
        self.hour          = r.hour
        self.lnRMSSD       = r.lnRMSSD
        self.dc            = r.dc
        self.restingHR     = r.restingHR
        self.pip           = r.pip
        self.dfa1          = r.dfa1
        self.breathBPM     = r.breathBPM
        self.late          = r.late
        self.motionKnown   = r.motionKnown
        self.confidenceRaw = r.confidence.rawValue
    }

    var reading: AnchorReading {
        AnchorReading(
            startedAt:   startedAt,
            durationSec: durationSec,
            hour:        hour,
            lnRMSSD:     lnRMSSD,
            dc:          dc,
            restingHR:   restingHR,
            pip:         pip,
            dfa1:        dfa1,
            breathBPM:   breathBPM,
            late:        late,
            motionKnown: motionKnown,
            confidence:  AnchorConfidence(rawValue: confidenceRaw) ?? .low)
    }
}

// MARK: - Backfill

/// Replay of stored samples into anchors, so a user with months of history does
/// not start from an empty baseline — and so a change to the detector does not
/// leave old anchors sitting in the same baseline as new ones.
enum AnchorBackfill {

    /// Versioned rather than boolean: whenever the detector's output changes,
    /// stored anchors have to be recomputed or they sit in the same baseline as
    /// anchors built by different rules, which is worse than having neither.
    static let flagKey = "anchorBackfillVersion"
    /// 2 — cadence-aware run splitting, tolerant quality gates, 300 s window.
    static let version = 2

    @MainActor
    static func runIfNeeded(context: ModelContext, defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: flagKey) < version else { return }
        defer { defaults.set(version, forKey: flagKey) }

        // Fetched directly rather than through sessions: continuous background
        // samples hang off an auto-created session, and an orphaned sample would
        // otherwise be invisible here.
        let samples = (try? context.fetch(FetchDescriptor<HRVSample>())) ?? []
        guard !samples.isEmpty else { return }

        let cal = Calendar.current
        let byDay = Dictionary(grouping: samples.map { MetricsHistoryPoint(from: $0) }) {
            cal.startOfDay(for: $0.timestamp)
        }

        // Recompute only days we can still recompute. A day whose raw samples
        // are gone keeps whatever was stored — a stale anchor beats no anchor,
        // and there is nothing to rebuild it from.
        let stored = (try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []
        for anchor in stored where byDay[anchor.day] != nil {
            context.delete(anchor)
        }

        for (_, dayPoints) in byDay {
            guard let reading = AnchorDetector.detect(MetricsQualityFilter.filter(dayPoints)) else { continue }
            context.insert(DailyAnchor(from: reading))
        }
        try? context.save()
    }
}
