import CoreBluetooth
import Combine
import Foundation
import UserNotifications
import UIKit

// MARK: - BLE Connection State

enum BLEState: Equatable {
    case idle
    case scanning
    case connecting(name: String)
    case connected(name: String)
    case disconnected(reason: String)
    /// Strap off-body: streaming stopped to save battery, a no-timeout pending
    /// connect is armed, and iOS will auto-reconnect the instant it's worn again.
    case standby(name: String)
    case unauthorized
    case unsupported
}

// MARK: - Discovered Device

struct BLEDevice: Identifiable, Equatable {
    let id:   UUID
    let name: String
    var rssi: Int

    var rssiDots: String {
        switch rssi {
        case (-50)...: return "●●●●"
        case (-65)...: return "●●●○"
        case (-75)...: return "●●○○"
        default:       return "●○○○"
        }
    }

    var rssiLabel: String {
        switch rssi {
        case (-50)...: return "Excellent"
        case (-65)...: return "Good"
        case (-75)...: return "Fair"
        default:       return "Weak"
        }
    }
}

// MARK: - Supported device identity and pairing

enum PolarH10ConnectionPolicy {
    /// A shared HR service (or even Polar's PMD service) does not identify H10.
    /// Prefer the current advertisement to CoreBluetooth's cached name.
    static func name(peripheralName: String?, advertisedName: String? = nil,
                     verifiedName: String? = nil) -> String? {
        let name = [advertisedName, peripheralName, verifiedName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let name else { return nil }
        let words = name.split(whereSeparator: \.isWhitespace)
        guard (2...3).contains(words.count),
              words[0].lowercased() == "polar", words[1].lowercased() == "h10" else { return nil }
        return name
    }

    /// Only the most recently connected strap can be selected automatically.
    /// With no saved strap, even a single H10 requires an explicit choice.
    static func preferredDevice(in devices: [BLEDevice], savedID: UUID?) -> BLEDevice? {
        guard let savedID else { return nil }
        return devices.first { $0.id == savedID && name(peripheralName: $0.name) != nil }
    }

    static func canAutomaticallyConnect(in state: BLEState) -> Bool {
        switch state {
        case .idle, .scanning, .disconnected: return true
        default: return false
        }
    }
}

/// Discovery runs independently of a connection. Connecting to the saved H10
/// must not hide other straps or stop collecting their advertisements.
struct BLEDiscoverySession {
    private(set) var isScanning = false
    private(set) var devices: [BLEDevice] = []

    mutating func start(devices: [BLEDevice]) {
        self.devices = devices.filter { PolarH10ConnectionPolicy.name(peripheralName: $0.name) != nil }
        isScanning = true
    }

    mutating func stop() { isScanning = false }

    mutating func remove(id: UUID) { devices.removeAll { $0.id == id } }

    mutating func receive(_ device: BLEDevice, connectionState: BLEState, savedID: UUID?) -> BLEDevice? {
        guard isScanning, PolarH10ConnectionPolicy.name(peripheralName: device.name) != nil else { return nil }
        devices = DeviceRanking.merge(devices, id: device.id, name: device.name, rssi: device.rssi)
        guard PolarH10ConnectionPolicy.canAutomaticallyConnect(in: connectionState) else { return nil }
        return PolarH10ConnectionPolicy.preferredDevice(in: [device], savedID: savedID)
    }
}

struct PolarH10Pairing {
    let defaults: UserDefaults
    private let uuidKey = "wythin.polar.uuid"
    private let identityKey = "wythin.polar.verifiedIdentity"

    var savedID: UUID? { defaults.string(forKey: uuidKey).flatMap(UUID.init(uuidString:)) }

    func name(for id: UUID, peripheralName: String?, advertisedName: String? = nil) -> String? {
        let record = defaults.dictionary(forKey: identityKey) as? [String: String]
        let verifiedName = savedID == id && record?["id"] == id.uuidString ? record?["name"] : nil
        return PolarH10ConnectionPolicy.name(peripheralName: peripheralName,
                                             advertisedName: advertisedName,
                                             verifiedName: verifiedName)
    }

    @discardableResult
    func remember(id: UUID, name: String) -> Bool {
        guard let name = PolarH10ConnectionPolicy.name(peripheralName: name) else { return false }
        defaults.set(["id": id.uuidString, "name": name], forKey: identityKey)
        defaults.set(id.uuidString, forKey: uuidKey)
        return true
    }

    /// Older builds stored *any* HR peripheral here. An absent name is not
    /// proof of a wrong device: preserve its UUID for rediscovery, but do not
    /// connect until its model is known.
    func discardIfUnsupported(id: UUID, name: String?) {
        guard savedID == id, let name,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              PolarH10ConnectionPolicy.name(peripheralName: name) == nil else { return }
        forget()
    }

    func forget() {
        defaults.removeObject(forKey: uuidKey)
        defaults.removeObject(forKey: identityKey)
    }
}

// MARK: - Device Ranking (pure, testable)
//
// The scan list promises "nearest first", but a single advertisement's RSSI
// jitters ±10 dB packet to packet — sorting on raw readings would make the
// NEAREST badge flap between straps. An EMA (α = 0.3) damps the jitter while
// still letting a genuinely approaching device overtake within a few packets.
// Deliberately free of CoreBluetooth so BLETests can drive it directly;
// `didDiscover` is the only production caller.
enum DeviceRanking {

    /// Weight of the newest reading in the moving average.
    private static let alpha = 0.3

    /// CoreBluetooth delivers 127 when RSSI is unavailable for a packet.
    private static let invalidRSSI = 127

    /// Folds one advertisement reading into the list and returns it
    /// re-sorted strongest-first (ties broken by id so order is stable).
    static func merge(_ devices: [BLEDevice], id: UUID, name: String, rssi: Int) -> [BLEDevice] {
        var devices = devices
        if let idx = devices.firstIndex(where: { $0.id == id }) {
            if rssi != invalidRSSI {
                let smoothed = Double(devices[idx].rssi) * (1 - alpha) + Double(rssi) * alpha
                devices[idx].rssi = Int(smoothed.rounded())
            }
            devices[idx] = BLEDevice(id: id, name: name, rssi: devices[idx].rssi)
        } else {
            guard rssi != invalidRSSI else { return devices }  // can't rank it yet
            devices.append(BLEDevice(id: id, name: name, rssi: rssi))
        }
        return devices.sorted {
            $0.rssi != $1.rssi ? $0.rssi > $1.rssi : $0.id.uuidString < $1.id.uuidString
        }
    }
}

// MARK: - BLE Diagnostics File
//
// Console capture from a devicectl-launched app is unreliable (stdout is
// block-buffered), so PMD-level diagnostics also land in a file in the app
// container that can be pulled over the wire:
//   xcrun devicectl device copy from --domain-type appDataContainer ...
/// Whether the Settings diagnostics row has anything to offer. Hidden for a
/// fresh install or right after `BLEDiag`'s own rotation has just cleared the
/// file — there is no value in a share sheet for an empty log.
enum BLEDiagExport {
    static func isAvailable(fileSize: Int?) -> Bool {
        guard let fileSize else { return false }
        return fileSize > 0
    }
}

enum BLEDiag {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
        .appendingPathComponent("ble-diag.log")

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 256_000 { try? FileManager.default.removeItem(at: url) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Persistent connection recovery

struct BLEConnectionRecovery {
    enum DisconnectAction { case ignore, waitForSystem, reconnect }
    private var nextRetryDelay: TimeInterval = 2
    private var pendingCheckAfter: Date?
    private var requestedAt: Date?

    static func options(delay: TimeInterval = 0) -> [String: Any] {
        [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
         CBConnectPeripheralOptionEnableAutoReconnect: true,
         CBConnectPeripheralOptionStartDelayKey: delay]
    }

    mutating func requested(at now: Date, delay: TimeInterval = 0) {
        requestedAt = now
        pendingCheckAfter = now.addingTimeInterval(delay + 8)
    }

    mutating func clearPendingRequest() {
        requestedAt = nil
        pendingCheckAfter = nil
    }
    mutating func connectionSucceeded() { self = Self() }

    mutating func failedAttemptDelay() -> TimeInterval {
        let delay = nextRetryDelay
        nextRetryDelay = min(60, delay * 2)
        return delay
    }

    func shouldRearm(linkState: CBPeripheralState, at now: Date) -> Bool {
        guard linkState == .disconnected, let pendingCheckAfter else { return false }
        return now >= pendingCheckAfter
    }

    func acceptsFailure(targetID: UUID?, failedID: UUID, userDisconnected: Bool,
                        linkState: CBPeripheralState, at failedAt: Date,
                        connectedAt: Date?) -> Bool {
        guard targetID == failedID, !userDisconnected,
              linkState != .connected, linkState != .disconnecting else { return false }
        if let connectedAt, failedAt < connectedAt { return false }
        if let requestedAt, failedAt < requestedAt { return false }
        return true
    }

    static func disconnectAction(isCurrent: Bool, userDisconnected: Bool,
                                 wasCanceled: Bool, linkState: CBPeripheralState,
                                 systemIsReconnecting: Bool, disconnectedAt: Date?,
                                 connectedAt: Date?) -> DisconnectAction {
        guard isCurrent, !userDisconnected else { return .ignore }
        if let disconnectedAt, let connectedAt, disconnectedAt < connectedAt { return .ignore }
        // OS reconnect can finish before the delayed disconnect callback is
        // handled. didConnect resets the stream state for the new connection.
        if linkState == .connected { return .ignore }
        if wasCanceled && linkState != .disconnected { return .ignore }
        return systemIsReconnecting || linkState == .connecting ? .waitForSystem : .reconnect
    }
}

// MARK: - RR stream recovery

/// Bluetooth events drive this state machine even when the app is in the
/// background. The watchdog is only a fallback while iOS allows execution.
struct RRStreamRecovery {
    enum Action: Equatable { case wait, probe, refreshHeartRate, reconnect }

    private var connectedAt: Date?
    private var lastPacketAt: Date?
    private var lastHealthyHRAt: Date?
    private var refreshAt: Date?
    private var probeAt: Date?
    private var lastReconnectAt: Date?
    private var reconnectPending = false

    mutating func beginConnection(at now: Date) {
        endConnection()
        connectedAt = now
    }

    /// Preserve the cooldown across automatic reconnects.
    mutating func endConnection() {
        connectedAt = nil
        lastPacketAt = nil
        lastHealthyHRAt = nil
        refreshAt = nil
        probeAt = nil
        reconnectPending = false
    }

    func acceptsPacket(at now: Date) -> Bool {
        !reconnectPending && (connectedAt.map { now >= $0 } ?? false)
    }

    mutating func receivedPacket(at now: Date) -> Action {
        guard acceptsPacket(at: now) else { return .wait }
        lastPacketAt = now
        return evaluate(at: now)
    }

    mutating func receivedHeartRate(_ frame: HRFrame, at now: Date,
                                   inStandby: Bool, ecgLive: Bool) -> Action {
        guard acceptsPacket(at: now) else { return .wait }
        lastPacketAt = now
        let hasRR = !frame.rrIntervalsMs.isEmpty && (!inStandby ||
            StandbyResumeGate.isPhysiologicallyPlausible(bpm: frame.bpm, rr: frame.rrIntervalsMs))
        // Fresh zero-HR beacons are normal off-body. A contact flag alone must
        // not hide a lost RR stream, particularly while ECG is still arriving.
        let offBodyBeacon = frame.bpm == 0 && frame.rrIntervalsMs.isEmpty &&
            frame.contact != true && !ecgLive
        if hasRR || offBodyBeacon {
            lastHealthyHRAt = now
            refreshAt = nil
            probeAt = nil
        }
        return evaluate(at: now)
    }

    mutating func evaluate(at now: Date) -> Action {
        guard let connectedAt, !reconnectPending,
              now.timeIntervalSince(lastHealthyHRAt ?? connectedAt) >= 15 else { return .wait }
        if let lastReconnectAt, now.timeIntervalSince(lastReconnectAt) < 60 { return .wait }
        // A lost notification acknowledgement must not strand the disabled
        // subscription, even if all traffic stops after the refresh request.
        if let refreshAt {
            guard now.timeIntervalSince(refreshAt) >= 10 else { return .wait }
            return reconnect(at: now)
        }
        if let lastPacketAt, now.timeIntervalSince(lastPacketAt) <= 5 {
            refreshAt = now
            probeAt = nil
            return .refreshHeartRate
        }
        if let probeAt {
            guard now.timeIntervalSince(probeAt) >= 10 else { return .wait }
            return reconnect(at: now)
        }
        guard now.timeIntervalSince(lastPacketAt ?? connectedAt) >= 30 else { return .wait }
        probeAt = now
        return .probe
    }

    private mutating func reconnect(at now: Date) -> Action {
        lastReconnectAt = now
        reconnectPending = true
        return .reconnect
    }
}

/// Owns the asynchronous command sequence independently of CoreBluetooth.
/// BLEService maps each command to one framework operation.
struct RRRecoveryCommands {
    enum Command: Equatable {
        case clearRecordingGap, setHRNotifications(Bool), discoverServices, readRSSI, cancelConnection
    }

    private var active = false
    private var refreshPending = false
    private(set) var reconnectPending = false

    mutating func beginConnection() {
        self = Self()
        active = true
    }

    mutating func endConnection() { self = Self() }

    mutating func perform(_ action: RRStreamRecovery.Action, hrIsNotifying: Bool?) -> [Command] {
        guard active, !reconnectPending else { return [] }
        switch action {
        case .wait: return []
        case .probe: return [.readRSSI]
        case .refreshHeartRate:
            guard !refreshPending else { return [] }
            // The >=15s RR gap is real even when refreshing succeeds without
            // disconnecting. Clear before new beats can enter the HRV buffer.
            guard let hrIsNotifying else { return [.clearRecordingGap, .discoverServices] }
            refreshPending = hrIsNotifying
            return [.clearRecordingGap, .setHRNotifications(!hrIsNotifying)]
        case .reconnect:
            refreshPending = false
            reconnectPending = true
            return [.cancelConnection]
        }
    }

    /// A failed disable still needs an enable. No timer is required between
    /// the two writes, and disconnect/cancel invalidates any pending ack.
    mutating func hrNotificationStateUpdated() -> Command? {
        guard active, !reconnectPending, refreshPending else { return nil }
        refreshPending = false
        return .setHRNotifications(true)
    }
}

// MARK: - Standby Policy (pure, testable)
//
// Off-body standby originally leaned on the HR packet's skin-contact bit in
// both directions — entry got +3 from `contact == false`, exit required
// `contact == true` outright. Some H10 firmware (C061602F) reports that bit
// only intermittently, which broke both directions at once: the strap
// wouldn't pause when taken off and — worse — couldn't wake when put back
// on. Both gates are now contact-OPTIONAL: the bit remains the authoritative
// fast path when present, and signal evidence carries the decision when not.
enum StandbyPolicy {
    /// Off-body confidence. ≥ 2 ⇒ off-body; ≥ 3 trips the fast (~20 s) path.
    /// Callers must feed `rrBad`/`ecgPoor` as true for DEAD streams too, not
    /// only poor-quality ones — no data is worse evidence of wear than bad data.
    static func offBodyScore(contact: Bool?, ecgPoor: Bool, rrBad: Bool, still: Bool,
                             rrLive: Bool = false, ecgLive: Bool = false) -> Int {
        // The contact bit and quality estimates can be wrong, especially
        // after the app backgrounds. Never turn off an actively arriving
        // physiological stream merely to save strap battery.
        if rrLive || ecgLive { return 0 }
        var score = 0
        if contact == false { score += 3 } else if contact == true { score -= 1 }
        if ecgPoor { score += 1 }
        if rrBad   { score += 1 }
        // Stillness only corroborates when the heartbeat is ALSO gone. A strap
        // on a table is dead-still and produces no RR; a sleeper is dead-still
        // and produces perfectly good RR for eight hours. Counting stillness
        // unconditionally made a motionless sleeper indistinguishable from a
        // doffed strap, and paired with the ECG dip that dry electrodes develop
        // overnight it reached the off-body threshold on its own — dropping the
        // strap into standby in the middle of the night the app most wants.
        if still && rrBad { score += 1 }

        // Live, plausible RR is the strongest evidence a body is present: a
        // doffed H10 stops producing it within seconds, while a worn one on
        // dry electrodes produces it all night. So when RR is flowing,
        // nothing else reaches the off-body threshold on its own — not even
        // an explicit contact=false.
        //
        // This is the same correction `still && rrBad` already made for
        // stillness, applied to the cue that was left out of it. Electrodes
        // dry across a night, the strap asserts no contact, and this scored
        // 4 — the fast path — on a sleeping wearer whose heart was in plain
        // view. Every other case is untouched: with RR gone, the weights
        // below are exactly as they were.
        if !rrBad { return min(score, 1) }
        return score
    }
}

/// Exit gate for standby: worn again? `contact == true` resumes instantly;
/// with the bit absent, a run of consecutive PHYSIOLOGICALLY CONSISTENT HR
/// frames is required instead. "Plausible" is deliberately strict — doffing
/// leaves seconds of electrode noise that can masquerade as beats, and a
/// cheap gate flapped the recording on/off right after standby. A frame
/// counts only if the bpm is human, the RR intervals are human, the RR
/// actually explains the reported bpm, and the bpm isn't jumping around
/// frame to frame. `contact == false` stays authoritative.
struct StandbyResumeGate {
    /// Consecutive plausible frames required when the contact bit is absent
    /// (~4 s at the HR characteristic's 1 Hz cadence).
    static let requiredRun = 4
    /// Consecutive plausible frames required to overrule an explicit
    /// `contact == false` (~16 s). Four times the usual bar, because this
    /// overrides a stated negative rather than filling in for a missing one
    /// — long enough that doffing noise can never accumulate it, short
    /// enough that a worn strap is not held down for a night.
    static let requiredRunAgainstContact = 16
    /// Human heart-rate band; outside it is beacon/noise, not a wearer.
    static let plausibleBPM = 30...220
    /// Human RR band in ms (30–200 bpm).
    static let plausibleRRms = 300...2000
    /// A real heart doesn't move this much between 1 Hz frames.
    static let maxBPMJump = 20
    /// Ignore non-contact evidence this long after entering standby — the
    /// doffing transient is still on the electrodes.
    static let entryGraceSeconds: TimeInterval = 8

    private var run = 0
    private var lastBPM: Int?

    mutating func step(contact: Bool?, bpm: Int, rrIntervalsMs: [Int],
                       secondsInStandby: TimeInterval) -> Bool {
        switch contact {
        case .some(true):
            run = 0; lastBPM = nil
            return true
        case .some(false):
            // Previously an unconditional `false`, and `enterStandby` keeps
            // the GATT link — so the connect path that clears standby never
            // fires either. Between them, a strap whose contact bit stuck
            // false was held in standby indefinitely: link up, beats
            // arriving, nothing recorded for as long as the bit lied.
            //
            // The bit still has the first word, and keeps it through the
            // doffing transient. It no longer has the last one.
            guard secondsInStandby >= Self.entryGraceSeconds else {
                run = 0; lastBPM = nil
                return false
            }
            run = isPlausible(bpm: bpm, rr: rrIntervalsMs) ? run + 1 : 0
            lastBPM = bpm
            if run >= Self.requiredRunAgainstContact {
                run = 0; lastBPM = nil
                return true
            }
            return false
        case .none:
            guard secondsInStandby >= Self.entryGraceSeconds else {
                run = 0; lastBPM = nil
                return false
            }
            run = isPlausible(bpm: bpm, rr: rrIntervalsMs) ? run + 1 : 0
            lastBPM = bpm
            if run >= Self.requiredRun { run = 0; lastBPM = nil; return true }
            return false
        }
    }

    /// The single-frame half of plausibility: is this one HR frame, on its
    /// own, consistent with a real worn heart? No history, so it carries no
    /// opinion on whether a run of noise is masquerading as a resume — that
    /// judgment needs `isPlausible`'s added jump check and `step`'s run
    /// length. It exists separately so a caller gating "is this one frame
    /// worth keeping" doesn't have to carry gate state to ask that question.
    static func isPhysiologicallyPlausible(bpm: Int, rr: [Int]) -> Bool {
        guard plausibleBPM.contains(bpm), !rr.isEmpty,
              rr.allSatisfy({ plausibleRRms.contains($0) }) else { return false }
        // The beats must explain the number: mean RR ↔ bpm within tolerance.
        let meanRR = rr.reduce(0, +) / rr.count
        guard abs(bpm - 60_000 / meanRR) <= 25 else { return false }
        return true
    }

    private func isPlausible(bpm: Int, rr: [Int]) -> Bool {
        guard Self.isPhysiologicallyPlausible(bpm: bpm, rr: rr) else { return false }
        if let last = lastBPM, abs(bpm - last) > Self.maxBPMJump { return false }
        return true
    }
}

// MARK: - Connection Failure Pattern (pure, testable)
//
// The H10 is a single-link BLE peripheral — only one central can hold its
// GATT connection. A native Polar app running its own background connection
// competes for that one slot, and CoreBluetooth gives the losing side
// nothing distinctive: the same `CBError.connectionTimeout` an out-of-range
// or powered-off strap would also produce. There is no code that means
// "someone else has it," so this can never name the cause with certainty.
// What it can notice honestly is the shape only contention tends to
// produce — several failures in quick succession — and say so as a
// possibility, not a diagnosis.
enum ConnectionFailurePattern {
    static let minCount = 3
    static let windowSeconds: TimeInterval = 60

    static func looksLikeContention(recentFailureCount: Int, windowSeconds: TimeInterval) -> Bool {
        recentFailureCount >= minCount && windowSeconds <= Self.windowSeconds
    }
}

// MARK: - Standby Gap Policy (pure, testable)
//
// Forwarding plausible RR during standby stops a brief misclassification
// from costing data, but it also means a GENUINE standby — the strap really
// off for real minutes — now bridges that gap silently in the RR array: the
// last pre-removal beat sits directly adjacent to the first post-reattachment
// one, no marker between them. PRSA reads that seam as an ordinary step, and
// with few beats yet in the post-gap window, one artificial jump can
// dominate the average.
//
// The two cases are told apart by the one signal that differs between them:
// whether a beat was forwarded recently. Continuous misclassification keeps
// forwarding throughout, so the gap since the last one stays near the H10's
// ~1 Hz cadence. A genuine standby forwards nothing for the whole real gap.
enum StandbyGapPolicy {
    /// Beats arrive about once per second under normal operation. Silence
    /// well beyond that is a real stop, not ordinary inter-frame spacing.
    static let genuineGapSeconds: TimeInterval = 10

    static func shouldClearOnResume(secondsSinceLastForwardedBeat: TimeInterval?) -> Bool {
        guard let gap = secondsSinceLastForwardedBeat else { return true }
        return gap >= genuineGapSeconds
    }
}

// MARK: - Discovery Retry Policy (pure, testable)
//
// `didDiscoverServices` and `didDiscoverCharacteristicsFor` used to print
// their error and return: no retry, no user-visible signal, `state` left at
// `.connected`. CoreBluetooth discovery errors are documented to happen, most
// often right after a background state-restoration connect — and when one
// did, the strap stayed "connected" with no characteristics ever subscribed:
// no HR, no PMD, nothing recorded, until something external intervened. This
// is the policy that stops it being permanent.
enum DiscoveryRetryPolicy {
    static let maxRetries = 2

    enum Action: Equatable {
        case retry
        case giveUpAndReconnect
    }

    static func decide(retriesUsed: Int) -> Action {
        retriesUsed < maxRetries ? .retry : .giveUpAndReconnect
    }
}

// MARK: - Skin Contact Display Policy (pure, testable)
//
// Some H10 firmware never sets the sensor-contact-supported flag in the HR
// measurement, so `sensorContact` stays nil forever on those straps. But a
// live ECG stream is direct evidence the electrodes are on skin — dead
// electrodes deliver no usable waveform — so fall back to that instead of
// showing a permanent "not reported".
enum SkinContactPolicy {
    static func label(contact: Bool?, ecgLive: Bool) -> String {
        switch contact {
        case .some(true):  return "on skin"
        case .some(false): return "off-body"
        case .none:        return ecgLive ? "on skin (ECG)" : "not reported"
        }
    }
}

// MARK: - Battery Alert Policy (pure, testable)
//
// The H10 runs on a user-replaceable CR2025 coin cell. Below 5% the strap can
// die mid-session, so the app warns — but at most once a day: background
// reconnects re-read the battery characteristic on every cycle, and a dying
// cell would otherwise ping on each reconnect. The banner on the Live screen
// (driven by `isCritical`) stays up the whole time; only the push is throttled.
enum BatteryAlertPolicy {

    /// "Below 5%" — 5% itself is not yet critical.
    static let criticalThreshold = 5

    /// Minimum gap between two low-battery notifications.
    static let notifyInterval: TimeInterval = 86_400

    static func isCritical(_ level: Int?) -> Bool {
        guard let level else { return false }
        return level < criticalThreshold
    }

    static func shouldNotify(level: Int, lastNotified: Date?, now: Date) -> Bool {
        guard isCritical(level) else { return false }
        guard let lastNotified else { return true }
        return now.timeIntervalSince(lastNotified) > notifyInterval
    }
}

// MARK: - ACC Watchdog Policy (pure, testable)
//
// The H10 answers PMD control-point writes asynchronously, but `launchStreams`
// serialises the ECG/ACC start commands with a fixed 250 ms timer rather than
// waiting for the device's actual response (see BLEService.launchStreams). The
// H10 can still be busy starting the 130 Hz ECG stream when the ACC start
// arrives, and nothing today inspects the response or notices — one lost ACC
// start silently disables breathing detection until the next reconnect or
// standby cycle. This type is the retry policy for a watchdog that catches
// that specific asymmetric failure and re-issues the ACC start itself.
//
// Deliberately free of CoreBluetooth: given liveness signals it returns a pure
// decision, so BLETests can exercise every branch without a real peripheral.
// `BLEService.evaluateACCWatchdog` is the only caller — it samples state, calls
// `decide`, and acts on the result.
enum PMDWatchdogPolicy {

    enum Action: Equatable {
        /// Nothing wrong (or a retry was just issued) — check again next tick.
        case keepWaiting
        /// ECG is flowing, ACC has been silent past the threshold, a retry slot
        /// remains, and enough time has passed since the last retry — reissue
        /// the ACC start command.
        case retryACCStart
        /// ECG **and** ACC silent while RR still flows: the link is alive but
        /// the PMD subsystem as a whole has stalled — reissue both start
        /// commands. This is the branch the 2026-08-07 outage needed: RR
        /// proves the connection, so the reconnect watchdog rightly stays
        /// quiet, and someone still has to retry.
        case retryBothPMD
        /// Retry budget exhausted with the stall persisting. NOT terminal:
        /// the watchdog stays alive for the session and reissues the start
        /// command(s) on a slow cadence — a session should never end with
        /// the app having permanently stopped trying.
        case slowRetry(both: Bool)
    }

    /// - Parameters:
    ///   - isConnected: true only while the BLE state is `.connected`. If false
    ///     the link itself is down — the existing reconnect machinery
    ///     (`BLEService.startWatchdog`) owns that, not this watchdog.
    ///   - inStandby: true while paused off-body. Streams are intentionally
    ///     stopped there, so ACC silence is expected, not a failure.
    ///   - ecgFlowing: whether ECG samples have arrived recently. This is the
    ///     asymmetry check the whole watchdog exists for — if ECG is ALSO
    ///     silent, the connection itself is the problem, not a lost ACC start,
    ///     and this watchdog must stay quiet and let the reconnect path work.
    ///   - timeSinceLastACCSample: seconds since the last ACC sample arrived.
    ///   - timeSinceLastRetry: seconds since the last retry was issued, or nil
    ///     if none has been issued since the streams were last (re)started.
    ///   - retriesUsed: retries issued since the streams were last (re)started.
    ///   - stallThreshold: seconds of ACC silence (while ECG flows) that counts
    ///     as a stall rather than normal jitter or a brief connection hiccup.
    ///   - retryGap: minimum seconds between successive retries — gives a
    ///     just-issued retry a chance to take effect before trying again.
    ///   - maxRetries: total retries allowed before giving up.
    static func decide(
        isConnected: Bool,
        inStandby: Bool,
        ecgFlowing: Bool,
        rrFlowing: Bool,
        timeSinceLastACCSample: TimeInterval,
        timeSinceLastRetry: TimeInterval?,
        retriesUsed: Int,
        stallThreshold: TimeInterval,
        retryGap: TimeInterval,
        maxRetries: Int,
        slowRetryGap: TimeInterval
    ) -> Action {
        guard isConnected, !inStandby else { return .keepWaiting }
        // RR is the liveness oracle, NOT ECG: RR rides the heart-rate
        // characteristic while ECG and ACC are both PMD streams. When RR has
        // also stopped the link itself is down and reconnect owns it — but
        // ECG-silent with RR flowing is a PMD-level stall this watchdog must
        // act on, which is exactly the case the old ecgFlowing guard vetoed.
        guard rrFlowing else { return .keepWaiting }
        guard timeSinceLastACCSample >= stallThreshold else { return .keepWaiting }
        let both = !ecgFlowing
        if retriesUsed < maxRetries {
            if let timeSinceLastRetry, timeSinceLastRetry < retryGap { return .keepWaiting }
            return both ? .retryBothPMD : .retryACCStart
        }
        // Budget exhausted: drop to a slow cadence instead of giving up.
        if let timeSinceLastRetry, timeSinceLastRetry < slowRetryGap { return .keepWaiting }
        return .slowRetry(both: both)
    }
}

// MARK: - BLEService
//
// State machine:
//   idle ──startScanning──► scanning ──didDiscover──► connecting ──didConnect──► connected
//                                 ◄──timeout(30s)──              ◄──timeout(15s)──
//   connected ──disconnect()──► idle
//   connected ──didDisconnect──► disconnected ──(backoff)──► scanning…

@MainActor
@Observable
final class BLEService: NSObject {

    // MARK: Observable state

    var state:             BLEState    = .idle
    var batteryLevel:      Int?        = nil
    var lastError:         String?     = nil
    private var discovery = BLEDiscoverySession()
    var discoveredDevices: [BLEDevice] { discovery.devices }
    var isScanning: Bool { discovery.isScanning }
    /// Latest Polar-reported skin-contact status (HR flags bits 1–2).
    /// nil = sensor doesn't report it; false = off-body; true = on skin.
    var sensorContact:     Bool?       = nil

    /// Human-readable CoreBluetooth central manager state — shown in the BLE sheet for diagnostics.
    var cbStateDescription: String {
        guard let cm = centralManager else { return "BT not initialised" }
        switch cm.state {
        case .poweredOn:      return "Bluetooth ON"
        case .poweredOff:     return "Bluetooth OFF — check Control Centre"
        case .unauthorized:   return "Permission denied — check Settings → Privacy"
        case .unsupported:    return "BT not supported on this device"
        case .resetting:      return "BT resetting…"
        case .unknown:        return "BT state unknown"
        @unknown default:     return "BT state unknown"
        }
    }

    // MARK: Publishers for metric pipeline

    let ecgSubject = PassthroughSubject<[Float], Never>()
    let accSubject = PassthroughSubject<[SIMD3<Int16>], Never>()
    let hrSubject  = PassthroughSubject<HRFrame, Never>()

    /// Fires whenever the connection drops (expectedly or not) — signals that any
    /// in-flight signal buffers span a gap and must be discarded rather than kept
    /// around for HRV computation, since a resumed stream's first RR intervals
    /// may reflect elapsed time across the gap rather than a real beat-to-beat interval.
    let connectionGapSubject = PassthroughSubject<Void, Never>()
    let rawChunkReadySubject = PassthroughSubject<Void, Never>()

    // MARK: Private

    private var centralManager:        CBCentralManager!
    private var peripheral:            CBPeripheral?
    private var pmdControl:            CBCharacteristic?
    private var pmdData:               CBCharacteristic?
    private var hrChar:                CBCharacteristic?
    private var battChar:              CBCharacteristic?
    private var peripheralMap:         [UUID: CBPeripheral] = [:]
    private var advertisedNames:       [UUID: String] = [:]
    private var restoredPeripherals:   [CBPeripheral] = []
    private var scanTimeoutTask:       Task<Void, Never>?
    private var settingsQueryTask:     Task<Void, Never>?
    private var reconnectTask:         Task<Void, Never>?  // cancellable, replaces asyncAfter
    private var watchdogTask:          Task<Void, Never>?  // detects silent drops
    private var accWatchdogTask:       Task<Void, Never>?  // detects a stalled ACC stream while ECG flows
    nonisolated let captureAudit: CaptureAuditLog? = try? CaptureAuditLog(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureAudit", isDirectory: true))
    nonisolated private let rawJournal: RawPacketJournal? = {
        guard RawArchiveFeature.isAvailable else { return nil }
        return try? RawPacketJournal(directory:
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PolarRaw", isDirectory: true))
    }()
    var packetJournal: RawPacketJournal? { rawJournal }

    /// Called on Core Bluetooth's serial delegate queue. The write is complete
    /// before the delegate callback returns, so suspension cannot strand an
    /// unstarted Task with the only copy of a delivered notification.
    nonisolated private func recordRaw(_ stream: RawPacketRecord.Stream, data: Data,
                                       receivedAt: Date, deviceTimestampNs: UInt64?) -> Bool {
        guard RawArchiveFeature.isAvailable else { return false }
        do {
            guard let rawJournal else { throw CocoaError(.fileWriteUnknown) }
            return try rawJournal.append(stream: stream, payload: data,
                                         receivedAt: receivedAt,
                                         deviceTimestampNs: deviceTimestampNs)
        } catch {
            let message = "Raw Polar recording failed: \(error.localizedDescription)"
            Task { @MainActor in self.lastError = message }
            return false
        }
    }

    private var ecgSettings: [UInt8: [UInt16]]?
    private var accSettings: [UInt8: [UInt16]]?

    // ACC watchdog liveness/retry state — see ACCWatchdogPolicy and evaluateACCWatchdog().
    private(set) var lastECGSampleAt: Date?

    /// ECG frames arrived within the last 5 s — direct evidence the strap is
    /// worn, used when firmware doesn't report the HR contact flag.
    var ecgStreamLive: Bool {
        lastECGSampleAt.map { Date().timeIntervalSince($0) < 5 } ?? false
    }

    /// Same liveness window for the ACC stream — display gates on this so a
    /// dead stream shows as dead instead of leaving stale numbers up.
    var accStreamLive: Bool {
        lastACCSampleAt.map { Date().timeIntervalSince($0) < 5 } ?? false
    }
    private(set) var lastACCSampleAt: Date?
    private var lastRRSampleAt:  Date?
    private var resumeGate = StandbyResumeGate()
    private var standbyEnteredAt: Date?
    /// Actual RR intervals (not just HR frames) arrived within the last 8 s.
    /// The most direct wear signal there is: off-body straps keep sending HR
    /// beacon frames but stop producing beats almost immediately.
    private(set) var lastRRIntervalAt: Date?
    var rrIntervalsLive: Bool {
        lastRRIntervalAt.map { Date().timeIntervalSince($0) < 4 } ?? false
    }
    /// The strap's own verdict, at 1 Hz: a worn H10 always reports a human
    /// bpm; within seconds of doffing it reports 0. Unlike tick-derived ECG
    /// quality this needs no computation and no foreground, so it is the cue
    /// that keeps off-body detection fast while the app is backgrounded.
    private(set) var lastPlausibleBPMAt: Date?
    var heartbeatLive: Bool {
        lastPlausibleBPMAt.map { Date().timeIntervalSince($0) < 4 } ?? false
    }
    private var lastECGStartCmd: Data?
    /// True once the fast budget has been spent and `lastError` surfaced —
    /// so the slow-retry loop doesn't rewrite it every minute.
    private var inSlowRetry = false
    private var lastACCRetryAt:  Date?
    private var accRetryCount:   Int = 0
    /// Resets on every fresh `discoverServices()` call, so an old failure
    /// never counts against a brand-new connection.
    private var discoveryRetryCount: Int = 0
    /// Recent `didFailToConnect` timestamps, pruned to the last 5 minutes —
    /// evidence for `ConnectionFailurePattern`, cleared on a successful
    /// connect so a resolved problem cannot flag a later, unrelated one.
    private var recentConnectFailures: [Date] = []
    /// When a beat was last actually forwarded into the pipeline — not when
    /// a frame merely arrived, since an off-body frame can still carry a
    /// non-empty (noise) RR array. `StandbyGapPolicy` reads this at resume
    /// to tell a genuine standby from a brief misclassification.
    private var lastForwardedBeatAt: Date?
    private var lastACCStartCmd: Data?

    // ACC watchdog tuning. At 200 Hz the H10 delivers ACC notifications many
    // times a second, so 5 s of total silence is ~1000 missed samples — never
    // happens from ordinary jitter or a brief connection hiccup, but is exactly
    // what a lost ACC start looks like, and is short enough that a user never
    // again loses two hours of breathing data the way the 2026-07-29 outage did.
    // 3 retries at a 5 s gap bounds worst-case recovery to ~20 s while still
    // giving a genuinely broken strap a few honest tries before giving up.
    private static let accStallThreshold:      TimeInterval = 5.0
    private static let accRetryGap:            TimeInterval = 5.0
    /// Cadence of the post-budget slow retries. The stall persisting past the
    /// fast budget means something is genuinely wedged; once a minute keeps
    /// pressure on it for the whole session without spamming the control point.
    private static let accSlowRetryGap:        TimeInterval = 60.0
    private static let accWatchdogMaxRetries:  Int          = 3
    private static let accWatchdogPollInterval: TimeInterval = 2.0

    private let bleQueue       = DispatchQueue(label: "com.wythin.ble", qos: .userInitiated)
    private let pairing = PolarH10Pairing(defaults: .standard)
    private var pmdStreamsStarted = false

    private var connectionRecovery = BLEConnectionRecovery()
    private var connectionEstablishedAt: Date?

    // Cancellations belong to a particular peripheral, not the next callback
    // from any device (a rejected watch can finish disconnecting after H10).
    private var canceledPeripheralIDs: Set<UUID> = []

    // When true, auto-scan on BT-power-on is skipped (user intentionally disconnected).
    private(set) var userDisconnected = false

    // Off-body standby pauses PMD, retaining HR notifications and recovery.
    private var inStandby = false
    private var rrRecovery = RRStreamRecovery()
    private var recoveryCommands = RRRecoveryCommands()
    private var recoveryReconnectPending: Bool { recoveryCommands.reconnectPending }

    // MARK: Init

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "wythin-ble-central"]
        )
    }

    // MARK: - Battery alert

    private let batteryAlertKey = "wythin.battery.lastAlert"

    /// Posts the once-a-day low-battery push. The Live-screen banner is not
    /// gated here — it renders directly off `batteryLevel` via
    /// `BatteryAlertPolicy.isCritical` for as long as the cell stays low.
    private func alertIfBatteryCritical(_ level: Int) {
        let lastAlert = UserDefaults.standard.object(forKey: batteryAlertKey) as? Date
        guard BatteryAlertPolicy.shouldNotify(level: level, lastNotified: lastAlert, now: Date())
        else { return }
        UserDefaults.standard.set(Date(), forKey: batteryAlertKey)
        print("🪫 BLE: battery \(level)% — posting low-battery notification")

        let content = UNMutableNotificationContent()
        content.title = "Strap battery below 5%"
        content.body = "Your Polar H10 is at \(level)% — replace the CR2025 coin cell soon so sessions don't cut out."
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: "wythin.battery.low",
                                            content: content,
                                            trigger: nil)   // deliver now, we're already awake
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Public API

    /// Refresh nearby H10s without interrupting the current connection.
    /// Opening the picker preserves an explicit disconnect; tapping Scan can
    /// opt back into connecting to the last-used strap.
    func startScanning(resumeAutoConnect: Bool = true) {
        if resumeAutoConnect { userDisconnected = false }
        scanTimeoutTask?.cancel()
        discovery.start(devices: [])
        if peripheral == nil || PolarH10ConnectionPolicy.canAutomaticallyConnect(in: state) {
            state = .scanning
        }
        guard centralManager.state == .poweredOn else { return }

        lastError = nil
        // Keep the current peripheral's advertisement identity while refreshing
        // the rest of the list. A scan never cancels a connection or its timeout.
        let currentName = peripheral.flatMap { advertisedNames[$0.identifier] }
        advertisedNames = [:]
        peripheralMap = [:]
        if let p = peripheral {
            peripheralMap[p.identifier] = p
            if let currentName { advertisedNames[p.identifier] = currentName }
        }
        centralManager.stopScan()
        let alreadyConnected = centralManager.retrieveConnectedPeripherals(withServices: [
            PolarH10Profile.heartRateService, PolarH10Profile.pmdService,
        ])
        if let savedID = pairing.savedID,
           let saved = centralManager.retrievePeripherals(withIdentifiers: [savedID]).first {
            pairing.discardIfUnsupported(id: savedID, name: advertisedNames[savedID] ?? saved.name)
        }
        discovery.start(devices: supportedDevices(alreadyConnected, source: "os-connected"))

        // No service filter: H10 advertisements may omit the HR service UUID.
        // The bounded foreground scan continues even after a strap connects.
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        scanTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, self.isScanning else { return }
            self.stopScanning()
            if case .idle = self.state, self.discoveredDevices.isEmpty {
                self.lastError = "No Polar H10 found (30 s). Wear the strap, moisten its electrodes and keep it nearby."
            }
        }

        if !userDisconnected, PolarH10ConnectionPolicy.canAutomaticallyConnect(in: state),
           let device = PolarH10ConnectionPolicy.preferredDevice(in: discoveredDevices, savedID: pairing.savedID),
           let p = peripheralMap[device.id] {
            BLEDiag.log("SELECT os-connected id=\(device.id) name=\(device.name)")
            doConnect(p)
        }
    }

    func stopScanning() {
        scanTimeoutTask?.cancel()
        discovery.stop()
        if centralManager.state == .poweredOn { centralManager.stopScan() }
        if case .scanning = state { state = .idle }
    }

    /// Seamless auto-connect to the already-paired strap. Arms a persistent,
    /// no-timeout connect so iOS reconnects the moment the strap is worn again —
    /// no scan, no tap, no give-up. Safe to call repeatedly (launch, foreground,
    /// BT power-on, disconnect). No-op if the user explicitly disconnected, we're
    /// paused/connected/connecting or BT isn't ready. With no verified cached
    /// strap, fall back to discovery.
    func ensureAutoConnect() {
        guard !userDisconnected, !inStandby,
              centralManager.state == .poweredOn else { return }
        guard PolarH10ConnectionPolicy.canAutomaticallyConnect(in: state) else { return }
        // A picker scan must not prevent arming the saved strap's persistent
        // connection: the strap may appear after the 30-second scan expires.
        guard let uuid = pairing.savedID else {
            if !centralManager.isScanning { startScanning() }
            return
        }

        // Adopt an already-OS-connected strap (e.g. after state restoration).
        if let p = centralManager.retrieveConnectedPeripherals(withServices: [
            PolarH10Profile.heartRateService, PolarH10Profile.pmdService,
        ]).first(where: { $0.identifier == uuid }) {
            guard supportedName(p) != nil else {
                rejectPeripheral(p, source: "saved-os-connected")
                startScanning()
                return
            }
            print("✅ BLE: auto-connect — adopting OS-connected strap")
            peripheralMap[p.identifier] = p
            doConnect(p)
            return
        }
        // Otherwise arm a no-timeout pending connect that fulfils on advertise.
        if let p = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first {
            guard supportedName(p) != nil else {
                rejectPeripheral(p, source: "saved-peripheral")
                startScanning()
                return
            }
            print("🔵 BLE: auto-connect — armed persistent pending connect")
            peripheralMap[p.identifier] = p
            armPendingConnect(p)
        } else {
            // iOS can evict a cached peripheral. Keep the UUID and rediscover it.
            if !centralManager.isScanning { startScanning() }
        }
    }

    /// Connect to a device the user tapped in the list.
    func connectToDevice(_ device: BLEDevice) {
        guard PolarH10ConnectionPolicy.name(peripheralName: device.name) != nil else {
            lastError = "Only Polar H10 is supported."
            return
        }
        userDisconnected = false
        print("🔵 BLE: connectToDevice — '\(device.name)'")
        if peripheral?.identifier == device.id {
            switch state {
            case .connected, .connecting, .standby: return
            default: break
            }
        }

        // Prefer the peripheral object captured during scanning over re-retrieval,
        // because retrieved peripherals may have stale state on older iOS.
        let p = peripheralMap[device.id]
               ?? centralManager.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let p else {
            lastError = "\(device.name) is no longer reachable. Tap Scan to try again."
            return
        }
        if let previous = peripheral, previous.identifier != p.identifier {
            cancelConnection(previous)
            clearConnectionState()
            connectionGapSubject.send()
        }
        inStandby = false
        BLEDiag.log("SELECT manual id=\(p.identifier) name=\(device.name)")
        // An explicit selection supersedes the previous strap immediately,
        // including restoration/retries before its first successful connect.
        if let name = supportedName(p) { pairing.remember(id: p.identifier, name: name) }
        doConnect(p)
    }

    func forgetSavedDevice() {
        pairing.forget()
        disconnect()
    }

    /// Intentional user-initiated disconnect. Does not trigger auto-reconnect.
    func disconnect() {
        print("🔵 BLE: user disconnect")
        userDisconnected = true
        inStandby = false
        scanTimeoutTask?.cancel()
        reconnectTask?.cancel()
        settingsQueryTask?.cancel()
        stopScanning()
        if let p = peripheral {
            stopPMDStreams()
            cancelConnection(p)
        }
        clearConnectionState()
        rrRecovery = RRStreamRecovery()
        connectionRecovery = BLEConnectionRecovery()
        state = .idle
    }

    /// Off-body auto-standby. Called when the strap has been off long enough that
    /// streaming is wasteful. We PAUSE in place rather than disconnect: a still-
    /// powered off-body strap keeps advertising for minutes and would immediately
    /// re-establish a dropped connection and re-stream garbage. So we stop the
    /// heavy ECG/ACC streams but keep the lightweight HR notification alive to
    /// watch the skin-contact bit, and resume the instant the strap is worn again
    /// (see resumeFromStandby). If the H10 powers itself off later, the normal
    /// disconnect/reconnect path takes over.
    func enterStandby() {
        guard case .connected = state, let p = peripheral, !inStandby else { return }
        print("🌙 BLE: entering standby — strap off-body (paused in place)")
        BLEDiag.log("STANDBY enter")
        inStandby = true
        resumeGate = StandbyResumeGate()   // fresh run for the wake decision
        standbyEnteredAt = Date()          // starts the resume grace window
        reconnectTask?.cancel()
        // Keep monitoring the HR link that is responsible for standby resume.
        accWatchdogTask?.cancel()
        // No `connectionGapSubject.send()` here any more. That used to wipe
        // the RR buffer on every standby entry — right, for a strap that is
        // genuinely off, but exactly wrong for a misclassification, which
        // cost real beats and sent Vagal Tone back to a 192-beat rebuild on
        // every brief flicker. RR itself is never silently discarded any
        // more either (see the `inStandby` branch below), so there is
        // nothing here worth clearing on this path. A real connection gap
        // still clears everything — see `handleUnexpectedDisconnect`.
        stopPMDStreams()                 // stop ECG/ACC; keep HR for contact
        pmdStreamsStarted = false        // allow a clean restart on resume
        state = .standby(name: p.name ?? "Polar H10")
    }

    /// Resume from off-body standby — the strap is worn again (contact restored).
    /// Restart the ECG/ACC streams and mark the link live.
    private func resumeFromStandby(name: String) {
        guard inStandby, peripheral != nil else { return }
        let gap = lastForwardedBeatAt.map { Date().timeIntervalSince($0) }
        if StandbyGapPolicy.shouldClearOnResume(secondsSinceLastForwardedBeat: gap) {
            // A real content gap: whatever is buffered predates it and is not
            // continuous with what is about to be measured. Clear now, right
            // as fresh measurement begins — not on entry, which would cost a
            // brief misclassification its whole pre-existing history for
            // nothing, the regression this exists to avoid.
            print("🌙 BLE: resuming after a real gap (\(gap.map { "\(Int($0))s" } ?? "no prior data")) — clearing buffered beats")
            connectionGapSubject.send()
        }
        print("🌙 BLE: resuming from standby — strap worn again")
        BLEDiag.log("STANDBY resume")
        inStandby = false
        state = .connected(name: name)
        startPMDStreams()
        startWatchdog()
    }

    // MARK: - Private helpers

    private func supportedName(_ p: CBPeripheral) -> String? {
        pairing.name(for: p.identifier, peripheralName: p.name,
                     advertisedName: advertisedNames[p.identifier])
    }

    private func cancelConnection(_ p: CBPeripheral) {
        guard p.state != .disconnected else { return }
        canceledPeripheralIDs.insert(p.identifier)
        centralManager.cancelPeripheralConnection(p)
    }

    private func rejectPeripheral(_ p: CBPeripheral, source: String) {
        let name = advertisedNames[p.identifier] ?? p.name
        BLEDiag.log("REJECT \(source) id=\(p.identifier) name=\(name ?? "<unknown>")")
        pairing.discardIfUnsupported(id: p.identifier, name: name)
        cancelConnection(p)
        peripheralMap.removeValue(forKey: p.identifier)
        discovery.remove(id: p.identifier)
        if peripheral?.identifier == p.identifier {
            clearConnectionState()
            state = .idle
        }
    }

    private func supportedDevices(_ peripherals: [CBPeripheral], source: String) -> [BLEDevice] {
        peripherals.compactMap { p in
            guard let name = supportedName(p) else {
                // OS retrieval includes other apps' watches. Do not attach to
                // them or cancel their connections; just exclude them.
                BLEDiag.log("IGNORE \(source) id=\(p.identifier) name=\(p.name ?? "<unknown>")")
                pairing.discardIfUnsupported(id: p.identifier, name: p.name)
                return nil
            }
            peripheralMap[p.identifier] = p
            return BLEDevice(id: p.identifier, name: name, rssi: -65)
        }
    }

    private func restoreSupportedPeripheral() {
        guard !restoredPeripherals.isEmpty else { return }
        let restored = restoredPeripherals
        restoredPeripherals = []
        let devices = supportedDevices(restored, source: "restore")
        let selected = PolarH10ConnectionPolicy.preferredDevice(in: devices, savedID: pairing.savedID)
        for p in restored where p.identifier != selected?.id {
            rejectPeripheral(p, source: "restore-unselected")
        }
        guard !userDisconnected, let device = selected,
              let p = restored.first(where: { $0.identifier == device.id }) else { return }
        peripheral = p
        p.delegate = self
        BLEDiag.log("SELECT restore id=\(device.id) name=\(device.name) state=\(p.state.rawValue)")
        if p.state == .connected {
            clearCharacteristics()
            pairing.remember(id: device.id, name: device.name)
            pmdStreamsStarted = false
            discoveryRetryCount = 0
            state = .connected(name: device.name)
            let connectedAt = Date()
            connectionEstablishedAt = connectedAt
            connectionRecovery.connectionSucceeded()
            rrRecovery.beginConnection(at: connectedAt)
            recoveryCommands.beginConnection()
            centralManager.connect(p, options: BLEConnectionRecovery.options())
            discoverServices()
            startWatchdog()
        } else {
            doConnect(p)
        }
    }

    /// Register a no-timeout pending connection. iOS keeps it queued indefinitely and
    /// connects when the peripheral next advertises (strap put back on).
    private func armPendingConnect(_ p: CBPeripheral, delay: TimeInterval = 0) {
        guard let name = supportedName(p) else {
            rejectPeripheral(p, source: "pending-connect")
            return
        }
        BLEDiag.log("CONNECT pending id=\(p.identifier) name=\(name) delay=\(delay)s")
        state = .connecting(name: name)
        print("🌙 BLE: armed pending reconnect (no timeout) — waiting for strap-on")
        peripheral = p
        p.delegate = self
        pmdStreamsStarted = false
        ecgSettings = nil
        accSettings = nil
        connectionRecovery.requested(at: Date(), delay: delay)
        centralManager.connect(p, options: BLEConnectionRecovery.options(delay: delay))
        startWatchdog()
    }

    private func doConnect(_ p: CBPeripheral) {
        guard let name = supportedName(p) else {
            rejectPeripheral(p, source: "connect")
            lastError = "Only Polar H10 is supported."
            return
        }
        BLEDiag.log("CONNECT id=\(p.identifier) name=\(name)")
        // Explicit selection and automatic recovery share the same persistent
        // request. A foreground/inactive transition must never expire it.
        armPendingConnect(p)
    }

    /// Acts on `DiscoveryRetryPolicy`'s decision for a failed discovery
    /// callback. A retry simply restarts the whole chain — service and
    /// characteristic discovery are cheap and idempotent, so there is no
    /// benefit to resuming from the exact failed step. Giving up forces a
    /// disconnect rather than inventing a second recovery path: leaving this
    /// cancellation unsuppressed routes it through `handleUnexpectedDisconnect`,
    /// the same persistent no-timeout pending-reconnect every other drop uses.
    private func retryOrGiveUpOnDiscoveryFailure(_ p: CBPeripheral) {
        switch DiscoveryRetryPolicy.decide(retriesUsed: discoveryRetryCount) {
        case .retry:
            discoveryRetryCount += 1
            print("🟡 BLE: discovery failed — retrying (\(discoveryRetryCount)/\(DiscoveryRetryPolicy.maxRetries))")
            discoverServices()
        case .giveUpAndReconnect:
            print("🔴 BLE: discovery failed \(DiscoveryRetryPolicy.maxRetries) times — forcing a reconnect")
            lastError = "Bluetooth setup failed — reconnecting"
            canceledPeripheralIDs.remove(p.identifier)
            centralManager.cancelPeripheralConnection(p)
        }
    }

    private func discoverServices() {
        peripheral?.discoverServices([
            PolarH10Profile.pmdService,
            PolarH10Profile.heartRateService,
            PolarH10Profile.batteryService,
        ])
    }

    private func startPMDStreams() {
        guard let ctrl = pmdControl, let data = pmdData, let p = peripheral else { return }
        guard !pmdStreamsStarted else { return }
        pmdStreamsStarted = true

        p.setNotifyValue(true, for: ctrl)
        p.setNotifyValue(true, for: data)
        // Stop any lingering streams before starting fresh
        p.writeValue(PolarH10Profile.cmdECGStop, for: ctrl, type: .withResponse)
        p.writeValue(PolarH10Profile.cmdACCStop, for: ctrl, type: .withResponse)

        // Query device capabilities; 0.4 s delay lets the stop-writes complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let ctrl = self.pmdControl, let p = self.peripheral else { return }
            print("🔵 BLE: querying ECG settings")
            p.writeValue(PolarH10Profile.cmdGetECGSettings, for: ctrl, type: .withResponse)

            // Fallback: if device doesn't answer the query in 4 s, use hardcoded defaults
            self.settingsQueryTask?.cancel()
            self.settingsQueryTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                print("⚠️ BLE: settings query timed out — using defaults")
                self.launchStreams(ecg: PolarH10Profile.cmdECGStart,
                                   acc: PolarH10Profile.cmdACCStart)
            }
        }
    }

    private func launchStreams(ecg: Data, acc: Data) {
        guard let ctrl = pmdControl, let p = peripheral else { return }
        lastECGStartCmd = ecg
        print("🔵 BLE: starting ECG — \(ecg.hexLog)")
        BLEDiag.log("START ECG \(ecg.hexLog)")
        p.writeValue(ecg, for: ctrl, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let ctrl = self.pmdControl, let p = self.peripheral else { return }
            print("🔵 BLE: starting ACC — \(acc.hexLog)")
            BLEDiag.log("START ACC \(acc.hexLog)")
            p.writeValue(acc, for: ctrl, type: .withResponse)
            self.startACCWatchdog(accCmd: acc)
        }
    }

    private func stopPMDStreams() {
        guard let ctrl = pmdControl, let data = pmdData, let p = peripheral else { return }
        p.writeValue(PolarH10Profile.cmdECGStop, for: ctrl, type: .withResponse)
        p.writeValue(PolarH10Profile.cmdACCStop, for: ctrl, type: .withResponse)
        p.setNotifyValue(false, for: ctrl)
        p.setNotifyValue(false, for: data)
    }

    /// Zero out all connection-specific state. Does NOT touch `state`, retry backoff,
    /// or `userDisconnected` — those are managed by the callers.
    /// Clears only GATT state (characteristics, stream flags). Keeps `peripheral` alive
    /// so the caller can attempt a direct reconnect without scanning.
    private func clearCharacteristics() {
        settingsQueryTask?.cancel()
        watchdogTask?.cancel()
        accWatchdogTask?.cancel()
        pmdControl        = nil
        pmdData           = nil
        hrChar            = nil
        battChar          = nil
        batteryLevel      = nil
        pmdStreamsStarted  = false
        ecgSettings       = nil
        accSettings       = nil
        lastECGSampleAt   = nil
        lastACCSampleAt   = nil
        lastACCRetryAt    = nil
        accRetryCount     = 0
        lastACCStartCmd   = nil
        lastRRSampleAt    = nil
        lastRRIntervalAt  = nil
        lastPlausibleBPMAt = nil
        lastForwardedBeatAt = nil
        sensorContact    = nil
        inStandby        = false
        standbyEnteredAt = nil
        recoveryCommands.endConnection()
        rrRecovery.endConnection()
        connectionEstablishedAt = nil
        connectionRecovery.clearPendingRequest()
    }

    /// Full reset including the peripheral reference. Used for intentional
    /// disconnects and fresh scans.
    private func clearConnectionState() {
        clearCharacteristics()
        peripheral = nil
    }

    // MARK: - Watchdog

    /// Starts an 8-second polling loop that checks whether the peripheral
    /// has silently dropped (iOS can discard the connection when another BT
    /// device connects without always delivering didDisconnectPeripheral).
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self else { return }
                self.checkRecordingRecovery()
            }
        }
    }

    /// Called on lifecycle transitions as well as by the fallback timer.
    /// HR/PMD callbacks evaluate recovery directly, without a foreground tick.
    func checkRecordingRecovery() {
        guard !userDisconnected, !recoveryReconnectPending,
              centralManager.state == .poweredOn, let p = peripheral else { return }
        switch state {
        case .connected, .standby: break
        case .connecting:
            // A legitimate pending connect has no expiry, even after days.
            // Only repair the case where the OS no longer has one armed.
            if connectionRecovery.shouldRearm(linkState: p.state, at: Date()) {
                BLEDiag.log("CONNECT maintenance — rearming lost pending request")
                armPendingConnect(p)
            }
            return
        default: return
        }
        if p.state == .disconnected {
            handleUnexpectedDisconnect(p, error: nil)
        } else if p.state == .connected {
            applyRecordingRecovery(rrRecovery.evaluate(at: Date()))
        }
    }

    private func applyRecordingRecovery(_ action: RRStreamRecovery.Action) {
        guard !userDisconnected, !recoveryReconnectPending,
              centralManager.state == .poweredOn,
              let p = peripheral, p.state == .connected else { return }
        for command in recoveryCommands.perform(action, hrIsNotifying: hrChar?.isNotifying) {
            performRecoveryCommand(command)
        }
    }

    private func performRecoveryCommand(_ command: RRRecoveryCommands.Command?) {
        guard let command, !userDisconnected, let p = peripheral,
              p.state == .connected else { return }
        switch command {
        case .clearRecordingGap:
            BLEDiag.log("RR recovery clearing buffered signals after gap")
            connectionGapSubject.send()
        case .readRSSI:
            BLEDiag.log("RR recovery probe background=\(UIApplication.shared.applicationState == .background)")
            p.readRSSI()
        case .setHRNotifications(let enabled):
            BLEDiag.log("RR recovery HR notify=\(enabled) background=\(UIApplication.shared.applicationState == .background)")
            if let hrChar {
                p.setNotifyValue(enabled, for: hrChar)
            }
        case .discoverServices:
            discoverServices()
        case .cancelConnection:
            BLEDiag.log("RR recovery reconnect background=\(UIApplication.shared.applicationState == .background)")
            state = .connecting(name: supportedName(p) ?? "Polar H10")
            // Deliberately use the unexpected-disconnect path: its callback
            // clears the gap and arms a persistent OS-managed connection.
            canceledPeripheralIDs.remove(p.identifier)
            centralManager.cancelPeripheralConnection(p)
        }
    }

    // MARK: - ACC Watchdog
    //
    // Detects the asymmetric failure where ECG keeps flowing but the ACC start
    // was lost or answered while the H10 was still busy (see launchStreams and
    // ACCWatchdogPolicy above). Runs independently of startWatchdog(), which
    // only detects a fully-dead connection — this one exists precisely for the
    // case where the connection is fine and only one of the two streams died,
    // so it must not fight the reconnect/standby machinery that owns that case.

    /// Arms the ACC watchdog for a freshly (re)started ACC stream: resets the
    /// retry budget and seeds both liveness clocks to "now" so a normal-but-slow
    /// stream start (the H10 still busy from the ECG start moments earlier)
    /// isn't mistaken for a stall before either stream has delivered a sample.
    private func startACCWatchdog(accCmd: Data) {
        accWatchdogTask?.cancel()
        accRetryCount   = 0
        lastACCRetryAt  = nil
        lastACCStartCmd = accCmd
        lastACCSampleAt = Date()
        lastECGSampleAt = Date()
        lastRRSampleAt  = Date()
        inSlowRetry     = false
        print("🔵 BLE: PMD watchdog armed — stall threshold \(Int(Self.accStallThreshold))s, max \(Self.accWatchdogMaxRetries) retries")

        accWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.accWatchdogPollInterval))
                guard !Task.isCancelled, let self else { return }
                self.evaluateACCWatchdog()
            }
        }
    }

    /// One poll tick: samples current liveness/state, asks the pure policy for
    /// a decision, and acts on it (retry write, log, or give up).
    private func evaluateACCWatchdog() {
        guard case .connected = state,
              let ctrl = pmdControl, let p = peripheral,
              let accCmd = lastACCStartCmd else { return }

        let now = Date()
        // "ECG flowing" reuses the stall threshold as its recency window: ECG
        // arrives far more often than every 5 s, so treating longer silence as
        // "not flowing" is generous, not tight — it only opens up when ECG has
        // genuinely stopped too, at which point this is a connection problem.
        let ecgFlowing = lastECGSampleAt.map { now.timeIntervalSince($0) < Self.accStallThreshold } ?? false
        let rrFlowing  = lastRRSampleAt.map  { now.timeIntervalSince($0) < Self.accStallThreshold } ?? false
        let timeSinceACC = lastACCSampleAt.map { now.timeIntervalSince($0) } ?? .infinity
        let timeSinceRetry = lastACCRetryAt.map { now.timeIntervalSince($0) }

        let action = PMDWatchdogPolicy.decide(
            isConnected: true,
            inStandby: inStandby,
            ecgFlowing: ecgFlowing,
            rrFlowing: rrFlowing,
            timeSinceLastACCSample: timeSinceACC,
            timeSinceLastRetry: timeSinceRetry,
            retriesUsed: accRetryCount,
            stallThreshold: Self.accStallThreshold,
            retryGap: Self.accRetryGap,
            maxRetries: Self.accWatchdogMaxRetries,
            slowRetryGap: Self.accSlowRetryGap
        )

        switch action {
        case .keepWaiting:
            break

        case .retryACCStart:
            accRetryCount += 1
            lastACCRetryAt = now
            print("🟡 BLE: PMD watchdog — no ACC for \(Int(timeSinceACC))s while ECG flows — reissuing ACC start (\(accRetryCount)/\(Self.accWatchdogMaxRetries))")
            p.writeValue(accCmd, for: ctrl, type: .withResponse)

        case .retryBothPMD:
            accRetryCount += 1
            lastACCRetryAt = now
            print("🟡 BLE: PMD watchdog — ECG and ACC both silent while RR flows — PMD stall, reissuing both starts (\(accRetryCount)/\(Self.accWatchdogMaxRetries))")
            reissuePMDStarts(acc: accCmd, ctrl: ctrl, p: p)

        case .slowRetry(let both):
            accRetryCount += 1
            lastACCRetryAt = now
            if !inSlowRetry {
                inSlowRetry = true
                lastError = "Breathing sensor stream stalled — still retrying in the background"
                print("🔴 BLE: PMD watchdog — fast budget exhausted, dropping to \(Int(Self.accSlowRetryGap))s retries for the rest of the session")
            }
            if both { reissuePMDStarts(acc: accCmd, ctrl: ctrl, p: p) }
            else    { p.writeValue(accCmd, for: ctrl, type: .withResponse) }
        }
    }

    /// Reissues ECG then ACC, serialised the same 250 ms apart as
    /// `launchStreams` — without going through `launchStreams` itself, which
    /// would re-arm the watchdog and hand the stall a fresh fast budget
    /// forever.
    private func reissuePMDStarts(acc: Data, ctrl: CBCharacteristic, p: CBPeripheral) {
        if let ecg = lastECGStartCmd {
            p.writeValue(ecg, for: ctrl, type: .withResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, let ctrl = self.pmdControl, let p = self.peripheral else { return }
                p.writeValue(acc, for: ctrl, type: .withResponse)
            }
        } else {
            p.writeValue(acc, for: ctrl, type: .withResponse)
        }
    }

    /// Records ACC liveness. If the watchdog had been retrying, logs the
    /// recovery and resets the retry budget so a later stall gets a full fresh
    /// set of retries.
    private func noteACCSampleReceived() {
        lastACCSampleAt = Date()
        if accRetryCount > 0 {
            print("✅ BLE: PMD watchdog — ACC stream recovered after \(accRetryCount) retry attempt(s)")
        }
        if inSlowRetry {
            inSlowRetry = false
            lastError   = nil
        }
        accRetryCount  = 0
        lastACCRetryAt = nil
    }

    // MARK: - Unexpected disconnect handler

    /// Shared logic for both watchdog-detected and delegate-reported unexpected drops.
    /// Keeps the peripheral reference and attempts a direct reconnect (no scan needed —
    /// iOS will reconnect to the known peripheral as soon as it's available).
    private func handleUnexpectedDisconnect(_ p: CBPeripheral, error: Error?,
                                            systemIsReconnecting: Bool = false) {
        BLEDiag.log("DISCONNECT unexpected: \(error?.localizedDescription ?? "no error")")
        reconnectTask?.cancel()
        clearCharacteristics()          // keep `peripheral` for the pending reconnect
        connectionGapSubject.send()
        state = .disconnected(reason: error?.localizedDescription ?? "Disconnected")

        // Persistent, no-timeout pending reconnect — no scan, no give-up. iOS
        // completes it the instant the strap advertises again (worn / back in
        // range). This is what makes reconnection seamless: the app is always
        // ready and never needs a manual scan.
        guard !userDisconnected else { return }
        if systemIsReconnecting {
            BLEDiag.log("CONNECT system auto-reconnect pending id=\(p.identifier)")
            state = .connecting(name: supportedName(p) ?? "Polar H10")
            connectionRecovery.requested(at: Date())
            startWatchdog()
        } else {
            armPendingConnect(p)
        }
    }
}

private extension Data {
    var hexLog: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("🔵 BLE: central state → \(central.state.rawValue)")
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                // On BT power-on, UNLESS the user explicitly disconnected: silently
                // auto-connect a previously-paired strap (persistent pending connect,
                // no scan), or scan only if none has been paired yet.
                if !self.userDisconnected {
                    self.restoreSupportedPeripheral()
                }
                if self.isScanning { self.startScanning(resumeAutoConnect: false) }
                self.ensureAutoConnect()
            case .unauthorized:
                self.discovery.stop()
                self.state = .unauthorized
            case .unsupported:
                self.discovery.stop()
                self.state = .unsupported
            case .poweredOff, .resetting:
                // BT went away — cancel timers, clean up, wait for poweredOn
                self.scanTimeoutTask?.cancel()
                self.discovery.stop()
                self.reconnectTask?.cancel()
                self.clearConnectionState()
                self.connectionGapSubject.send()
                self.state = .disconnected(reason: "Bluetooth is off")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey]
                as? [CBPeripheral] else { return }
        Task { @MainActor in
            self.restoredPeripherals = peripherals
            // Restoration can precede poweredOn. Defer central operations until
            // Bluetooth is ready, including canceling a restored watch.
            if central.state == .poweredOn {
                self.restoreSupportedPeripheral()
                self.ensureAutoConnect()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssiVal = RSSI.intValue
        let uuid = peripheral.identifier

        Task { @MainActor in
            guard self.isScanning else { return }
            if let advertisedName, !advertisedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.advertisedNames[uuid] = advertisedName
            }
            guard let displayName = self.supportedName(peripheral) else {
                self.pairing.discardIfUnsupported(id: uuid,
                    name: self.advertisedNames[uuid] ?? peripheral.name)
                self.discovery.remove(id: uuid)
                self.peripheralMap.removeValue(forKey: uuid)
                return
            }
            if self.peripheralMap[uuid] == nil {
                BLEDiag.log("DISCOVER id=\(uuid) name=\(displayName) rssi=\(rssiVal)")
            }
            self.peripheralMap[uuid] = peripheral
            let selected = self.discovery.receive(
                BLEDevice(id: uuid, name: displayName, rssi: rssiVal),
                connectionState: self.state, savedID: self.pairing.savedID)
            guard selected != nil, !self.userDisconnected else { return }
            BLEDiag.log("SELECT saved-advertisement id=\(uuid) name=\(displayName)")
            self.doConnect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        print("✅ BLE: connected to '\(peripheral.name ?? "?")'")
        let connectedAt = Date()
        Task { @MainActor in
            guard !self.userDisconnected,
                  self.peripheral?.identifier == peripheral.identifier,
                  let name = self.supportedName(peripheral) else {
                self.rejectPeripheral(peripheral, source: "didConnect")
                return
            }
            guard peripheral.state == .connected else { return }
            // Auto-reconnect may have completed before its delayed disconnect
            // event. Always initialize the new connection independently.
            self.clearCharacteristics()
            self.connectionGapSubject.send()
            // A live connection outdates any earlier failure — most visibly the
            // "No Polar H10 found (30 s)" scan timeout, which otherwise stays
            // on screen under a green connected card.
            self.lastError = nil
            self.inStandby = false      // worn again — leaving off-body standby
            self.pairing.remember(id: peripheral.identifier, name: name)
            BLEDiag.log("CONNECTED id=\(peripheral.identifier) name=\(name)")
            self.connectionRecovery.connectionSucceeded()
            self.connectionEstablishedAt = connectedAt
            self.discoveryRetryCount = 0
            self.recentConnectFailures.removeAll()
            self.state = .connected(name: name)
            self.rrRecovery.beginConnection(at: connectedAt)
            self.recoveryCommands.beginConnection()
            self.discoverServices()
            self.startWatchdog()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let failedAt = Date()
        let nsError = error as NSError?
        print("❌ BLE: failed to connect — \(error?.localizedDescription ?? "unknown")"
              + (nsError.map { " (\($0.domain) \($0.code))" } ?? ""))
        Task { @MainActor in
            guard self.canceledPeripheralIDs.remove(peripheral.identifier) == nil,
                  self.supportedName(peripheral) != nil,
                  self.connectionRecovery.acceptsFailure(
                    targetID: self.peripheral?.identifier, failedID: peripheral.identifier,
                    userDisconnected: self.userDisconnected, linkState: peripheral.state,
                    at: failedAt, connectedAt: self.connectionEstablishedAt) else { return }
            self.clearCharacteristics()   // keep the peripheral for a re-arm

            let now = Date()
            self.recentConnectFailures.append(now)
            self.recentConnectFailures.removeAll { now.timeIntervalSince($0) > 300 }
            let span = self.recentConnectFailures.first.map { now.timeIntervalSince($0) } ?? 0
            let looksLikeContention = ConnectionFailurePattern.looksLikeContention(
                recentFailureCount: self.recentConnectFailures.count, windowSeconds: span)
            BLEDiag.log("connect failed: \(nsError.map { "\($0.domain) \($0.code)" } ?? "unknown")"
                       + (looksLikeContention ? " — repeated in \(Int(span))s" : ""))

            var message = "Could not connect: \(error?.localizedDescription ?? "unknown error")"
            if looksLikeContention {
                // Hedged on purpose — this is a pattern, not a detection. The
                // H10 cannot be read by two apps at once, and this is the
                // only shape the losing side ever sees.
                message += " — if another app (e.g. the Polar app) is also connected to this sensor, close it fully and try again."
            }
            self.lastError = message
            // Keep the current selected H10, including a first connection.
            // A scan fallback could otherwise switch back to the old strap.
            let delay = self.connectionRecovery.failedAttemptDelay()
            // Register the retry now. CoreBluetooth owns the delay even
            // if iOS suspends the app before another timer can fire.
            self.armPendingConnect(peripheral, delay: delay)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.handleDisconnectEvent(peripheral, disconnectedAt: nil,
                                       systemIsReconnecting: false, error: error)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    timestamp: CFAbsoluteTime, isReconnecting: Bool,
                                    error: Error?) {
        let disconnectedAt = Date(timeIntervalSinceReferenceDate: timestamp)
        Task { @MainActor in
            self.handleDisconnectEvent(peripheral, disconnectedAt: disconnectedAt,
                                       systemIsReconnecting: isReconnecting, error: error)
        }
    }

    private func handleDisconnectEvent(_ p: CBPeripheral, disconnectedAt: Date?,
                                       systemIsReconnecting: Bool, error: Error?) {
        let wasCanceled = canceledPeripheralIDs.remove(p.identifier) != nil
        let action = BLEConnectionRecovery.disconnectAction(
            isCurrent: peripheral?.identifier == p.identifier && supportedName(p) != nil,
            userDisconnected: userDisconnected, wasCanceled: wasCanceled,
            linkState: p.state, systemIsReconnecting: systemIsReconnecting,
            disconnectedAt: disconnectedAt, connectedAt: connectionEstablishedAt)
        switch action {
        case .ignore: return
        case .waitForSystem:
            handleUnexpectedDisconnect(p, error: error, systemIsReconnecting: true)
        case .reconnect:
            handleUnexpectedDisconnect(p, error: error)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        if let error { print("❌ BLE: service discovery error — \(error)") }
        Task { @MainActor in
            guard self.peripheral?.identifier == peripheral.identifier,
                  !self.recoveryReconnectPending, peripheral.state == .connected,
                  self.supportedName(peripheral) != nil else { return }
            guard error == nil, let services = peripheral.services else {
                self.retryOrGiveUpOnDiscoveryFailure(peripheral)
                return
            }
            for svc in services {
                switch svc.uuid {
                case PolarH10Profile.pmdService:
                    peripheral.discoverCharacteristics(
                        [PolarH10Profile.pmdControl, PolarH10Profile.pmdData], for: svc)
                case PolarH10Profile.heartRateService:
                    peripheral.discoverCharacteristics([PolarH10Profile.hrMeasurement], for: svc)
                case PolarH10Profile.batteryService:
                    peripheral.discoverCharacteristics([PolarH10Profile.batteryLevel], for: svc)
                default: break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        if let error { print("❌ BLE: char discovery error — \(error)") }
        Task { @MainActor in
            guard self.peripheral?.identifier == peripheral.identifier,
                  !self.recoveryReconnectPending, peripheral.state == .connected,
                  self.supportedName(peripheral) != nil else { return }
            guard error == nil, let chars = service.characteristics else {
                self.retryOrGiveUpOnDiscoveryFailure(peripheral)
                return
            }
            for c in chars {
                switch c.uuid {
                case PolarH10Profile.pmdControl:
                    self.pmdControl = c
                    print("✅ BLE: PMD control char found")
                case PolarH10Profile.pmdData:
                    self.pmdData = c
                    print("✅ BLE: PMD data char found")
                case PolarH10Profile.hrMeasurement:
                    self.hrChar = c
                    peripheral.setNotifyValue(true, for: c)
                    print("✅ BLE: HR measurement subscribed")
                case PolarH10Profile.batteryLevel:
                    self.battChar = c
                    peripheral.readValue(for: c)
                default: break
                }
            }
            // Start PMD streams once both control and data chars are ready.
            // This may fire from the PMD service char discovery callback while
            // HR/Battery discovery is still in flight — that's fine, they're independent.
            if self.pmdControl != nil && self.pmdData != nil {
                print("✅ BLE: both PMD chars ready — starting streams")
                self.startPMDStreams()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil, let data = characteristic.value else {
            self.captureAudit?.recordPhase("ble_notification_error")
            return
        }
        let receivedAt = Date()

        switch characteristic.uuid {

        case PolarH10Profile.pmdData:
            let stream: RawPacketRecord.Stream? =
                data.first == PolarH10Profile.frameECG ? .ecg :
                data.first == PolarH10Profile.frameACC ? .acc : nil
            let deviceTimestampNs: UInt64? = data.count >= 9 ? data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 1, as: UInt64.self).littleEndian
            } : nil
            let sealed = stream.map { self.recordRaw($0, data: data,
                                                      receivedAt: receivedAt,
                                                      deviceTimestampNs: deviceTimestampNs) } ?? false
            let parsed = PolarH10Profile.parsePMDFrame(data)
            if let stream {
                captureAudit?.recordBLE(stream, rrCount: 0,
                                        valid: parsed != nil, at: receivedAt)
            }
            Task { @MainActor in
                guard self.peripheral?.identifier == peripheral.identifier,
                      !self.recoveryReconnectPending, peripheral.state == .connected,
                      self.supportedName(peripheral) != nil, !self.userDisconnected else { return }
                if sealed { self.rawChunkReadySubject.send(()) }
                guard self.rrRecovery.acceptsPacket(at: receivedAt) else { return }
                if let ecg = parsed as? ECGFrame {
                    self.lastECGSampleAt = receivedAt
                    self.ecgSubject.send(ecg.samplesUV.map { Float($0) })
                } else if let acc = parsed as? ACCFrame {
                    self.noteACCSampleReceived()
                    self.accSubject.send(acc.samples)
                }
                self.applyRecordingRecovery(self.rrRecovery.receivedPacket(at: receivedAt))
            }

        case PolarH10Profile.pmdControl:
            // Diagnostic: always log the raw response — firmware variants have
            // disagreed with the documented layout before, and the raw bytes
            // are the only ground truth when a strap rejects our commands.
            print("🔬 BLE: PMD CP raw — \(data.hexLog)")
            BLEDiag.log("CP raw \(data.hexLog)")
            // PMD CP response format: [0xF0][opCode][measType][status][...payload...]
            guard data.count >= 4, data[0] == 0xF0 else { break }
            let opCode   = data[1]
            let measType = data[2]
            let status   = data[3]

            switch opCode {

            case PolarH10Profile.opGetSettings:
                if let parsed = PolarH10Profile.parseAvailableSettings(data) {
                    let tag = parsed.measType == PolarH10Profile.typeECGMeas ? "ECG" : "ACC"
                    print("✅ BLE: \(tag) settings received")
                    Task { @MainActor in
                        guard self.peripheral?.identifier == peripheral.identifier,
                              self.supportedName(peripheral) != nil, !self.userDisconnected else { return }
                        if parsed.measType == PolarH10Profile.typeECGMeas {
                            self.ecgSettings = parsed.settings
                            // Chain: query ACC settings next
                            if let ctrl = self.pmdControl, let p = self.peripheral {
                                print("🔵 BLE: querying ACC settings")
                                p.writeValue(PolarH10Profile.cmdGetACCSettings,
                                             for: ctrl, type: .withResponse)
                            }
                        } else if parsed.measType == PolarH10Profile.typeACCMeas {
                            self.accSettings = parsed.settings
                            self.settingsQueryTask?.cancel()
                            let ecgCmd = self.ecgSettings.map {
                                PolarH10Profile.buildStartCommand(
                                    measurementType: PolarH10Profile.typeECGMeas, from: $0)
                            } ?? PolarH10Profile.cmdECGStart
                            let accCmd = PolarH10Profile.buildStartCommand(
                                measurementType: PolarH10Profile.typeACCMeas,
                                from: parsed.settings)
                            self.launchStreams(ecg: ecgCmd, acc: accCmd)
                        }
                    }
                } else {
                    // Device doesn't support the settings query — fall back to hardcoded defaults
                    print("⚠️ BLE: GET_SETTINGS not supported (status=0x\(String(status, radix:16))) — using defaults")
                    Task { @MainActor in
                        guard self.peripheral?.identifier == peripheral.identifier,
                              self.supportedName(peripheral) != nil, !self.userDisconnected else { return }
                        self.settingsQueryTask?.cancel()
                        self.launchStreams(ecg: PolarH10Profile.cmdECGStart,
                                           acc: PolarH10Profile.cmdACCStart)
                    }
                }

            case PolarH10Profile.opStart:
                let mt = String(measType, radix: 16, uppercase: true)
                if status == 0x00 {
                    print("✅ BLE: stream start type=0x\(mt) OK")
                    BLEDiag.log("START RESULT type=0x\(mt) OK")
                } else {
                    let st = String(status, radix: 16, uppercase: true)
                    print("❌ BLE: stream start type=0x\(mt) failed status=0x\(st)")
                    BLEDiag.log("START RESULT type=0x\(mt) FAILED status=0x\(st)")
                    Task { @MainActor in
                        guard self.peripheral?.identifier == peripheral.identifier,
                              self.supportedName(peripheral) != nil, !self.userDisconnected else { return }
                        self.lastError = "PMD start error type=0x\(mt) status=0x\(st)"
                    }
                }

            default:
                print("🔵 BLE: PMD response op=0x\(String(opCode, radix:16)) type=0x\(String(measType, radix:16)) status=0x\(String(status, radix:16))")
            }

        case PolarH10Profile.hrMeasurement:
            let sealed = recordRaw(.hr, data: data, receivedAt: receivedAt,
                                   deviceTimestampNs: nil)
            if sealed {
                Task { @MainActor in self.rawChunkReadySubject.send(()) }
            }
            let frame = PolarH10Profile.parseHRFrame(data)
            captureAudit?.recordBLE(.hr, rrCount: frame?.rrIntervalsMs.count ?? 0,
                                    valid: frame != nil, at: receivedAt)
            if let frame {
                Task { @MainActor in
                    guard self.peripheral?.identifier == peripheral.identifier,
                          !self.recoveryReconnectPending, peripheral.state == .connected,
                          let name = self.supportedName(peripheral), !self.userDisconnected else { return }
                    guard self.rrRecovery.acceptsPacket(at: receivedAt) else { return }
                    let recoveryAction = self.rrRecovery.receivedHeartRate(frame, at: receivedAt,
                        inStandby: self.inStandby, ecgLive: self.ecgStreamLive)
                    defer { self.applyRecordingRecovery(recoveryAction) }
                    // RR liveness for the PMD watchdog: this characteristic is
                    // independent of both PMD streams, so it can prove the
                    // link is alive while ECG and ACC are both stalled.
                    self.lastRRSampleAt = receivedAt
                    if !frame.rrIntervalsMs.isEmpty { self.lastRRIntervalAt = receivedAt }
                    if frame.bpm >= 30 { self.lastPlausibleBPMAt = receivedAt }
                    self.sensorContact = frame.contact
                    // Paused for off-body: keep watching the contact bit over the
                    // lightweight HR link and resume the moment the strap is worn
                    // again. Don't forward off-body beats into the pipeline.
                    if self.inStandby {
                        // Contact bit when reported; otherwise a run of
                        // physiologically consistent beats — see StandbyResumeGate.
                        let inStandbyFor = self.standbyEnteredAt.map {
                            Date().timeIntervalSince($0)
                        } ?? .infinity
                        if self.resumeGate.step(contact: frame.contact,
                                                bpm: frame.bpm,
                                                rrIntervalsMs: frame.rrIntervalsMs,
                                                secondsInStandby: inStandbyFor) {
                            self.resumeFromStandby(name: name)
                        } else if inStandbyFor >= StandbyResumeGate.entryGraceSeconds,
                                  StandbyResumeGate.isPhysiologicallyPlausible(
                                      bpm: frame.bpm, rr: frame.rrIntervalsMs) {
                            // Standby's classification may be wrong, or correct
                            // but about to end — either way this beat is real,
                            // so it is not thrown away pending that verdict.
                            // The grace window still screens out the doffing
                            // transient, exactly as it does for the resume
                            // decision above. State stays `.standby` — ECG/ACC
                            // remain off and the UI is untouched — only RR
                            // keeps accumulating so a correct resume, whenever
                            // it comes, starts from a warm buffer, not zero.
                            self.lastForwardedBeatAt = Date()
                            self.hrSubject.send(frame)
                        }
                        return
                    }
                    // Live data means we ARE connected — keep the top-bar indicator
                    // honest if the state drifted (an ineffective disconnect, or an
                    // OS-level reconnect after the strap was worn again). Treat it as
                    // a real, managed connection (clear the user-disconnect latch) so
                    // it's maintained in the background too — not just while open.
                    self.userDisconnected = false
                    if case .connected = self.state {} else {
                        self.state = .connected(name: name)
                    }
                    self.lastForwardedBeatAt = Date()
                    self.hrSubject.send(frame)
                }
            }

        case PolarH10Profile.batteryLevel:
            let level = Int(data[0])
            Task { @MainActor in
                guard self.peripheral?.identifier == peripheral.identifier,
                      self.supportedName(peripheral) != nil, !self.userDisconnected else { return }
                self.batteryLevel = level
                self.alertIfBatteryCritical(level)
            }

        default: break
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            guard self.peripheral?.identifier == peripheral.identifier,
                  !self.userDisconnected, !self.recoveryReconnectPending,
                  peripheral.state == .connected,
                  characteristic === self.hrChar else { return }
            if let error {
                BLEDiag.log("HR notification error: \(error.localizedDescription)")
            }
            self.performRecoveryCommand(self.recoveryCommands.hrNotificationStateUpdated())
            self.checkRecordingRecovery()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber,
                                error: Error?) {
        let receivedAt = Date()
        Task { @MainActor in
            guard self.peripheral?.identifier == peripheral.identifier,
                  !self.userDisconnected, !self.recoveryReconnectPending,
                  peripheral.state == .connected else { return }
            if error == nil {
                self.applyRecordingRecovery(self.rrRecovery.receivedPacket(at: receivedAt))
            } else {
                self.checkRecordingRecovery()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error {
            print("❌ BLE: write error for \(characteristic.uuid) — \(error)")
            Task { @MainActor in
                self.lastError = "BLE write error: \(error.localizedDescription)"
            }
        }
    }
}
