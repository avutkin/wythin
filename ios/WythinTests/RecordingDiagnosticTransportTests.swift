import Foundation
import Network
import XCTest
@testable import Wythin

@MainActor
final class RecordingDiagnosticTransportTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func event(_ sequence: Int, installation: UUID = UUID(), launch: UUID = UUID(),
                       launchSequence: Int = 1) -> RecordingDiagnosticEvent {
        .init(installationId: installation, launchId: launch, launchSequence: launchSequence,
              sequence: sequence, observedAt: clock, uptimeSeconds: 1, reason: .heartbeat,
              appVersion: "1", appBuild: "156", osVersion: "26", phase: .background,
              sensor: .init(), recording: .init(), delivery: .init(), droppedReports: 0)
    }

    func testRestartReusesExactBatchAndOrdersNewReportsAfterResolution() throws {
        let directory = root()
        let queue = try RecordingDiagnosticOutbox(root: directory)
        let identity = try queue.beginLaunch()
        let old = event(1)
        try queue.enqueue(old, at: clock)
        let batch = try XCTUnwrap(queue.nextBatch(at: clock))
        let next = event(2)
        try queue.enqueue(next, at: clock)
        try queue.retry(batch, at: clock)

        let reopened = try RecordingDiagnosticOutbox(root: directory)
        let updated = try reopened.beginLaunch()
        XCTAssertEqual(updated.installationID, identity.installationID)
        XCTAssertEqual(updated.launchSequence, 2)
        let replay = try XCTUnwrap(reopened.nextBatch(at: clock))
        XCTAssertEqual(replay.id, batch.id)
        XCTAssertEqual(replay.eventIDs, [old.eventId])
        XCTAssertEqual(replay.notBefore, clock.addingTimeInterval(30))
        try reopened.resolve(replay, dropped: false)
        XCTAssertEqual(try reopened.nextBatch(at: clock)?.eventIDs, [next.eventId])
    }

    func testExpiredAndCorruptReportsCannotPoisonQueue() throws {
        let directory = root()
        let queue = try RecordingDiagnosticOutbox(root: directory)
        let expired = event(1)
        let corrupt = event(2)
        let live = event(3)
        try queue.enqueue(expired, at: clock.addingTimeInterval(-48 * 3600 - 1))
        try queue.enqueue(corrupt, at: clock)
        let reports = directory.appendingPathComponent("reports")
        let corrupted = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
            .first { $0.deletingPathExtension().lastPathComponent.hasSuffix(corrupt.eventId.uuidString) })
        try Data("bad JSON".utf8).write(to: corrupted)
        try queue.enqueue(live, at: clock)

        XCTAssertEqual(try queue.nextBatch(at: clock)?.eventIDs, [live.eventId])
        XCTAssertEqual(queue.droppedReports, 2)
    }

    func testCapacityKeepsNewestAndPreservesImmutableBatchPastExpiry() throws {
        let queue = try RecordingDiagnosticOutbox(root: root())
        let inFlight = event(1)
        try queue.enqueue(inFlight, at: clock)
        let first = try XCTUnwrap(queue.nextBatch(at: clock))

        let installation = UUID()
        let launch = UUID()
        var newest: [UUID] = []
        for index in 1...2049 {
            let report = event(index, installation: installation, launch: launch)
            try queue.enqueue(report, at: clock.addingTimeInterval(2 * 3600 + Double(index)))
            if index >= 2000 { newest.append(report.eventId) }
        }
        XCTAssertEqual(queue.droppedReports, 1)
        XCTAssertEqual(try queue.nextBatch(at: clock.addingTimeInterval(49 * 3600))?.eventIDs, [inFlight.eventId])
        try queue.resolve(first, dropped: true)
        XCTAssertEqual(queue.droppedReports, 2)
        XCTAssertEqual(try queue.nextBatch(at: clock.addingTimeInterval(49 * 3600))?.eventIDs, Array(newest.reversed()))
    }

    func testAccountAndServerScopesDoNotShareIdentityOrQueuedReports() throws {
        let directory = root()
        let first = makeSync(root: directory, user: "one")
        let second = makeSync(root: directory, user: "two")
        let otherServer = makeSync(root: directory, user: "one", port: 3)
        XCTAssertNotEqual(first.installationID, second.installationID)
        XCTAssertNotEqual(first.installationID, otherServer.installationID)
        XCTAssertEqual(first.launchSequence, 1)
        XCTAssertEqual(second.launchSequence, 1)

        let report = event(1, installation: first.installationID, launch: first.launchID)
        first.submit(event: report)
        XCTAssertEqual(try persistedEvents(in: directory).map(\.eventId), [report.eventId])
        second.setEnabled(false)
        otherServer.setEnabled(false)
        XCTAssertEqual(try persistedEvents(in: directory).map(\.eventId), [report.eventId])
    }

    func testWrongAcknowledgementPersistsRetryAndExactAcknowledgementRemovesBatch() async throws {
        let directory = root()
        var resumedAt: Date?
        let now = { [clock] in
            resumedAt.map { clock.addingTimeInterval(29.8 + Date().timeIntervalSince($0)) } ?? clock
        }
        let stub = DiagnosticHTTPStub()
        let sync = makeSync(root: directory, configuration: stub.configuration, clock: now)
        let report = event(1, installation: sync.installationID, launch: sync.launchID)
        stub.reply(status: 200, accepted: [UUID()])
        sync.submit(event: report)
        try await until { stub.requestCount == 1 }
        let outboxRoot = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory,
                                                                                   includingPropertiesForKeys: nil).first)
        try await until {
            try RecordingDiagnosticOutbox(root: outboxRoot).nextBatch(at: self.clock)?.notBefore == self.clock.addingTimeInterval(30)
        }
        XCTAssertEqual(try persistedEvents(in: directory).map(\.eventId), [report.eventId])

        stub.reply(status: 200, accepted: [report.eventId])
        // Simulate resuming just before the persisted deadline. The session's
        // own timer must retry without a new report or another call to start.
        resumedAt = Date()
        sync.start()
        XCTAssertEqual(stub.requestCount, 1)
        try await until { try self.persistedEvents(in: directory).isEmpty }
        XCTAssertEqual(stub.requestCount, 2)
    }

    func testTerminalRejectionCountsDroppedEventsAndDrainsNewerReports() async throws {
        let directory = root()
        let stub = DiagnosticHTTPStub()
        let sync = makeSync(root: directory, configuration: stub.configuration)
        let report = event(1, installation: sync.installationID, launch: sync.launchID)
        let reject = stub.hold(status: 422, accepted: [])
        sync.submit(event: report)
        try await until { stub.requestCount == 1 }
        let fresh = event(2, installation: sync.installationID, launch: sync.launchID)
        stub.reply(status: 200, accepted: [fresh.eventId])
        sync.submit(event: fresh)
        reject()
        try await until { try self.persistedEvents(in: directory).isEmpty }
        XCTAssertEqual(sync.droppedReports, 1)
        XCTAssertEqual(stub.requestCount, 2)
    }

    func testDisableClearsReportsPreservesIdentityAndIgnoresStaleCompletion() async throws {
        let directory = root()
        let stub = DiagnosticHTTPStub()
        let sync = makeSync(root: directory, configuration: stub.configuration)
        let first = event(1, installation: sync.installationID, launch: sync.launchID)
        let stale = stub.hold(status: 200, accepted: [first.eventId])
        sync.submit(event: first)
        try await until { stub.requestCount == 1 }
        let installation = sync.installationID
        sync.setEnabled(false)
        XCTAssertTrue(try persistedEvents(in: directory).isEmpty)
        XCTAssertEqual(sync.droppedReports, 0)
        XCTAssertEqual(sync.installationID, installation)

        sync.setEnabled(true)
        let fresh = event(2, installation: sync.installationID, launch: sync.launchID)
        let current = stub.hold(status: 200, accepted: [fresh.eventId])
        sync.submit(event: fresh)
        stale()
        try await until { stub.requestCount == 2 }
        XCTAssertEqual(try persistedEvents(in: directory).map(\.eventId), [fresh.eventId])
        current()
        try await until { try self.persistedEvents(in: directory).isEmpty }
    }

    func testRestoredCompletionBeforeInventoryStillAcknowledgesDurably() async throws {
        let directory = root()
        let staleProcess = makeSync(root: directory)
        let report = event(1, installation: staleProcess.installationID, launch: staleProcess.launchID)
        let scopedRoot = try scopeDirectory(in: directory)
        let queue = try RecordingDiagnosticOutbox(root: scopedRoot)
        try queue.enqueue(report, at: clock)
        let batch = try XCTUnwrap(queue.nextBatch(at: clock))
        let transferID = try queue.registerTransfer(batch)
        let api = APIClient(baseURL: URL(string: "http://127.0.0.1:2")!)
        let stub = DiagnosticHTTPStub()
        stub.reply(status: 200, accepted: [report.eventId])
        var restoredTask: URLSessionUploadTask?
        var delegate: URLSessionDelegate?
        var session: URLSession?
        let sync = makeSync(root: directory, configuration: stub.configuration, sessionFactory: { config, target in
            let restored = URLSession(configuration: config, delegate: target, delegateQueue: nil)
            let task = restored.uploadTask(with: api.recordingDiagnosticUploadRequest(userID: "user"),
                                           fromFile: queue.payloadURL(batch))
            task.taskDescription = "\(scopedRoot.lastPathComponent):\(transferID.uuidString)"
            restoredTask = task
            delegate = target
            session = restored
            return restored
        })
        let task = try XCTUnwrap(restoredTask)
        task.resume()
        try await until { task.state == .completed }
        XCTAssertEqual(try persistedEvents(in: directory).map(\.eventId), [report.eventId])
        let restoredSession = try XCTUnwrap(session)
        delegate?.urlSessionDidFinishEvents?(forBackgroundURLSession: restoredSession)
        var completed = false
        sync.handleBackgroundEvents {
            completed = true
            XCTAssertTrue((try? self.persistedEvents(in: directory).isEmpty) == true)
        }
        try await until { completed }
        XCTAssertEqual(stub.requestCount, 1, "an early receipt must prevent a duplicate upload")
    }

    func testDisabledRelaunchCancelsScopedRestoredTask() async throws {
        let directory = root()
        let staleProcess = makeSync(root: directory)
        let report = event(1, installation: staleProcess.installationID, launch: staleProcess.launchID)
        let scopedRoot = try scopeDirectory(in: directory)
        let queue = try RecordingDiagnosticOutbox(root: scopedRoot)
        try queue.enqueue(report, at: clock)
        let batch = try XCTUnwrap(queue.nextBatch(at: clock))
        let transferID = try queue.registerTransfer(batch)
        let api = APIClient(baseURL: URL(string: "http://127.0.0.1:2")!)
        let stub = DiagnosticHTTPStub()
        let release = stub.hold(status: 200, accepted: [report.eventId])
        var restoredTask: URLSessionUploadTask?
        let sync = makeSync(root: directory, configuration: stub.configuration, enabled: false,
                            sessionFactory: { config, delegate in
            let restored = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = restored.uploadTask(with: api.recordingDiagnosticUploadRequest(userID: "user"),
                                           fromFile: queue.payloadURL(batch))
            task.taskDescription = "\(scopedRoot.lastPathComponent):\(transferID.uuidString)"
            restoredTask = task
            return restored
        })
        let task = try XCTUnwrap(restoredTask)
        task.resume()
        try await until { stub.requestCount == 1 }
        sync.start()
        try await until { task.state == .completed }
        release()
        XCTAssertEqual((task.error as? URLError)?.code, .cancelled)
        XCTAssertTrue(try persistedEvents(in: directory).isEmpty)
        XCTAssertEqual(sync.installationID, report.installationId)
        XCTAssertEqual(sync.launchSequence, 2)
    }

    func testUnavailableIdentityRecoversWithoutResettingInstallation() async throws {
        let directory = root()
        let old = makeSync(root: directory)
        let scope = try scopeDirectory(in: directory)
        let state = scope.appendingPathComponent("state.json")
        let parked = scope.appendingPathComponent("state.parked")
        try FileManager.default.moveItem(at: state, to: parked)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)

        let sync = makeSync(root: directory)
        var becameReady = false
        sync.onReady = { becameReady = true }
        XCTAssertEqual(sync.launchSequence, 0)
        XCTAssertEqual(sync.nextSequence(), 0)
        sync.submit(event: event(1, installation: sync.installationID, launch: sync.launchID))
        XCTAssertTrue(try persistedEvents(in: directory).isEmpty)

        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: parked, to: state)
        sync.start()
        try await until { becameReady }
        XCTAssertEqual(sync.installationID, old.installationID)
        XCTAssertEqual(sync.launchSequence, 2)
        XCTAssertEqual(sync.nextSequence(), 1)
    }

    func testBackgroundSessionUploadsFileToLoopbackListener() async throws {
        let directory = root()
        let listener = try DiagnosticLoopbackListener()
        defer { listener.cancel() }
        try await until("listener startup") { listener.port != nil }
        let port = try XCTUnwrap(listener.port)
        let config = URLSessionConfiguration.background(withIdentifier: "com.wythin.diagnostic-test.\(UUID())")
        config.isDiscretionary = false
        var session: URLSession?
        let sync = makeSync(root: directory, user: "loopback-fixture", port: Int(port), configuration: config,
                            sessionFactory: { config, delegate in
            let created = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            session = created
            return created
        })
        let transferSession = try XCTUnwrap(session)
        defer { transferSession.invalidateAndCancel() }
        let report = event(1, installation: sync.installationID, launch: sync.launchID)
        sync.submit(event: report)
        do {
            try await until("background request and durable acknowledgement") {
                try listener.upload != nil && self.persistedEvents(in: directory).isEmpty
            }
        } catch {
            let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
                transferSession.getAllTasks { continuation.resume(returning: $0) }
            }
            XCTFail("Loopback upload timed out. Listener: \(listener.boundary). Tasks: \(tasks.map { [$0.state.rawValue, $0.countOfBytesSent, ($0.error as? URLError)?.code.rawValue ?? 0].map(String.init(describing:)).joined(separator: ",") }).")
            return
        }
        let upload = try XCTUnwrap(listener.upload)
        XCTAssertEqual(upload.requestLine, "POST /v1/recording-diagnostics HTTP/1.1")
        XCTAssertEqual(upload.userID, "loopback-fixture")
        XCTAssertEqual(upload.events.map(\.eventId), [report.eventId])
    }

    private func scopeDirectory(in root: URL) throws -> URL {
        try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
    }

    private func until(_ operation: String = "condition", _ check: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try !check() {
            guard ContinuousClock.now < deadline else { throw WaitError.timeout(operation) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum WaitError: Error { case timeout(String) }

    private func makeSync(root: URL, user: String = "user", port: Int = 2,
                          configuration: URLSessionConfiguration? = .ephemeral,
                          clock: (() -> Date)? = nil, enabled: Bool = true,
                          sessionFactory: ((URLSessionConfiguration, URLSessionDelegate) -> URLSession)? = nil) -> RecordingDiagnosticSync {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set(enabled, forKey: "cloudSyncEnabled")
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        return RecordingDiagnosticSync(client: client, userID: user, defaults: defaults,
                                       directory: root, configuration: configuration,
                                       now: clock ?? { self.clock }, sessionFactory: sessionFactory)
    }

    private func persistedEvents(in root: URL) throws -> [RecordingDiagnosticEvent] {
        let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return try (entries?.allObjects as? [URL] ?? [])
            .filter { $0.deletingLastPathComponent().lastPathComponent == "reports" && $0.pathExtension == "json" }
            .map { try RecordingDiagnosticEvent.decoder().decode(RecordingDiagnosticEvent.self, from: Data(contentsOf: $0)) }
    }
}


private final class DiagnosticHTTPStub: @unchecked Sendable {
    private let token = UUID().uuidString
    private let lock = NSLock()
    private var responses: [(DiagnosticURLProtocol) -> Void] = []
    private var requests = 0

    init() { DiagnosticURLProtocol.register(self, token: token) }
    deinit { DiagnosticURLProtocol.unregister(token) }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Stub": token]
        return configuration
    }

    var requestCount: Int { lock.withLock { requests } }

    func reply(status: Int, accepted: [UUID]) {
        lock.withLock { responses.append { $0.respond(status: status, accepted: accepted) } }
    }

    func hold(status: Int, accepted: [UUID]) -> () -> Void {
        let held = HeldResponse()
        lock.withLock {
            responses.append { task in held.store { task.respond(status: status, accepted: accepted) } }
        }
        return { held.release() }
    }

    func receive(_ task: DiagnosticURLProtocol) {
        let response = lock.withLock { () -> ((DiagnosticURLProtocol) -> Void)? in
            requests += 1
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        if let response { response(task) }
        else { task.respond(status: 500, accepted: []) }
    }

    private final class HeldResponse {
        private let lock = NSLock()
        private var work: (() -> Void)?
        private var released = false

        func store(_ callback: @escaping () -> Void) {
            let run = lock.withLock {
                if released { return true }
                work = callback
                return false
            }
            if run { callback() }
        }

        func release() {
            let callback = lock.withLock {
                released = true
                let callback = work
                work = nil
                return callback
            }
            callback?()
        }
    }
}

private final class DiagnosticURLProtocol: URLProtocol {
    private static let registry = NSMapTable<NSString, DiagnosticHTTPStub>.strongToWeakObjects()
    private static let registryLock = NSLock()
    private let lock = NSLock()
    private var stopped = false

    static func register(_ stub: DiagnosticHTTPStub, token: String) {
        registryLock.withLock { registry.setObject(stub, forKey: token as NSString) }
    }

    static func unregister(_ token: String) {
        registryLock.withLock { registry.removeObject(forKey: token as NSString) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Test-Stub") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: "X-Test-Stub"),
              let stub = Self.registryLock.withLock({ Self.registry.object(forKey: token as NSString) }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        stub.receive(self)
    }

    override func stopLoading() { lock.withLock { stopped = true } }

    func respond(status: Int, accepted: [UUID]) {
        guard !lock.withLock({ stopped }) else { return }
        let payload = try! JSONEncoder().encode(["accepted_ids": accepted])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}


private final class DiagnosticLoopbackListener: @unchecked Sendable {
    struct Upload {
        let requestLine: String
        let userID: String?
        let events: [RecordingDiagnosticEvent]
    }

    private struct Payload: Decodable {
        let events: [RecordingDiagnosticEvent]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "RecordingDiagnosticTransportTests.loopback")
    private let lock = NSLock()
    private var received: Upload?
    private var connectionCount = 0
    private var byteCount = 0

    var boundary: String { lock.withLock { "\(connectionCount) connections; \(byteCount) bytes; parsed=\(received != nil)" } }

    var port: UInt16? {
        guard let port = listener.port?.rawValue, port != 0 else { return nil }
        return port
    }
    var upload: Upload? { lock.withLock { received } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.lock.withLock { self.connectionCount += 1 }
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }

    func cancel() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            self.lock.withLock { self.byteCount += data.count }
            let message = buffered + data
            if let upload = self.parse(message) {
                self.lock.withLock { self.received = upload }
                let receipt = try! JSONEncoder().encode(["accepted_ids": upload.events.map(\.eventId)])
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(receipt.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(headers.utf8) + receipt, completion: .contentProcessed { _ in connection.cancel() })
            } else if done || message.count > 300_000 {
                connection.cancel()
            } else {
                self.receive(connection, buffered: message)
            }
        }
    }

    private func parse(_ message: Data) -> Upload? {
        guard let split = message.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: message[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let fields = lines.dropFirst().reduce(into: [String: String]()) { fields, line in
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                fields[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let requestLine = lines.first, let length = fields["content-length"].flatMap(Int.init),
              length == message.count - split.upperBound,
              let payload = try? RecordingDiagnosticEvent.decoder().decode(Payload.self, from: message[split.upperBound...])
        else { return nil }
        return Upload(requestLine: requestLine, userID: fields["x-user-id"], events: payload.events)
    }
}
