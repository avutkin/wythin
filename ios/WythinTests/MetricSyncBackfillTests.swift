import XCTest
import SwiftData
@testable import Wythin

final class MetricSyncBackfillTests: XCTestCase {

    func testBackfillTriggersBelowCurrentSchemaVersion() {
        XCTAssertTrue(MetricSyncService.needsBackfill(storedVersion: 0),
                      "a device that never ran the widened payload must backfill")
        XCTAssertFalse(MetricSyncService.needsBackfill(storedVersion: MetricSyncService.currentSchemaVersion),
                       "an up-to-date device must not backfill again")
        XCTAssertFalse(MetricSyncService.needsBackfill(storedVersion: MetricSyncService.currentSchemaVersion + 1),
                       "a newer stored version must not trigger a downgrade backfill")
    }

    func testBackfillBatchIsLargerThanNormalBatch() {
        XCTAssertGreaterThan(MetricSyncService.backfillBatchSize, MetricSyncService.normalBatchSize)
        XCTAssertLessThanOrEqual(MetricSyncService.backfillBatchSize, 5000,
                                 "server rejects batches over its 5000-sample cap with 413")
    }

    // MARK: - Finding 1: a fetch error must not be treated as "drained"

    func testDrainActionTreatsFetchFailureAsRetryNotDrained() {
        let action = MetricSyncService.drainAction(for: .failed)
        XCTAssertTrue(action.stopLoop, "the loop must stop so the failed fetch doesn't spin")
        XCTAssertFalse(action.drained,
                        "a fetch error is not 'store is empty' — treating it as drained would permanently " +
                        "stamp the schema version and strand the device with un-backfilled rows")
    }

    func testDrainActionTreatsGenuinelyEmptyStoreAsDrained() {
        let action = MetricSyncService.drainAction(for: .empty)
        XCTAssertTrue(action.stopLoop)
        XCTAssertTrue(action.drained, "a genuinely empty fetch result means history is fully drained")
    }

    func testDrainActionContinuesOnSamples() {
        let sample = HRVSample(timestamp: .now)
        let action = MetricSyncService.drainAction(for: .samples([sample]))
        XCTAssertFalse(action.stopLoop)
        XCTAssertFalse(action.drained)
    }

    // MARK: - Finding 2: the watermark reset must fire exactly once per backfill

    func testWatermarkResetsOnlyOnTheFirstBackfillPass() {
        XCTAssertTrue(MetricSyncService.shouldResetWatermark(backfilling: true, backfillStarted: false),
                      "the very first pass of a new backfill must reset the watermark")
        XCTAssertFalse(MetricSyncService.shouldResetWatermark(backfilling: true, backfillStarted: true),
                       "a later pass of the SAME backfill (e.g. after an upload failure left it " +
                       "unstamped) must NOT reset again, or progress made so far is thrown away " +
                       "and the drain restarts from Date.distantPast every time")
    }

    func testWatermarkNeverResetsWhenNotBackfilling() {
        XCTAssertFalse(MetricSyncService.shouldResetWatermark(backfilling: false, backfillStarted: false))
        XCTAssertFalse(MetricSyncService.shouldResetWatermark(backfilling: false, backfillStarted: true))
    }
}

// MARK: - Integration coverage: syncIfEnabled resumes instead of restarting

/// Exercises the real `syncIfEnabled()` end to end against an in-memory
/// SwiftData store and a fake network client, to prove Finding 2's fix at the
/// behavioral level (not just the pure predicate above): a backfill that was
/// interrupted after advancing its watermark must, on the next pass, upload
/// only the rows after that watermark — never the whole history again.
@MainActor
final class MetricSyncBackfillIntegrationTests: XCTestCase {

    private struct StubError: Error {}

    private final class FakeUploadClient: MetricUploadClient {
        private(set) var uploadedBatches: [[MetricSamplePayload]] = []
        func uploadMetrics(_ payload: MetricsUploadPayload, userID: String) async throws -> MetricsUploadResponse {
            uploadedBatches.append(payload.samples)
            return MetricsUploadResponse(stored: payload.samples.count)
        }
        func uploadProfile(_ payload: ProfilePayload, userID: String) async throws {}
    }

    private func makeContainer() -> ModelContainer {
        let schema = Schema([HRVSample.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() {
        for key in ["metricsSyncSchemaVersion", "metricsBackfillStarted", "metricsLastSyncedAt", "cloudSyncEnabled"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testInterruptedBackfillResumesFromWatermarkInsteadOfRestarting() async {
        let iso = ISO8601DateFormatter()
        let watermark = Date(timeIntervalSince1970: 1_000_000)
        let alreadyUploaded = watermark.addingTimeInterval(-100)
        let stillPending = watermark.addingTimeInterval(100)

        // Simulate a backfill that already advanced partway before an upload
        // failure left the schema version unstamped: the watermark sits at
        // `watermark`, and the "a reset already happened" flag is set — this
        // is exactly the state MetricSyncService leaves behind after Finding
        // 2's failure path.
        UserDefaults.standard.set(true, forKey: "cloudSyncEnabled")
        UserDefaults.standard.set(0, forKey: "metricsSyncSchemaVersion")
        UserDefaults.standard.set(true, forKey: "metricsBackfillStarted")
        UserDefaults.standard.set(iso.string(from: watermark), forKey: "metricsLastSyncedAt")

        let container = makeContainer()
        let context = ModelContext(container)
        context.insert(HRVSample(timestamp: alreadyUploaded))
        context.insert(HRVSample(timestamp: stillPending))
        try! context.save()

        let fake = FakeUploadClient()
        let service = MetricSyncService(client: fake, userID: "u1", container: container)
        await service.syncIfEnabled()

        XCTAssertEqual(fake.uploadedBatches.count, 1)
        XCTAssertEqual(fake.uploadedBatches.first?.count, 1,
                        "resuming must only pick up rows after the saved watermark; if the watermark " +
                        "were reset to distantPast (the bug), the already-uploaded row would be sent again")
        XCTAssertEqual(fake.uploadedBatches.first?.first?.ts, iso.string(from: stillPending))
    }
}
