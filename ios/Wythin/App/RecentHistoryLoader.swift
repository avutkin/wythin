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

    func request(after: Date) {
        pendingAfter = min(pendingAfter ?? after, after)
        guard task == nil else { return }
        isLoading = true
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation { self.task = nil; self.isLoading = false }
            }
            while let after = self.pendingAfter, self.generation == generation, !Task.isCancelled {
                self.pendingAfter = nil
                let read = self.read, limit = self.limit
                let result = await Task.detached(priority: .utility) {
                    Result { try read(after, limit) }
                }.value
                guard self.generation == generation, !Task.isCancelled else { return }
                if case .success(let points) = result {
                    self.publish(Self.merged(fetched: points, current: self.current(), limit: limit))
                } else {
                    BLEDiag.log("HISTORY reload failed; retaining current readings")
                }
            }
        }
    }

    /// A prior store snapshot cannot reappear after a restore/invalidation.
    func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
        pendingAfter = nil
        isLoading = false
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
        var byDate: [Date: MetricsHistoryPoint] = [:]
        for point in fetched + current where point.timestamp.timeIntervalSince1970.isFinite {
            byDate[point.timestamp] = point
        }
        return byDate.keys.sorted().suffix(limit).compactMap { byDate[$0] }
    }
}
