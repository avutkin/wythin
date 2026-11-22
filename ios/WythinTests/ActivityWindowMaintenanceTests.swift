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

    func testHealthProjectionWaitsForOldWriterAndAutomaticallyRepairsNewInterval() async throws {
        let store = try container()
        let ctx = ModelContext(store)
        let start = Date(timeIntervalSince1970: 10000)
        var workout = HealthWorkout(id: UUID(), activityCode: 37, activityName: "Running",
            startedAt: start, endedAt: start.addingTimeInterval(600), activeDurationSeconds: 600,
            source: HealthSourceInfo(bundleIdentifier: "test", name: "Watch"), timezone: "Asia/Dubai")
        let id = UUID()
        let row = ActivityLog(activityType: "Exercise", startedAt: start, endedAt: workout.endedAt)
        row.id = id; row.origin = "apple_health"; row.externalWorkoutID = workout.id.uuidString
        ctx.insert(row)
        let point = HRVSample(anchorTestTimestamp: start.addingTimeInterval(3700), meanBPM: 90)
        point.sdnn = 40; point.rmssd = 30; point.signalQuality = 0.95
        ctx.insert(point); try ctx.save()
        let gate = Gate()
        let worker = ActivityWindowMaintenance(container: store) { container in
            XCTAssertFalse(Thread.isMainThread)
            let context = ModelContext(container)
            if gate.next() == 1 {
                let old = try XCTUnwrap(try context.fetch(FetchDescriptor<ActivityLog>()).first)
                gate.entered.signal()
                _ = gate.release.wait(timeout: .now() + 3)
                old.duringHR = 60; old.duringStress = 30; old.settledAt = Date()
                try context.save()
            } else {
                ActivityLog.backfillMissingWindows(context: context)
            }
        }
        let running = worker.request()
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(entered)
        workout.startedAt = start.addingTimeInterval(3600)
        workout.endedAt = start.addingTimeInterval(4200)
        var projected = false
        let importing = Task {
            try await worker.projectHealthActivities([HealthEntry(workout: workout, activityId: id)])
            projected = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(projected)
        gate.release.signal()
        try await importing.value; await running.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var repaired: ActivityLog?
        repeat {
            await Task.yield()
            repaired = try ModelContext(store).fetch(FetchDescriptor<ActivityLog>()).first
            if repaired?.duringHR == 90, repaired?.settledAt != nil { break }
        } while ContinuousClock.now < deadline
        XCTAssertEqual(repaired?.startedAt, start.addingTimeInterval(3600))
        XCTAssertEqual(repaired?.duringHR, 90, "Projection must schedule repair without another foreground event")
        XCTAssertNotNil(repaired?.settledAt)
        XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<HRVSample>()), 1)
    }

    func testNewerHealthDeletionSupersedesSnapshotWaitingForMaintenance() async throws {
        for _ in 0..<16 {
            let store = try container(), gate = Gate()
            let workout = HealthWorkout(id: UUID(), activityCode: 37, activityName: "Running",
                startedAt: Date(timeIntervalSince1970: 10000), endedAt: Date(timeIntervalSince1970: 10600),
                activeDurationSeconds: 600, source: HealthSourceInfo(bundleIdentifier: "test", name: "Watch"), timezone: "UTC")
            let entry = HealthEntry(workout: workout, activityId: UUID())
            let worker = ActivityWindowMaintenance(container: store) { _ in
                if gate.next() == 1 {
                    gate.entered.signal()
                    _ = gate.release.wait(timeout: .now() + 3)
                }
            }
            let running = worker.request()
            let entered = await Task.detached { gate.entered.wait(timeout: .now() + 3) == .success }.value
            XCTAssertTrue(entered)
            let stale = Task { try await worker.projectHealthActivities([entry]) }
            for _ in 0..<20 { await Task.yield() }
            let deletion = Task { try await worker.projectHealthActivities([]) }
            for _ in 0..<20 { await Task.yield() }
            gate.release.signal()
            try await stale.value; try await deletion.value; await running.value
            XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<ActivityLog>()), 0,
                           "An older waiting snapshot must never resurrect a newly deleted imported workout")
        }
    }

    func testFailedMigrationSliceDoesNotAdvanceCursorAndRetryCompletesRemainingRows() throws {
        let defaults = UserDefaults.standard
        let keys = ["activityBackfillVersion", "activityBackfillCursor"]
        let old = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, old) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        } }
        defaults.set(0, forKey: keys[0]); defaults.removeObject(forKey: keys[1])
        let store = try container()
        // Use one real persisted store for both the failing writer and fresh readers.
        let writer = ModelContext(store); writer.autosaveEnabled = false
        let original = Date(timeIntervalSince1970: 500)
        for i in 0..<13 {
            let start = Date(timeIntervalSince1970: 1000 + Double(i) * 3600)
            let row = ActivityLog(activityType: "Exercise", startedAt: start, endedAt: start.addingTimeInterval(600))
            row.settledAt = original
            writer.insert(row)
        }
        try writer.save()
        var saves = 0
        ActivityLog.migrate(context: writer) { ctx in
            saves += 1
            if saves == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            try ctx.save()
        }
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(defaults.integer(forKey: keys[0]), 0)
        XCTAssertEqual(defaults.object(forKey: keys[1]) as? Date, Date(timeIntervalSince1970: 1000 + 5 * 3600))
        let read = ModelContext(store)
        let partial = try read.fetch(FetchDescriptor<ActivityLog>())
        XCTAssertEqual(partial.filter { $0.settledAt == original }.count, 7)
        writer.rollback()
        ActivityLog.migrate(context: ModelContext(store))
        XCTAssertEqual(defaults.integer(forKey: keys[0]), ActivityLog.currentBackfillVersion)
        XCTAssertNil(defaults.object(forKey: keys[1]))
        let complete = try ModelContext(store).fetch(FetchDescriptor<ActivityLog>())
        XCTAssertTrue(complete.allSatisfy { $0.settledAt != original })
    }

    func testEditWaitsForOldWindowWriterThenKeepsEditedIntervalAndMetrics() async throws {
        let store = try container()
        let writer = ModelContext(store)
        let start = Date(timeIntervalSince1970: 1000)
        let row = ActivityLog(activityType: "Exercise", startedAt: start, endedAt: start.addingTimeInterval(600))
        writer.insert(row); try writer.save()
        let id = row.id, gate = Gate()
        let worker = ActivityWindowMaintenance(container: store) { container in
            let ctx = ModelContext(container)
            let entry = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ActivityLog>()).first { $0.id == id })
            let oldStart = entry.startedAt
            gate.entered.signal()
            _ = gate.release.wait(timeout: .now() + 3)
            entry.duringHR = oldStart == start ? 60 : 90
            entry.settledAt = Date()
            try ctx.save()
        }
        let pending = worker.request()
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(entered)
        var edited = false
        let editing = Task {
            await worker.performEdit {
                row.startedAt = start.addingTimeInterval(3600)
                row.endedAt = start.addingTimeInterval(4200)
                row.duringHR = 90
                try! writer.save()
                edited = true
            }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(edited, "A stale writer must finish before an edit changes its input window")
        gate.release.signal()
        await editing.value; await pending.value
        let saved = try XCTUnwrap(try ModelContext(store).fetch(FetchDescriptor<ActivityLog>()).first)
        XCTAssertEqual(saved.startedAt, start.addingTimeInterval(3600))
        XCTAssertEqual(saved.endedAt, start.addingTimeInterval(4200))
        XCTAssertEqual(saved.duringHR, 90)
    }

}
