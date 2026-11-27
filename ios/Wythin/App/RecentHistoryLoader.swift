import Foundation
import SwiftData

/// One coalesced read, using value snapshots across the actor boundary.
/// Incoming live readings remain authoritative when a disk snapshot arrives.
@MainActor
final class RecentHistoryLoader {
    typealias Reader = @Sendable (Date, Int) throws -> [MetricsHistoryPoint]
    private let limit: Int
    private let read: Reader
    private let current: () -> [MetricsHistoryPoint]
    private let publish: ([MetricsHistoryPoint]) -> Void
    private var task: Task<Void, Never>?
    private var pendingAfter: Date?
    private var generation = 0
    private(set) var isLoading = false

    init(limit: Int = 43_200, read: @escaping Reader,
         current: @escaping () -> [MetricsHistoryPoint],
         publish: @escaping ([MetricsHistoryPoint]) -> Void) {
        self.limit = max(0, limit); self.read = read; self.current = current; self.publish = publish
    }

    deinit { task?.cancel() }

    func waitUntilIdle() async {
        while let task { await task.value }
    }

    func request(after: Date) {
        pendingAfter = min(pendingAfter ?? after, after)
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard task == nil, pendingAfter != nil else { return }
        isLoading = true
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.isLoading = false
                self.startIfNeeded()
            }
            while let after = self.pendingAfter, self.generation == generation, !Task.isCancelled {
                self.pendingAfter = nil
                let read = self.read, limit = self.limit
                let result = await Task.detached(priority: .utility) {
                    Result { try read(after, limit) }
                }.value
                guard self.generation == generation, !Task.isCancelled else { return }
                if case .success(let points) = result {
                    guard !points.isEmpty else { continue }
                    self.publish(Self.merged(fetched: points, current: self.current(), limit: limit))
                } else {
                    BLEDiag.log("HISTORY reload failed; retaining current readings")
                }
            }
        }
    }

    /// A prior store snapshot cannot reappear after a restore/invalidation.
    /// Keep ownership until its synchronous disk read drains, so a subsequent
    /// request cannot start a second full-day fetch alongside it.
    func invalidate() {
        generation += 1
        task?.cancel()
        pendingAfter = nil
    }

    nonisolated static func read(container: ModelContainer, after: Date, limit: Int) throws -> [MetricsHistoryPoint] {
        guard limit > 0 else { return [] }
        return try autoreleasepool {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<HRVSample>(
                predicate: #Predicate { $0.timestamp > after },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor).reversed().map { MetricsHistoryPoint(from: $0) }
        }
    }

    static func merged(fetched: [MetricsHistoryPoint], current: [MetricsHistoryPoint],
                       limit: Int) -> [MetricsHistoryPoint] {
        guard limit > 0 else { return [] }
        // Both inputs are normally chronological (disk fetch + live append).
        // Repair clock rollback defensively, without hashing or sorting normal
        // full-day histories on every foreground transition.
        func ordered(_ points: [MetricsHistoryPoint]) -> [MetricsHistoryPoint] {
            var previous = -Double.infinity
            for point in points {
                let time = point.timestamp.timeIntervalSince1970
                if !time.isFinite || time < previous {
                    return points.filter { $0.timestamp.timeIntervalSince1970.isFinite }
                        .sorted { $0.timestamp < $1.timestamp }
                }
                previous = time
            }
            return points
        }
        let disk = ordered(fetched), live = ordered(current)
        var i = disk.count - 1, j = live.count - 1
        var newest: [MetricsHistoryPoint] = []
        newest.reserveCapacity(min(limit, disk.count + live.count))
        while newest.count < limit && (i >= 0 || j >= 0) {
            let point: MetricsHistoryPoint
            if j >= 0 && (i < 0 || live[j].timestamp >= disk[i].timestamp) {
                point = live[j]; j -= 1
            } else {
                point = disk[i]; i -= 1
            }
            if newest.last?.timestamp != point.timestamp { newest.append(point) }
        }
        return newest.reversed()
    }
}
