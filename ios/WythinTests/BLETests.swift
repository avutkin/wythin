import XCTest
@testable import Wythin

/// BLE packet parser tests — run on simulator or device.
final class BLETests: XCTestCase {

    // MARK: - ECG packet parsing

    func testECGFrameParsing() {
        // Minimal synthetic ECG PMD frame:
        //   byte 0:   frame type = 0x00 (ECG)
        //   bytes 1–8: timestamp = 12345678 ns LE
        //   byte 9:   frame info (ignored)
        //   bytes 10–12: sample 1 = 1000 µV (0x0003E8 LE)
        //   bytes 13–15: sample 2 = -500 µV (0xFFFE0C LE → sign-extended)
        var data = Data(count: 16)
        data[0] = 0x00   // ECG frame type
        // Timestamp: 12345678 = 0x00BC614E LE
        let ts: UInt64 = 12345678
        withUnsafeBytes(of: ts.littleEndian) { buf in
            data.replaceSubrange(1..<9, with: buf)
        }
        data[9] = 0x00   // frame info
        // Sample 1: 1000 = 0x0003E8 → bytes [0xE8, 0x03, 0x00]
        data[10] = 0xE8; data[11] = 0x03; data[12] = 0x00
        // Sample 2: -500 = 0xFFFE0C → bytes [0x0C, 0xFE, 0xFF]
        data[13] = 0x0C; data[14] = 0xFE; data[15] = 0xFF

        let frame = PolarH10Profile.parseECGFrame(data)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.samplesUV.count, 2)
        XCTAssertEqual(frame?.samplesUV[0],  1000)
        XCTAssertEqual(frame?.samplesUV[1], -500)
        XCTAssertEqual(frame?.timestampNs, 12345678)
    }

    func testHRFrameWithRR() {
        // Heart Rate GATT packet: flags=0x10 (RR present, 8-bit HR)
        // HR = 72 bpm, two RR values: 834 raw = 815 ms, 818 raw = 799 ms
        var data = Data()
        data.append(0x10)   // flags: RR present, 8-bit HR
        data.append(72)     // BPM
        // RR 1: 834 = 0x0342 LE
        data.append(0x42); data.append(0x03)
        // RR 2: 818 = 0x0332 LE
        data.append(0x32); data.append(0x03)

        let frame = PolarH10Profile.parseHRFrame(data)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.bpm, 72)
        XCTAssertEqual(frame?.rrIntervalsMs.count, 2)
        // 834 * 1000 / 1024 = 814
        XCTAssertEqual(frame?.rrIntervalsMs[0], 834 * 1000 / 1024)
    }

    func testACCFrameParsing() {
        var data = Data(count: 22)
        data[0] = 0x02   // ACC frame type
        let ts: UInt64 = 99999
        withUnsafeBytes(of: ts.littleEndian) { buf in data.replaceSubrange(1..<9, with: buf) }
        data[9] = 0x00   // frame info
        // Sample 1: X=100, Y=200, Z=-300 (mg)
        let x: Int16 = 100;  let y: Int16 = 200;  let z: Int16 = -300
        withUnsafeBytes(of: x.littleEndian) { b in data.replaceSubrange(10..<12, with: b) }
        withUnsafeBytes(of: y.littleEndian) { b in data.replaceSubrange(12..<14, with: b) }
        withUnsafeBytes(of: z.littleEndian) { b in data.replaceSubrange(14..<16, with: b) }
        // Sample 2: X=0, Y=0, Z=1000
        let x2: Int16 = 0; let y2: Int16 = 0; let z2: Int16 = 1000
        withUnsafeBytes(of: x2.littleEndian) { b in data.replaceSubrange(16..<18, with: b) }
        withUnsafeBytes(of: y2.littleEndian) { b in data.replaceSubrange(18..<20, with: b) }
        withUnsafeBytes(of: z2.littleEndian) { b in data.replaceSubrange(20..<22, with: b) }

        let frame = PolarH10Profile.parseACCFrame(data)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.samples.count, 2)
        XCTAssertEqual(frame?.samples[0].x, 100)
        XCTAssertEqual(frame?.samples[0].z, -300)
        XCTAssertEqual(frame?.samples[1].z, 1000)
    }

    // MARK: - ACC watchdog retry policy (pure, no CoreBluetooth)
    //
    // PMDWatchdogPolicy.decide is the retry policy extracted from the ACC
    // watchdog so it can be tested without a real peripheral — see BLEService's
    // PMDWatchdogPolicy and evaluateACCWatchdog for the CoreBluetooth plumbing
    // that samples state and acts on this decision.

    func testACCWatchdogFiresWhenECGFlowsButACCSilent() {
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: true, rrFlowing: true,
            timeSinceLastACCSample: 6, timeSinceLastRetry: nil,
            retriesUsed: 0, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .retryACCStart)
    }

    func testACCWatchdogStaysQuietWhenBothStreamsSilent() {
        // Both ECG and ACC dead is a connection problem — owned by the
        // existing reconnect/standby machinery, not this watchdog.
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: false, rrFlowing: false,
            timeSinceLastACCSample: 30, timeSinceLastRetry: nil,
            retriesUsed: 0, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .keepWaiting)
    }

    func testACCWatchdogStaysQuietInStandby() {
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: true, ecgFlowing: true, rrFlowing: true,
            timeSinceLastACCSample: 30, timeSinceLastRetry: nil,
            retriesUsed: 0, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .keepWaiting)
    }

    func testACCWatchdogStaysQuietWhenDisconnected() {
        let action = PMDWatchdogPolicy.decide(
            isConnected: false, inStandby: false, ecgFlowing: true, rrFlowing: true,
            timeSinceLastACCSample: 30, timeSinceLastRetry: nil,
            retriesUsed: 0, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .keepWaiting)
    }

    func testACCWatchdogWaitsBelowStallThreshold() {
        // Below the threshold is normal jitter or a brief hiccup, not a stall.
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: true, rrFlowing: true,
            timeSinceLastACCSample: 3, timeSinceLastRetry: nil,
            retriesUsed: 0, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .keepWaiting)
    }

    func testACCWatchdogRespectsRetryGap() {
        // Just retried a second ago — give it time to take effect before
        // trying again, even though ACC is still silent.
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: true, rrFlowing: true,
            timeSinceLastACCSample: 20, timeSinceLastRetry: 1,
            retriesUsed: 1, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .keepWaiting)
    }

    func testACCWatchdogRetriesAgainAfterGapElapses() {
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: true, rrFlowing: true,
            timeSinceLastACCSample: 20, timeSinceLastRetry: 6,
            retriesUsed: 1, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .retryACCStart)
    }

    func testACCWatchdogRespectsRetryBudget() {
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: true, rrFlowing: true,
            timeSinceLastACCSample: 20, timeSinceLastRetry: 6,
            retriesUsed: 3, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        // Budget spent, last retry only 6 s ago: too soon for the slow lane.
        XCTAssertEqual(action, .keepWaiting)
    }

    func testExhaustedBudgetDropsToSlowRetryInsteadOfGivingUp() {
        // The 2026-08-07 outage: after ~20 s of fast retries the old policy
        // cancelled itself for the rest of the session. Now the stall keeps
        // being retried on a slow cadence indefinitely.
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: true, rrFlowing: true,
            timeSinceLastACCSample: 200, timeSinceLastRetry: 61,
            retriesUsed: 3, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .slowRetry(both: false))
    }

    func testPMDStallWithLiveRRRetriesBothStreams() {
        // ECG and ACC both silent while RR still flows: the link is provably
        // alive, so this is a PMD-level stall — the branch the old ecgFlowing
        // guard vetoed, leaving nobody retrying. Both starts get reissued.
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: false, rrFlowing: true,
            timeSinceLastACCSample: 30, timeSinceLastRetry: nil,
            retriesUsed: 0, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .retryBothPMD)
    }

    func testExhaustedPMDStallSlowRetriesBoth() {
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: false, rrFlowing: true,
            timeSinceLastACCSample: 300, timeSinceLastRetry: 120,
            retriesUsed: 3, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .slowRetry(both: true))
    }

    func testACCWatchdogNoStallImmediatelyAfterRecovery() {
        // An ACC sample just arrived (time-since ~0) — no stall regardless of
        // retry history. BLEService.noteACCSampleReceived is what actually
        // resets retriesUsed to 0 on real recovery; this only checks the
        // policy doesn't fire while ACC is freshly live.
        let action = PMDWatchdogPolicy.decide(
            isConnected: true, inStandby: false, ecgFlowing: true, rrFlowing: true,
            timeSinceLastACCSample: 0, timeSinceLastRetry: 6,
            retriesUsed: 2, stallThreshold: 5, retryGap: 5, maxRetries: 3, slowRetryGap: 60)
        XCTAssertEqual(action, .keepWaiting)
    }

    // MARK: - Device ranking (nearest-first scan list)

    func testDeviceRankingAppendsNewDevicesSortedByRSSI() {
        let far = UUID(), near = UUID()
        var list = DeviceRanking.merge([], id: far, name: "Polar H10 A", rssi: -60)
        list = DeviceRanking.merge(list, id: near, name: "Polar H10 B", rssi: -40)
        XCTAssertEqual(list.map(\.id), [near, far], "Strongest signal must be first")
    }

    func testDeviceRankingSmoothsRepeatReadings() {
        let id = UUID()
        var list = DeviceRanking.merge([], id: id, name: "Polar H10", rssi: -60)
        list = DeviceRanking.merge(list, id: id, name: "Polar H10", rssi: -30)
        // EMA (α = 0.3): -60 × 0.7 + -30 × 0.3 = -51, not a raw jump to -30
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].rssi, -51)
    }

    func testDeviceRankingResortsWhenUpdatedDeviceOvertakes() {
        let stable = UUID(), approaching = UUID()
        var list = DeviceRanking.merge([], id: stable, name: "A", rssi: -40)
        list = DeviceRanking.merge(list, id: approaching, name: "B", rssi: -70)
        XCTAssertEqual(list.first?.id, stable)
        // The phone moves toward B: strong readings pull its EMA past A's -40.
        for _ in 0..<4 {
            list = DeviceRanking.merge(list, id: approaching, name: "B", rssi: -20)
        }
        XCTAssertEqual(list.first?.id, approaching,
                       "List must re-sort when an updated device becomes strongest")
        XCTAssertEqual(list.count, 2)
    }

    func testDeviceRankingIgnoresInvalidRSSI() {
        // CoreBluetooth reports 127 when RSSI is unavailable.
        let known = UUID(), unknown = UUID()
        var list = DeviceRanking.merge([], id: known, name: "A", rssi: -50)
        list = DeviceRanking.merge(list, id: known, name: "A", rssi: 127)
        XCTAssertEqual(list[0].rssi, -50, "Invalid reading must not disturb the EMA")
        list = DeviceRanking.merge(list, id: unknown, name: "B", rssi: 127)
        XCTAssertEqual(list.count, 1, "A device with no valid reading yet cannot be ranked")
    }

    // MARK: - Battery alert (below 5% → warn once a day)

    func testBatteryAlertFiresBelowThreshold() {
        XCTAssertTrue(BatteryAlertPolicy.shouldNotify(
            level: 4, lastNotified: nil, now: Date(timeIntervalSince1970: 1_000_000)))
    }

    func testBatteryAlertQuietAtOrAboveThreshold() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(BatteryAlertPolicy.shouldNotify(level: 5, lastNotified: nil, now: now),
                       "5% is not below 5%")
        XCTAssertFalse(BatteryAlertPolicy.shouldNotify(level: 80, lastNotified: nil, now: now))
    }

    func testBatteryAlertThrottledWithinADay() {
        // Background reconnects re-read the battery char every cycle — without
        // the throttle a dying cell would ping on every reconnect.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let anHourAgo = now.addingTimeInterval(-3600)
        XCTAssertFalse(BatteryAlertPolicy.shouldNotify(level: 3, lastNotified: anHourAgo, now: now))
    }

    func testBatteryAlertFiresAgainAfterADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let overADayAgo = now.addingTimeInterval(-86_401)
        XCTAssertTrue(BatteryAlertPolicy.shouldNotify(level: 3, lastNotified: overADayAgo, now: now))
    }

    func testBatteryCriticalClassification() {
        XCTAssertTrue(BatteryAlertPolicy.isCritical(4))
        XCTAssertFalse(BatteryAlertPolicy.isCritical(5))
        XCTAssertFalse(BatteryAlertPolicy.isCritical(nil), "No reading yet is not an alert")
    }

    // MARK: - DataBuffer

    @MainActor
    func testDataBufferArtifactRejection() async {
        let buf = DataBuffer()
        // Append both valid and artifact RR intervals
        await buf.appendRR([800, 200, 800, 2500, 800])   // 200 and 2500 are artifacts
        let snap = await buf.snapshot()
        XCTAssertEqual(snap.rr.count, 3, "Artifacts should be rejected on append")
    }
}
