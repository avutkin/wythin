import XCTest
import SwiftData
@testable import Wythin

final class HealthRepositoryTests: XCTestCase {
    let source = HealthSourceInfo(bundleIdentifier: "test", name: "Watch")
    var workout: HealthWorkout { HealthWorkout(id: UUID(), activityCode: 37, activityName: "Running", startedAt: Date(timeIntervalSince1970: 10000), endedAt: Date(timeIntervalSince1970: 10600), activeDurationSeconds: 600, source: source) }

    func testDeletingUnimportedWorkoutsDoesNotRepeatedlyDecodeSavedHistory() async throws {
        let store = try await Task.detached { try HealthRepository(inMemory: true) }.value
        let kept = workout
        try await store.applyWorkouts(.init(workouts: [kept], deletedIDs: [], nextAnchor: nil, hasMore: false))
        try await store.seedDeletionHistory(workout: kept, count: 800)
        let deletedIDs = (0..<24).map { _ in UUID() }
        let start = ContinuousClock.now
        try await store.applyWorkouts(.init(workouts: [], deletedIDs: deletedIDs,
                                            nextAnchor: Data([7]), hasMore: false))
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1), "Unknown HealthKit deletions must not rescan the entire sample archive per ID")
        let samples = try await store.samples(for: kept)
        let state = try await store.state()
        XCTAssertEqual(samples.count, 800)
        XCTAssertEqual(state.anchors["workouts"], Data([7]))
    }

    func testBusyHealthRepositoryDoesNotBlockMainActorWhenAnotherCallIsQueued() async throws {
        let store = try await Task.detached { try HealthRepository(inMemory: true) }.value
        let entered = expectation(description: "Repository is busy")
        let requesting = expectation(description: "Main actor requests state")
        let gate = DispatchSemaphore(value: 0)
        let busy = Task.detached { await store.holdForResponsivenessTest(gate: gate, entered: entered) }
        await fulfillment(of: [entered], timeout: 2)
        let release = Task.detached {
            try? await Task.sleep(for: .seconds(1))
            gate.signal()
        }
        let request = Task { @MainActor in
            requesting.fulfill()
            return try await store.state()
        }
        await fulfillment(of: [requesting], timeout: 2)
        let start = ContinuousClock.now
        await MainActor.run {}
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300),
                          "Awaiting Health storage must yield the UI while existing storage work drains")
        await release.value
        await busy.value
        _ = try await request.value
    }

    func testBatchWorkoutDeletionCrossesPagesAndPreservesSharedSamplesOnReplay() async throws {
        let store = try HealthRepository(inMemory: true)
        let first = workout, second = workout, kept = workout
        try await store.applyWorkouts(.init(workouts: [first, second, kept], deletedIDs: [],
                                            nextAnchor: nil, hasMore: false))
        try await store.seedDeletionHistory(workout: first, count: 300, sharedWith: kept.id)
        try await store.seedDeletionHistory(workout: second, count: 300, sharedWith: kept.id)
        let before = try await store.samples(for: kept)
        let retainedIDs = Set(before.filter { $0.workoutIds.contains(kept.id) }.map(\.id))
        XCTAssertEqual(retainedIDs.count, 300)
        let queueBefore = try await store.pendingCount()
        let page = HealthWorkoutPage(workouts: [], deletedIDs: [first.id, second.id, first.id],
                                     nextAnchor: Data([8]), hasMore: false)
        try await store.applyWorkouts(page)
        try await store.applyWorkouts(page)
        let entries = try await store.entries()
        let after = try await store.samples(for: kept)
        let state = try await store.state()
        let queueAfter = try await store.pendingCount()
        XCTAssertEqual(entries.map(\.workout.id), [kept.id])
        XCTAssertEqual(Set(after.map(\.id)), retainedIDs)
        XCTAssertTrue(after.allSatisfy { $0.workoutIds == [kept.id] && $0.value == 70 })
        XCTAssertEqual(queueAfter, queueBefore + 2, "Each deletion is queued once across duplicates/replay")
        XCTAssertEqual(state.anchors["workouts"], Data([8]))
    }

    func testDeletingUnknownWorkoutCleansLinksFromRestoredSharedSamples() async throws {
        let store = try HealthRepository(inMemory: true), kept = workout, absent = UUID(), job = UUID()
        try await store.mergeRestored([snapshot(kept, revision: 1)], cursor: "one")
        let sample = HealthSample(id: UUID(), metric: .heartRate, value: 70,
            startedAt: kept.startedAt, endedAt: kept.startedAt, source: source,
            workoutIds: [kept.id, absent])
        var payload = try JSONSerialization.jsonObject(with: HealthCoding.encode(sample)) as! [String: Any]
        payload["external_id"] = sample.id.uuidString
        _ = try await store.stageCloudSamples([JSONSerialization.data(withJSONObject: payload)], job: job)
        try await store.publishCloudSamples(job: job, workoutId: kept.id, epoch: 1)
        try await store.applyWorkouts(.init(workouts: [], deletedIDs: [absent], nextAnchor: nil, hasMore: false))
        let retained = try await store.samples(for: kept)
        XCTAssertEqual(retained.first?.workoutIds, [kept.id])
        try await store.hideWorkout(kept.id)
        let remaining = try await store.samples(for: kept)
        XCTAssertTrue(remaining.isEmpty, "Deleted remote workout links must not keep orphan measurements")
    }
    func testReplayPreservesOneWorkoutAndPersistentAnchor() async throws {
        let store = try HealthRepository(inMemory: true)
        let w = workout
        let page = HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: Data([1,2]), hasMore: false)
        try await store.applyWorkouts(page)
        try await store.applyWorkouts(page)
        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1)
        let state = try await store.state()
        XCTAssertEqual(state.anchors["workouts"], Data([1,2]))
        let pending = try await store.pendingCount()
        XCTAssertEqual(pending, 1)
    }
    func testLateSampleUpdatesOldWorkoutAndDeletionRemovesMeasurement() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: nil, hasMore: false))
        let s = HealthSample(id: UUID(), metric: .heartRate, value: 123, startedAt: w.startedAt, endedAt: w.startedAt, source: source)
        try await store.applySamples(HealthSamplePage(samples: [s], deletedIDs: [], nextAnchor: nil, hasMore: false), metric: .heartRate)
        try await store.refreshAnalyses(now: w.endedAt.addingTimeInterval(1000))
        var entries = try await store.entries()
        XCTAssertEqual(entries.first?.analysis?.statistics.first?.mean, 123)
        try await store.applySamples(HealthSamplePage(samples: [], deletedIDs: [s.id], nextAnchor: nil, hasMore: false), metric: .heartRate)
        try await store.refreshAnalyses(now: w.endedAt.addingTimeInterval(1000))
        entries = try await store.entries()
        XCTAssertEqual(entries.first?.analysis?.status, "no_data")
    }
    func testDeletedWorkoutDoesNotResurrectOnReplayAndPurgeStopsReading() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: nil, hasMore: false))
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [], deletedIDs: [w.id], nextAnchor: nil, hasMore: false))
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: nil, hasMore: false))
        let entries = try await store.entries()
        XCTAssertTrue(entries.isEmpty)
        try await store.beginPurge()
        let state = try await store.state()
        XCTAssertFalse(state.enabled)
        XCTAssertFalse(state.cloudConsent)
        XCTAssertTrue(state.pendingPurge)
        let pending = try await store.pendingCount()
        XCTAssertEqual(pending, 0)
    }
    func testFrozenBatchSurvivesReopenAndAckCannotEraseNewerEdits() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "health-\(UUID())/health.store")
        let w = workout
        var store: HealthRepository? = try HealthRepository(url: url)
        try await store!.setEnabled(true)
        try await store!.setCloudConsent(true, server: "https://example.test")
        try await store!.bindConnection(id: UUID(), epoch: 1, expectedSequence: 1)
        try await store!.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: Data([3]), hasMore: false))
        let first = try await store!.prepareBatch()
        store = nil
        let reopened = try HealthRepository(url: url)
        let retry = try await reopened.prepareBatch()
        XCTAssertEqual(first, retry)
        try await reopened.annotate(w.id, title: nil, notes: "new note")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(first)) as! [String: Any]
        try await reopened.acknowledge(batchId: UUID(uuidString: body["batch_id"] as! String)!, sequence: 1, epoch: 1, serverRevision: 1)
        let pending = try await reopened.pendingCount()
        XCTAssertEqual(pending, 1)
        let entry = try await reopened.entry(w.id)
        XCTAssertEqual(entry?.notes, "new note")
    }
    func testNoCloudBatchWithoutBothConsentAndEnabledConnection() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: nil, hasMore: false))
        try await store.bindConnection(id: UUID(), epoch: 1, expectedSequence: 1)
        var batch = try await store.prepareBatch(); XCTAssertNil(batch)
        try await store.setEnabled(true)
        batch = try await store.prepareBatch(); XCTAssertNil(batch)
        try await store.setCloudConsent(true, server: "https://example.test")
        batch = try await store.prepareBatch(); XCTAssertNotNil(batch)
        try await store.beginPurge()
        batch = try await store.prepareBatch(); XCTAssertNil(batch)
    }
    func testInvalidPageRollsBackRecordsAnchorAndOutbox() async throws {
        let store = try HealthRepository(inMemory: true), good = workout
        var bad = workout; bad.endedAt = bad.startedAt.addingTimeInterval(-1)
        do {
            try await store.applyWorkouts(HealthWorkoutPage(workouts: [good,bad], deletedIDs: [], nextAnchor: Data([9]), hasMore: false))
            XCTFail("invalid workout accepted")
        } catch {}
        let entries = try await store.entries(), state = try await store.state(), count = try await store.pendingCount()
        XCTAssertTrue(entries.isEmpty); XCTAssertNil(state.anchors["workouts"]); XCTAssertEqual(count, 0)
    }
    func testInFlightReadCannotResurrectAfterPurgeEpoch() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.setEnabled(true)
        try await store.beginPurge(); try await store.finishPurge(epoch: 2); try await store.setEnabled(true)
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: Data([1]), hasMore: false), expectedEpoch: 1)
        let entries = try await store.entries(), state = try await store.state()
        XCTAssertTrue(entries.isEmpty); XCTAssertNil(state.anchors["workouts"])
    }
    private func snapshot(_ w: HealthWorkout, revision: Int, deleted: Bool = false) throws -> Data {
        var body = try JSONSerialization.jsonObject(with: HealthCoding.encode(w)) as! [String: Any]
        body.removeValue(forKey: "id")
        return try JSONSerialization.data(withJSONObject: ["external_id": w.id.uuidString, "activity_id": w.id.uuidString,
            "server_revision": revision, "deleted": deleted, "workout": deleted ? NSNull() as Any : body,
            "annotation": ["notes": "restored note"]])
    }
    private func acknowledgeAll(_ store: HealthRepository, revision: Int) async throws {
        while let data = try await store.prepareBatch() {
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try await store.acknowledge(batchId: UUID(uuidString: body["batch_id"] as! String)!, sequence: body["sequence"] as! Int, epoch: 1, serverRevision: revision)
        }
    }
    func testAcknowledgedReimportStillRestoresCloudAnnotationsAndCanonicalIdentity() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.setEnabled(true); try await store.setCloudConsent(true, server: "https://example.test")
        try await store.bindConnection(id: UUID(), epoch: 1, expectedSequence: 1)
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: nil, hasMore: false))
        try await acknowledgeAll(store, revision: 20)
        try await store.mergeRestored([snapshot(w, revision: 10)], cursor: "ten")
        let entry = try await store.entry(w.id)
        XCTAssertEqual(entry?.notes, "restored note"); XCTAssertEqual(entry?.activityId, w.id)
        try await store.mergeRestored([snapshot(w, revision: 11, deleted: true)], cursor: "eleven")
        let removed = try await store.entry(w.id); XCTAssertNil(removed)
    }
    func testUnknownDeletionIsQueuedAndCannotBeRestored() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [], deletedIDs: [w.id], nextAnchor: nil, hasMore: false))
        let count = try await store.pendingCount(); XCTAssertEqual(count, 1)
        try await store.mergeRestored([snapshot(w, revision: 10)], cursor: "ten")
        let entry = try await store.entry(w.id); XCTAssertNil(entry)
    }
    func testDeletionRemovesOnlyUnsharedSamples() async throws {
        let store = try HealthRepository(inMemory: true), first = workout
        var second = workout; second.startedAt = first.endedAt.addingTimeInterval(500); second.endedAt = second.startedAt.addingTimeInterval(600)
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [first, second], deletedIDs: [], nextAnchor: nil, hasMore: false))
        let privateSample = HealthSample(id: UUID(), metric: .heartRate, value: 100, startedAt: first.startedAt, endedAt: first.startedAt, source: source)
        let shared = HealthSample(id: UUID(), metric: .heartRate, value: 110, startedAt: second.startedAt, endedAt: second.startedAt, source: source)
        try await store.applySamples(HealthSamplePage(samples: [privateSample, shared], deletedIDs: [], nextAnchor: nil, hasMore: false), metric: .heartRate)
        try await store.hideWorkout(first.id)
        let samples = try await store.samples(for: first)
        XCTAssertEqual(samples.map(\.id), [shared.id]); XCTAssertEqual(samples.first?.workoutIds, [second.id])
    }
    func testInFlightRestoreCannotResurrectAfterPurge() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.setEnabled(true); try await store.setCloudConsent(true, server: "https://example.test")
        try await store.beginPurge()
        try await store.mergeRestored([snapshot(w, revision: 10)], cursor: "ten", expectedEpoch: 1)
        let entries = try await store.entries(), state = try await store.state()
        XCTAssertTrue(entries.isEmpty); XCTAssertNil(state.restoreCursor)
    }
    func testOversizedAnnotationCannotPoisonOutbox() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: nil, hasMore: false))
        let before = try await store.pendingCount()
        do { try await store.annotate(w.id, title: String(repeating: "x", count: 201), notes: nil); XCTFail("Accepted oversized title") } catch {}
        let after = try await store.pendingCount(), entry = try await store.entry(w.id)
        XCTAssertEqual(before, after); XCTAssertNil(entry?.title)
    }
    func testCloudOnlyDeletionKeepsLocalHistoryAndRebuildsOnlyAfterNewConsent() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.setEnabled(true); try await store.setCloudConsent(true, server: "https://example.test")
        try await store.bindConnection(id: UUID(), epoch: 1, expectedSequence: 1)
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: nil, hasMore: false))
        try await store.annotate(w.id, title: "My run", notes: "Keep me")
        try await acknowledgeAll(store, revision: 3)
        try await store.beginPurge(retainingLocal: true); try await store.finishPurge(epoch: 2)
        let kept = try await store.entry(w.id), empty = try await store.pendingCount(), s = try await store.state()
        XCTAssertEqual(kept?.notes, "Keep me"); XCTAssertEqual(empty, 0); XCTAssertTrue(s.enabled); XCTAssertFalse(s.cloudConsent)
        try await store.setCloudConsent(true, server: "https://example.test")
        let queued = try await store.pendingCount(); XCTAssertGreaterThanOrEqual(queued, 2)
    }
    func testReinstallKeepsSavedAnalysisWhenCurrentHealthReadIsEmpty() async throws {
        let store = try HealthRepository(inMemory: true), w = workout
        try await store.setEnabled(true); try await store.setCloudConsent(true, server: "https://example.test")
        try await store.bindConnection(id: UUID(), epoch: 1, expectedSequence: 1)
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: nil, hasMore: false))
        try await store.refreshAnalyses()
        let point = HealthSample(id: UUID(), metric: .heartRate, value: 120, startedAt: w.startedAt, endedAt: w.startedAt, source: source)
        var body = try JSONSerialization.jsonObject(with: snapshot(w, revision: 5)) as! [String: Any]
        body["analysis"] = try JSONSerialization.jsonObject(with: HealthCoding.encode(HealthAnalysis.compute(workout: w, samples: [point], now: w.endedAt.addingTimeInterval(100))))
        try await store.mergeRestored([JSONSerialization.data(withJSONObject: body)], cursor: "five")
        var latestPoint = point; latestPoint.value = 140
        body["server_revision"] = 10
        body["analysis"] = try JSONSerialization.jsonObject(with: HealthCoding.encode(HealthAnalysis.compute(workout: w, samples: [latestPoint], now: w.endedAt.addingTimeInterval(100))))
        try await store.mergeRestored([JSONSerialization.data(withJSONObject: body)], cursor: "ten")
        try await store.refreshAnalyses(now: w.endedAt.addingTimeInterval(2000))
        let restored = try await store.entry(w.id)
        XCTAssertEqual(restored?.analysis?.statistics.first?.mean, 140)
        let batch = try await store.prepareBatch()
        let wire = try JSONSerialization.jsonObject(with: XCTUnwrap(batch)) as! [String: Any]
        let analysis = (wire["changes"] as! [[String: Any]]).first { $0["operation"] as? String == "upsert_analysis" }?["analysis"] as? [String: Any]
        XCTAssertEqual((analysis?["statistics"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((analysis?["statistics"] as? [[String: Any]])?.first?["mean"] as? Double, 140)
        try await acknowledgeAll(store, revision: 11)
        var pointBody = try JSONSerialization.jsonObject(with: HealthCoding.encode(point)) as! [String: Any]
        pointBody["external_id"] = point.id.uuidString; pointBody["workout_ids"] = [w.id.uuidString]
        let job = UUID()
        _ = try await store.stageCloudSamples([JSONSerialization.data(withJSONObject: pointBody)], job: job)
        try await store.publishCloudSamples(job: job, workoutId: w.id, epoch: 1)
        let measurements = try await store.samples(for: w)
        XCTAssertEqual(measurements.map(\.value), [120])
    }
    func testOldDetailCannotPublishWhenNewNamespaceReusesEpoch() async throws {
        let store = try HealthRepository(inMemory: true), w = workout, job = UUID()
        try await store.beginPurge(); try await store.finishPurge(epoch: 2)
        try await store.setEnabled(true); try await store.setCloudConsent(true, server: "https://example.test")
        try await store.bindConnection(id: UUID(), epoch: 1, expectedSequence: 1)
        try await store.mergeRestored([snapshot(w, revision: 1)], cursor: "one")
        let point = HealthSample(id: UUID(), metric: .heartRate, value: 80, startedAt: w.startedAt, endedAt: w.startedAt, source: source)
        var body = try JSONSerialization.jsonObject(with: HealthCoding.encode(point)) as! [String: Any]
        body["external_id"] = point.id.uuidString
        _ = try await store.stageCloudSamples([JSONSerialization.data(withJSONObject: body)], job: job)
        try await store.publishCloudSamples(job: job, workoutId: w.id, epoch: 1, generation: nil)
        let samples = try await store.samples(for: w); XCTAssertTrue(samples.isEmpty)
    }
    func testSeriesBatchWireFixtureAndAck() async throws {
        let store = try HealthRepository(inMemory: true), w = workout, parent = UUID()
        try await store.setEnabled(true); try await store.setCloudConsent(true, server: "https://example.test")
        try await store.bindConnection(id: UUID(), epoch: 1, expectedSequence: 1)
        try await store.applyWorkouts(HealthWorkoutPage(workouts: [w], deletedIDs: [], nextAnchor: Data([5]), hasMore: false))
        let samples = (0..<3).map { index in HealthSample(id: HealthSample.childID(parent: parent, index: index), metric: .heartRate, value: Double(100 + index), startedAt: w.startedAt.addingTimeInterval(Double(index)), endedAt: w.startedAt.addingTimeInterval(Double(index)), source: source, parentId: parent, representation: .series) }
        try await store.applySamples(HealthSamplePage(samples: samples, deletedIDs: [], nextAnchor: nil, hasMore: false), metric: .heartRate)
        try await store.refreshAnalyses(); try await store.annotate(w.id, title: "Fixture", notes: "Synthetic only")
        let prepared = try await store.prepareBatch()
        let data = try XCTUnwrap(prepared)
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let changes = body["changes"] as! [[String: Any]]
        XCTAssertEqual(changes.compactMap { $0["operation"] as? String }, ["upsert_workout", "begin_series", "series_part", "commit_series", "upsert_analysis", "update_annotation"])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "HealthContractFixture.json"; attachment.lifetime = .keepAlways; add(attachment)
        try await acknowledgeAll(store, revision: 1)
        let count = try await store.pendingCount(); XCTAssertEqual(count, 0)
    }
}

private extension HealthRepository {
    func seedDeletionHistory(workout: HealthWorkout, count: Int, sharedWith: UUID? = nil) throws {
        for index in 0..<count {
            let time = workout.startedAt.addingTimeInterval(Double(index) / 2)
            var ids = [workout.id]
            if let sharedWith, index.isMultiple(of: 2) { ids.append(sharedWith) }
            let sample = HealthSample(id: UUID(), metric: .heartRate, value: 70,
                startedAt: time, endedAt: time, source: workout.source, workoutIds: ids)
            modelContext.insert(HealthStoredObject(kind: "sample", id: sample.id,
                start: time, end: time, payload: try HealthCoding.encode(sample)))
        }
        try modelContext.save()
    }

    func holdForResponsivenessTest(gate: DispatchSemaphore, entered: XCTestExpectation) {
        entered.fulfill()
        _ = gate.wait(timeout: .now() + 3)
    }
}
