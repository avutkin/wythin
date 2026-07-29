import XCTest
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
}
