import XCTest
import SwiftData
import SwiftUI
@testable import Wythin

@MainActor
final class ForegroundPreparationTests: XCTestCase {
    func testMemoryPressureCancelsAndDefersRetryUntilARealForegroundTransition() async {
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        var canceled = false
        let entered = expectation(description: "preparation started")
        let drained = expectation(description: "canceled preparation drained")
        let retried = expectation(description: "preparation retried")
        let work = ForegroundPreparation {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { release = $0; entered.fulfill() }
                canceled = Task.isCancelled
                drained.fulfill()
            } else { retried.fulfill() }
        }
        work.setForeground(true)
        await fulfillment(of: [entered], timeout: 3)
        work.suspendUntilNextForeground()
        work.setForeground(true)
        release?.resume()
        await fulfillment(of: [drained], timeout: 3)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(canceled)
        XCTAssertEqual(calls, 1, "Draining a canceled read must not restart it under pressure")
        work.invalidate()
        work.setForeground(true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, 1, "Invalidation and duplicate phase delivery must not lift the pressure latch")
        work.setForeground(false)
        work.setForeground(true)
        await fulfillment(of: [retried], timeout: 3)
        XCTAssertEqual(calls, 2)
    }

    func testBackgroundLaunchDoesNotPrepareUIAndForegroundPreparesOnlyOnce() async {
        var calls = 0
        let prepared = expectation(description: "foreground prepared")
        let work = ForegroundPreparation {
            calls += 1
            prepared.fulfill()
        }
        work.setForeground(false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 0)
        work.setForeground(true)
        work.setForeground(true)
        await fulfillment(of: [prepared], timeout: 3)
        for _ in 0..<10 { await Task.yield() }
        work.setForeground(false)
        work.setForeground(true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1)
    }

    func testCancellationDrainsBeforeReentryAndCannotCompleteNewGeneration() async {
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        var cancellationSeen = false
        let entered = expectation(description: "first operation entered")
        let resumed = expectation(description: "reentered after drain")
        let work = ForegroundPreparation {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered.fulfill()
                }
                cancellationSeen = Task.isCancelled
            } else { resumed.fulfill() }
        }
        work.setForeground(true)
        await fulfillment(of: [entered], timeout: 3)
        work.setForeground(false)
        work.setForeground(true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1, "Do not overlap an uncancellable store read")
        release?.resume()
        await fulfillment(of: [resumed], timeout: 3)
        XCTAssertTrue(cancellationSeen)
        XCTAssertEqual(calls, 2)
    }

    func testInvalidationDefersRebuildUntilForeground() async {
        var calls = 0
        let initial = expectation(description: "initial")
        let rebuilt = expectation(description: "rebuilt")
        let work = ForegroundPreparation {
            calls += 1
            if calls == 1 { initial.fulfill() } else { rebuilt.fulfill() }
        }
        work.setForeground(true)
        await fulfillment(of: [initial], timeout: 3)
        for _ in 0..<10 { await Task.yield() }
        work.setForeground(false)
        work.invalidate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        work.setForeground(true)
        await fulfillment(of: [rebuilt], timeout: 3)
        XCTAssertEqual(calls, 2)
    }
}

final class AppStartupTests: XCTestCase {
    @MainActor
    func testOpenFailurePreservesOriginalStoreAndDoesNotReturnEmptyReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            try Data("original history \(suffix)".utf8).write(to: URL(fileURLWithPath: store.path + suffix))
        }
        let config = ModelConfiguration(schema: AppStoreBootstrap.schema, url: store, cloudKitDatabase: .none)
        let empty = try ModelContainer(for: AppStoreBootstrap.schema, configurations: [
            ModelConfiguration(schema: AppStoreBootstrap.schema, isStoredInMemoryOnly: true)])
        var attempts = 0
        XCTAssertThrowsError(try AppStoreBootstrap.open(configuration: config) { _ in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadNoPermission) }
            return empty
        }, "A failed open must not silently replace the user's history with a new empty store")
        for suffix in ["", "-wal", "-shm"] {
            let data = try? Data(contentsOf: URL(fileURLWithPath: store.path + suffix))
            XCTAssertEqual(data, Data("original history \(suffix)".utf8), "Keep every original file in place")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["default.store", "default.store-shm", "default.store-wal"])
    }
}

@MainActor
final class AppStartupLifecycleTests: XCTestCase {
    private func waitUntilIdle<T>(_ startup: AppStartup<T>) async {
        let deadline = Date().addingTimeInterval(10)
        while startup.isLoading && Date() < deadline { await Task.yield() }
        XCTAssertFalse(startup.isLoading, "Startup must finish or report a recoverable error")
    }

    func testUnavailableStoreHasAVisibleRecoveryScreen() throws {
        let renderer = ImageRenderer(content: StartupUnavailableView(retry: {}).frame(width: 390, height: 844))
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "startup-storage-recovery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFailedStartupRemainsRetryableWithoutViewAndSuccessfulValueIsRetained() async throws {
        var attempts = 0
        let startup = AppStartup<Int> {
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadNoPermission) }
            return 42
        }
        startup.start()
        await waitUntilIdle(startup)
        XCTAssertNil(startup.value)
        XCTAssertNotNil(startup.error)
        startup.start()
        await waitUntilIdle(startup)
        XCTAssertEqual(startup.value, 42)
        XCTAssertNil(startup.error)
        startup.start()
        await Task.yield()
        XCTAssertEqual(attempts, 2, "A successful environment must not be initialized again")
    }

    func testDuplicateStartsShareOneInitialization() async {
        var release: CheckedContinuation<Int, Never>?
        let startup = AppStartup<Int> {
            await withCheckedContinuation { release = $0 }
        }
        startup.start()
        while release == nil { await Task.yield() }
        startup.start()
        release?.resume(returning: 7)
        await waitUntilIdle(startup)
        XCTAssertEqual(startup.value, 7)
    }

    func testProtectedDataNotificationRetriesAnUnavailableStore() async {
        let center = NotificationCenter()
        var unlocked = false
        let startup = AppStartup<Int>(notifications: center) {
            guard unlocked else { throw CocoaError(.fileReadNoPermission) }
            return 9
        }
        startup.start()
        await waitUntilIdle(startup)
        XCTAssertNotNil(startup.error)
        unlocked = true
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        for _ in 0..<100 where startup.value == nil { await Task.yield() }
        XCTAssertEqual(startup.value, 9)
    }

    func testRealUnreadableStoreReportsFailureWithoutReplacingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        let sentinel = Data("original bytes".utf8)
        try sentinel.write(to: blocker)
        let config = ModelConfiguration(schema: AppStoreBootstrap.schema,
            url: blocker.appendingPathComponent("default.store"), cloudKitDatabase: .none)
        let startup = AppStartup<ModelContainer> { try await AppStoreBootstrap.load(configuration: config) }
        startup.start()
        await waitUntilIdle(startup)
        XCTAssertNil(startup.value)
        XCTAssertNotNil(startup.error)
        XCTAssertEqual(try Data(contentsOf: blocker), sentinel)
    }

    func testExistingDiskStoreOpensAsynchronouslyWithItsHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ModelConfiguration(schema: AppStoreBootstrap.schema,
            url: root.appendingPathComponent("default.store"), cloudKitDatabase: .none)
        let id = UUID()
        try autoreleasepool {
            let c = try AppStoreBootstrap.open(configuration: config)
            let entry = ActivityLog(activityType: "Exercise", startedAt: Date(timeIntervalSince1970: 1_000))
            entry.id = id
            c.mainContext.insert(entry)
            try c.mainContext.save()
        }
        let loaded = try await AppStoreBootstrap.load(configuration: config)
        let entries = try loaded.mainContext.fetch(FetchDescriptor<ActivityLog>())
        XCTAssertEqual(entries.map(\.id), [id])
    }
}


@MainActor
final class StartupReviewRegressionTests: XCTestCase {
    private func idle<T>(_ startup: AppStartup<T>) async {
        let deadline = Date().addingTimeInterval(3)
        while startup.isLoading && Date() < deadline { await Task.yield() }
        XCTAssertFalse(startup.isLoading)
    }

    func testBackgroundCallbacksBeforeAndAfterFailedOpenFinishExactlyOnce() async {
        let events = StartupBackgroundEvents()
        var completions = 0
        var routed: (() -> Void)?
        events.receive(completion: { completions += 1 }, route: { routed = $0 })
        let startup = AppStartup<Int>(backgroundEvents: events) { throw CocoaError(.fileReadNoPermission) }
        startup.start()
        await idle(startup)
        XCTAssertEqual(completions, 1)
        events.receive(completion: { completions += 1 }, route: { _ in XCTFail("No service exists after failed open") })
        XCTAssertEqual(completions, 2)
        routed?()
        routed?()
        XCTAssertEqual(completions, 2, "A delayed service callback must not complete the OS wake twice")
    }

    func testAllowanceStartsBeforeYieldAndEndsOnceOnSuccessOrFailure() async {
        for failing in [false, true] {
            var begun = 0, ended = 0
            let startup = AppStartup<Int>(backgroundEvents: StartupBackgroundEvents(), beginAllowance: { _ in
                begun += 1
                return UIBackgroundTaskIdentifier(rawValue: 31)
            }, endAllowance: { id in
                XCTAssertEqual(id.rawValue, 31); ended += 1
            }) {
                XCTAssertEqual(begun, 1)
                if failing { throw CocoaError(.fileReadNoPermission) }
                return 1
            }
            startup.start()
            XCTAssertEqual(begun, 1, "Acquire execution time before yielding startup")
            await idle(startup)
            XCTAssertEqual(ended, 1)
        }
    }

    func testAllowanceExpirationReleasesWakeWithoutDuplicatingInitialization() async {
        let events = StartupBackgroundEvents()
        var expire: (@MainActor @Sendable () -> Void)?
        var resume: CheckedContinuation<Int, Never>?
        var ended = 0, completed = 0, loads = 0
        let startup = AppStartup<Int>(backgroundEvents: events, beginAllowance: {
            expire = $0; return UIBackgroundTaskIdentifier(rawValue: 7)
        }, endAllowance: { _ in ended += 1 }) {
            loads += 1
            return await withCheckedContinuation { resume = $0 }
        }
        startup.start()
        while resume == nil { await Task.yield() }
        events.receive(completion: { completed += 1 }, route: { _ in })
        expire?()
        expire?()
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(completed, 1)
        startup.start()
        resume?.resume(returning: 9)
        await idle(startup)
        XCTAssertEqual(startup.value, 9)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(ended, 1)
    }

    func testUnlockDuringOpenRetriesOneFailedAttemptWithoutAnotherNotification() async {
        let center = NotificationCenter()
        var resume: CheckedContinuation<Void, Never>?
        var attempts = 0
        let startup = AppStartup<Int>(notifications: center, backgroundEvents: StartupBackgroundEvents()) {
            attempts += 1
            if attempts == 1 {
                await withCheckedContinuation { resume = $0 }
                throw CocoaError(.fileReadNoPermission)
            }
            return 12
        }
        startup.start()
        while resume == nil { await Task.yield() }
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        for _ in 0..<10 { await Task.yield() }
        resume?.resume()
        await idle(startup)
        XCTAssertEqual(startup.value, 12)
        XCTAssertEqual(attempts, 2)
    }

    func testSceneDeliveryDeduplicatesSameEnvironmentAndPhaseButDeliversInitialState() {
        let first = NSObject(), replacement = NSObject()
        var delivery = StartupSceneDelivery()
        XCTAssertTrue(delivery.shouldDeliver(.active, to: first))
        XCTAssertFalse(delivery.shouldDeliver(.active, to: first))
        XCTAssertTrue(delivery.shouldDeliver(.background, to: first))
        XCTAssertFalse(delivery.shouldDeliver(.background, to: first))
        XCTAssertTrue(delivery.shouldDeliver(.background, to: replacement))
        XCTAssertTrue(delivery.shouldDeliver(.active, to: replacement))
    }
}
