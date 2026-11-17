import XCTest
import SwiftData
import UIKit
@testable import Wythin

final class RecordingReliabilityTests: XCTestCase {
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

/// Opt-in system transport smoke test. The coordinator supplies a loopback
/// receiver and backgrounds the host app after the ready marker appears.
/// This tests actual background URLSession file delivery, not physical BLE.
@MainActor
final class RecordingBackgroundSmokeTests: XCTestCase {
    func testSystemFileUploadCompletesWhileHostAppIsBackgrounded() async throws {
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
        let sample = HRVSample(anchorTestTimestamp: Date(), meanBPM: 65, timezone: "UTC")
        context.insert(sample)
        try context.save()
        let folder = documents.appendingPathComponent("background-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = URLSessionConfiguration.background(withIdentifier: "com.wythin.tests.background.\(UUID().uuidString)")
        transport.sessionSendsLaunchEvents = true
        transport.isDiscretionary = false
        let service = MetricSyncService(client: APIClient(baseURL: base), userID: "local-background-smoke",
            container: container, queueDirectory: folder, sessionConfiguration: transport)
        let ready = documents.appendingPathComponent("wythin-background-smoke.ready")
        try Data("ready".utf8).write(to: ready)
        defer { try? FileManager.default.removeItem(at: ready) }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while UIApplication.shared.applicationState != .background && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(UIApplication.shared.applicationState, .background, "External harness must background Wythin")
        await service.syncIfEnabled()
        let uploadDeadline = ProcessInfo.processInfo.systemUptime + 90
        while service.lastUploadedAt == nil && ProcessInfo.processInfo.systemUptime < uploadDeadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertNotNil(service.lastUploadedAt, service.lastError ?? "No system upload receipt")
        XCTAssertEqual(UIApplication.shared.applicationState, .background)
        let check = ModelContext(container)
        XCTAssertEqual(try check.fetch(FetchDescriptor<HRVSample>()).first?.cloudUploadState, 1)
    }
}
