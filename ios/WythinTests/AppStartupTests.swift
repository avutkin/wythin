import XCTest
import SwiftData
import SwiftUI
@testable import Wythin

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
