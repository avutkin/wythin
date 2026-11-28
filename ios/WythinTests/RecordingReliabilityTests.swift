import XCTest
import SwiftData
import UIKit
@testable import Wythin

final class RecordingReliabilityTests: XCTestCase {
    private func deliverySnapshot() -> DataSnapshot {
        DataSnapshot(ecg: [], accZ: [], accXYZ: [], rr: [800, 810], bpm: [75],
            recordingGeneration: 1, lastValidRRAt: Date(timeIntervalSince1970: 100), lastValidRRUptime: 100)
    }

    func testFailedPersistenceReportsErrorButFreshTickStillReachesLiveConsumers() {
        enum Failure: Error { case diskFull }
        let tick = MetricsEngine.compute(from: deliverySnapshot())
        var events: [String] = []
        MetricDelivery.deliver(tick, disposition: { .live }, persist: { _ in
            events.append("save"); throw Failure.diskFull
        }, saveFailed: { _ in events.append("error") },
        recordHistory: { _ in events.append("history") },
        publishLive: { _ in events.append("live") })
        XCTAssertEqual(events, ["save", "error", "history", "live"])
    }

    func testSlowSaveKeepsHistoricalPointButDoesNotPublishExpiredLiveValue() {
        let snapshot = deliverySnapshot()
        let tick = MetricsEngine.compute(from: snapshot)
        var uptime = 101.0
        var events: [String] = []
        MetricDelivery.deliver(tick, disposition: {
            MetricCompletionDisposition.decide(snapshot: snapshot, generation: 1, connected: true,
                admittedUptime: 101, completedUptime: uptime)
        }, persist: { _ in events.append("save"); uptime = 131 },
        saveFailed: { _ in XCTFail("unexpected failure") },
        recordHistory: { _ in events.append("history") },
        publishLive: { _ in events.append("live") })
        XCTAssertEqual(events, ["save", "history"])
    }

    func testRejectedCompletionHasNoPersistenceHistoryOrLiveEffects() {
        let tick = MetricsEngine.compute(from: deliverySnapshot())
        for reason in [MetricCompletionDisposition.Rejection.connection, .generation, .staleAdmission, .invalidClock] {
            MetricDelivery.deliver(tick, disposition: { .discard(reason) },
                persist: { _ in XCTFail("rejected result saved") },
                saveFailed: { _ in XCTFail("unexpected save attempt") },
                recordHistory: { _ in XCTFail("rejected result in chart") },
                publishLive: { _ in XCTFail("rejected result presented as live") })
        }
    }

    @MainActor
    func testDelayedBreathingCandidateIsNotPersistedAsTrackedRespiration() throws {
        var tracker = BreathRateTracker()
        for _ in 0..<8 { _ = tracker.update([.init(bpm: 14, confidence: 6)], dt: 2) }
        let candidate: Float = 28
        XCTAssertNotEqual(tracker.update([.init(bpm: candidate, confidence: 3)], dt: 2), candidate)
        var tick = MetricsEngine.compute(from: deliverySnapshot())
        tick.breathBPM = candidate
        tick.breathSource = .accelerometer
        tick.breathConfidence = 3
        let container = try ModelContainer(for: HRVSample.self, HRVSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        MetricDelivery.deliver(tick, disposition: { .historyOnly }, persist: { completed in
            try MetricSampleStore.persist(HRVSample(from: completed, timezone: "Australia/Sydney"),
                session: nil, context: container.mainContext)
        }, saveFailed: { _ in XCTFail("unexpected failure") }, recordHistory: { completed in
            XCTAssertNil(completed.breathBPM)
            XCTAssertNil(completed.breathSource)
        }, publishLive: { _ in XCTFail("delayed point cannot be live") })
        let row = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<HRVSample>()).first)
        XCTAssertNil(row.breathBPM)
        XCTAssertNil(row.breathSourceRaw)
    }

    @MainActor
    func testDelayedAdmittedMetricIsSavedAtCaptureTimeWithoutBecomingLive() throws {
        let captured = Date(timeIntervalSince1970: 1795821188) // Sydney 2026-11-28, UTC 2026-11-27
        let snapshot = DataSnapshot(ecg: [], accZ: [], accXYZ: [], rr: [800, 810], bpm: [75],
            recordingGeneration: 1, lastValidRRAt: captured, lastValidRRUptime: 100)
        let disposition = MetricCompletionDisposition.decide(snapshot: snapshot,
            generation: 1, connected: true, admittedUptime: 101, completedUptime: 131)
        XCTAssertTrue(disposition.shouldPersist)
        XCTAssertFalse(disposition.shouldPublishLive)
        XCTAssertEqual(disposition, .historyOnly)
        let container = try ModelContainer(for: HRVSample.self, HRVSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let tick = MetricsEngine.compute(from: snapshot)
        if disposition.shouldPersist {
            try MetricSampleStore.persist(HRVSample(from: tick, timezone: "Australia/Sydney"),
                session: nil, context: container.mainContext)
        }
        let rows = try container.mainContext.fetch(FetchDescriptor<HRVSample>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.timestamp, captured)
        XCTAssertEqual(rows.first?.timezone, "Australia/Sydney")
        XCTAssertEqual(rows.first?.cloudUploadState, 0)
    }

    func testMetricCompletionKeepsGenerationAndAdmissionFences() {
        let snapshot = DataSnapshot(ecg: [], accZ: [], accXYZ: [], rr: [800], bpm: [75],
            recordingGeneration: 1, lastValidRRAt: Date(timeIntervalSince1970: 100), lastValidRRUptime: 100)
        XCTAssertEqual(MetricCompletionDisposition.decide(snapshot: snapshot, generation: 1,
            connected: true, admittedUptime: 101, completedUptime: 102), .live)
        for (generation, connected, admitted, completed) in [
            (UInt64(2), true, 101.0, 131.0), (1, false, 101, 131),
            (1, true, 106, 131), (1, true, 99, 131), (1, true, 101, 100)
        ] {
            let result = MetricCompletionDisposition.decide(snapshot: snapshot, generation: generation,
                connected: connected, admittedUptime: admitted, completedUptime: completed)
            XCTAssertFalse(result.shouldPersist)
            XCTAssertFalse(result.shouldPublishLive)
        }
    }

    func testSelectivePMDResumeClearsOnlyInterruptedWaveforms() async {
        let buffer = DataBuffer()
        await buffer.appendRR([800, 810], generation: 1, uptime: 100)
        await buffer.appendECG([1], generation: 1, uptime: 100)
        await buffer.appendACC(xyz: [SIMD3(1, 2, 3)], generation: 1, uptime: 100)
        await buffer.appendECG([2], generation: 1, uptime: 106)
        await buffer.appendECG([9], generation: 1, uptime: 101)
        await buffer.appendACC(xyz: [SIMD3(4, 5, 6)], generation: 1, uptime: 106)
        let snapshot = await buffer.snapshot()
        XCTAssertEqual(snapshot.ecg, [2])
        XCTAssertEqual(snapshot.accZ, [6])
        XCTAssertEqual(snapshot.rr, [800, 810], "Repairing PMD must retain healthy RR")
    }

    func testComputedTimestampDescribesCapturedDataNotCompletionTime() {
        let captured = Date(timeIntervalSince1970: 100)
        let snapshot = DataSnapshot(ecg: [], accZ: [], accXYZ: [], rr: [800, 810], bpm: [75],
            recordingGeneration: 1, lastValidRRAt: captured, lastValidRRUptime: 100)
        XCTAssertEqual(MetricsEngine.compute(from: snapshot).timestamp, captured)
    }

    func testWallClockChangeDoesNotBlockFreshRR() async {
        let buffer = DataBuffer()
        await buffer.appendRR([800], generation: 1, at: Date(timeIntervalSince1970: 5000), uptime: 100)
        let accepted = await buffer.appendRR([810], generation: 1,
            at: Date(timeIntervalSince1970: 1000), uptime: 101)
        XCTAssertTrue(accepted)
        let snapshot = await buffer.snapshot()
        XCTAssertTrue(snapshot.isUsable(recordingGeneration: 1, uptime: 102))
        XCTAssertEqual(snapshot.rr, [800, 810])
    }

    func testLateFramesAndLateResetCannotEraseNewConnectionSamples() async {
        let buffer = DataBuffer()
        await buffer.appendRR([800], generation: 0)
        await buffer.appendRR([900], generation: 1)
        await buffer.clear(generation: 1)
        await buffer.appendRR([1200], generation: 0)
        await buffer.appendECG([55], generation: 0)
        let snapshot = await buffer.snapshot()
        XCTAssertEqual(snapshot.rr, [900])
        XCTAssertTrue(snapshot.ecg.isEmpty)
        XCTAssertEqual(snapshot.recordingGeneration, 1)
    }

    func testInvalidOrOlderRRDoesNotMakePreviousWindowFresh() async {
        let buffer = DataBuffer()
        let start = Date(timeIntervalSince1970: 100)
        let accepted = await buffer.appendRR([800], generation: 1, at: start, uptime: 100)
        let invalid = await buffer.appendRR([0, 299, 2001], generation: 1, at: start.addingTimeInterval(10), uptime: 110)
        let older = await buffer.appendRR([900], generation: 1, at: start.addingTimeInterval(-1), uptime: 99)
        XCTAssertTrue(accepted)
        XCTAssertFalse(invalid)
        XCTAssertFalse(older)
        let snapshot = await buffer.snapshot()
        XCTAssertEqual(snapshot.rr, [800])
        XCTAssertEqual(snapshot.lastValidRRAt, start)
        XCTAssertFalse(snapshot.isUsable(recordingGeneration: 1, uptime: 110))
    }

    func testResultSpanningGapIsRejectedEvenIfComputationFinishesLater() async {
        let buffer = DataBuffer()
        let now = Date(timeIntervalSince1970: 100)
        await buffer.appendRR([800, 810], generation: 1, at: now, uptime: 100)
        let computing = await buffer.snapshot()
        XCTAssertTrue(computing.isUsable(recordingGeneration: 1, uptime: 101))
        await buffer.clear(generation: 2)
        XCTAssertFalse(computing.isUsable(recordingGeneration: 2, uptime: 101))
        let cleared = await buffer.snapshot()
        XCTAssertFalse(cleared.isUsable(recordingGeneration: 2, uptime: 101))
    }

    func testAuditDistinguishesValidBeatsSavedSamplesAndWriteFailures() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audit = try CaptureAuditLog(directory: folder)
        let now = Date(timeIntervalSince1970: 100)
        audit.recordBLE(.hr, rrCount: 4, validRRCount: 1, at: now)
        audit.recordMetricSave(success: true, at: now.addingTimeInterval(1))
        audit.recordMetricSave(success: false, at: now.addingTimeInterval(2))
        let export = try audit.exportSnapshot()
        let text = String(decoding: export, as: UTF8.self)
        XCTAssertTrue(text.contains("\"validRRIntervals\":1"))
        XCTAssertTrue(text.contains("\"savedMetrics\":1"))
        XCTAssertTrue(text.contains("\"failedSaves\":1"))
        XCTAssertTrue(text.contains("\"lastValidRRAt\""))
        let reopened = try CaptureAuditLog(directory: folder)
        XCTAssertTrue(String(decoding: try reopened.exportSnapshot(), as: UTF8.self).contains("\"savedMetrics\":1"))
    }

    func testDiagnosticsIncludesAllStagesAndRedactsCredentials() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try RecordingDiagnostics.write(directory: folder,
            metadata: ["build": "150", "upload.pending": "3"],
            bluetooth: "RR recovery\nAuthorization: Bearer secret-token\nX-API-Key: private-key",
            capture: "{\"savedMetrics\":12}", captureError: nil)
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("upload.pending: 3"))
        XCTAssertTrue(body.contains("RR recovery"))
        XCTAssertTrue(body.contains("savedMetrics"))
        XCTAssertFalse(body.contains("secret-token"))
        XCTAssertFalse(body.contains("private-key"))
    }

    func testSydneyExportKeepsUTCAndMakesLocalDayAndOffsetExplicit() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-27T23:13:11Z"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try RecordingDiagnostics.write(directory: folder, metadata: [:],
            bluetooth: "2026-11-27T23:13:11Z BG TICK", capture: "{}", captureError: nil,
            at: date, timeZone: zone)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Exported: 2026-11-27T23:13:11Z"))
        XCTAssertTrue(text.contains("time.zone: Australia/Sydney"))
        XCTAssertTrue(text.contains("time.utcOffsetSeconds: 39600"))
        XCTAssertTrue(text.contains("time.exportedLocal: 2026-11-28T10:13:11+11:00"))
        XCTAssertTrue(text.contains("2026-11-27T23:13:11Z BG TICK"), "Original UTC events must not be rewritten")
    }

    func testSydneyDiagnosticOffsetFollowsBothDSTTransitions() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let fixtures = [
            ("2026-04-04T15:59:59Z", "2026-04-05T02:59:59+11:00", "39600"),
            ("2026-04-04T16:00:00Z", "2026-04-05T02:00:00+10:00", "36000"),
            ("2026-10-03T15:59:59Z", "2026-10-04T01:59:59+10:00", "36000"),
            ("2026-10-03T16:00:00Z", "2026-10-04T03:00:00+11:00", "39600")
        ]
        for (utc, local, offset) in fixtures {
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: utc))
            let context = RecordingDiagnostics.timeMetadata(at: date, timeZone: zone)
            XCTAssertEqual(context["time.exportedLocal"], local)
            XCTAssertEqual(context["time.utcOffsetSeconds"], offset)
        }
        let runtime = RecordingDiagnostics.runtimeMetadata(deviceUptime: 234842, recordingStartedUptime: 234314)
        XCTAssertEqual(runtime["device.uptimeSeconds"], "234842")
        XCTAssertEqual(runtime["recording.environmentUptimeSeconds"], "528")
        XCTAssertNil(runtime["app.uptimeSeconds"], "Device uptime must not masquerade as app lifetime")
    }

    func testDiagnosticsReportsMissingCaptureAndBoundsLogSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try RecordingDiagnostics.write(directory: folder, metadata: [:],
            bluetooth: String(repeating: "x", count: 1_000_000), capture: nil,
            captureError: "unavailable")
        let bytes = try Data(contentsOf: url)
        XCTAssertLessThan(bytes.count, 600_000)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Capture audit unavailable"))
    }
}

@MainActor
final class RecordingMemoryMonitorTests: XCTestCase {
    func testSamplingIsBoundedButWarningsBypassThrottleAndTrackObservedPeak() {
        var reads = 0
        var footprint: UInt64 = 200
        var lines: [String] = []
        let monitor = RecordingMemoryMonitor(read: {
            reads += 1
            return .init(footprintBytes: footprint, availableBytes: 400)
        }, output: { lines.append($0) })
        monitor.record(.launch, uptime: 100)
        monitor.record(.state, uptime: 115)
        XCTAssertEqual(reads, 1)
        footprint = 100
        monitor.record(.heartbeat, uptime: 160)
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(lines.last?.contains("footprint_bytes=100") == true)
        XCTAssertTrue(lines.last?.contains("observed_peak_bytes=200") == true)
        footprint = 300
        monitor.record(.memoryWarning, uptime: 161)
        monitor.record(.lifecycle, uptime: 162)
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(lines.last?.contains("reason=memory_warning") == true)
        XCTAssertTrue(lines.last?.contains("observed_peak_bytes=300") == true)
    }

    func testUnknownFootprintDoesNotInventZeroOrErasePeakAndClockRollbackCanSample() {
        var snapshot = RecordingMemoryMonitor.Snapshot(footprintBytes: nil, availableBytes: 0)
        var lines: [String] = []
        let monitor = RecordingMemoryMonitor(read: { snapshot }, output: { lines.append($0) })
        monitor.record(.launch, uptime: 100)
        XCTAssertTrue(lines.last?.contains("footprint_bytes=unknown") == true)
        XCTAssertTrue(lines.last?.contains("observed_peak_bytes=unknown") == true)
        XCTAssertTrue(lines.last?.contains("available_bytes=0") == true)
        snapshot = .init(footprintBytes: 20, availableBytes: nil)
        monitor.record(.heartbeat, uptime: 40)
        XCTAssertEqual(lines.count, 2)
        snapshot = .init(footprintBytes: nil, availableBytes: nil)
        monitor.record(.heartbeat, uptime: 101)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.last?.contains("observed_peak_bytes=20") == true)
        XCTAssertTrue(lines.last?.contains("available_bytes=unknown") == true)
    }

    func testNativeSnapshotReadsTheCurrentProcessFootprint() throws {
        let snapshot = RecordingMemoryMonitor.systemSnapshot()
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.footprintBytes), 0)
        XCTAssertNotNil(snapshot.availableBytes)
    }

    func testReporterSamplesOnlyAcceptedEventsWithCollectionEnabled() {
        var enabled = false
        var launchSequence = 0
        var sequence = 0
        var reads = 0
        let monitor = RecordingMemoryMonitor(read: {
            reads += 1
            return .init(footprintBytes: 10, availableBytes: 20)
        }, output: { _ in })
        let installationID = UUID(), launchID = UUID()
        let reporter = RecordingDiagnosticReporter(installationID: installationID,
            launchID: launchID, launchSequence: 0, appVersion: "1", appBuild: "161", osVersion: "26",
            uptime: { 100 }, enabled: { enabled }, nextSequence: { sequence },
            droppedReports: { 0 }, sensor: { .init() }, delivery: { .init() }, submit: { _ in },
            identity: { (installationID, launchID, launchSequence) }, memoryMonitor: monitor)
        reporter.request(.launch)
        enabled = true
        reporter.request(.launch)
        launchSequence = 1
        reporter.request(.launch)
        XCTAssertEqual(reads, 0, "No sampling for disabled collection or an unpersisted identity/event")
        sequence = 1
        reporter.request(.launch)
        reporter.request(.launch)
        XCTAssertEqual(reads, 1)
        enabled = false
        reporter.request(.memoryWarning)
        XCTAssertEqual(reads, 1)
    }
}

/// Opt-in system transport smoke test. The coordinator supplies a loopback
/// receiver and backgrounds the host app after the ready marker appears.
/// This tests actual background URLSession file delivery, not physical BLE.
@MainActor
final class RecordingBackgroundSmokeTests: XCTestCase {
    func testSystemFileUploadCompletesWhileHostAppIsBackgrounded() async throws {
        try await exerciseBackgroundUpload(holdNative: false)
    }

    func testImmediateFileUploadCompletesWithNativeHeldWhileHostAppIsBackgrounded() async throws {
        try await exerciseBackgroundUpload(holdNative: true)
    }

    private func exerciseBackgroundUpload(holdNative: Bool) async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let configuration = documents.appendingPathComponent("wythin-background-smoke.json")
        guard FileManager.default.fileExists(atPath: configuration.path) else {
            throw XCTSkip("Opt-in: requires local receiver and external app-background action")
        }
        let settings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: configuration))
        let base = try XCTUnwrap(settings["url"].flatMap(URL.init(string:)))
        guard base.host == "127.0.0.1", base.scheme == "http" else {
            XCTFail("Smoke fixture must be a local loopback receiver")
            return
        }
        let defaults = UserDefaults.standard
        let keys = ["cloudSyncEnabled", "metricsLastSyncedEpoch", "metricsLastSyncedAt", "metricsLastUploadAtEpoch", "profileLastSynced"]
        let oldValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, oldValues) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "cloudSyncEnabled")
        let container = try ModelContainer(for: HRVSession.self, HRVSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        func saveSample() throws {
            context.insert(HRVSample(anchorTestTimestamp: Date(), meanBPM: 65, timezone: "UTC"))
            try context.save()
        }
        if !holdNative { try saveSample() }
        let folder = documents.appendingPathComponent("background-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = URLSessionConfiguration.background(withIdentifier: "com.wythin.tests.background.\(UUID().uuidString)")
        transport.sessionSendsLaunchEvents = true
        transport.isDiscretionary = false
        var native: URLSession?
        defer { native?.invalidateAndCancel() }
        let service = MetricSyncService(client: APIClient(baseURL: base), userID: "local-background-smoke",
            container: container, queueDirectory: folder, sessionConfiguration: transport,
            sessionFactory: { config, delegate in
                let actual = holdNative ? URLSessionConfiguration.ephemeral : config
                if holdNative { actual.protocolClasses = [DeferredNativeUploadProtocol.self] }
                native = URLSession(configuration: actual, delegate: delegate, delegateQueue: nil)
                return native!
            }, makeImmediateUpload: { holdNative ? ImmediateFileUpload() : nil })
        let originalNativeStarts = DeferredNativeUploadProtocol.startCount
        if holdNative { await service.syncIfEnabled() }
        let ready = documents.appendingPathComponent("wythin-background-smoke.ready")
        try Data("ready".utf8).write(to: ready)
        defer { try? FileManager.default.removeItem(at: ready) }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while UIApplication.shared.applicationState != .background && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(UIApplication.shared.applicationState, .background, "External harness must background Wythin")
        if holdNative {
            try saveSample()
            service.savedMetricsDidChange()
        } else {
            await service.syncIfEnabled()
        }
        let uploadDeadline = ProcessInfo.processInfo.systemUptime + 90
        while service.recordingDiagnosticDelivery.lastAckAt == nil && ProcessInfo.processInfo.systemUptime < uploadDeadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertNotNil(service.recordingDiagnosticDelivery.lastAckAt, service.lastError ?? "No system upload receipt")
        XCTAssertEqual(UIApplication.shared.applicationState, .background)
        if holdNative {
            XCTAssertEqual(DeferredNativeUploadProtocol.startCount, originalNativeStarts + 1)
            XCTAssertNotNil(service.recordingDiagnosticDelivery.lastAttemptAt)
        }
        let check = ModelContext(container)
        XCTAssertEqual(try check.fetch(FetchDescriptor<HRVSample>()).first?.cloudUploadState, 1)
    }
}


/// Models a system upload whose scheduler never grants a network start.
private final class DeferredNativeUploadProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var starts = 0
    static var startCount: Int { lock.withLock { starts } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.starts += 1 } }
    override func stopLoading() {}
}
