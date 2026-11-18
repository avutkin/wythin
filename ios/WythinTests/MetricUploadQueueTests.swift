import XCTest
import SwiftData
@testable import Wythin

private final class MetricReceiptURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var receipt = Data()
    private static var status = 200

    static func respond(_ text: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        receipt = Data(text.utf8)
        self.status = status
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "receipt.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let data = Self.receipt, status = Self.status
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Real responses can arrive across several delegate callbacks.
        let middle = data.count / 2
        client?.urlProtocol(self, didLoad: data.prefix(middle))
        client?.urlProtocol(self, didLoad: data.suffix(from: middle))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class MetricUploadReceiptTests: XCTestCase {
    private func sample(_ json: String) throws -> MetricSamplePayload {
        try JSONDecoder().decode(MetricSamplePayload.self, from: Data(json.utf8))
    }
    private func client() -> (APIClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetricReceiptURLProtocol.self]
        let session = URLSession(configuration: config)
        return (APIClient(baseURL: URL(string: "https://receipt.invalid")!, session: session), session)
    }

    // A 200 with fewer accepted records must never retire the local batch.
    func testPartialReceiptIsRejected() async throws {
        let (api, session) = client()
        defer { session.invalidateAndCancel() }
        MetricReceiptURLProtocol.respond(#"{"stored":0,"skipped":0}"#)
        let body = MetricsUploadPayload(samples: [try sample(#"{"ts":"2026-11-16T12:00:00Z","mean_bpm":60}"#)])
        do {
            _ = try await api.uploadMetrics(body, userID: "fixture")
            XCTFail("A partial receipt cannot acknowledge an unsent sample")
        } catch { }
    }

    func testSkippedValuedSampleIsRejected() async throws {
        let (api, session) = client()
        defer { session.invalidateAndCancel() }
        MetricReceiptURLProtocol.respond(#"{"stored":0,"skipped":1}"#)
        let body = MetricsUploadPayload(samples: [try sample(#"{"ts":"2026-11-16T12:00:00Z","stress_balance":24}"#)])
        do {
            _ = try await api.uploadMetrics(body, userID: "fixture")
            XCTFail("Only valueless samples may be skipped")
        } catch { }
    }

    func testCompleteDuplicateReceiptAndExplicitEmptySkipAreAccepted() async throws {
        let (api, session) = client()
        defer { session.invalidateAndCancel() }
        let body = MetricsUploadPayload(samples: [
            try sample(#"{"ts":"2026-11-16T12:00:00Z","mean_bpm":60,"timezone":"Asia/Dubai","stress_balance":24}"#),
            try sample(#"{"ts":"2026-11-16T12:00:02Z"}"#)
        ])
        MetricReceiptURLProtocol.respond(#"{"stored":1,"skipped":1}"#)
        _ = try await api.uploadMetrics(body, userID: "fixture")
        _ = try await api.uploadMetrics(body, userID: "fixture")
    }

    func testErrorStatusCannotAcknowledgeEvenWithCompleteReceipt() async throws {
        let (api, session) = client()
        defer { session.invalidateAndCancel() }
        MetricReceiptURLProtocol.respond(#"{"stored":1,"skipped":0}"#, status: 503)
        let body = MetricsUploadPayload(samples: [try sample(#"{"ts":"2026-11-16T12:00:00Z","mean_bpm":60}"#)])
        do {
            _ = try await api.uploadMetrics(body, userID: "fixture")
            XCTFail("HTTP failure must preserve the pending batch")
        } catch { }
    }
}

final class MetricUploadQueueTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("metric-queue-\(UUID())", isDirectory: true)
    }
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let bytes = Data(#"{"samples":[{"ts":"2027-01-15T08:00:00Z","mean_bpm":60,"timezone":"Asia/Dubai","stress_balance":24}]}"#.utf8)

    func testPendingTailSurvivesReopenWithExactPayloadAndMembership() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = try MetricUploadQueue(root: root, migrationBoundary: instant)
        let entry = try queue.enqueue(payload: bytes, members: [Data("row-one".utf8)],
                                      latestSampleAt: instant, expectedStored: 1, expectedSkipped: 0, now: instant)
        let reopened = try MetricUploadQueue(root: root, migrationBoundary: instant.addingTimeInterval(999))
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries.first?.members, [Data("row-one".utf8)])
        XCTAssertEqual(reopened.migrationBoundary, instant, "migration boundary cannot follow later acknowledgements")
        XCTAssertEqual(try Data(contentsOf: reopened.payloadURL(for: entry.id)), bytes)
    }

    func testFailedUploadBackoffPersistsWithoutAnotherSample() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        let entry = try queue.enqueue(payload: bytes, members: [], latestSampleAt: instant,
                                      expectedStored: 1, expectedSkipped: 0, now: instant)
        try queue.fail(entry.id, now: instant)
        queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        XCTAssertEqual(queue.entries.first?.attempts, 1)
        XCTAssertEqual(queue.entries.first?.nextAttemptAt, instant.addingTimeInterval(30))
        try queue.fail(entry.id, now: instant.addingTimeInterval(30))
        XCTAssertEqual(queue.entries.first?.nextAttemptAt, instant.addingTimeInterval(90))
        for _ in 0..<20 { try queue.fail(entry.id, now: instant) }
        XCTAssertEqual(queue.entries.first?.nextAttemptAt, instant.addingTimeInterval(3600))
        XCTAssertEqual(try Data(contentsOf: queue.payloadURL(for: entry.id)), bytes)
    }

    func testReceiptSurvivesCrashBeforeSwiftDataAcknowledgementAndDuplicateCallback() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        let entry = try queue.enqueue(payload: bytes, members: [Data("row-one".utf8)], latestSampleAt: instant,
                                      expectedStored: 1, expectedSkipped: 0, now: instant)
        try queue.acknowledge(entry.id, response: Data(#"{"stored":1,"skipped":0}"#.utf8), now: instant)
        queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        XCTAssertEqual(queue.entries.first?.acknowledgedAt, instant)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.payloadURL(for: entry.id).path))
        try queue.acknowledge(entry.id, response: Data(#"{"stored":1,"skipped":0}"#.utf8), now: instant.addingTimeInterval(1))
        XCTAssertEqual(queue.entries.first?.acknowledgedAt, instant)
        try queue.removeAcknowledged(entry.id)
        try queue.removeAcknowledged(entry.id)
        XCTAssertTrue(try MetricUploadQueue(root: root, migrationBoundary: .distantPast).entries.isEmpty)
    }

    func testInvalidAndPartialReceiptsNeverRemovePayload() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        let entry = try queue.enqueue(payload: bytes, members: [], latestSampleAt: instant,
                                      expectedStored: 1, expectedSkipped: 0, now: instant)
        for receipt in [#"{"stored":0,"skipped":0}"#, #"{"stored":1,"skipped":1}"#, #"{"stored":-1}"#, "{}", "not JSON"] {
            XCTAssertThrowsError(try queue.acknowledge(entry.id, response: Data(receipt.utf8), now: instant))
            XCTAssertNil(queue.entries.first?.acknowledgedAt)
            XCTAssertEqual(try Data(contentsOf: queue.payloadURL(for: entry.id)), bytes)
        }
        XCTAssertThrowsError(try queue.removeAcknowledged(entry.id))
    }
}

private final class MetricDeliveryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var held = false
    private static var requests: [Data] = []
    private static var waiting: [MetricDeliveryURLProtocol] = []
    private static var status = 200
    private var pendingBody = Data()
    static func reset(hold: Bool = false) {
        lock.lock(); defer { lock.unlock() }; held = hold; requests = []; waiting = []; status = 200
    }
    static func release() { lock.lock(); defer { lock.unlock() }; held = false; status = 200 }
    static func requestCount() -> Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    static func heldCount() -> Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
    static func completeHeld(status: Int) {
        lock.lock()
        let protocols = waiting
        waiting = []; held = false; self.status = status
        lock.unlock()
        for item in protocols { item.respond(item.pendingBody, status: status) }
    }
    static func samples() throws -> [MetricSamplePayload] {
        lock.lock(); defer { lock.unlock() }
        return try requests.flatMap { try JSONDecoder().decode(MetricsUploadPayload.self, from: $0).samples }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "delivery.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        Self.requests.append(bytes)
        let hold = Self.held, status = Self.status
        pendingBody = bytes
        if hold { Self.waiting.append(self) }
        Self.lock.unlock()
        guard !hold else { return }
        respond(bytes, status: status)
    }
    private func respond(_ bytes: Data, status: Int) {
        let payload = try? JSONDecoder().decode(MetricsUploadPayload.self, from: bytes)
        let stored = payload?.samples.filter(\.hasStoredValue).count ?? 0
        let skipped = (payload?.samples.count ?? 0) - stored
        let body = Data("{\"stored\":\(stored),\"skipped\":\(skipped)}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body.prefix(4))
        client?.urlProtocol(self, didLoad: body.suffix(from: 4))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.waiting.removeAll { $0 === self }
    }
}

@MainActor
final class MetricDeliveryLifecycleTests: XCTestCase {
    private var oldDefaults: [String: Any] = [:]
    private let keys = ["cloudSyncEnabled", "metricsLastSyncedEpoch", "metricsLastSyncedAt", "metricsLastUploadAtEpoch", "profileLastSynced", ClientProfileStore.key]
    override func setUp() {
        super.setUp()
        for key in keys { oldDefaults[key] = UserDefaults.standard.object(forKey: key); UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(true, forKey: "cloudSyncEnabled")
        MetricDeliveryURLProtocol.reset()
    }
    override func tearDown() {
        for key in keys {
            if let value = oldDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }
    private func store() throws -> ModelContainer {
        try ModelContainer(for: HRVSession.self, HRVSample.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func service(_ container: ModelContainer, root: URL, interval: TimeInterval = 0.01) -> MetricSyncService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetricDeliveryURLProtocol.self]
        return MetricSyncService(client: APIClient(baseURL: URL(string: "https://delivery.invalid")!),
                                 userID: "fixture", container: container, queueDirectory: root,
                                 sessionConfiguration: config, coalescingInterval: interval,
                                 now: { Date(timeIntervalSince1970: 1_800_000_100) })
    }
    private func waitForDrain(_ service: MetricSyncService) async throws {
        for _ in 0..<300 {
            if service.lastUploadedAt != nil && service.pendingCount == 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("saved metrics did not drain: \(service.diagnosticsSummary)")
    }

    private func dualMetricService(_ container: ModelContainer, root: URL, native: DiagnosticHTTPStub,
                                   immediate: DiagnosticHTTPStub) -> MetricSyncService {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.wythin.test.\(UUID())")
        return MetricSyncService(client: APIClient(baseURL: URL(string: "http://127.0.0.1:2")!),
            userID: "fixture", container: container, queueDirectory: root, sessionConfiguration: configuration,
            sessionFactory: { _, delegate in
                URLSession(configuration: native.configuration, delegate: delegate, delegateQueue: nil)
            }, makeImmediateUpload: { ImmediateFileUpload(configuration: immediate.configuration) },
            coalescingInterval: 0.01)
    }

    private func waitForRequests(native: DiagnosticHTTPStub, immediate: DiagnosticHTTPStub) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while native.requestCount == 0 || immediate.requestCount == 0 {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testHeldNativeMetricTaskAndNewDurableSaveDrainsOnImmediateExactReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        let native = DiagnosticHTTPStub(), immediate = DiagnosticHTTPStub()
        let service = dualMetricService(container, root: root, native: native, immediate: immediate)
        await service.syncIfEnabled()
        let ack = Data(#"{"stored":1,"skipped":0}"#.utf8)
        let nativeLate = native.hold(status: 200, body: ack)
        let accept = immediate.hold(status: 200, body: ack)
        context.insert(HRVSample(anchorTestTimestamp: Date(), meanBPM: 64))
        try context.save()
        service.savedMetricsDidChange()
        try await waitForRequests(native: native, immediate: immediate)
        let queued = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        let entry = try XCTUnwrap(queued.entries.first)
        XCTAssertNil(entry.acknowledgedAt)
        let file = try Data(contentsOf: queued.payloadURL(for: entry.id))
        XCTAssertEqual(native.lastRequestBody, file)
        XCTAssertEqual(immediate.lastRequestBody, file)
        accept()
        try await waitForDrain(service)
        nativeLate()
        let delivery = service.recordingDiagnosticDelivery
        XCTAssertEqual(delivery.lastHttpStatus, 200)
        XCTAssertEqual(delivery.maximumAttempts, 0)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<HRVSample>()).first?.cloudUploadState, 1)
        XCTAssertTrue(try MetricUploadQueue(root: root, migrationBoundary: .distantPast).entries.isEmpty)
    }

    func testInvalidImmediateMetricReceiptLeavesNativeUploadAndRetryBudgetUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        context.insert(HRVSample(anchorTestTimestamp: Date(), meanBPM: 64))
        try context.save()
        let native = DiagnosticHTTPStub(), immediate = DiagnosticHTTPStub()
        let service = dualMetricService(container, root: root, native: native, immediate: immediate)
        let win = native.hold(status: 200, body: Data(#"{"stored":1,"skipped":0}"#.utf8))
        let invalid = immediate.hold(status: 200, body: Data(#"{"stored":0,"skipped":0}"#.utf8))
        await service.syncIfEnabled()
        try await waitForRequests(native: native, immediate: immediate)
        invalid()
        let deadline = ContinuousClock.now + .seconds(3)
        while service.recordingDiagnosticDelivery.lastErrorCode == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(service.recordingDiagnosticDelivery.lastErrorCode)
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertEqual(service.recordingDiagnosticDelivery.maximumAttempts, 0)
        XCTAssertEqual(native.cancellationCount, 0)
        win()
        try await waitForDrain(service)
        XCTAssertNil(service.recordingDiagnosticDelivery.lastErrorCode)
    }

    func testMetricDeletionWaitsForBothLanesAndPreservesConcurrentOptOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        context.insert(HRVSample(anchorTestTimestamp: Date(), meanBPM: 64))
        try context.save()
        let native = DiagnosticHTTPStub(), immediate = DiagnosticHTTPStub()
        let service = dualMetricService(container, root: root, native: native, immediate: immediate)
        let ack = Data(#"{"stored":1,"skipped":0}"#.utf8)
        let nativeLate = native.hold(status: 200, body: ack)
        let sideLate = immediate.hold(status: 200, body: ack)
        await service.syncIfEnabled()
        try await waitForRequests(native: native, immediate: immediate)
        try await service.withCloudDataDeletion {
            XCTAssertEqual(native.cancellationCount, 1)
            XCTAssertEqual(immediate.cancellationCount, 1)
            await service.syncIfEnabled()
            service.setEnabled(false)
            nativeLate()
            sideLate()
        }
        await service.syncIfEnabled()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "cloudSyncEnabled"))
        XCTAssertEqual(native.requestCount, 1)
        XCTAssertEqual(immediate.requestCount, 1)
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertNil(service.recordingDiagnosticDelivery.lastAckAt)
    }

    func testAttemptTimestampOnlyChangesOnFirstEvidenceOfNetworkStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        context.insert(HRVSample(anchorTestTimestamp: Date(), meanBPM: 62))
        try context.save()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetricDeliveryURLProtocol.self]
        MetricDeliveryURLProtocol.reset(hold: true)
        var time = Date(timeIntervalSince1970: 1_800_000_100)
        var native: URLSession?
        let service = MetricSyncService(client: APIClient(baseURL: URL(string: "https://delivery.invalid")!),
            userID: "fixture", container: container, queueDirectory: root, sessionConfiguration: config,
            sessionFactory: { config, delegate in
                native = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                return native!
            }, now: { time })
        await service.syncIfEnabled()
        let session = try XCTUnwrap(native)
        defer { session.invalidateAndCancel() }
        let tasks = await session.allTasks
        let transfer = try XCTUnwrap(tasks.first)
        let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
        XCTAssertNil(service.recordingDiagnosticDelivery.lastAttemptAt)
        delegate.urlSession?(session, task: transfer, didSendBodyData: 1, totalBytesSent: 1, totalBytesExpectedToSend: 10)
        try await Task.sleep(for: .milliseconds(20))
        let start = try XCTUnwrap(service.recordingDiagnosticDelivery.lastAttemptAt)
        time.addTimeInterval(60)
        delegate.urlSession?(session, task: transfer, didSendBodyData: 9, totalBytesSent: 10, totalBytesExpectedToSend: 10)
        MetricDeliveryURLProtocol.completeHeld(status: 200)
        try await waitForDrain(service)
        XCTAssertEqual(service.recordingDiagnosticDelivery.lastAttemptAt, start)
    }

    func testSavedFinalTailUploadsAfterCoalescingWithoutAnotherTick() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        let service = service(container, root: root)
        XCTAssertNil(service.recordingDiagnosticDelivery.pendingSamples, "not scanned is not an empty queue")
        await service.syncIfEnabled()
        let sample = HRVSample(anchorTestTimestamp: Date(timeIntervalSince1970: 1_800_000_000), meanBPM: 61, timezone: "Asia/Dubai")
        sample.stressBalance = 23
        context.insert(sample); try context.save()
        service.savedMetricsDidChange()
        XCTAssertEqual(service.recordingDiagnosticDelivery.pendingSamples, 1,
                       "a new durable save is pending even before the coalesced queue scan")
        XCTAssertEqual(service.recordingDiagnosticDelivery.state, .uploading)
        try await waitForDrain(service)
        let sent = try MetricDeliveryURLProtocol.samples()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.ts, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(sent.first?.timezone, "Asia/Dubai")
        XCTAssertEqual(sent.first?.stress_balance, 23)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<HRVSample>()).first?.cloudUploadState, 1)
        let diagnostic = service.recordingDiagnosticDelivery
        XCTAssertEqual(diagnostic.state, .idle)
        XCTAssertEqual(diagnostic.pendingSamples, 0)
        XCTAssertEqual(diagnostic.lastHttpStatus, 200)
        XCTAssertEqual(diagnostic.lastAckSampleAt, sample.timestamp)
        XCTAssertNotNil(diagnostic.lastAckAt)
    }

    func testMigrationDoesNotHideNewRowsWithEarlierOrEqualTimestamps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        UserDefaults.standard.set(cutoff.timeIntervalSince1970, forKey: "metricsLastSyncedEpoch")
        let container = try store(), context = ModelContext(container)
        let legacy = HRVSample(anchorTestTimestamp: cutoff.addingTimeInterval(-10), meanBPM: 60)
        legacy.cloudUploadState = nil
        context.insert(legacy)
        let legacyBoundary = HRVSample(anchorTestTimestamp: cutoff, meanBPM: 61)
        legacyBoundary.cloudUploadState = nil
        context.insert(legacyBoundary)
        context.insert(HRVSample(anchorTestTimestamp: cutoff.addingTimeInterval(-5), meanBPM: 62))
        context.insert(HRVSample(anchorTestTimestamp: cutoff, meanBPM: 63))
        try context.save()
        let service = service(container, root: root)
        await service.syncIfEnabled()
        try await waitForDrain(service)
        XCTAssertEqual(try MetricDeliveryURLProtocol.samples().compactMap(\.mean_bpm).sorted(), [61, 62, 63])
        context.insert(HRVSample(anchorTestTimestamp: cutoff.addingTimeInterval(-1000), meanBPM: 64))
        try context.save()
        service.savedMetricsDidChange()
        service.applicationDidEnterBackground()
        try await waitForDrain(service)
        XCTAssertEqual(try MetricDeliveryURLProtocol.samples().compactMap(\.mean_bpm).sorted(), [61, 62, 63, 64])
    }

    func testOptOutCancelsTransportAndRetainsPendingRowsAndFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        context.insert(HRVSample(anchorTestTimestamp: Date(timeIntervalSince1970: 1_800_000_000), meanBPM: 60))
        try context.save()
        MetricDeliveryURLProtocol.reset(hold: true)
        let service = service(container, root: root, interval: 300)
        await service.syncIfEnabled()
        XCTAssertEqual(service.diagnosticsSummary["in_flight"], "1")
        service.setEnabled(false)
        XCTAssertEqual(service.diagnosticsSummary["in_flight"], "0", "the UI action cancels synchronously")
        let queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        let entry = try XCTUnwrap(queue.entries.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.payloadURL(for: entry.id).path))
        XCTAssertNil(entry.acknowledgedAt)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<HRVSample>()).first?.cloudUploadState, 0)
        MetricDeliveryURLProtocol.release()
        service.setEnabled(true)
        try await waitForDrain(service)
        XCTAssertTrue(try MetricUploadQueue(root: root, migrationBoundary: .distantPast).entries.isEmpty)
    }
    func testDurableReceiptIsAppliedAfterRestartBeforeAnyNetworkRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        let sample = HRVSample(anchorTestTimestamp: Date(timeIntervalSince1970: 1_800_000_000), meanBPM: 60)
        context.insert(sample); try context.save()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        let batch = try queue.enqueue(payload: encoder.encode(MetricsUploadPayload(samples: [MetricSamplePayload(from: sample)])),
                                      members: [encoder.encode(sample.persistentModelID)], latestSampleAt: sample.timestamp,
                                      expectedStored: 1, expectedSkipped: 0, now: sample.timestamp)
        try queue.acknowledge(batch.id, response: Data(#"{"stored":1,"skipped":0}"#.utf8), now: sample.timestamp)
        let service = service(container, root: root)
        await service.syncIfEnabled()
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<HRVSample>()).first?.cloudUploadState, 1)
        XCTAssertEqual(MetricDeliveryURLProtocol.requestCount(), 0, "receipt recovery does not resend acknowledged data")
        XCTAssertTrue(try MetricUploadQueue(root: root, migrationBoundary: .distantPast).entries.isEmpty)
    }

    func testRestoredPendingFileRemainsIntactWhenStartingWithConsentOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        let sample = HRVSample(anchorTestTimestamp: Date(timeIntervalSince1970: 1_800_000_000), meanBPM: 60)
        context.insert(sample); try context.save()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        let bytes = try encoder.encode(MetricsUploadPayload(samples: [MetricSamplePayload(from: sample)]))
        let batch = try queue.enqueue(payload: bytes, members: [encoder.encode(sample.persistentModelID)],
                                      latestSampleAt: sample.timestamp, expectedStored: 1, expectedSkipped: 0, now: sample.timestamp)
        UserDefaults.standard.set(false, forKey: "cloudSyncEnabled")
        let service = service(container, root: root)
        await service.syncIfEnabled()
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertEqual(service.diagnosticsSummary["queued_batches"], "1")
        XCTAssertEqual(MetricDeliveryURLProtocol.requestCount(), 0)
        XCTAssertEqual(try Data(contentsOf: queue.payloadURL(for: batch.id)), bytes)
        UserDefaults.standard.set(true, forKey: "cloudSyncEnabled")
        await service.syncIfEnabled()
        try await waitForDrain(service)
    }

    func testRetryMetadataFailureDoesNotCauseAnImmediateUploadLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        context.insert(HRVSample(anchorTestTimestamp: Date(timeIntervalSince1970: 1_800_000_000), meanBPM: 60))
        try context.save()
        MetricDeliveryURLProtocol.reset(hold: true)
        let service = service(container, root: root)
        await service.syncIfEnabled()
        for _ in 0..<200 where MetricDeliveryURLProtocol.heldCount() == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(MetricDeliveryURLProtocol.heldCount(), 1)
        let sidecar = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "batch" })
        let saved = try Data(contentsOf: sidecar)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        MetricDeliveryURLProtocol.completeHeld(status: 503)
        for _ in 0..<200 where service.diagnosticsSummary["storage_retry_blocked"] != "true" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.diagnosticsSummary["storage_retry_blocked"], "true")
        XCTAssertEqual(service.recordingDiagnosticDelivery.state, .storageBlocked)
        XCTAssertEqual(service.recordingDiagnosticDelivery.lastHttpStatus, 503)
        XCTAssertNotNil(service.recordingDiagnosticDelivery.lastErrorCode)
        XCTAssertNil(service.recordingDiagnosticDelivery.lastAckAt)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(MetricDeliveryURLProtocol.requestCount(), 1, "failed persistence cannot create an immediate retry loop")
        XCTAssertEqual(service.pendingCount, 1)
        try FileManager.default.removeItem(at: sidecar)
        try saved.write(to: sidecar, options: .atomic)
        MetricDeliveryURLProtocol.release()
        await service.syncIfEnabled()
        try await waitForDrain(service)
    }

    func testRestoredTaskForAnotherAccountCannotRetireMatchingBatchID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        let sample = HRVSample(anchorTestTimestamp: Date(), meanBPM: 64)
        context.insert(sample)
        try context.save()
        let queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let entry = try queue.enqueue(payload: encoder.encode(MetricsUploadPayload(samples: [MetricSamplePayload(from: sample)])),
            members: [encoder.encode(sample.persistentModelID)], latestSampleAt: sample.timestamp,
            expectedStored: 1, expectedSkipped: 0, now: sample.timestamp)
        let api = APIClient(baseURL: URL(string: "http://127.0.0.1:2")!)
        let native = DiagnosticHTTPStub()
        let good = Data(#"{"stored":1,"skipped":0}"#.utf8)
        let stale = native.hold(status: 200, body: good)
        let current = native.hold(status: 200, body: good)
        defer { stale(); current() }
        var old: URLSessionUploadTask?
        let service = MetricSyncService(client: api, userID: "current-account", container: container,
            queueDirectory: root, sessionConfiguration: native.configuration, sessionFactory: { config, delegate in
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let task = session.uploadTask(with: api.metricUploadRequest(userID: "prior-account"),
                                              fromFile: queue.payloadURL(for: entry.id))
                task.taskDescription = entry.id.uuidString
                old = task
                task.resume()
                return session
            })
        let deadline = ContinuousClock.now + .seconds(3)
        while native.requestCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await service.syncIfEnabled()
        while native.requestCount < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(native.requestCount, 2)
        XCTAssertEqual((old?.error as? URLError)?.code, .cancelled)
        stale()
        XCTAssertNil(service.recordingDiagnosticDelivery.lastAckAt)
        current()
        try await waitForDrain(service)
    }

    func testRestoredSuspendedUploadResumesAndDrainsItsExistingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        let recordedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = HRVSample(anchorTestTimestamp: recordedAt, meanBPM: 67)
        context.insert(sample); try context.save()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let queue = try MetricUploadQueue(root: root, migrationBoundary: .distantPast)
        let entry = try queue.enqueue(payload: encoder.encode(MetricsUploadPayload(samples: [MetricSamplePayload(from: sample)])),
                                      members: [encoder.encode(sample.persistentModelID)], latestSampleAt: recordedAt,
                                      expectedStored: 1, expectedSkipped: 0, now: recordedAt)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetricDeliveryURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://delivery.invalid")!)
        var restoredSession: URLSession?
        var restoredTask: URLSessionUploadTask?
        MetricDeliveryURLProtocol.reset(hold: true)
        let service = MetricSyncService(client: api, userID: "fixture", container: container,
            queueDirectory: root, sessionConfiguration: config,
            sessionFactory: { configuration, delegate in
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                let task = session.uploadTask(with: api.metricUploadRequest(userID: "fixture"),
                                              fromFile: queue.payloadURL(for: entry.id))
                task.taskDescription = entry.id.uuidString
                restoredSession = session
                restoredTask = task
                return session
            }, now: { recordedAt.addingTimeInterval(100) })
        let session = try XCTUnwrap(restoredSession), task = try XCTUnwrap(restoredTask)
        // Foundation omits never-resumed tasks from getAllTasks. Activate the
        // real request, hold its response, then suspend to create an inventory
        // that actually exercises the production restoration branch.
        task.resume()
        for _ in 0..<200 where MetricDeliveryURLProtocol.heldCount() == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(MetricDeliveryURLProtocol.heldCount(), 1)
        task.suspend()
        let inventory = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(inventory.contains { $0 === task }, "fixture must be present in the real session inventory")
        XCTAssertEqual(task.state, .suspended)
        MetricDeliveryURLProtocol.release()
        await service.syncIfEnabled()
        MetricDeliveryURLProtocol.completeHeld(status: 200)
        try await waitForDrain(service)
        XCTAssertEqual(task.state, .completed, "the original task must resume; recreating a replacement does not satisfy this test")
        XCTAssertNil(task.error, "cancelling the inventoried task and replacing it is not suspended-task recovery")
        XCTAssertEqual(try MetricDeliveryURLProtocol.samples().last?.mean_bpm, 67)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<HRVSample>()).first?.cloudUploadState, 1)
        XCTAssertTrue(try MetricUploadQueue(root: root, migrationBoundary: .distantPast).entries.isEmpty)
    }

    func testConsentCancelsProfileAndRapidReenableDoesNotLosePendingSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try store(), context = ModelContext(container)
        var profile = ClientProfile()
        profile.firstName = "Ada"; profile.lastName = "Lovelace"; profile.email = "ada@example.com"
        ClientProfileStore().save(profile)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetricDeliveryURLProtocol.self]
        let profileSession = URLSession(configuration: config)
        defer { profileSession.invalidateAndCancel() }
        let api = APIClient(baseURL: URL(string: "https://delivery.invalid")!, session: profileSession)
        let service = MetricSyncService(client: api, userID: "fixture", container: container,
                                        queueDirectory: root, sessionConfiguration: config)
        MetricDeliveryURLProtocol.reset(hold: true)
        var initialFinished = false
        let initial = Task { await service.syncIfEnabled(); initialFinished = true }
        defer { initial.cancel() }
        for _ in 0..<200 where MetricDeliveryURLProtocol.heldCount() == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(MetricDeliveryURLProtocol.heldCount(), 1, "profile transport is genuinely pending")
        XCTAssertNil(UserDefaults.standard.string(forKey: "profileLastSynced"))
        service.setEnabled(false)
        context.insert(HRVSample(anchorTestTimestamp: Date(timeIntervalSince1970: 1_800_000_000), meanBPM: 68))
        try context.save()
        service.savedMetricsDidChange()
        MetricDeliveryURLProtocol.release()
        service.setEnabled(true)
        for _ in 0..<300 where !initialFinished {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(initialFinished, "consent cancellation releases the held profile request")
        try await waitForDrain(service)
        for _ in 0..<200 where UserDefaults.standard.string(forKey: "profileLastSynced") == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(UserDefaults.standard.string(forKey: "profileLastSynced"))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<HRVSample>()).first?.cloudUploadState, 1)
        XCTAssertEqual(MetricDeliveryURLProtocol.heldCount(), 0)
    }

}
