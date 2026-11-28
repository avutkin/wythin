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
        /// Exactly one calendar day, returned as values rather than models.
        var samples: (Date) throws -> [MetricsHistoryPoint]
        var anchors: () throws -> [DailyAnchor]
        var delete:  (DailyAnchor) -> Void
        var insert:  (DailyAnchor) -> Void
        var save:    () throws -> Void
        var rollback: () -> Void
        var canCommit: () -> Bool

        static func live(_ context: ModelContext, calendar: Calendar = .current) -> Store {
            let container = context.container
            let timezone = calendar.timeZone.identifier
            return Store(
                samples: { day in
                    guard let end = calendar.date(byAdding: .day, value: 1, to: day) else {
                        throw HistoricalDayReader.ReadError.invalidRange
                    }
                    return try HistoricalDayReader.read(container: container, from: day, until: end)
                },
                anchors: { try context.fetch(FetchDescriptor<DailyAnchor>()) },
                delete:  { context.delete($0) },
                insert:  { context.insert($0) },
                save:    { try context.save() },
                rollback: { context.rollback() },
                canCommit: { TimeZone.autoupdatingCurrent.identifier == timezone })
        }
    }

    @discardableResult
    static func runIfNeeded(container: ModelContainer,
                            defaults: UserDefaults = .standard) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard defaults.integer(forKey: flagKey) < version else { return true }
        let calendar = Calendar.current
        let now = Date()
        let worker = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return replay(.live(context, calendar: calendar), calendar: calendar, now: now)
        }
        let outcome = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return false }
        record(outcome, in: defaults)
        return outcome.saved
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
    static func replay(_ store: Store, calendar: Calendar = .current, now: Date = .now) -> Outcome {
        var outcome = Outcome()
        let today = calendar.startOfDay(for: now)
        guard var day = calendar.date(byAdding: .day, value: -AnchorBaseline.windowDays, to: today)
        else { return outcome }
        // Only small candidate readings survive the next iteration. The day's
        // snapshots and all detector temporaries are released before another read.
        var candidates: [(day: Date, reading: AnchorReading?)] = []
        do {
            while day < today {
                try Task.checkCancellation()
                let candidate: (day: Date, reading: AnchorReading?)? = try autoreleasepool {
                    let points = try store.samples(day)
                    try Task.checkCancellation()
                    guard !points.isEmpty else { return nil }
                    return (day, AnchorDetector.detect(MetricsQualityFilter.filter(points), calendar: calendar))
                }
                if let candidate { candidates.append(candidate) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
                    return outcome
                }
                day = next
            }
            try Task.checkCancellation()
            guard store.canCommit() else { return outcome }
        } catch {
            BLEDiag.log("ANCHOR_BACKFILL read cancelled or failed; original anchors retained")
            return outcome
        }
        outcome.daysConsidered = candidates.count
        guard !candidates.isEmpty else {
            outcome.saved = true
            return outcome
        }
        // No mutations until every day's read succeeds. Today, out-of-window
        // anchors and days without samples remain untouched.
        do {
            let stored = try store.anchors()
            try Task.checkCancellation()
            guard store.canCommit() else { return outcome }
            let replayedDays = Set(candidates.map(\.day))
            var hadAnchor: Set<Date> = []
            for anchor in stored where replayedDays.contains(anchor.day) {
                hadAnchor.insert(anchor.day)
                store.delete(anchor)
            }
            for candidate in candidates {
                guard let reading = candidate.reading else {
                    if hadAnchor.contains(candidate.day) { outcome.anchorsDropped += 1 }
                    continue
                }
                let replacement = DailyAnchor(from: reading)
                replacement.day = candidate.day
                store.insert(replacement)
                outcome.anchorsWritten += 1
            }
            try Task.checkCancellation()
            guard store.canCommit() else { store.rollback(); return outcome }
            try store.save()
            outcome.saved = true
        } catch {
            store.rollback()
            BLEDiag.log("ANCHOR_BACKFILL commit cancelled or failed; original anchors retained")
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
        return SleepWindow(startedAt: start, endedAt: end, timezone: window.timezone, dayOverride: window.day)
    }
}
