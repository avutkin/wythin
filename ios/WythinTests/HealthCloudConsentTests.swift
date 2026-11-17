import Foundation
import XCTest
@testable import Wythin

/// These tests exercise request consent while the simulator app is unsigned.
/// Keychain capability itself is verified on the signed-device checklist.
private final class HealthConsentCredentials: HealthCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: HealthEnrollment?
    func load(server: URL) throws -> HealthEnrollment? { lock.withLock { identity } }
    func save(_ enrollment: HealthEnrollment, server: URL) throws { lock.withLock { identity = enrollment } }
    func remove(server: URL) throws { lock.withLock { identity = nil } }
}

private actor HealthConsentRequestGate {
    private let entered: XCTestExpectation
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) { self.entered = entered }

    func wait() async {
        entered.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class HealthConsentEmptySource: HealthSource, Sendable {
    let available = true
    func requestAuthorization() async throws {}
    func workoutPage(anchor: Data?) async throws -> HealthWorkoutPage {
        HealthWorkoutPage(workouts: [], deletedIDs: [], nextAnchor: Data([1]), hasMore: false)
    }
    func samplePage(metric: HealthMetric, anchor: Data?) async throws -> HealthSamplePage {
        HealthSamplePage(samples: [], deletedIDs: [], nextAnchor: Data([1]), hasMore: false)
    }
    func samples(metric: HealthMetric, start: Date, end: Date) async throws -> [HealthSample] { [] }
    func startObserving(onChange: @escaping @Sendable () async -> Void) {}
    func stopObserving() {}
}

private actor HealthConsentCloud: HealthCloudTransport {
    struct Calls: Sendable {
        var enrollments = 0
        var connections = 0
        var restores = 0
        var batchSizes: [Int] = []
    }
    private enum UnexpectedRequest: Error { case detail, purge, pause }
    private let connectionID = UUID()
    private let connectGate: HealthConsentRequestGate?
    private let firstSendGate: HealthConsentRequestGate?
    private var calls = Calls()

    init(connectGate: HealthConsentRequestGate? = nil, firstSendGate: HealthConsentRequestGate? = nil) {
        self.connectGate = connectGate
        self.firstSendGate = firstSendGate
    }

    func recordedCalls() -> Calls { calls }

    func enroll() async throws -> HealthEnrollment {
        calls.enrollments += 1
        return HealthEnrollment(installationId: UUID(), credential: "synthetic-health-consent-test-secret")
    }

    func connect(streamId: UUID, credential: String) async throws -> HealthConnectionResponse {
        calls.connections += 1
        if let connectGate { await connectGate.wait() }
        return HealthConnectionResponse(connectionId: connectionID, connectionEpoch: 1,
                                        expectedSequence: calls.batchSizes.count + 1)
    }

    func restore(cursor: String?, credential: String) async throws -> HealthRestorePage {
        calls.restores += 1
        return HealthRestorePage(items: [], nextCursor: "saved-watermark", hasMore: false)
    }

    func send(batch: Data, credential: String) async throws -> HealthBatchAck {
        struct Envelope: Decodable {
            struct Change: Decodable { var operationId: UUID }
            var batchId: UUID
            var sequence: Int
            var connectionEpoch: Int
            var changes: [Change]
        }
        let envelope = try HealthCoding.decode(Envelope.self, from: batch)
        calls.batchSizes.append(envelope.changes.count)
        if calls.batchSizes.count == 1, let firstSendGate { await firstSendGate.wait() }
        return HealthBatchAck(batchId: envelope.batchId, sequence: envelope.sequence,
                              connectionEpoch: envelope.connectionEpoch, serverRevision: envelope.sequence)
    }

    func detail(externalId: UUID, credential: String, cursor: String?) async throws -> HealthRestoreDetail {
        throw UnexpectedRequest.detail
    }
    func purge(epoch: Int, credential: String) async throws -> Int { throw UnexpectedRequest.purge }
    func pause(connectionId: UUID, credential: String) async throws { throw UnexpectedRequest.pause }
}

final class HealthCloudConsentTests: XCTestCase {
    @MainActor
    func testTurningOffGlobalCloudDuringConnectPreventsRestoreAndUpload() async throws {
        try await withCloudEnvironment { server, repository in
            let workout = Self.workout()
            try await repository.applyWorkouts(HealthWorkoutPage(
                workouts: [workout], deletedIDs: [], nextAnchor: nil, hasMore: false))
            let entered = self.expectation(description: "Connection request is waiting")
            let gate = HealthConsentRequestGate(entered: entered)
            let cloud = HealthConsentCloud(connectGate: gate)
            let credentials = HealthConsentCredentials()
            let service = HealthSyncCoordinator(source: HealthConsentEmptySource(), repository: repository, cloud: cloud, credentialStore: credentials)
            let synchronization = Task { await service.synchronize() }

            // The real coordinator enrolls and persists its secret before connect.
            // A timeout fails rather than hanging if that prerequisite fails.
            await self.fulfillment(of: [entered], timeout: 10)
            UserDefaults.standard.set(false, forKey: "cloudSyncEnabled")
            await gate.release()
            await synchronization.value

            let calls = await cloud.recordedCalls()
            XCTAssertEqual(calls.enrollments, 1)
            XCTAssertEqual(calls.connections, 1)
            XCTAssertEqual(calls.restores, 0, "Consent must be checked after the awaited connection response")
            XCTAssertTrue(calls.batchSizes.isEmpty)
            XCTAssertNotNil(try credentials.load(server: server))
            XCTAssertNil(service.lastError)
            let pending = try await repository.pendingCount()
            XCTAssertGreaterThan(pending, 0, "Turning off cloud must preserve the queued local workout")
        }
    }

    @MainActor
    func testTurningOffGlobalCloudDuringFirstUploadLeavesNextBatchQueued() async throws {
        try await withCloudEnvironment { _, repository in
            let workout = Self.workout()
            try await repository.applyWorkouts(HealthWorkoutPage(
                workouts: [workout], deletedIDs: [], nextAnchor: nil, hasMore: false))
            // One workout plus separate note revisions guarantees more than the
            // 200-change batch bound without hundreds of context-query jobs.
            for index in 0..<201 {
                try await repository.annotate(workout.id, title: nil, notes: "Saved note revision \(index)")
            }
            let initialPending = try await repository.pendingCount()
            XCTAssertGreaterThan(initialPending, 200)
            let entered = self.expectation(description: "First upload is waiting")
            let gate = HealthConsentRequestGate(entered: entered)
            let cloud = HealthConsentCloud(firstSendGate: gate)
            let service = HealthSyncCoordinator(source: HealthConsentEmptySource(), repository: repository, cloud: cloud, credentialStore: HealthConsentCredentials())
            let synchronization = Task { await service.synchronize() }

            await self.fulfillment(of: [entered], timeout: 10)
            let pendingAtFirstSend = try await repository.pendingCount()
            UserDefaults.standard.set(false, forKey: "cloudSyncEnabled")
            await gate.release()
            await synchronization.value

            let calls = await cloud.recordedCalls()
            XCTAssertEqual(calls.restores, 1)
            XCTAssertEqual(calls.batchSizes, [200], "No second upload may begin after global consent is withdrawn")
            XCTAssertNil(service.lastError)
            let pending = try await repository.pendingCount()
            XCTAssertEqual(pending, pendingAtFirstSend - 200, "Only the already-sent batch may be acknowledged")
            XCTAssertGreaterThan(pending, 0)
            let state = try await repository.state()
            XCTAssertEqual(state.nextSequence, 2)
        }
    }

    @MainActor
    private func withCloudEnvironment(_ body: (URL, HealthRepository) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let oldServer = defaults.object(forKey: "serverURL")
        let oldCloud = defaults.object(forKey: "cloudSyncEnabled")
        let server = URL(string: "https://health-consent-\(UUID().uuidString.lowercased()).example.test")!
        defaults.set(server.absoluteString, forKey: "serverURL")
        defaults.set(true, forKey: "cloudSyncEnabled")
        defer {
            try? HealthCredentialStore().remove(server: server)
            defaults.set(oldServer, forKey: "serverURL")
            defaults.set(oldCloud, forKey: "cloudSyncEnabled")
        }
        let repository = try HealthRepository(inMemory: true)
        try await repository.setEnabled(true)
        try await repository.setCloudConsent(true, server: server.absoluteString)
        try await body(server, repository)
    }

    private static func workout() -> HealthWorkout {
        HealthWorkout(id: UUID(), activityCode: 37, activityName: "Running",
                      startedAt: Date(timeIntervalSince1970: 10_000),
                      endedAt: Date(timeIntervalSince1970: 10_600), activeDurationSeconds: 600,
                      source: HealthSourceInfo(bundleIdentifier: "test.synthetic", name: "Synthetic watch"))
    }
}
