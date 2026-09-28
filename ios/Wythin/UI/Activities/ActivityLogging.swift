import Foundation
import SwiftData

// MARK: - ActivityLogging
//
// Single source of truth for creating/finishing ActivityLog records, shared by
// the Activities tab and the Practices hub. Behaviour matches the original
// ActivitiesView.beginActivity / endActivity / logPast exactly.

/// Seed values for prefilling the "Log it" sheet from a Practice.
struct ActivityPrefill {
    let type:         ActivityType
    let subtype:      String?
    let durationMins: Double?
}

enum ActivityLogging {

    /// Start a live activity (isManual = false, endedAt = nil → active).
    ///
    /// At most one activity records at a time, so anything already running is
    /// closed first. Enforced here rather than in the UI because the Activities
    /// tab is not the only caller — the nudge "walk" action starts an activity
    /// too, and when it did so on top of a running one the older entry ended up
    /// unreachable: never stamped with an end, hidden from the history list
    /// (which filters active entries out) and absent from the banner (which
    /// showed only the newest).
    @discardableResult
    static func begin(type: ActivityType, subtype: String?, customName: String?,
                      targetMinutes: Int?, context: ModelContext,
                      client: InsightAPIClient? = nil) -> ActivityLog {
        finishAnyActive(context: context, client: client)

        let entry = ActivityLog(
            activityType:    type.rawValue,
            activitySubtype: subtype,
            customName:      customName,
            startedAt:       .now,
            isManual:        false,
            targetMinutes:   targetMinutes
        )
        context.insert(entry)
        try? context.save()
        // Hopped to the main actor rather than making the whole logging path
        // isolated: ActivityKit is main-actor bound, the callers are not, and
        // the lock screen is not on the critical path of saving the entry.
        let name = entry.displayName, icon = type.icon, began = entry.startedAt
        Task { @MainActor in
            LiveSessionController.shared.start(name: name, icon: icon,
                                               startedAt: began,
                                               targetMinutes: targetMinutes)
        }
        return entry
    }

    /// Close every activity still recording. Also the repair path for databases
    /// written before the single-active invariant existed, which can already
    /// hold several.
    static func finishAnyActive(context: ModelContext, client: InsightAPIClient?) {
        let running = ((try? context.fetch(FetchDescriptor<ActivityLog>())) ?? []).filter(\.isActive)
        for entry in running {
            end(entry, context: context, client: client)
        }
    }

    /// Every unfinished activity, oldest first — so a stale orphan surfaces above
    /// whatever is running now instead of behind it.
    static func activeEntries(in entries: [ActivityLog]) -> [ActivityLog] {
        entries.filter(\.isActive).sorted { $0.startedAt < $1.startedAt }
    }

    /// The entries whose numbers are still moving: every one recording now,
    /// and every one that stopped inside its after-window. The Activities list
    /// recomputes these on each strap tick; everything older is settled and
    /// left alone.
    static func liveRefreshCandidates(in entries: [ActivityLog],
                                      now: Date = .now) -> [ActivityLog] {
        entries.filter { ActivityLivePhase.of(startedAt: $0.startedAt,
                                              endedAt: $0.endedAt,
                                              now: now,
                                              isManual: $0.isManual) != nil }
    }

    /// Recompute every live candidate from the samples in store.
    static func refreshLive(entries: [ActivityLog], context: ModelContext, now: Date = .now) {
        let live = liveRefreshCandidates(in: entries, now: now)
        guard !live.isEmpty else { return }
        for entry in live { entry.refreshLive(context: context, now: now) }
    }

    /// Finish a live activity: stamp endedAt, fill HRV windows, save, generate insight.
    ///
    /// `client` is optional so the repair path above can run without one; a nil
    /// client skips insight generation but still closes the entry properly.
    static func end(_ entry: ActivityLog, context: ModelContext, client: InsightAPIClient?) {
        entry.endedAt = .now
        Task { @MainActor in LiveSessionController.shared.end() }
        entry.computeHRVWindows(context: context)
        entry.computeExerciseResponse(context: context)
        try? context.save()
        guard let client else { return }
        Task { await InsightGenerator(client: client).generate(for: entry, context: context) }
    }

    /// Log a past/retrospective activity (isManual = true) with explicit window.
    static func logPast(type: ActivityType, subtype: String?, customName: String?,
                        start: Date, end: Date,
                        context: ModelContext, client: InsightAPIClient) {
        let entry = ActivityLog(
            activityType:    type.rawValue,
            activitySubtype: subtype,
            customName:      customName,
            startedAt:       start,
            endedAt:         end,
            isManual:        true
        )
        context.insert(entry)
        entry.computeHRVWindows(context: context)
        entry.computeExerciseResponse(context: context)
        try? context.save()
        Task { await InsightGenerator(client: client).generate(for: entry, context: context) }
    }
}

// MARK: - ActivityLivePhase

/// Where a session is in the arc the app measures: running, or stopped and
/// still inside the ten minutes its recovery is read over. Nil once that is
/// over — the row is then an ordinary finished entry.
///
/// The five minutes before the start are part of the same arc, but they are
/// already in the past when the session begins; the row names them rather
/// than counting them.
enum ActivityLivePhase: Equatable {
    /// Seconds since the session began.
    case live(elapsed: TimeInterval)
    /// Seconds of after-window still to come.
    case settling(remaining: TimeInterval)

    static func of(startedAt: Date, endedAt: Date?, now: Date = .now,
                   isManual: Bool = false) -> ActivityLivePhase? {
        guard !isManual else { return nil }
        guard let end = endedAt else {
            return .live(elapsed: max(0, now.timeIntervalSince(startedAt)))
        }
        let remaining = ActivityLog.afterWindowSeconds - now.timeIntervalSince(end)
        return remaining > 0 ? .settling(remaining: remaining) : nil
    }
}
