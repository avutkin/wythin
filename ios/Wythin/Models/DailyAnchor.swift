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

/// One-time replay of stored history into anchors, so a user with months of
/// samples does not start from an empty baseline. Motion is unavailable for
/// past samples, so the HR-stability proxy applies and every anchor produced
/// here is marked low-confidence.
enum AnchorBackfill {

    static let flagKey = "anchorBackfillCompleted"

    @MainActor
    static func runIfNeeded(context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }
        defer { defaults.set(true, forKey: flagKey) }

        let existing = Set(((try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []).map { $0.day })
        let sessions = (try? context.fetch(FetchDescriptor<HRVSession>())) ?? []
        let points = sessions.flatMap { $0.samples }.map { MetricsHistoryPoint(from: $0) }
        guard !points.isEmpty else { return }

        let cal = Calendar.current
        let byDay = Dictionary(grouping: points) { cal.startOfDay(for: $0.timestamp) }
        for (day, dayPoints) in byDay where !existing.contains(day) {
            guard let reading = AnchorDetector.detect(MetricsQualityFilter.filter(dayPoints)) else { continue }
            context.insert(DailyAnchor(from: reading))
        }
        try? context.save()
    }
}
