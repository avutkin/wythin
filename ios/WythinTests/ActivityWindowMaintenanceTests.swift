import XCTest
import SwiftData
@testable import Wythin

@MainActor
final class ActivityWindowMaintenanceTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([ActivityLog.self, HRVSample.self, HRVSession.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    func testSettledActivityWithoutPolarStressDoesNotReenterLaunchBackfill() {
        let now = Date()
        let row = ActivityLog(activityType: "Exercise", startedAt: now.addingTimeInterval(-7200),
                              endedAt: now.addingTimeInterval(-3600))
        row.origin = "apple_health"
        row.settledAt = now.addingTimeInterval(-1800)
        XCTAssertNil(row.duringStress)
        XCTAssertFalse(row.needsWindowRefresh(now: now), "Nil stress is valid missing Polar data, not an unfinished calculation")
    }

    private final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    func testMaintenanceLeavesMainActorResponsiveAndCoalescesForegroundRequests() async throws {
        let gate = Gate()
        let worker = ActivityWindowMaintenance(container: try container()) { _ in
            XCTAssertFalse(Thread.isMainThread, "The symbolicated watchdog was a main-thread window fetch")
            if gate.next() == 1 {
                gate.entered.signal()
                XCTAssertEqual(gate.release.wait(timeout: .now() + 1), .success,
                               "Main actor must be able to release a running maintenance job")
            }
        }
        let first = worker.request()
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(entered)
        var requests: [Task<Void, Never>] = []
        for _ in 0..<20 { requests.append(worker.request()) }
        gate.release.signal()
        await first.value
        for task in requests { await task.value }
        XCTAssertEqual(gate.count, 2, "Concurrent requests require at most one follow-up pass")
    }

    func testFailedMaintenanceCanBeRetried() async throws {
        let gate = Gate()
        let worker = ActivityWindowMaintenance(container: try container()) { _ in
            if gate.next() == 1 { throw CocoaError(.fileReadNoPermission) }
        }
        await worker.request().value
        await worker.request().value
        XCTAssertEqual(gate.count, 2)
    }

    func testLargeHistoryRepairPersistsResultsAndLeavesSettledEmptyActivitiesAlone() async throws {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "activityBackfillVersion")
        defaults.set(ActivityLog.currentBackfillVersion, forKey: "activityBackfillVersion")
        defer {
            if let old { defaults.set(old, forKey: "activityBackfillVersion") }
            else { defaults.removeObject(forKey: "activityBackfillVersion") }
        }
        let store = try container()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let settled = start.addingTimeInterval(-86400)
        let context = ModelContext(store)
        for i in 0..<20_000 {
            let point = HRVSample(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30), meanBPM: 65)
            point.sdnn = 40; point.rmssd = 30; point.signalQuality = 0.95
            context.insert(point)
        }
        for i in 0..<100 {
            let before = start.addingTimeInterval(-Double(i + 10) * 86400)
            let row = ActivityLog(activityType: "Exercise", startedAt: before,
                                  endedAt: before.addingTimeInterval(1800))
            row.origin = "apple_health"; row.settledAt = settled
            context.insert(row)
        }
        let pending = ActivityLog(activityType: "Exercise", startedAt: start,
                                  endedAt: start.addingTimeInterval(3600))
        let pendingID = pending.id
        context.insert(pending)
        try context.save()
        let worker = ActivityWindowMaintenance(container: store)
        await worker.request().value
        let read = ModelContext(store)
        let rows = try read.fetch(FetchDescriptor<ActivityLog>())
        XCTAssertEqual(rows.count, 101)
        let repaired = try XCTUnwrap(rows.first { $0.id == pendingID })
        XCTAssertNotNil(repaired.settledAt)
        XCTAssertEqual(repaired.duringHR, 65)
        XCTAssertFalse(repaired.needsWindowRefresh())
        XCTAssertTrue(rows.filter { $0.id != pendingID }.allSatisfy { $0.settledAt == settled },
                      "Already settled empty windows must not be fetched/recomputed each launch")
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<HRVSample>()), 20_000)
    }
}
