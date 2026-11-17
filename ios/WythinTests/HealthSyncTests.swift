import XCTest
@testable import Wythin

private actor HealthReadGate {
    private var opened = false
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var entering: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; entering?.resume(); entering = nil
        if !opened { await withCheckedContinuation { waiting = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entering = $0 } }
    }
    func release() { opened = true; waiting?.resume(); waiting = nil }
}

private final class HealthFakeSource: HealthSource, @unchecked Sendable {
    let available = true
    private let lock = NSLock()
    private var reads = 0
    private var authorizations = 0
    let pages: [[HealthWorkout]]
    let gate: HealthReadGate?
    init(pages: [[HealthWorkout]], gate: HealthReadGate? = nil) { self.pages = pages; self.gate = gate }
    var readCount: Int { lock.withLock { reads } }
    var authorizationCount: Int { lock.withLock { authorizations } }
    func requestAuthorization() async throws { lock.withLock { authorizations += 1 } }
    func workoutPage(anchor: Data?) async throws -> HealthWorkoutPage {
        let index = lock.withLock { let n = reads; reads += 1; return n }
        if let gate { await gate.wait() }
        return HealthWorkoutPage(workouts: index < pages.count ? pages[index] : [], deletedIDs: [], nextAnchor: Data([UInt8(index)]), hasMore: false)
    }
    func samplePage(metric: HealthMetric, anchor: Data?) async throws -> HealthSamplePage { HealthSamplePage(samples: [], deletedIDs: [], nextAnchor: nil, hasMore: false) }
    func samples(metric: HealthMetric, start: Date, end: Date) async throws -> [HealthSample] { [] }
    func startObserving(onChange: @escaping @Sendable () async -> Void) {}
    func stopObserving() {}
}

final class HealthSyncTests: XCTestCase {
    private func workout() -> HealthWorkout {
        HealthWorkout(id: UUID(), activityCode: 37, activityName: "Running", startedAt: Date(timeIntervalSince1970: 10000), endedAt: Date(timeIntervalSince1970: 10600), activeDurationSeconds: 600, source: HealthSourceInfo(bundleIdentifier: "test", name: "Watch"))
    }
    @MainActor func testAuthorizationIsExplicitAndDisconnectStopsReads() async throws {
        let old = UserDefaults.standard.object(forKey: "health.integrationEnabled")
        defer { UserDefaults.standard.set(old, forKey: "health.integrationEnabled") }
        let repo = try HealthRepository(inMemory: true), source = HealthFakeSource(pages: [[workout()]])
        let service = HealthSyncCoordinator(source: source, repository: repo)
        await service.synchronize()
        XCTAssertEqual(source.authorizationCount, 0); XCTAssertEqual(source.readCount, 0)
        await service.connect()
        XCTAssertEqual(source.authorizationCount, 1); XCTAssertEqual(service.entries.count, 1)
        XCTAssertFalse(service.cloudEnabled)
        await service.disconnect(); let reads = source.readCount
        await service.synchronize()
        XCTAssertEqual(source.readCount, reads)
    }
    @MainActor func testOverlappingObserverWaitsForAnotherDeltaPass() async throws {
        let repo = try HealthRepository(inMemory: true), gate = HealthReadGate()
        try await repo.setEnabled(true)
        let source = HealthFakeSource(pages: [[workout()], [workout()]], gate: gate)
        let service = HealthSyncCoordinator(source: source, repository: repo)
        let first = Task { await service.synchronize(importOnly: true) }
        await gate.waitUntilEntered()
        let second = Task { await service.synchronize(importOnly: true) }
        await Task.yield()
        await gate.release()
        await first.value; await second.value
        XCTAssertGreaterThanOrEqual(source.readCount, 2)
        let entries = try await repo.entries()
        XCTAssertEqual(entries.filter { !$0.deleted }.count, 2)
    }
}
