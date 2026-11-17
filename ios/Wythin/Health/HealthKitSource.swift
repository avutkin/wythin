import Foundation
import HealthKit

/// Read-only HealthKit boundary. Mutable observer state is protected by observationLock;
/// each one-shot query and series collector independently serialize their callbacks.
final class HealthKitSource: HealthSource, @unchecked Sendable {
    private let store: HKHealthStore
    private let observationLock = NSLock()
    private var observers: [HKObserverQuery] = []
    private var observationGeneration: UUID?
    private static let workoutLimit = 200
    private static let sampleLimit = 500

    init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: [HKSampleType] {
        [HKObjectType.workoutType()] + HealthMetric.allCases.compactMap(HealthWorkoutMapping.quantityType)
    }

    func requestAuthorization() async throws {
        guard available else { throw HealthKitSourceError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: Set(readTypes)) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: HealthKitSourceError.authorizationRequestFailed) }
            }
        }
        // A completed request does not prove read permission; HealthKit deliberately hides denial.
    }

    func workoutPage(anchor: Data?) async throws -> HealthWorkoutPage {
        let page = try await anchoredPage(type: HKObjectType.workoutType(), predicate: nil,
            anchor: Self.decodeAnchor(anchor), limit: Self.workoutLimit)
        let workouts = try page.objects.map { raw -> HealthWorkout in
            guard let workout = raw as? HKWorkout else { throw HealthKitSourceError.unexpectedSampleType }
            return HealthWorkoutMapping.workout(workout)
        }
        return HealthWorkoutPage(workouts: workouts, deletedIDs: page.deletedIDs,
            nextAnchor: try Self.encodeAnchor(page.anchor), hasMore: page.hasMore)
    }

    func samplePage(metric: HealthMetric, anchor: Data?) async throws -> HealthSamplePage {
        guard let type = HealthWorkoutMapping.quantityType(metric) else {
            return HealthSamplePage(samples: [], deletedIDs: [], nextAnchor: anchor, hasMore: false)
        }
        let page = try await anchoredPage(type: type, predicate: nil,
            anchor: Self.decodeAnchor(anchor), limit: Self.sampleLimit)
        let samples = try await expand(page.objects, metric: metric)
        return HealthSamplePage(samples: samples, deletedIDs: page.deletedIDs,
            nextAnchor: try Self.encodeAnchor(page.anchor), hasMore: page.hasMore)
    }

    func samples(metric: HealthMetric, start: Date, end: Date) async throws -> [HealthSample] {
        guard end >= start else { throw HealthKitSourceError.invalidInterval }
        guard let type = HealthWorkoutMapping.quantityType(metric) else { return [] }
        // Default options find interval overlaps. Do not restrict to samples linked to a
        // workout: doing so drops the before/after context and separately recorded readings.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        var anchor: HKQueryAnchor?
        var values: [UUID: HealthSample] = [:]
        while true {
            try Task.checkCancellation()
            let page = try await anchoredPage(type: type, predicate: predicate, anchor: anchor, limit: Self.sampleLimit)
            // Enumerate the complete parent before filtering, so child indices remain identical
            // between context reads and unfiltered incremental reads.
            for sample in try await expand(page.objects, metric: metric)
            where sample.startedAt <= end && sample.endedAt >= start {
                values[sample.id] = sample
            }
            if !page.deletedIDs.isEmpty {
                let deleted = Set(page.deletedIDs)
                values = values.filter { !deleted.contains($0.value.parent) }
            }
            if !page.hasMore { break }
            anchor = page.anchor
        }
        return values.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func startObserving(onChange: @escaping @Sendable () async -> Void) {
        guard available else { return }
        observationLock.lock()
        defer { observationLock.unlock() }
        guard observers.isEmpty else { return }
        let generation = UUID()
        observationGeneration = generation
        for type in readTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                let delivery = HealthObserverCompletion(completion)
                guard error == nil, self?.isObserving(generation) == true else {
                    delivery.finish()
                    return
                }
                Task {
                    defer { delivery.finish() }
                    guard self?.isObserving(generation) == true else { return }
                    await onChange()
                }
            }
            observers.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { [weak self] success, _ in
                guard success else { return } // Foreground anchored reads remain available.
                self?.disableLateBackgroundDeliveryIfStopped(type)
            }
        }
    }

    func stopObserving() {
        observationLock.lock()
        defer { observationLock.unlock() }
        observationGeneration = nil
        for query in observers { store.stop(query) }
        observers.removeAll()
        for type in readTypes { store.disableBackgroundDelivery(for: type) { _, _ in } }
    }

    private func isObserving(_ generation: UUID) -> Bool {
        observationLock.lock()
        defer { observationLock.unlock() }
        return observationGeneration == generation
    }

    private func disableLateBackgroundDeliveryIfStopped(_ type: HKSampleType) {
        observationLock.lock()
        defer { observationLock.unlock() }
        if observationGeneration == nil { store.disableBackgroundDelivery(for: type) { _, _ in } }
    }

    private func anchoredPage(type: HKSampleType, predicate: NSPredicate?, anchor: HKQueryAnchor?,
                              limit: Int) async throws -> HealthAnchoredPage {
        guard available else { throw HealthKitSourceError.unavailable }
        let operation = HealthQueryOperation<HealthAnchoredPage>(store: store)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: limit) {
                    _, objects, deletions, nextAnchor, error in
                    if let error { operation.finish(.failure(error)); return }
                    guard let nextAnchor else {
                        operation.finish(.failure(HealthKitSourceError.missingAnchor)); return
                    }
                    operation.finish(.success(HealthAnchoredPage(objects: objects ?? [],
                        deletedIDs: (deletions ?? []).map(\.uuid), anchor: nextAnchor, limit: limit)))
                }
                operation.start(query, continuation: continuation)
            }
        } onCancel: {
            operation.finish(.failure(CancellationError()))
        }
    }

    private func expand(_ objects: [HKSample], metric: HealthMetric) async throws -> [HealthSample] {
        var result: [HealthSample] = []
        for object in objects {
            try Task.checkCancellation()
            guard let parent = object as? HKQuantitySample else { throw HealthKitSourceError.unexpectedSampleType }
            if parent.count > 1 {
                result.append(contentsOf: try await series(parent: parent, metric: metric))
            } else {
                result.append(HealthWorkoutMapping.sample(parent, metric: metric))
            }
        }
        return result
    }

    private func series(parent: HKQuantitySample, metric: HealthMetric) async throws -> [HealthSample] {
        let operation = HealthQueryOperation<[HealthSample]>(store: store)
        let collector = HealthSeriesCollector(parent: parent, metric: metric)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKQuantitySeriesSampleQuery(quantityType: parent.quantityType,
                    predicate: HKQuery.predicateForObject(with: parent.uuid)) { _, quantity, interval, _, done, error in
                    if let result = collector.receive(quantity: quantity, interval: interval, done: done, error: error) {
                        operation.finish(result)
                    }
                }
                query.orderByQuantitySampleStartDate = true
                operation.start(query, continuation: continuation)
            }
        } onCancel: {
            operation.finish(.failure(CancellationError()))
        }
    }

    static func decodeAnchor(_ data: Data?) throws -> HKQueryAnchor? {
        guard let data else { return nil }
        guard let anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) else {
            throw HealthKitSourceError.invalidAnchor
        }
        return anchor
    }

    static func encodeAnchor(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }
}

enum HealthKitSourceError: Error {
    case unavailable, authorizationRequestFailed, invalidInterval, invalidAnchor, missingAnchor, unexpectedSampleType
    case incompleteSeries
}

struct HealthAnchoredPage: Sendable {
    var objects: [HKSample]
    var deletedIDs: [UUID]
    var anchor: HKQueryAnchor
    var limit: Int
    // HK's limit counts additions AND deletions, never expanded children.
    var hasMore: Bool { objects.count + deletedIDs.count >= limit }
}

/// Completion or cancellation can arrive before registration, or concurrently. The lock
/// guarantees one resume and prevents a cancelled query from being executed afterward.
private final class HealthQueryOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HKHealthStore
    private var query: HKQuery?
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    init(store: HKHealthStore) { self.store = store }

    func start(_ query: HKQuery, continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.query = query
        self.continuation = continuation
        store.execute(query)
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let query = self.query
        let continuation = self.continuation
        self.query = nil
        self.continuation = nil
        lock.unlock()
        if let query { store.stop(query) }
        continuation?.resume(with: result)
    }
}

final class HealthSeriesCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: HKQuantitySample
    private let metric: HealthMetric
    private var values: [HealthSample] = []
    private var finished = false

    init(parent: HKQuantitySample, metric: HealthMetric) { self.parent = parent; self.metric = metric }

    func receive(quantity: HKQuantity?, interval: DateInterval?, done: Bool,
                 error: Error?) -> Result<[HealthSample], Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        if let error { finished = true; values.removeAll(); return .failure(error) }
        if let quantity, let interval {
            values.append(HealthWorkoutMapping.seriesPoint(parent: parent, metric: metric,
                index: values.count, quantity: quantity, interval: interval))
        }
        guard done else { return nil }
        finished = true
        guard values.count == parent.count else { values.removeAll(); return .failure(HealthKitSourceError.incompleteSeries) }
        return .success(values)
    }
}

/// HKObserverQuery's completion block isn't annotated Sendable by the SDK. Ownership is
/// transferred to this synchronized box before the async handler is launched.
final class HealthObserverCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func finish() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
    }
}
