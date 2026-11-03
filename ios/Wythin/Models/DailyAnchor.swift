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
    /// 3 — breath gate widened to admit resonance breathing (was 8...20, now
    /// 4...20): mornings paced at ~5.5-6/min were being rejected outright, and
    /// a user already parked on v2 is never touched by that fix unless the
    /// flag advances again to force a replay.
    static let version = 3

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

    /// Every store operation the replay can fail on, behind closures.
    ///
    /// The seam exists because these failures decide whether the version flag
    /// advances, and a wrongly-advanced flag is permanent: there is no second
    /// attempt and no undo. An in-memory `ModelContainer` has no reachable way
    /// to make a real fetch or save throw, so without this the failure branches
    /// could only be argued about, not tested.
    struct Store {
        var samples: (Date) throws -> [HRVSample]
        var anchors: () throws -> [DailyAnchor]
        var delete:  (DailyAnchor) -> Void
        var insert:  (DailyAnchor) -> Void
        var save:    () throws -> Void

        static func live(_ context: ModelContext) -> Store {
            Store(
                // Fetched directly rather than through sessions: continuous
                // background samples hang off an auto-created session, and an
                // orphaned sample would otherwise be invisible here.
                samples: { cutoff in
                    try context.fetch(
                        FetchDescriptor<HRVSample>(predicate: #Predicate { $0.timestamp >= cutoff }))
                },
                anchors: { try context.fetch(FetchDescriptor<DailyAnchor>()) },
                delete:  { context.delete($0) },
                insert:  { context.insert($0) },
                save:    { try context.save() })
        }
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
            replay(.live(ModelContext(container)))
        }.value

        record(outcome, in: defaults)
    }

    /// The flag advances only on a replay that actually landed. Split out from
    /// `runIfNeeded` so the decision is testable without a store: setting the
    /// flag after a failure would strand the user on the old anchors *and*
    /// claim the rebuild was done, with no retry — the exact inconsistent
    /// baseline this exists to remove.
    static func record(_ outcome: Outcome, in defaults: UserDefaults) {
        guard outcome.saved else {
            print("⚠️ AnchorBackfill: incomplete — will retry on next launch")
            return
        }
        defaults.set(version, forKey: flagKey)
        print("⚓️ AnchorBackfill v\(version): \(outcome.daysConsidered) days replayed, "
              + "\(outcome.anchorsWritten) anchored, \(outcome.anchorsDropped) lost their anchor")
    }

    /// Pure of UserDefaults so the caller owns the flag. Returns what it did.
    static func replay(_ store: Store) -> Outcome {
        var outcome = Outcome()

        // Bounded to the baseline window: `AnchorBaseline.build` cuts at
        // `windowDays`, so an anchor older than that feeds nothing and
        // recomputing it buys nothing. Unbounded, this grows without limit for
        // the life of the install — `HRVSample` rows are never pruned.
        let cal    = Calendar.current
        let cutoff = cal.startOfDay(
            for: cal.date(byAdding: .day, value: -AnchorBaseline.windowDays, to: .now) ?? .distantPast)

        let samples: [HRVSample]
        do {
            samples = try store.samples(cutoff)
        } catch {
            // A throwing fetch is not an empty store. Treating it as one would
            // report "nothing to replay, we are done" and advance the flag,
            // freezing the user on v1 anchors forever.
            print("❌ AnchorBackfill: sample fetch — \(error)")
            return outcome
        }
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
        let stored: [DailyAnchor]
        do {
            stored = try store.anchors()
        } catch {
            // Must not fall through to the insert loop on an empty `stored`:
            // nothing would be deleted but a fresh anchor would still be
            // written for every replayable day, and `DailyAnchor` has no unique
            // constraint on `day`. Two rows per day, saved, flag advanced,
            // never retried — and both rows counted by `AnchorBaseline.build`.
            print("❌ AnchorBackfill: anchor fetch — \(error)")
            return outcome
        }
        var hadAnchor: Set<Date> = []
        for anchor in stored where byDay[anchor.day] != nil {
            hadAnchor.insert(anchor.day)
            store.delete(anchor)
        }

        for (day, dayPoints) in byDay {
            guard let reading = AnchorDetector.detect(MetricsQualityFilter.filter(dayPoints)) else {
                if hadAnchor.contains(day) { outcome.anchorsDropped += 1 }
                continue
            }
            store.insert(DailyAnchor(from: reading))
            outcome.anchorsWritten += 1
        }

        do {
            try store.save()
            outcome.saved = true
        } catch {
            // Leave the flag where it is; the deletes go with the unsaved
            // context and the store keeps its old anchors.
            print("❌ AnchorBackfill: \(error)")
        }
        return outcome
    }
}

// MARK: - Sleep window override

/// A night's boundaries as the sleeper corrected them.
///
/// Lives here rather than in its own file for the same reason `DailyAnchor`
/// does: it is one row per day, keyed the same way, and adding a Swift file to
/// this project means a hand-edited `project.pbxproj` whose reference tokens
/// are assigned by hand — a merge of that file left `main` uncompilable once
/// already.
///
/// **Why an override exists at all.** The detector is inference, and it will
/// keep being inference: a chest strap cannot see you close your eyes. It has
/// put a night's onset in the evening it was recorded in, and it has ended a
/// night three hours early. Each of those was a real bug and each was fixed —
/// but the class of error does not go away, because the boundary genuinely is
/// ambiguous for the last person who can settle it. So the app proposes, and
/// the sleeper corrects.
///
/// **Keyed by wake date, and that matters.** `SleepWindow.day` is already the
/// date a night is filed under — the 20th-to-21st night is the 21st's — so an
/// override keyed the same way survives the thing that would otherwise erase
/// it. Every algorithm bump purges stored nights and re-detects them from the
/// samples; a correction stored *on the night* would be deleted with it, and
/// the sleeper would have to make the same correction after every release. Kept
/// beside the night instead, it is re-applied to whatever the detector produces
/// next.
@Model
final class SleepWindowOverride {
    /// Start of the local day the night is filed under — its WAKE date.
    /// One row per night.
    var day: Date
    /// The corrected boundaries. Either may be nil: correcting only the end is
    /// the common case, and forcing the sleeper to restate a start the detector
    /// already had right would be a good way to introduce a second error.
    var startedAt: Date?
    var endedAt: Date?
    /// When the correction was made, so a later one supersedes an earlier.
    var correctedAt: Date

    init(day: Date, startedAt: Date? = nil, endedAt: Date? = nil, correctedAt: Date = .now) {
        self.day = day
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.correctedAt = correctedAt
    }

    /// The window with this correction laid over it.
    ///
    /// Ordering is enforced rather than trusted: a drag that puts the start
    /// past the end would otherwise store a negative-length night that every
    /// downstream duration, share and score would then divide by.
    func applied(to window: SleepWindow) -> SleepWindow {
        let start = startedAt ?? window.startedAt
        let end = endedAt ?? window.endedAt
        guard end > start else { return window }
        return SleepWindow(startedAt: start, endedAt: end)
    }
}
