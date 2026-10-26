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

    private func sample(_ ts: String, rmssd: Float? = 40,
                        motion: Float? = nil, ecgQualityTier: Int? = nil) -> MetricExportSample {
        MetricExportSample(ts: ts, mean_bpm: 62, rmssd: rmssd, sdnn: nil, pnn50: nil,
                           lf_hf: 1.2, rsa_ms: 25, coherence: nil, cbi: nil,
                           breath_bpm: nil, dfa1: 1.0, rcmse: nil, pip: 40,
                           dc: 7.5, vti: 3.7, motion: motion,
                           signal_quality: nil, rr_invalid_rate: nil, ecg_quality_tier: ecgQualityTier)
    }

    /// A restored night has to carry motion, or it scores differently from the
    /// night the device recorded — every gate in the sleep pipeline is relative
    /// to it. A page written before motion was carried decodes with nil.
    func testRestoredSamplesCarryMotion() throws {
        let json = """
        {"samples": [
          {"ts": "2026-09-06T04:00:00Z", "mean_bpm": 57, "motion": 3.9},
          {"ts": "2026-09-06T04:00:30Z", "mean_bpm": 58}
        ], "next_cursor": null}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(MetricExportPage.self, from: json)
        XCTAssertEqual(page.samples.count, 2)
        XCTAssertEqual(page.samples[0].motion ?? -1, 3.9, accuracy: 0.001)
        XCTAssertNil(page.samples[1].motion, "a page written before motion was carried still decodes")
    }

    /// 2026-10-24: a night read 160 bpm with RMSSD 150 ms for ten hours, and
    /// there was no way from the server side to tell "bad strap contact" from
    /// "an unusually active night" — the on-device quality read never left
    /// the phone. It has to restore the same way motion does.
    func testRestoredSamplesCarrySignalQuality() throws {
        let json = """
        {"samples": [
          {"ts": "2026-10-24T04:00:00Z", "mean_bpm": 58,
           "signal_quality": 0.95, "rr_invalid_rate": 0.02, "ecg_quality_tier": 2},
          {"ts": "2026-10-24T08:00:00Z", "mean_bpm": 60}
        ], "next_cursor": null}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(MetricExportPage.self, from: json)
        XCTAssertEqual(page.samples[0].ecg_quality_tier, 2)
        XCTAssertEqual(page.samples[0].rr_invalid_rate ?? -1, 0.02, accuracy: 0.001)
        XCTAssertNil(page.samples[1].ecg_quality_tier, "a page written before quality was carried still decodes")
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

    /// Carried the same way motion is: present when the export page has it,
    /// nil on a page written before it existed.
    func testImportCarriesTheQualityTier() throws {
        let ctx = try freshContext()
        _ = CloudRestoreService.insert([sample("2026-07-27T10:00:00Z", ecgQualityTier: 0)], into: ctx)
        let stored = try ctx.fetch(FetchDescriptor<HRVSample>()).first
        XCTAssertEqual(stored?.ecgQualityTier, 0)
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
