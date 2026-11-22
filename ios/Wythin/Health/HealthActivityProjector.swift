import Foundation
import SwiftData

/// Metadata projection owns a serial background queue and creates its context there.
/// No Polar history scans or derived calculations belong in this import transaction.
final class HealthActivityProjector: @unchecked Sendable {
    private let container: ModelContainer
    private let queue = DispatchQueue(label: "wythin.health.activity-projection", qos: .utility)

    init(modelContainer: ModelContainer) { container = modelContainer }

    // Enqueue synchronously on the caller's main actor to preserve snapshot
    // ordering. All persistence still runs on the explicit background queue.
    @MainActor @discardableResult
    func project(_ entries: [HealthEntry]) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try autoreleasepool { try persist(entries) } })
            }
        }
    }

    private func persist(_ entries: [HealthEntry]) throws -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var needsRepair = false
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
                row.settledAt = nil
                // Nil stress also makes an old changed interval eligible beyond
                // the normal after-window retry horizon.
                row.duringStress = nil
                needsRepair = true
            }
        }
        try context.save()
        return needsRepair
    }
}
