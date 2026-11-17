import Foundation
import SwiftData

/// Serialized background projection; Health snapshots never write into Polar sample tables.
@ModelActor actor HealthActivityProjector {
    func project(_ entries: [HealthEntry]) throws {
        let context = modelContext
        let imported = try context.fetch(FetchDescriptor<ActivityLog>()).filter(\.isHealthImported)
        let byExternal = Dictionary(imported.compactMap { row in row.externalWorkoutID.map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
        let present = Set(entries.filter { !$0.deleted }.map { $0.workout.id.uuidString })
        for row in imported where !present.contains(row.externalWorkoutID ?? "") { context.delete(row) }
        for entry in entries where !entry.deleted {
            let workout = entry.workout, key = entry.workout.id.uuidString
            let existing = byExternal[key]
            let row = existing ?? ActivityLog(activityType: ActivityType.exercise.rawValue, activitySubtype: workout.activityName,
                                              startedAt: workout.startedAt, endedAt: workout.endedAt, isManual: true, timezone: workout.timezone)
            if existing == nil { row.id = entry.activityId; row.origin = "apple_health"; row.externalWorkoutID = key; context.insert(row) }
            row.id = entry.activityId
            let changedWindow = row.startedAt != workout.startedAt || row.endedAt != workout.endedAt
            row.startedAt = workout.startedAt; row.endedAt = workout.endedAt
            row.timezone = workout.timezone
            row.activitySubtype = entry.title ?? workout.activityName; row.notes = entry.notes
            // Existing fields still describe real Polar data only. Health analysis is a separate projection.
            if existing == nil || changedWindow {
                row.computeHRVWindows(context: context); row.computeExerciseResponse(context: context)
            }
        }
        try context.save()
    }
}
