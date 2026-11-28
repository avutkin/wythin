import XCTest
import SwiftData
@testable import Wythin

@MainActor
final class RecentHistoryLoaderTests: XCTestCase {
    func testDailyReaderTraversesBatchesWithoutDroppingEqualTimestampsAndRefusesTruncation() throws {
        let container = try ModelContainer(for: AppStoreBootstrap.schema, configurations: [
            ModelConfiguration(schema: AppStoreBootstrap.schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 10_000)
        for _ in 0..<2_005 { context.insert(HRVSample(anchorTestTimestamp: start, meanBPM: 60)) }
        try context.save()
        let points = try HistoricalDayReader.read(container: container, from: start,
            until: start.addingTimeInterval(86_400), limit: 2_005)
        XCTAssertEqual(points.count, 2_005, "A batch boundary must not lose tied timestamps")
        XCTAssertThrowsError(try HistoricalDayReader.read(container: container, from: start,
            until: start.addingTimeInterval(86_400), limit: 2_004)) { error in
            guard case HistoricalDayReader.ReadError.tooManySamples = error else {
                return XCTFail("Expected explicit oversized-day failure, got \(error)")
            }
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRVSample>()), 2_005)
    }

    func testDailyReaderKeepsLastHourOfDSTDayAndExcludesNextMidnight() throws {
        let container = try ModelContainer(for: AppStoreBootstrap.schema, configurations: [
            ModelConfiguration(schema: AppStoreBootstrap.schema, isStoredInMemoryOnly: true)])
        let parse = ISO8601DateFormatter()
        // New York's 2026 fall-back day spans 25 hours.
        let start = try XCTUnwrap(parse.date(from: "2026-11-01T04:00:00Z"))
        let lastHour = try XCTUnwrap(parse.date(from: "2026-11-02T04:30:00Z"))
        let end = try XCTUnwrap(parse.date(from: "2026-11-02T05:00:00Z"))
        let context = ModelContext(container)
        for time in [start.addingTimeInterval(-1), start, lastHour, end] {
            context.insert(HRVSample(anchorTestTimestamp: time, meanBPM: 60))
        }
        try context.save()
        let points = try HistoricalDayReader.read(container: container, from: start, until: end)
        XCTAssertEqual(points.map(\.timestamp), [start, lastHour])
    }

    nonisolated private static func point(_ time: Double, value: Float? = nil) -> MetricsHistoryPoint {
        MetricsHistoryPoint(timestamp: Date(timeIntervalSince1970: time), meanBPM: value)
    }

    func testMergePreservesConcurrentLiveReadingsAndDoesNotDuplicateOverlap() {
        let points = RecentHistoryLoader.merged(
            fetched: [Self.point(1, value: 10), Self.point(2, value: 20)],
            current: [Self.point(2, value: 200), Self.point(3, value: 30)], limit: 10)
        XCTAssertEqual(points.map { $0.timestamp.timeIntervalSince1970 }, [1, 2, 3])
        XCTAssertEqual(points.map(\.meanBPM), [10, 200, 30])
    }

    func testMergeKeepsNewestBoundedHistoryEvenWhenFetchFinishesLate() {
        let points = RecentHistoryLoader.merged(fetched: [Self.point(1), Self.point(2), Self.point(3)],
            current: [Self.point(4), Self.point(5)], limit: 3)
        XCTAssertEqual(points.map { $0.timestamp.timeIntervalSince1970 }, [3, 4, 5])
    }

    func testReadLeavesMainActorAvailableForLivePackets() async {
        let gate = DispatchSemaphore(value: 0)
        let published = expectation(description: "history published after main actor releases worker")
        let loader = RecentHistoryLoader(read: { _, _ in
            XCTAssertFalse(Thread.isMainThread, "Disk fetch and SwiftData mapping must not run on the UI thread")
            guard gate.wait(timeout: .now() + 1) == .success else { throw CocoaError(.userCancelled) }
            return [Self.point(1)]
        }, current: { [] }, publish: { points in
            XCTAssertEqual(points.count, 1)
            published.fulfill()
        })
        loader.request(after: .distantPast)
        // This must execute while the reader is waiting, not after it returns.
        gate.signal()
        await fulfillment(of: [published], timeout: 3)
    }
}

@MainActor
final class RecentHistoryReloadLifecycleTests: XCTestCase {
    nonisolated private static func point(_ time: Double) -> MetricsHistoryPoint {
        MetricsHistoryPoint(timestamp: Date(timeIntervalSince1970: time), meanBPM: 60)
    }

    private final class ReadGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    func testDiskReaderUsesNewestBoundAndReturnsPlainSnapshots() async throws {
        let container = try ModelContainer(for: AppStoreBootstrap.schema, configurations: [
            ModelConfiguration(schema: AppStoreBootstrap.schema, isStoredInMemoryOnly: true)])
        for i in 0..<10 {
            container.mainContext.insert(HRVSample(anchorTestTimestamp: Date(timeIntervalSince1970: Double(i)),
                                                   meanBPM: Float(60 + i)))
        }
        try container.mainContext.save()
        let loaded = expectation(description: "bounded disk history")
        var result: [MetricsHistoryPoint] = []
        let loader = RecentHistoryLoader(limit: 3, read: { after, limit in
            try RecentHistoryLoader.read(container: container, after: after, limit: limit)
        }, current: { [] }, publish: { result = $0; loaded.fulfill() })
        loader.request(after: Date(timeIntervalSince1970: 2))
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertEqual(result.map { $0.timestamp.timeIntervalSince1970 }, [7, 8, 9])
        XCTAssertEqual(result.map(\.meanBPM), [67, 68, 69])
    }

    func testRepeatedReloadsCoalesceAndKeepLiveArrivals() async throws {
        let gate = ReadGate()
        var history: [MetricsHistoryPoint] = []
        let published = expectation(description: "initial and one coalesced read")
        published.expectedFulfillmentCount = 2
        let loader = RecentHistoryLoader(read: { _, _ in
            let n = gate.next()
            if n == 1 {
                gate.entered.signal()
                guard gate.release.wait(timeout: .now() + 3) == .success else { throw CocoaError(.userCancelled) }
            }
            return [Self.point(Double(n))]
        }, current: { history }, publish: { history = $0; published.fulfill() })
        loader.request(after: .distantPast)
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(entered)
        history = [Self.point(3)]
        for _ in 0..<20 { loader.request(after: .distantPast) }
        gate.release.signal()
        await fulfillment(of: [published], timeout: 5)
        XCTAssertEqual(history.map { $0.timestamp.timeIntervalSince1970 }, [1, 2, 3])
        XCTAssertEqual(gate.calls, 2)
    }

    func testInvalidationDrainsOldReaderBeforeNextAndRejectsItsResult() async {
        let gate = ReadGate()
        var history: [MetricsHistoryPoint] = []
        let newPublished = expectation(description: "new generation")
        let oldFinished = expectation(description: "old reader released")
        let loader = RecentHistoryLoader(read: { _, _ in
            if gate.next() == 1 {
                gate.entered.signal()
                _ = gate.release.wait(timeout: .now() + 5)
                oldFinished.fulfill()
                return [Self.point(1)]
            }
            return [Self.point(2)]
        }, current: { history }, publish: {
            history = $0
            XCTAssertEqual(history.map { $0.timestamp.timeIntervalSince1970 }, [2])
            newPublished.fulfill()
        })
        loader.request(after: .distantPast)
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(entered)
        loader.invalidate()
        loader.request(after: .distantPast)
        // Give a wrongly concurrent reader an opportunity to start. A second
        // full-day SwiftData fetch during draining doubles peak memory.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(gate.calls, 1, "An invalidated fetch must drain before the next fetch")
        gate.release.signal()
        await fulfillment(of: [oldFinished], timeout: 3)
        await fulfillment(of: [newPublished], timeout: 3)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(history.map { $0.timestamp.timeIntervalSince1970 }, [2])
    }

    func testFailedReadRetainsCurrentHistoryAndAllowsRetry() async {
        let gate = ReadGate()
        var history = [Self.point(5)]
        let recovered = expectation(description: "retried read")
        let loader = RecentHistoryLoader(read: { _, _ in
            if gate.next() == 1 { throw CocoaError(.fileReadNoPermission) }
            return [Self.point(4)]
        }, current: { history }, publish: { history = $0; recovered.fulfill() })
        loader.request(after: .distantPast)
        let deadline = Date().addingTimeInterval(3)
        while loader.isLoading && Date() < deadline { await Task.yield() }
        XCTAssertFalse(loader.isLoading)
        XCTAssertEqual(history.map { $0.timestamp.timeIntervalSince1970 }, [5])
        loader.request(after: .distantPast)
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(history.map { $0.timestamp.timeIntervalSince1970 }, [4, 5])
    }

    func testEmptyForegroundReadDoesNotRepublishOrCopyExistingHistory() async {
        var currentReads = 0, publications = 0
        let loader = RecentHistoryLoader(read: { _, _ in [] }, current: {
            currentReads += 1
            return (0..<43_200).map { Self.point(Double($0)) }
        }, publish: { _ in publications += 1 })
        loader.request(after: .distantPast)
        let deadline = Date().addingTimeInterval(3)
        while loader.isLoading && Date() < deadline { await Task.yield() }
        XCTAssertFalse(loader.isLoading)
        XCTAssertEqual(currentReads, 0)
        XCTAssertEqual(publications, 0)
    }

    func testLargeMergeRetainsNewest43200SamplesAndCurrentDuplicateValue() {
        let stored = (0..<43_200).map { Self.point(Double($0)) }
        let live = (43_199...43_202).map { Self.point(Double($0)) }
        let result = RecentHistoryLoader.merged(fetched: stored, current: live, limit: 43_200)
        XCTAssertEqual(result.count, 43_200)
        XCTAssertEqual(result.first?.timestamp.timeIntervalSince1970, 3)
        XCTAssertEqual(result.last?.timestamp.timeIntervalSince1970, 43_202)
        XCTAssertEqual(Set(result.map(\.timestamp)).count, 43_200)
    }
}
