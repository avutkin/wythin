import XCTest
import SwiftData
@testable import Wythin

final class CloudRestoreTests: XCTestCase {

    private func freshContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: HRVSample.self, ActivityLog.self, configurations: config)
        return ModelContext(container)
    }

    private func sample(_ ts: String, rmssd: Float? = 40) -> MetricExportSample {
        MetricExportSample(ts: ts, mean_bpm: 62, rmssd: rmssd, sdnn: nil, pnn50: nil,
                           lf_hf: 1.2, rsa_ms: 25, coherence: nil, cbi: nil,
                           breath_bpm: nil, dfa1: 1.0, rcmse: nil, pip: 40,
                           dc: 7.5, vti: 3.7)
    }

    // MARK: Timestamp parsing

    /// Server pages come back as isoformat with a numeric offset (with or
    /// without microseconds); the app's own uploads used "Z". All must parse,
    /// and to the same instant.
    func testParsesAllThreeServerTimestampShapes() {
        let z      = CloudRestoreService.date("2026-07-27T10:00:00Z")
        let offset = CloudRestoreService.date("2026-07-27T10:00:00+00:00")
        let frac   = CloudRestoreService.date("2026-07-27T10:00:00.500000+00:00")
        XCTAssertNotNil(z)
        XCTAssertEqual(z, offset)
        XCTAssertEqual(frac!.timeIntervalSince(z!), 0.5, accuracy: 0.001)
    }

    // MARK: Sample import

    func testImportMapsEveryFieldAndSkipsDuplicates() throws {
        let ctx = try freshContext()
        let inserted = CloudRestoreService.insert([sample("2026-07-27T10:00:00Z")], into: ctx)
        XCTAssertEqual(inserted, 1)

        let stored = try ctx.fetch(FetchDescriptor<HRVSample>()).first
        XCTAssertEqual(stored?.rmssd, 40)
        XCTAssertEqual(stored?.lfHF ?? 0, 1.2, accuracy: 0.001)
        XCTAssertEqual(stored?.rsaMs, 25)
        XCTAssertEqual(stored?.dc, 7.5)
        XCTAssertNil(stored?.motion)     // never synced → must stay nil

        // Re-import of the same page inserts nothing.
        let again = CloudRestoreService.insert([sample("2026-07-27T10:00:00Z")], into: ctx)
        XCTAssertEqual(again, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<HRVSample>()).count, 1)
    }

    // MARK: Activity import

    private func activity(id: String, endedAt: String?, isManual: Bool = false) -> ActivityUploadPayload {
        // Codable round-trip is the only public way to build the payload in
        // tests without adding a test-only initializer to production code.
        let json = """
        {"id":"\(id)","activity_type":"Walk","started_at":"2026-07-27T10:00:00Z",
         \(endedAt.map { "\"ended_at\":\"\($0)\"," } ?? "")
         "is_manual":\(isManual),"during_rmssd":44.0}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(ActivityUploadPayload.self, from: json)
    }

    func testActivityImportRestoresByIdAndSkipsExisting() throws {
        let ctx = try freshContext()
        let id  = UUID().uuidString
        let n = CloudRestoreService.insert(
            [activity(id: id, endedAt: "2026-07-27T10:30:00Z")], into: ctx)
        XCTAssertEqual(n, 1)
        let log = try ctx.fetch(FetchDescriptor<ActivityLog>()).first
        XCTAssertEqual(log?.id.uuidString, id)
        XCTAssertEqual(log?.duringRMSSD, 44.0)
        XCTAssertNotNil(log?.endedAt)

        let again = CloudRestoreService.insert(
            [activity(id: id, endedAt: "2026-07-27T10:30:00Z")], into: ctx)
        XCTAssertEqual(again, 0)
    }

    /// An unended, non-manual server row must not be resurrected — it would
    /// read as "recording now" and pin a live banner to a dead session.
    func testUnendedNonManualActivityIsNotRestored() throws {
        let ctx = try freshContext()
        let n = CloudRestoreService.insert(
            [activity(id: UUID().uuidString, endedAt: nil)], into: ctx)
        XCTAssertEqual(n, 0)
    }
}
