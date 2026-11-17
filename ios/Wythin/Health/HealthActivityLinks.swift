import Foundation

/// Explicit, device-local associations. Only IDs are persisted; neither ActivityLog nor
/// its notes, legacy upload payload, or Health source payload is modified by a link.
struct HealthActivityLinks {
    struct Record: Identifiable {
        var id: UUID
        var startedAt: Date
        var endedAt: Date?
        var isExercise: Bool
        var isImported: Bool
        var subtype: String?
    }

    private let defaults: UserDefaults
    private static let key = "health.activityLinks.v1"
    private static let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func candidates(for workout: HealthWorkout, among records: [Record]) -> [Record] {
        records.filter { matches(workout, $0) }.sorted {
            let lhs = abs($0.startedAt.timeIntervalSince(workout.startedAt))
            let rhs = abs($1.startedAt.timeIntervalSince(workout.startedAt))
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
    }

    func linkedActivityID(for workoutID: UUID) -> UUID? {
        Self.lock.withLock {
            (defaults.dictionary(forKey: Self.key)?[workoutID.uuidString.lowercased()] as? String)
                .flatMap(UUID.init(uuidString:))
        }
    }

    @discardableResult func link(_ workout: HealthWorkout, to record: Record) -> Bool {
        guard Self.matches(workout, record) else { return false }
        Self.lock.withLock {
            var links = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
            links[workout.id.uuidString.lowercased()] = record.id.uuidString.lowercased()
            defaults.set(links, forKey: Self.key)
        }
        return true
    }

    func unlink(_ workoutID: UUID) {
        Self.lock.withLock {
            var links = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
            links.removeValue(forKey: workoutID.uuidString.lowercased())
            defaults.set(links, forKey: Self.key)
        }
    }

    func removeAll() { Self.lock.withLock { defaults.removeObject(forKey: Self.key) } }

    private static func matches(_ workout: HealthWorkout, _ record: Record) -> Bool {
        guard record.isExercise, !record.isImported, let endedAt = record.endedAt else { return false }
        let duration = workout.endedAt.timeIntervalSince(workout.startedAt)
        let manualDuration = endedAt.timeIntervalSince(record.startedAt)
        guard duration > 0, manualDuration > 0,
              abs(record.startedAt.timeIntervalSince(workout.startedAt)) <= 120,
              abs(duration - manualDuration) <= min(300, max(60, duration * 0.1)) else { return false }
        let overlap = min(workout.endedAt, endedAt).timeIntervalSince(max(workout.startedAt, record.startedAt))
        guard overlap >= 0.8 * max(duration, manualDuration) else { return false }
        // A known conflicting sport is not a candidate. Unspecified/custom labels remain
        // a suggestion requiring the user's confirmation, never an automatic merge.
        let compatibleCodes: [String: Set<UInt>] = [
            "easy run": [37], "tempo run": [37], "intervals": [37], "long run": [37], "trail run": [37],
            "nature walk": [52], "city walk": [52], "hiking": [24], "treadmill": [37, 52],
            "yoga": [57], "hiit": [63], "power lifting": [20, 50], "pilates": [66],
            "cycling": [13], "swimming": [46], "stretching": [33, 62, 80],
            "crossfit": [11, 20, 50, 63, 73], "boxing": [8, 65], "rowing": [35],
            "climbing": [9], "martial arts": [28, 65]
        ]
        guard let subtype = record.subtype?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let codes = compatibleCodes[subtype] else { return true }
        return codes.contains(workout.activityCode)
    }
}
