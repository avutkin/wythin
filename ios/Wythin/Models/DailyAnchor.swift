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

    /// What the replay did, for the log line. The counts are the only way to
    /// read an on-device before/after anchor total: a total that moved little
    /// could be many days gained and as many lost, and those are very different
    /// outcomes.
    struct Outcome: Sendable, Equatable {
        var daysConsidered  = 0   // days with replayable samples in the window
        var anchorsWritten  = 0   // of those, days that produced an anchor
        var anchorsDropped  = 0   // of those, days that had an anchor and now do not
        var saved           = false
    }

    static func runIfNeeded(container: ModelContainer,
                            defaults: UserDefaults = .standard) async {
        guard defaults.integer(forKey: flagKey) < version else { return }

        // Off the main actor. This user records ~4–5k samples a day, so even
        // bounded to the baseline window it is a six-figure row count of a
        // 28-attribute model — and the one caller is `DayPotentialStore.refresh`
        // on Live-tab appearance, where a main-thread stall of that size is a
        // watchdog kill. Same shape as `AppEnvironment.loadHistory`.
        let outcome = await Task.detached(priority: .utility) {
            replay(in: ModelContext(container))
        }.value

        // The flag advances only on a save that actually landed. Setting it
        // unconditionally would strand the user on the old anchors *and* claim
        // the rebuild was done, with no retry — the exact inconsistent baseline
        // this exists to remove.
        guard outcome.saved else {
            print("⚠️ AnchorBackfill: save failed — will retry on next launch")
            return
        }
        defaults.set(version, forKey: flagKey)
        print("⚓️ AnchorBackfill v\(version): \(outcome.daysConsidered) days replayed, "
              + "\(outcome.anchorsWritten) anchored, \(outcome.anchorsDropped) lost their anchor")
    }

    /// Pure of UserDefaults so the caller owns the flag. Returns what it did.
    private static func replay(in context: ModelContext) -> Outcome {
        var outcome = Outcome()

        // Bounded to the baseline window: `AnchorBaseline.build` cuts at
        // `windowDays`, so an anchor older than that feeds nothing and
        // recomputing it buys nothing. Unbounded, this grows without limit for
        // the life of the install — `HRVSample` rows are never pruned.
        let cal    = Calendar.current
        let cutoff = cal.startOfDay(
            for: cal.date(byAdding: .day, value: -AnchorBaseline.windowDays, to: .now) ?? .distantPast)

        // Fetched directly rather than through sessions: continuous background
        // samples hang off an auto-created session, and an orphaned sample would
        // otherwise be invisible here.
        let descriptor = FetchDescriptor<HRVSample>(predicate: #Predicate { $0.timestamp >= cutoff })
        let samples = (try? context.fetch(descriptor)) ?? []
        guard !samples.isEmpty else {
            // Nothing to replay is a finished backfill, not a failed one —
            // anything written from here on is written by the current rules.
            outcome.saved = true
            return outcome
        }

        // Today is left alone. `DailyAnchor` is documented as written once and
        // never recomputed, and today's is the one row the tick loop may be
        // writing concurrently on the main actor — replaying it would both break
        // the freeze and risk two rows for the same day. It costs nothing: today
        // is not in its own baseline, and if it has no anchor yet the normal
        // path will build one under the current rules anyway.
        let today = cal.startOfDay(for: .now)
        let byDay = Dictionary(grouping: samples.map { MetricsHistoryPoint(from: $0) }) {
            cal.startOfDay(for: $0.timestamp)
        }.filter { $0.key < today }
        outcome.daysConsidered = byDay.count

        // Recompute only days we can still recompute. A day whose raw samples
        // are gone — or that fell out of the window — keeps whatever was
        // stored: a stale anchor beats no anchor, and there is nothing to
        // rebuild it from.
        let stored = (try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []
        var hadAnchor: Set<Date> = []
        for anchor in stored where byDay[anchor.day] != nil {
            hadAnchor.insert(anchor.day)
            context.delete(anchor)
        }

        for (day, dayPoints) in byDay {
            guard let reading = AnchorDetector.detect(MetricsQualityFilter.filter(dayPoints)) else {
                if hadAnchor.contains(day) { outcome.anchorsDropped += 1 }
                continue
            }
            context.insert(DailyAnchor(from: reading))
            outcome.anchorsWritten += 1
        }

        do {
            try context.save()
            outcome.saved = true
        } catch {
            // Leave the flag where it is; the deletes go with the unsaved
            // context and the store keeps its old anchors.
            print("❌ AnchorBackfill: \(error)")
        }
        return outcome
    }
}
