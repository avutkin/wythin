import XCTest
@testable import Wythin

@MainActor
final class RecordingDiagnosticReporterTests: XCTestCase {
    func testTestHostCannotSendAutomaticReportsToProduction() {
        XCTAssertEqual(UserDefaults.standard.string(forKey: "serverURL"), "http://127.0.0.1:18765")
    }

    func testLockedIdentityEmitsNothingAndUsesRecoveredDurableIdentity() {
        var identity = (installationID: UUID(), launchID: UUID(), launchSequence: 0)
        var output: [RecordingDiagnosticEvent] = []
        var sequence = 0
        let reporter = RecordingDiagnosticReporter(installationID: UUID(), launchID: UUID(), launchSequence: 0,
            appVersion: "1", appBuild: "157", osVersion: "26", enabled: { true },
            nextSequence: { sequence += 1; return sequence }, droppedReports: { 0 },
            sensor: { .init() }, delivery: { .init() }, submit: { output.append($0) },
            identity: { identity })
        reporter.request(.launch)
        XCTAssertTrue(output.isEmpty)
        XCTAssertEqual(sequence, 0)
        identity = (UUID(), UUID(), 12)
        reporter.request(.launch)
        XCTAssertEqual(output.first?.installationId, identity.installationID)
        XCTAssertEqual(output.first?.launchId, identity.launchID)
        XCTAssertEqual(output.first?.launchSequence, 12)
    }
    private var clock: TimeInterval = 100
    private var enabled = true
    private var events: [RecordingDiagnosticEvent] = []
    private var sensor = RecordingDiagnosticEvent.Sensor()
    private var delivery = RecordingDiagnosticEvent.Delivery()
    private var sequence = 0

    private func reporter() -> RecordingDiagnosticReporter {
        RecordingDiagnosticReporter(installationID: UUID(), launchID: UUID(), launchSequence: 1,
            appVersion: "1.0", appBuild: "157", osVersion: "26.3",
            now: { Date(timeIntervalSince1970: self.clock) }, uptime: { self.clock },
            enabled: { self.enabled }, nextSequence: { self.sequence += 1; return self.sequence },
            droppedReports: { 0 }, sensor: { self.sensor }, delivery: { self.delivery },
            submit: { self.events.append($0) })
    }

    func testBackgroundHeartbeatDoesNotRequireMetricsOrRR() {
        sensor.intended = true
        let reporter = reporter()
        reporter.setPhase(.background)
        events.removeAll()
        clock += 60
        reporter.poll()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .heartbeat)
        XCTAssertEqual(events.first?.phase, .background)
        XCTAssertEqual(events.first?.recording.computedCount, 0)
        XCTAssertEqual(events.first?.recording.savedCount, 0)
    }

    func testComputeSaveAndUploadAreIndependent() {
        let reporter = reporter()
        let sampleAt = Date(timeIntervalSince1970: 95)
        reporter.computed(sampleAt: sampleAt)
        reporter.saveFailed(NSError(domain: NSCocoaErrorDomain, code: 640,
                                    userInfo: [NSLocalizedDescriptionKey: "private sensor / secret"]))
        XCTAssertEqual(events.last?.recording.computedCount, 1)
        XCTAssertEqual(events.last?.recording.savedCount, 0)
        XCTAssertEqual(events.last?.recording.saveErrorDomain, .cocoa)
        XCTAssertEqual(events.last?.recording.saveErrorCode, 640)
        XCTAssertNil(events.last?.delivery.lastAckAt)
        reporter.saved(sampleAt: sampleAt)
        clock += 16
        reporter.request(.state)
        XCTAssertEqual(events.last?.recording.savedCount, 1)
        XCTAssertEqual(events.last?.recording.lastSavedSampleAt, sampleAt)
        XCTAssertEqual(events.last?.recording.savedAgeSeconds, 16)
        XCTAssertNil(events.last?.recording.saveErrorCode)
        XCTAssertNil(events.last?.delivery.lastAckAt)
        let data = try! RecordingDiagnosticEvent.encoder().encode(events)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private sensor"))
    }

    func testRRGraceClockResetsOnGapAndGeneration() {
        sensor.intended = true; sensor.connectionState = .connected; sensor.rrLive = true
        let reporter = reporter()
        for t in stride(from: 100.0, through: 165.0, by: 1) {
            clock = t; reporter.receivedRR(uptime: t, generation: 1)
        }
        reporter.request(.lifecycle)
        XCTAssertEqual(events.last?.recording.rrActiveAgeSeconds, 65)
        XCTAssertNil(events.last?.recording.computedAgeSeconds)
        clock = 180; reporter.receivedRR(uptime: clock, generation: 1)
        reporter.request(.lifecycle)
        XCTAssertEqual(events.last?.recording.rrActiveAgeSeconds, 0)
        clock = 181; reporter.receivedRR(uptime: clock, generation: 2)
        reporter.request(.lifecycle)
        XCTAssertEqual(events.last?.recording.rrActiveAgeSeconds, 0)
        clock = 190; reporter.request(.lifecycle)
        XCTAssertNil(events.last?.recording.rrActiveAgeSeconds)
    }

    func testDisabledCollectionAndReenableBeginFreshState() {
        let reporter = reporter()
        enabled = false
        reporter.computed(sampleAt: Date())
        reporter.saved(sampleAt: Date())
        reporter.request(.saveError)
        reporter.poll()
        XCTAssertTrue(events.isEmpty)
        enabled = true
        reporter.consentChanged()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.recording.computedCount, 0)
        XCTAssertEqual(events.first?.recording.savedCount, 0)
    }

    func testStateChangesCoalesceButLifecycleAndErrorsPersistPromptly() {
        let reporter = reporter()
        reporter.request(.launch)
        reporter.request(.state)
        clock += 5
        reporter.request(.state)
        XCTAssertEqual(events.count, 1)
        reporter.setPhase(.background)
        XCTAssertEqual(events.count, 2)
        reporter.saveFailed(NSError(domain: "private domain", code: 42))
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.last?.recording.saveErrorDomain, .other)
        clock += 16
        reporter.poll()
        XCTAssertEqual(events.count, 3, "Prompt snapshots already include pending state changes")
    }

    func testWireKeysMatchServerContractAndContainNoMetricValues() throws {
        let reporter = reporter()
        reporter.request(.launch)
        let bytes = try RecordingDiagnosticEvent.encoder().encode(events[0])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertNotNil(json["event_id"])
        XCTAssertNil(json["eventId"])
        let sensor = try XCTUnwrap(json["sensor"] as? [String: Any])
        XCTAssertNotNil(sensor["rr_live"])
        XCTAssertNil(sensor["name"])
        XCTAssertNil(json["mean_bpm"])
        let roundTrip = try RecordingDiagnosticEvent.decoder().decode(RecordingDiagnosticEvent.self, from: bytes)
        XCTAssertEqual(roundTrip.eventId, events[0].eventId)
    }

    func testAuditSnapshotReadsLiveCountersWithoutAppendingAFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audit = try CaptureAuditLog(directory: root)
        let at = Date(timeIntervalSince1970: 100)
        audit.recordBLE(.hr, rrCount: 3, valid: true, validRRCount: 2, at: at)
        audit.recordBLE(.ecg, rrCount: 0, at: at)
        let url = root.appendingPathComponent("capture-audit.jsonl")
        let before = try Data(contentsOf: url)
        let snapshot = audit.counters()
        XCTAssertEqual(snapshot.hrPackets, 1)
        XCTAssertEqual(snapshot.rrIntervals, 3)
        XCTAssertEqual(snapshot.validRRIntervals, 2)
        XCTAssertEqual(snapshot.ecgPackets, 1)
        XCTAssertEqual(snapshot.lastValidRRAt, at)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
