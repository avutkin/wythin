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

    func testCloudActivityRestorePreservesRecordedZoneAndLegacyUnknown() throws {
        let ctx = try freshContext()
        let json = """
        [{"id":"00000000-0000-4000-8000-000000000001","activity_type":"Walk","started_at":"2026-11-11T19:30:00Z","ended_at":"2026-11-11T20:00:00Z","is_manual":false,"timezone":"Asia/Dubai"},
         {"id":"00000000-0000-4000-8000-000000000002","activity_type":"Walk","started_at":"2026-11-12T19:30:00Z","ended_at":"2026-11-12T20:00:00Z","is_manual":false}]
        """
        let rows = try JSONDecoder().decode([ActivityUploadPayload].self, from: Data(json.utf8))
        XCTAssertEqual(CloudRestoreService.insert(rows, into: ctx), 2)
        let logs = try ctx.fetch(FetchDescriptor<ActivityLog>(sortBy: [SortDescriptor(\.startedAt)]))
        XCTAssertEqual(ActivityUploadPayload(from: logs[0]).timezone, "Asia/Dubai")
        XCTAssertNil(ActivityUploadPayload(from: logs[1]).timezone)
    }

    func testMetricExportRoundTripKeepsRecordedZone() throws {
        let wire = Data(#"{"ts":"2026-11-11T19:30:00Z","timezone":"Asia/Dubai"}"#.utf8)
        let row = try JSONDecoder().decode(MetricExportSample.self, from: wire)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        XCTAssertEqual(decoded["timezone"] as? String, "Asia/Dubai")
        let context = try freshContext()
        XCTAssertEqual(CloudRestoreService.insert([row, sample("2026-11-11T19:31:00Z")], into: context), 2)
        let stored = try context.fetch(FetchDescriptor<HRVSample>(sortBy: [SortDescriptor(\.timestamp)]))
        XCTAssertEqual(stored[0].timezone, "Asia/Dubai")
        XCTAssertEqual(MetricsHistoryPoint(from: stored[0]).timezone, "Asia/Dubai")
        XCTAssertNil(stored[1].timezone)
        XCTAssertNil(MetricsHistoryPoint(from: stored[1]).timezone)
    }

    func testRestoreCanFillVerifiedZoneOnExistingUnknownSampleWithoutOverwritingKnownZone() throws {
        let context = try freshContext()
        let timestamp = try XCTUnwrap(CloudRestoreService.date("2026-11-11T19:30:00Z"))
        context.insert(HRVSample(anchorTestTimestamp: timestamp, meanBPM: 62))
        try context.save()
        func wire(_ zone: String?) throws -> MetricExportSample {
            let data = try JSONSerialization.data(withJSONObject: ["ts": "2026-11-11T19:30:00Z", "timezone": zone as Any? ?? NSNull()])
            return try JSONDecoder().decode(MetricExportSample.self, from: data)
        }
        XCTAssertEqual(CloudRestoreService.insert([try wire("Asia/Dubai")], into: context), 0)
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<HRVSample>()).first)
        XCTAssertEqual(stored.timezone, "Asia/Dubai")
        XCTAssertEqual(CloudRestoreService.insert([try wire(nil), try wire("Europe/Moscow")], into: context), 0)
        XCTAssertEqual(stored.timezone, "Asia/Dubai")
        XCTAssertEqual(stored.timestamp, timestamp)
    }

    func testRestoreFillsOnlyMissingZoneOnExistingActivity() throws {
        let context = try freshContext()
        let log = ActivityLog(activityType: "Walk", startedAt: .now, timezone: nil)
        log.endedAt = .now
        context.insert(log)
        try context.save()
        let data = try JSONSerialization.data(withJSONObject: ["id": log.id.uuidString, "activity_type": "Walk", "started_at": "2026-11-11T19:30:00Z", "ended_at": "2026-11-11T20:00:00Z", "is_manual": false, "timezone": "Asia/Dubai"])
        let row = try JSONDecoder().decode(ActivityUploadPayload.self, from: data)
        XCTAssertEqual(CloudRestoreService.insert([row], into: context), 0)
        XCTAssertEqual(log.timezone, "Asia/Dubai")
        XCTAssertEqual(CloudRestoreService.insert([activity(id: log.id.uuidString, endedAt: "2026-11-11T20:00:00Z")], into: context), 0)
        XCTAssertEqual(log.timezone, "Asia/Dubai")
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

    func testPartialRestoreDoesNotDuplicateLocallyRecordedSubmillisecondSample() throws {
        let ctx = try freshContext()
        let rounded = try XCTUnwrap(CloudRestoreService.date("2026-07-27T10:00:00.123Z"))
        let local = rounded.addingTimeInterval(0.000456)
        ctx.insert(HRVSample(anchorTestTimestamp: local, meanBPM: 62))
        try ctx.save()

        // ISO8601DateFormatter uploads only milliseconds, while SwiftData
        // retains the original Date precision. A partial restore must match
        // the local point rather than insert a second copy of that tick.
        let imported = CloudRestoreService.insert(
            [sample("2026-07-27T10:00:00.123+00:00")], into: ctx)
        XCTAssertEqual(imported, 0)
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

private final class MetricSyncURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calls = 0
    nonisolated(unsafe) private static var failFirst = true
    nonisolated(unsafe) private static var payloads: [Data] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        calls = 0
        failFirst = true
        payloads = []
    }

    static func metricCalls() -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    static func metricPayloads() throws -> [MetricsUploadPayload] {
        lock.lock(); defer { lock.unlock() }
        return try payloads.map { try JSONDecoder().decode(MetricsUploadPayload.self, from: $0) }
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            body.append(contentsOf: buffer.prefix(n))
        }
        return body
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sync.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isMetrics = request.url?.path == "/v1/metrics"
        var shouldFail = false
        if isMetrics {
            Self.lock.lock()
            Self.payloads.append(requestBody())
            Self.calls += 1
            shouldFail = Self.failFirst
            Self.failFirst = false
            Self.lock.unlock()
        }
        let code = shouldFail ? 503 : 200
        // A gateway can preserve the response shape while returning 503.
        // The uploader must trust the HTTP status, not just decodable JSON.
        let body = Data("{\"stored\":2}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: code,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class MetricSyncBacklogTests: XCTestCase {
    func testFailedBatchRetriesAndThenDrainsEntireBacklog() async throws {
        let defaults = UserDefaults.standard
        let keys = ["cloudSyncEnabled", "metricsLastSyncedAt", "metricsLastSyncedEpoch",
                    "metricsLastUploadAtEpoch", "profileLastSynced"]
        let old = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, old) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "cloudSyncEnabled")
        for key in keys.dropFirst() { defaults.removeObject(forKey: key) }

        let container = try ModelContainer(for: HRVSession.self, HRVSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let zones: [String?] = ["Asia/Dubai", "Asia/Dubai", "Europe/Moscow", "Europe/Moscow", nil]
        for i in 0..<5 {
            context.insert(HRVSample(anchorTestTimestamp: start.addingTimeInterval(Double(i * 2)),
                                     meanBPM: 65, timezone: zones[i]))
        }
        try context.save()

        MetricSyncURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetricSyncURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = MetricSyncService(
            client: APIClient(baseURL: URL(string: "https://sync.invalid")!, session: session),
            userID: "test-device", container: container, batchSize: 2)

        await service.syncIfEnabled()
        XCTAssertEqual(MetricSyncURLProtocol.metricCalls(), 1)
        XCTAssertEqual(defaults.double(forKey: "metricsLastSyncedEpoch"), 0,
                       "a rejected batch must not advance the cursor")

        await service.syncIfEnabled()
        let sent = try MetricSyncURLProtocol.metricPayloads()
        XCTAssertEqual(sent[0].samples.map(\.timezone), ["Asia/Dubai", "Asia/Dubai"], "retry keeps the capture zone")
        XCTAssertEqual(sent.dropFirst().flatMap(\.samples).map(\.timezone), zones, "upload never stamps the current zone on stored samples")
        XCTAssertEqual(sent[0].samples.first?.ts, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(MetricSyncURLProtocol.metricCalls(), 4,
                       "five samples in batches of two need three successful requests")
        XCTAssertEqual(defaults.double(forKey: "metricsLastSyncedEpoch"),
                       start.addingTimeInterval(8).timeIntervalSince1970, accuracy: 0.001)
    }
}

@MainActor
final class MetricCapturePersistenceTests: XCTestCase {
    func testLiveTickSharesOneRecordedZoneBetweenHistoryAndPersistence() throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let tick = MetricsTick(timestamp: instant,
            meanBPM: nil, sdnn: nil, rmssd: nil, pnn50: nil, vti: nil,
            ulfPower: nil, vlfPower: nil, lfPower: nil, hfPower: nil, lfHF: nil,
            rsaMs: nil, rsaIdx: nil, breathBPM: nil, breathHz: nil, regularity: nil,
            coherenceScore: nil, cbi: nil, dfa1: nil, signalQuality: nil, ecgQuality: nil,
            rcmse: nil, pip: nil, ials: nil, dc: nil, breathPhases: nil,
            psdFreqs: nil, psdValues: nil, coherenceFreqs: nil, coherenceValues: nil)
        for zone in ["Asia/Dubai", "Europe/Moscow"] {
            let sample = HRVSample(from: tick, timezone: zone)
            let point = MetricsHistoryPoint(from: tick, timezone: zone)
            XCTAssertEqual(sample.timezone, zone)
            XCTAssertEqual(point.timezone, sample.timezone)
            XCTAssertEqual(MetricsHistoryPoint(from: sample).timezone, point.timezone)
            XCTAssertEqual(sample.timestamp, instant)
            XCTAssertEqual(point.timestamp, instant)
        }
        XCTAssertEqual(HRVSample(from: tick).timezone, TimeZone.autoupdatingCurrent.identifier)
        XCTAssertEqual(MetricsHistoryPoint(from: tick).timezone, TimeZone.autoupdatingCurrent.identifier)
    }

    func testAutomaticCapturePersistsWithoutAnUnboundedSessionRelationship() throws {
        let container = try ModelContainer(for: HRVSession.self, HRVSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for i in 0..<300 {
            try MetricSampleStore.persist(
                HRVSample(anchorTestTimestamp: start.addingTimeInterval(Double(i * 2)),
                          meanBPM: 65),
                session: nil, context: context)
        }

        let samples = try context.fetch(FetchDescriptor<HRVSample>(
            sortBy: [SortDescriptor(\.timestamp)]))
        XCTAssertEqual(samples.count, 300)
        XCTAssertEqual(samples.first?.timestamp, start)
        XCTAssertEqual(samples.last?.timestamp, start.addingTimeInterval(598))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRVSession>()), 0,
                       "continuous capture must not retain every tick in one auto-session")

        let explicit = HRVSession(startedAt: start.addingTimeInterval(600))
        context.insert(explicit)
        try MetricSampleStore.persist(
            HRVSample(anchorTestTimestamp: start.addingTimeInterval(602), meanBPM: 66),
            session: explicit, context: context)
        XCTAssertEqual(explicit.samples.count, 1,
                       "an explicitly started session still owns its sample")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRVSample>()), 301)
    }
}

@MainActor
final class StressBalancePersistenceTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: HRVSession.self, HRVSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func tick(rmssd: Float?, breath: Float?) -> MetricsTick {
        MetricsTick(timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            meanBPM: 60, sdnn: 50, rmssd: rmssd, pnn50: nil, vti: nil,
            ulfPower: nil, vlfPower: nil, lfPower: 9, hfPower: 1, lfHF: 9,
            rsaMs: nil, rsaIdx: nil, breathBPM: breath, breathHz: nil, regularity: nil,
            coherenceScore: nil, cbi: nil, dfa1: nil, signalQuality: nil, ecgQuality: nil,
            rcmse: nil, pip: nil, ials: nil, dc: nil, breathPhases: nil,
            psdFreqs: nil, psdValues: nil, coherenceFreqs: nil, coherenceValues: nil)
    }

    func testCapturePersistsTheSameDialAsLiveIncludingSpectralFallback() throws {
        for (rmssd, breath, expected): (Float?, Float?, Float?) in [(40, 6, 50), (nil, 14, 90), (nil, 6, nil)] {
            let reading = tick(rmssd: rmssd, breath: breath)
            let store = try container()
            let ctx = ModelContext(store)
            try MetricSampleStore.persist(HRVSample(from: reading), session: nil, context: ctx)
            let reloaded = try XCTUnwrap(ModelContext(store).fetch(FetchDescriptor<HRVSample>()).first)
            XCTAssertEqual(reloaded.stressBalance, expected)
            XCTAssertEqual(MetricsHistoryPoint(from: reading).stressBalance, expected)
            XCTAssertEqual(LiveMetric.stressBalance.value(MetricsHistoryPoint(from: reloaded)), expected)
        }
    }

    func testSavedSnapshotWinsOverRecomputationAndIsUploadedUnderItsOwnKey() throws {
        let sample = HRVSample(from: tick(rmssd: 40, breath: 6))
        sample.stressBalance = 17.5
        let history = MetricsHistoryPoint(from: sample)
        XCTAssertEqual(LiveMetric.stressBalance.value(history), 17.5)
        XCTAssertEqual(DailyRollupCompute.stressBalance(history), 17.5)
        XCTAssertEqual(NudgeSignals.balance(history), 17.5)
        XCTAssertEqual(metricDef(.stressBalance).extract(history), 17.5)
        let payload = MetricSamplePayload(from: sample)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(json["stress_balance"] as? Double, 17.5)
        XCTAssertEqual(json["lf_hf"] as? Double, 9)
        XCTAssertEqual(SamplePayload(from: sample).stressBalance, 17.5)
        let sessionJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SamplePayload(from: sample))) as? [String: Any])
        XCTAssertEqual(sessionJSON["stress_balance"] as? Double, 17.5)
        XCTAssertEqual(sessionJSON["mean_bpm"] as? Double, 60)
        XCTAssertEqual(sessionJSON["lf_hf"] as? Double, 9)
        let session = HRVSession(startedAt: sample.timestamp)
        session.samples.append(sample)
        let sessionWire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionPayload(from: session))) as? [String: Any])
        XCTAssertNotNil(sessionWire["started_at"])
        XCTAssertNil(sessionWire["startedAt"])
    }

    func testLegacyLocalSampleStillUploadsComputedDialWithoutInventingMissingData() throws {
        let sample = HRVSample(from: tick(rmssd: 40, breath: 6))
        sample.stressBalance = nil
        XCTAssertEqual(MetricSamplePayload(from: sample).stress_balance, 50)
        let missing = HRVSample(anchorTestTimestamp: .now, meanBPM: 60)
        XCTAssertNil(MetricSamplePayload(from: missing).stress_balance)
    }

    func testCloudRestorePreservesSnapshotAndFillsOnlyMissingValues() throws {
        let store = try container()
        let ctx = ModelContext(store)
        func wire(_ value: Float?) throws -> MetricExportSample {
            var object: [String: Any] = ["ts": "2026-11-16T10:00:00Z", "rmssd": 40, "lf_hf": 9]
            if let value { object["stress_balance"] = value }
            return try JSONDecoder().decode(MetricExportSample.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(CloudRestoreService.insert([try wire(17.5)], into: ctx), 1)
        try ctx.save()
        let sample = try XCTUnwrap(ctx.fetch(FetchDescriptor<HRVSample>()).first)
        XCTAssertEqual(sample.stressBalance, 17.5)
        XCTAssertEqual(MetricsHistoryPoint(from: sample).stressBalance, 17.5)
        XCTAssertEqual(CloudRestoreService.insert([try wire(nil), try wire(90)], into: ctx), 0)
        XCTAssertEqual(sample.stressBalance, 17.5)
        sample.stressBalance = nil
        XCTAssertEqual(CloudRestoreService.insert([try wire(25)], into: ctx), 0)
        XCTAssertEqual(sample.stressBalance, 25)
        XCTAssertNil(try wire(nil).stress_balance)
    }
}
