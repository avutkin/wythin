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

    private static let lock = NSLock()

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
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

/// Private policy instants use uptime in production, so changing the wall
/// clock cannot reject fresh packets or postpone recovery. Date-only callers
/// retain deterministic virtual-time support. These comparison instants must
/// never be exposed as physiological timestamps; receivedAt stays a real Date.
enum BLERecoveryClock {
    static func instant(at date: Date, uptime: TimeInterval?) -> Date {
        uptime.map { Date(timeIntervalSinceReferenceDate: $0) } ?? date
    }
}

struct BLEConnectionRecovery {
    enum DisconnectAction { case ignore, waitForSystem, reconnect }
    private var nextRetryDelay: TimeInterval = 2
    private var pendingCheckAfter: Date?
    private var requestedAt: Date?
    private var cancellationAt: Date?
    private var cancellationRetries = 0

    enum CancellationAction { case wait, retryCancellation, rearm, waitForSystem }

    mutating func cancellationRequested(at date: Date, uptime: TimeInterval? = nil) {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        cancellationAt = now
        cancellationRetries = 0
    }

    /// Reconcile a lost cancel callback without starting a competing connection.
    /// CoreBluetooth owns `.connecting` indefinitely, including system reconnect.
    mutating func reconcileCancellation(linkState: CBPeripheralState, at date: Date,
                                       uptime: TimeInterval? = nil) -> CancellationAction {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        guard let cancellationAt else { return .wait }
        if linkState == .disconnected { return .rearm }
        if linkState == .connecting { return .waitForSystem }
        let delay: TimeInterval = cancellationRetries < 3 ? 8 : 60
        guard now.timeIntervalSince(cancellationAt) >= delay else { return .wait }
        self.cancellationAt = now
        cancellationRetries = min(3, cancellationRetries + 1)
        return .retryCancellation
    }

    static func options(delay: TimeInterval = 0) -> [String: Any] {
        var options: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: NSNumber(value: true),
            CBConnectPeripheralOptionEnableAutoReconnect: NSNumber(value: true)
        ]
        let delay = BLEConnectionParameters.boundedDelay(delay)
        if delay > 0 {
            options[CBConnectPeripheralOptionStartDelayKey] = NSNumber(value: delay)
        }
        return options
    }

    mutating func requested(at date: Date, delay: TimeInterval = 0, uptime: TimeInterval? = nil) {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        requestedAt = now
        pendingCheckAfter = now.addingTimeInterval(delay + 8)
    }

    mutating func clearPendingRequest() {
        requestedAt = nil
        pendingCheckAfter = nil
        cancellationAt = nil
        cancellationRetries = 0
    }
    mutating func connectionSucceeded() { self = Self() }

    mutating func failedAttemptDelay() -> TimeInterval {
        let delay = nextRetryDelay
        nextRetryDelay = min(60, delay * 2)
        return delay
    }

    func shouldRearm(linkState: CBPeripheralState, at date: Date, uptime: TimeInterval? = nil) -> Bool {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        guard linkState == .disconnected, let pendingCheckAfter else { return false }
        return now >= pendingCheckAfter
    }

    func acceptsFailure(targetID: UUID?, failedID: UUID, userDisconnected: Bool,
                        linkState: CBPeripheralState, at failedAt: Date,
                        connectedAt: Date?, uptime: TimeInterval? = nil,
                        connectedUptime: TimeInterval? = nil) -> Bool {
        let failedAt = BLERecoveryClock.instant(at: failedAt, uptime: uptime)
        let connectedAt = connectedAt.map { BLERecoveryClock.instant(at: $0, uptime: connectedUptime) }
        guard targetID == failedID, !userDisconnected,
              linkState != .connected, linkState != .disconnecting else { return false }
        if let connectedAt, failedAt < connectedAt { return false }
        if let requestedAt, failedAt < requestedAt { return false }
        return true
    }

    static func disconnectAction(isCurrent: Bool, userDisconnected: Bool,
                                 wasCanceled: Bool, linkState: CBPeripheralState,
                                 systemIsReconnecting: Bool, disconnectedAt: Date?,
                                 connectedAt: Date?, disconnectedUptime: TimeInterval? = nil,
                                 connectedUptime: TimeInterval? = nil) -> DisconnectAction {
        let disconnectedAt = disconnectedAt.map { BLERecoveryClock.instant(at: $0, uptime: disconnectedUptime) }
        let connectedAt = connectedAt.map { BLERecoveryClock.instant(at: $0, uptime: connectedUptime) }
        guard isCurrent, !userDisconnected else { return .ignore }
        if let disconnectedAt, let connectedAt, disconnectedAt < connectedAt { return .ignore }
        // OS reconnect can finish before the delayed disconnect callback is
        // handled. didConnect resets the stream state for the new connection.
        if linkState == .connected { return .ignore }
        if wasCanceled && linkState != .disconnected { return .ignore }
        return systemIsReconnecting || linkState == .connecting ? .waitForSystem : .reconnect
    }
}

/// An invalid-parameters callback must change the next request, not replay the
/// rejected options forever. Remember the fallback per sensor for this process;
/// success and ordinary reconnects must not reintroduce the rejected options.
struct BLEConnectionParameters {
    struct Request {
        let options: [String: Any]?
        /// Only needed when all optional CoreBluetooth parameters are omitted.
        let localDelay: TimeInterval
    }

    private var basicPeripheralIDs: Set<UUID> = []

    static func boundedDelay(_ delay: TimeInterval) -> TimeInterval {
        delay.isFinite ? min(60, max(0, delay)) : 0
    }

    static func isInvalidParameters(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == CBErrorDomain && error.code == CBError.invalidParameters.rawValue
    }

    /// Returns true only for the first transition to the basic request, allowing
    /// one immediate retry. Repeated failures must use the normal backoff.
    mutating func rejected(_ error: Error?, for id: UUID) -> Bool {
        guard Self.isInvalidParameters(error) else { return false }
        return basicPeripheralIDs.insert(id).inserted
    }

    func request(for id: UUID, delay: TimeInterval = 0) -> Request {
        let delay = Self.boundedDelay(delay)
        if basicPeripheralIDs.contains(id) {
            return Request(options: nil, localDelay: delay)
        }
        return Request(options: BLEConnectionRecovery.options(delay: delay), localDelay: 0)
    }

    static func canSubmitDeferred(targetID: UUID?, requestedID: UUID,
                                  userDisconnected: Bool, poweredOn: Bool,
                                  linkState: CBPeripheralState) -> Bool {
        targetID == requestedID && !userDisconnected && poweredOn && linkState == .disconnected
    }
}

// MARK: - RR stream recovery

/// Shared with the recording buffer: packets outside this range cannot prove
/// that useful RR recording is healthy, even if the HR characteristic is busy.
enum RRSignalValidity {
    static func isValid(_ interval: Int) -> Bool { (300...2000).contains(interval) }
}

/// Bluetooth events drive this state machine even when the app is in the
/// background. The watchdog is only a fallback while iOS allows execution.
struct RRStreamRecovery {
    enum Action: Equatable { case wait, probe, refreshHeartRate, reconnect }

    private var connectedAt: Date?
    private var lastPacketAt: Date?
    private var lastHealthyHRAt: Date?
    private var lastHRPacketAt: Date?
    private var refreshAt: Date?
    private var probeAt: Date?
    private var lastReconnectAt: Date?
    private var reconnectPending = false

    mutating func beginConnection(at date: Date, uptime: TimeInterval? = nil) {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        endConnection()
        connectedAt = now
    }

    /// Preserve the cooldown across automatic reconnects.
    mutating func endConnection() {
        connectedAt = nil
        lastPacketAt = nil
        lastHealthyHRAt = nil
        lastHRPacketAt = nil
        refreshAt = nil
        probeAt = nil
        reconnectPending = false
    }

    func acceptsPacket(at date: Date, uptime: TimeInterval? = nil) -> Bool {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        return !reconnectPending && (connectedAt.map { now >= $0 } ?? false)
    }

    func acceptsHeartRate(at date: Date, uptime: TimeInterval? = nil) -> Bool {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        return acceptsPacket(at: now) && now >= (lastHRPacketAt ?? .distantPast)
    }

    mutating func receivedPacket(at date: Date, uptime: TimeInterval? = nil) -> Action {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        guard acceptsPacket(at: now) else { return .wait }
        lastPacketAt = max(lastPacketAt ?? now, now)
        return evaluate(at: now)
    }

    mutating func receivedHeartRate(_ frame: HRFrame, at date: Date, uptime: TimeInterval? = nil,
                                   inStandby: Bool, ecgLive: Bool) -> Action {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        guard acceptsHeartRate(at: now) else { return .wait }
        lastHRPacketAt = now
        lastPacketAt = max(lastPacketAt ?? now, now)
        let validRR = frame.rrIntervalsMs.filter(RRSignalValidity.isValid)
        let hasRR = !validRR.isEmpty && (!inStandby ||
            StandbyResumeGate.isPhysiologicallyPlausible(bpm: frame.bpm, rr: validRR))
        // Fresh zero-HR beacons are normal off-body. A contact flag alone must
        // not hide a lost RR stream, particularly while ECG is still arriving.
        let offBodyBeacon = frame.bpm == 0 && frame.rrIntervalsMs.isEmpty &&
            frame.contact != true && !ecgLive
        if hasRR || offBodyBeacon {
            lastHealthyHRAt = max(lastHealthyHRAt ?? now, now)
            refreshAt = nil
            probeAt = nil
        }
        return evaluate(at: now)
    }

    mutating func evaluate(at date: Date, uptime: TimeInterval? = nil) -> Action {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
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
// Repeated connection failures can accompany interference, range loss or
// other setup failures. They do not identify the cause, a competing app,
// or an exclusive Bluetooth owner. This only gates a troubleshooting hint.
enum ConnectionFailurePattern {
    static let minCount = 3
    static let windowSeconds: TimeInterval = 60

    static func looksLikeContention(recentFailureCount: Int, windowSeconds: TimeInterval,
                                    error: Error? = nil) -> Bool {
        !BLEConnectionParameters.isInvalidParameters(error)
            && recentFailureCount >= minCount && windowSeconds <= Self.windowSeconds
    }

    static func message(for error: Error?, usingBasicRetry: Bool,
                        recentFailureCount: Int, windowSeconds: TimeInterval) -> String {
        if BLEConnectionParameters.isInvalidParameters(error) {
            return usingBasicRetry
                ? "Bluetooth could not start the connection. Retrying automatically…"
                : "Bluetooth still cannot connect. Retrying. If this continues, restart Bluetooth in iPhone Settings."
        }
        var message = "Could not connect: \(error?.localizedDescription ?? "unknown error")"
        if looksLikeContention(recentFailureCount: recentFailureCount,
                               windowSeconds: windowSeconds, error: error) {
            message += " — if another app is using this sensor, stop its recording and try again."
        }
        return message
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

// MARK: - Independent PMD recovery

enum PMDWatchdogPolicy {
    enum Action: Equatable {
        case keepWaiting, retryECGStart, retryACCStart, retryBothPMD
        case slowRetryECG, slowRetry(both: Bool)
    }

    struct Retry {
        var used: Int
        var elapsed: TimeInterval?
    }

    static func decide(
        isConnected: Bool, inStandby: Bool, ecgFlowing: Bool, rrFlowing: Bool,
        timeSinceLastACCSample: TimeInterval, timeSinceLastRetry: TimeInterval?,
        retriesUsed: Int, stallThreshold: TimeInterval, retryGap: TimeInterval,
        maxRetries: Int, slowRetryGap: TimeInterval, ecgRetry: Retry? = nil
    ) -> Action {
        guard isConnected, !inStandby, rrFlowing else { return .keepWaiting }
        let ecg = ecgRetry ?? Retry(used: retriesUsed, elapsed: timeSinceLastRetry)
        func due(_ retry: Retry) -> Bool {
            let gap = retry.used < maxRetries ? retryGap : slowRetryGap
            return retry.elapsed.map { $0 >= gap } ?? true
        }
        let retryECG = !ecgFlowing && due(ecg)
        let retryACC = timeSinceLastACCSample >= stallThreshold &&
            due(Retry(used: retriesUsed, elapsed: timeSinceLastRetry))
        switch (retryECG, retryACC) {
        case (true, true):
            return ecg.used >= maxRetries || retriesUsed >= maxRetries ? .slowRetry(both: true) : .retryBothPMD
        case (true, false): return ecg.used >= maxRetries ? .slowRetryECG : .retryECGStart
        case (false, true): return retriesUsed >= maxRetries ? .slowRetry(both: false) : .retryACCStart
        case (false, false): return .keepWaiting
        }
    }
}

/// One retry budget per stream. ACC traffic cannot reset an ECG outage's
/// budget, and startup grace never appears as a received sample in the UI.
struct PMDStreamRecovery {
    enum Stream: CaseIterable { case ecg, acc }
    private struct Health {
        var lastSampleAt: Date?
        var lastSampleUptime: TimeInterval?
        var lastSampleInstant: Date?
        var lastRetryAt: Date?
        var retries = 0
    }
    private var startedAt: Date?
    private var graceStartedAt: Date?
    private var ecg = Health()
    private var acc = Health()

    mutating func begin(at date: Date, uptime: TimeInterval? = nil) {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        self = Self()
        startedAt = now
        graceStartedAt = now
    }
    mutating func extendStartupGrace(at date: Date, uptime: TimeInterval? = nil) {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        guard let startedAt, now >= startedAt else { return }
        graceStartedAt = now
    }
    mutating func end() { self = Self() }
    func lastSampleAt(_ stream: Stream) -> Date? {
        stream == .ecg ? ecg.lastSampleAt : acc.lastSampleAt
    }
    func lastSampleUptime(_ stream: Stream) -> TimeInterval? {
        stream == .ecg ? ecg.lastSampleUptime : acc.lastSampleUptime
    }
    @discardableResult
    mutating func received(_ stream: Stream, at date: Date, uptime: TimeInterval? = nil) -> Bool {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        let lastSampleInstant = stream == .ecg ? ecg.lastSampleInstant : acc.lastSampleInstant
        guard let startedAt, now >= startedAt,
              now >= (lastSampleInstant ?? startedAt) else { return false }
        let healthy = Health(lastSampleAt: date, lastSampleUptime: uptime, lastSampleInstant: now)
        if stream == .ecg { ecg = healthy } else { acc = healthy }
        return true
    }

    mutating func evaluate(at date: Date, uptime: TimeInterval? = nil,
                           isConnected: Bool, inStandby: Bool,
                           rrFlowing: Bool) -> PMDWatchdogPolicy.Action {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        guard let startedAt, let graceStartedAt else { return .keepWaiting }
        let action = PMDWatchdogPolicy.decide(
            isConnected: isConnected, inStandby: inStandby,
            ecgFlowing: now.timeIntervalSince(max(ecg.lastSampleInstant ?? startedAt, graceStartedAt)) < 5,
            rrFlowing: rrFlowing,
            timeSinceLastACCSample: now.timeIntervalSince(max(acc.lastSampleInstant ?? startedAt, graceStartedAt)),
            timeSinceLastRetry: acc.lastRetryAt.map { now.timeIntervalSince($0) },
            retriesUsed: acc.retries, stallThreshold: 5, retryGap: 5,
            maxRetries: 3, slowRetryGap: 60,
            ecgRetry: .init(used: ecg.retries, elapsed: ecg.lastRetryAt.map { now.timeIntervalSince($0) }))
        let retryECG: Bool
        let retryACC: Bool
        switch action {
        case .keepWaiting: return action
        case .retryECGStart, .slowRetryECG: (retryECG, retryACC) = (true, false)
        case .retryACCStart: (retryECG, retryACC) = (false, true)
        case .retryBothPMD: (retryECG, retryACC) = (true, true)
        case .slowRetry(let both): (retryECG, retryACC) = (both, true)
        }
        if retryECG { ecg.lastRetryAt = now; ecg.retries = min(3, ecg.retries + 1) }
        if retryACC { acc.lastRetryAt = now; acc.retries = min(3, acc.retries + 1) }
        return action
    }
}

/// PMD responses have an opcode/type pair but no request identifier. Keep one
/// transaction in flight, reject mismatched/older callbacks, and bound waiting
/// when the sensor never answers. Epochs invalidate the *effects* of old work;
/// an in-flight command still drains before a replacement session can write.
struct PMDCommandQueue {
    struct Transaction: Equatable {
        let id: UInt64
        let generation: UInt64
        let data: Data
        let sentAt: Date
        let sentUptime: TimeInterval?
    }
    private(set) var generation: UInt64 = 0
    private(set) var inFlight: Transaction?
    private var pending: [Data] = []
    private var nextID: UInt64 = 0
    var isIdle: Bool { inFlight == nil && pending.isEmpty }

    mutating func replacePending(with commands: [Data]) {
        generation &+= 1
        pending = []
        enqueue(commands)
    }
    mutating func reset() {
        inFlight = nil
        replacePending(with: [])
    }
    mutating func enqueue(_ commands: [Data]) {
        for command in commands where command.count >= 2 {
            guard !pending.contains(command),
                  !(inFlight?.generation == generation && inFlight?.data == command) else { continue }
            pending.append(command)
        }
    }
    mutating func removePendingStart(measurement: UInt8) {
        pending.removeAll { $0[0] == PolarH10Profile.opStart && $0[1] == measurement }
    }
    mutating func next(at now: Date, uptime: TimeInterval? = nil) -> Transaction? {
        guard inFlight == nil, !pending.isEmpty else { return nil }
        nextID &+= 1
        let transaction = Transaction(id: nextID, generation: generation,
                                      data: pending.removeFirst(), sentAt: now, sentUptime: uptime)
        inFlight = transaction
        return transaction
    }
    mutating func complete(opCode: UInt8, measurement: UInt8, at date: Date,
                           uptime: TimeInterval? = nil) -> Transaction? {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        guard let transaction = inFlight,
              now >= BLERecoveryClock.instant(at: transaction.sentAt, uptime: transaction.sentUptime),
              transaction.data[0] == opCode, transaction.data[1] == measurement else { return nil }
        inFlight = nil
        return transaction
    }
    mutating func expire(at date: Date, uptime: TimeInterval? = nil) -> Transaction? {
        let now = BLERecoveryClock.instant(at: date, uptime: uptime)
        guard let transaction = inFlight,
              now.timeIntervalSince(BLERecoveryClock.instant(at: transaction.sentAt,
                                                            uptime: transaction.sentUptime)) >= 4 else { return nil }
        inFlight = nil
        return transaction
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

    var state: BLEState = .idle { didSet { diagnosticStateSubject.send() } }
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
    let diagnosticStateSubject = PassthroughSubject<Void, Never>()
    private var diagnosticErrorDomain: RecordingDiagnosticEvent.SensorErrorDomain?
    private var diagnosticErrorCode: Int?
    private var diagnosticErrorAt: Date?

    private func noteDiagnosticError(_ error: Error) {
        let ns = error as NSError
        switch ns.domain {
        case CBErrorDomain, CBATTErrorDomain: diagnosticErrorDomain = .coreBluetooth
        case NSCocoaErrorDomain: diagnosticErrorDomain = .cocoa
        case NSPOSIXErrorDomain: diagnosticErrorDomain = .posix
        default: diagnosticErrorDomain = .other
        }
        diagnosticErrorCode = RecordingDiagnosticEvent.errorCode(error)
        diagnosticErrorAt = Date()
        diagnosticStateSubject.send()
    }

    var diagnosticSensor: RecordingDiagnosticEvent.Sensor {
        var result = RecordingDiagnosticEvent.Sensor()
        switch centralManager?.state ?? .unknown {
        case .unknown: result.centralState = .unknown
        case .resetting: result.centralState = .resetting
        case .unsupported: result.centralState = .unsupported
        case .unauthorized: result.centralState = .unauthorized
        case .poweredOff: result.centralState = .poweredOff
        case .poweredOn: result.centralState = .poweredOn
        @unknown default: result.centralState = .unknown
        }
        switch state {
        case .idle: result.connectionState = .idle
        case .scanning: result.connectionState = .scanning
        case .connecting: result.connectionState = .connecting
        case .connected: result.connectionState = .connected
        case .disconnected: result.connectionState = .disconnected
        case .standby: result.connectionState = .standby
        case .unauthorized: result.connectionState = .unauthorized
        case .unsupported: result.connectionState = .unsupported
        }
        result.intended = !userDisconnected && (pairing.savedID != nil || peripheral != nil)
        result.rrLive = rrIntervalsLive; result.ecgLive = ecgStreamLive; result.accLive = accStreamLive
        result.generation = Int(clamping: recordingGeneration)
        if case .connected = state {
            result.connectionAgeSeconds = connectionEstablishedUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) }
        }
        let counters = captureAudit?.counters()
        result.lastRrAt = counters?.lastValidRRAt ?? lastRRIntervalAt
        result.lastEcgAt = counters?.lastECGAt ?? lastECGSampleAt
        result.lastAccAt = counters?.lastACCAt ?? lastACCSampleAt
        result.sensorContact = sensorContact
        result.hrPackets = counters?.hrPackets; result.ecgPackets = counters?.ecgPackets
        result.accPackets = counters?.accPackets; result.rrIntervals = counters?.rrIntervals
        result.validRrIntervals = counters?.validRRIntervals; result.invalidPackets = counters?.invalidPackets
        result.errorDomain = diagnosticErrorDomain; result.errorCode = diagnosticErrorCode
        result.errorAt = diagnosticErrorAt
        return result
    }

    /// Fires whenever the connection drops (expectedly or not) — signals that any
    /// in-flight signal buffers span a gap and must be discarded rather than kept
    /// around for HRV computation, since a resumed stream's first RR intervals
    /// may reflect elapsed time across the gap rather than a real beat-to-beat interval.
    let connectionGapSubject = PassthroughSubject<Void, Never>()
    private(set) var recordingGeneration: UInt64 = 0

    private func emitRecordingGap() {
        recordingGeneration &+= 1
        connectionGapSubject.send()
    }
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
    private var pmdCommandTask:        Task<Void, Never>?
    private var reconnectTask:         Task<Void, Never>?  // cancellable, replaces asyncAfter
    private var watchdogTask:          Task<Void, Never>?  // detects silent drops
    private var pmdWatchdogTask:       Task<Void, Never>?  // fallback for independent ECG/ACC maintenance
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

    // Actual PMD arrivals; startup grace is kept separately by pmdRecovery.
    var lastECGSampleAt: Date? { pmdRecovery.lastSampleAt(.ecg) }
    var lastECGSampleUptime: TimeInterval? { pmdRecovery.lastSampleUptime(.ecg) }

    /// ECG frames arrived within the last 5 s — direct evidence the strap is
    /// worn, used when firmware doesn't report the HR contact flag.
    var ecgStreamLive: Bool {
        lastECGSampleUptime.map { ProcessInfo.processInfo.systemUptime - $0 < 5 } ?? false
    }

    /// Same liveness window for the ACC stream — display gates on this so a
    /// dead stream shows as dead instead of leaving stale numbers up.
    var accStreamLive: Bool {
        lastACCSampleUptime.map { ProcessInfo.processInfo.systemUptime - $0 < 5 } ?? false
    }
    var lastACCSampleAt: Date? { pmdRecovery.lastSampleAt(.acc) }
    var lastACCSampleUptime: TimeInterval? { pmdRecovery.lastSampleUptime(.acc) }
    private var resumeGate = StandbyResumeGate()
    private var standbyEnteredUptime: TimeInterval?
    /// Actual RR intervals (not just HR frames) arrived within the last 8 s.
    /// The most direct wear signal there is: off-body straps keep sending HR
    /// beacon frames but stop producing beats almost immediately.
    private(set) var lastRRIntervalAt: Date?
    private(set) var lastRRIntervalUptime: TimeInterval?
    var rrIntervalsLive: Bool {
        lastRRIntervalUptime.map { ProcessInfo.processInfo.systemUptime - $0 < 4 } ?? false
    }
    /// The strap's own verdict, at 1 Hz: a worn H10 always reports a human
    /// bpm; within seconds of doffing it reports 0. Unlike tick-derived ECG
    /// quality this needs no computation and no foreground, so it is the cue
    /// that keeps off-body detection fast while the app is backgrounded.
    private(set) var lastPlausibleBPMAt: Date?
    private var lastPlausibleBPMUptime: TimeInterval?
    var heartbeatLive: Bool {
        lastPlausibleBPMUptime.map { ProcessInfo.processInfo.systemUptime - $0 < 4 } ?? false
    }
    private var lastECGStartCmd: Data?
    /// True once the fast budget has been spent and `lastError` surfaced —
    /// so the slow-retry loop doesn't rewrite it every minute.
    private var inSlowRetry = false
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
    private var lastForwardedBeatUptime: TimeInterval?
    private var lastACCStartCmd: Data?

    private var pmdRecovery = PMDStreamRecovery()
    private var pmdCommands = PMDCommandQueue()
    private var pmdSessionStartedUptime: TimeInterval?
    private var pmdConnectionEpoch: UInt64 = 0
    private var pmdStartupPending = false

    private let bleQueue       = DispatchQueue(label: "com.wythin.ble", qos: .userInitiated)
    private let pairing = PolarH10Pairing(defaults: .standard)
    private var pmdStreamsStarted = false

    private var connectionRecovery = BLEConnectionRecovery()
    private var connectionParameters = BLEConnectionParameters()
    private var connectionEstablishedAt: Date?
    private var connectionEstablishedUptime: TimeInterval?

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
            emitRecordingGap()
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
        pmdCommandTask?.cancel()
        stopScanning()
        if let p = peripheral {
            stopPMDStreams()
            cancelConnection(p)
        }
        if peripheral != nil { emitRecordingGap() }
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
        standbyEnteredUptime = ProcessInfo.processInfo.systemUptime
        reconnectTask?.cancel()
        // Keep monitoring the HR link that is responsible for standby resume.
        pmdWatchdogTask?.cancel()
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
        let gap = lastForwardedBeatUptime.map { ProcessInfo.processInfo.systemUptime - $0 }
        if StandbyGapPolicy.shouldClearOnResume(secondsSinceLastForwardedBeat: gap) {
            // A real content gap: whatever is buffered predates it and is not
            // continuous with what is about to be measured. Clear now, right
            // as fresh measurement begins — not on entry, which would cost a
            // brief misclassification its whole pre-existing history for
            // nothing, the regression this exists to avoid.
            print("🌙 BLE: resuming after a real gap (\(gap.map { "\(Int($0))s" } ?? "no prior data")) — clearing buffered beats")
            emitRecordingGap()
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
            let connectedUptime = ProcessInfo.processInfo.systemUptime
            connectionEstablishedAt = connectedAt
            connectionEstablishedUptime = connectedUptime
            connectionRecovery.connectionSucceeded()
            rrRecovery.beginConnection(at: connectedAt, uptime: connectedUptime)
            recoveryCommands.beginConnection()
            centralManager.connect(p, options: connectionParameters.request(for: p.identifier).options)
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
        let delay = BLEConnectionParameters.boundedDelay(delay)
        let request = connectionParameters.request(for: p.identifier, delay: delay)
        reconnectTask?.cancel()
        reconnectTask = nil
        BLEDiag.log("CONNECT pending id=\(p.identifier) name=\(name) delay=\(delay)s"
                    + " options=\(request.options == nil ? "basic" : "automatic")"
                    + " retryOwner=\(request.localDelay > 0 ? "app" : "system")"
                    + " background=\(UIApplication.shared.applicationState == .background)")
        state = .connecting(name: name)
        print(request.localDelay > 0 ? "🔵 BLE: basic reconnect scheduled" :
              "🌙 BLE: armed pending reconnect (no timeout) — waiting for strap-on")
        peripheral = p
        p.delegate = self
        pmdStreamsStarted = false
        ecgSettings = nil
        accSettings = nil
        connectionRecovery.requested(at: Date(), delay: delay,
                                     uptime: ProcessInfo.processInfo.systemUptime)
        if request.localDelay > 0 {
            // A basic request cannot carry the rejected system-delay option.
            // This timer is opportunistic, not a background wake guarantee.
            // The watchdog/lifecycle path also retains the retry deadline and
            // rearms if execution resumes after the timer was suspended.
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(request.localDelay))
                guard !Task.isCancelled, let self,
                      BLEConnectionParameters.canSubmitDeferred(
                        targetID: self.peripheral?.identifier, requestedID: p.identifier,
                        userDisconnected: self.userDisconnected,
                        poweredOn: self.centralManager.state == .poweredOn,
                        linkState: p.state) else { return }
                self.armPendingConnect(p)
            }
        } else {
            // A nil-options connect is still persistent and owned by iOS; it
            // does not need a timer or an open app to wait for the sensor.
            centralManager.connect(p, options: request.options)
        }
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
            applyRecordingRecovery(.reconnect)
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
        guard !userDisconnected, !inStandby, !recoveryReconnectPending,
              let ctrl = pmdControl, let data = pmdData, let p = peripheral,
              p.state == .connected, !pmdStreamsStarted else { return }
        pmdStreamsStarted = true
        pmdStartupPending = true
        let startedAt = Date()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        pmdSessionStartedUptime = startedUptime
        pmdRecovery.begin(at: startedAt, uptime: startedUptime)
        ecgSettings = nil
        accSettings = nil
        p.setNotifyValue(true, for: ctrl)
        p.setNotifyValue(true, for: data)
        // Subscribe and request our streams without first stopping a stream
        // another app on this same iPhone may already be using.
        pmdCommands.replacePending(with: [PolarH10Profile.cmdGetECGSettings,
                                          PolarH10Profile.cmdGetACCSettings])
        startPMDWatchdog()
        pumpPMDCommands()
    }

    private func launchStreams() {
        guard pmdStartupPending, pmdStreamsStarted, !inStandby,
              !userDisconnected, !recoveryReconnectPending else { return }
        pmdStartupPending = false
        let ecg = ecgSettings.map {
            PolarH10Profile.buildStartCommand(measurementType: PolarH10Profile.typeECGMeas, from: $0)
        } ?? PolarH10Profile.cmdECGStart
        let acc = accSettings.map {
            PolarH10Profile.buildStartCommand(measurementType: PolarH10Profile.typeACCMeas, from: $0)
        } ?? PolarH10Profile.cmdACCStart
        lastECGStartCmd = ecg
        lastACCStartCmd = acc
        pmdRecovery.extendStartupGrace(at: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        inSlowRetry = false
        pmdCommands.enqueue([ecg, acc])
    }

    /// Both event callbacks and the fallback timer drive this queue. A lost
    /// response cannot strand it, and delayed work can never choose a newer
    /// connection's characteristic after waking up.
    private func pumpPMDCommands() {
        guard !userDisconnected, !recoveryReconnectPending,
              let p = peripheral, p.state == .connected, let ctrl = pmdControl else { return }
        if let timedOut = pmdCommands.expire(at: Date(), uptime: ProcessInfo.processInfo.systemUptime) {
            BLEDiag.log("PMD response timeout op=\(timedOut.data[0]) type=\(timedOut.data[1])")
        }
        if pmdCommands.isIdle && pmdStartupPending { launchStreams() }
        guard let transaction = pmdCommands.next(at: Date(), uptime: ProcessInfo.processInfo.systemUptime) else { return }
        // Stops only enter this queue on an intentional pause. A superseded
        // session cannot enqueue starts or apply a late settings response.
        p.writeValue(transaction.data, for: ctrl, type: .withResponse)
        BLEDiag.log("PMD command op=\(transaction.data[0]) type=\(transaction.data[1]) epoch=\(transaction.generation)")
        pmdCommandTask?.cancel()
        let connectionEpoch = pmdConnectionEpoch
        pmdCommandTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self,
                  self.pmdConnectionEpoch == connectionEpoch,
                  self.peripheral === p, self.pmdControl === ctrl,
                  self.pmdCommands.inFlight?.id == transaction.id else { return }
            self.pumpPMDCommands()
        }
    }

    private func stopPMDStreams() {
        let hadStartCommands = lastECGStartCmd != nil || lastACCStartCmd != nil
        pmdStartupPending = false
        pmdStreamsStarted = false
        pmdSessionStartedUptime = nil
        pmdRecovery.end()
        pmdWatchdogTask?.cancel()
        // Preserve the in-flight transaction until its response/timeout, but
        // discard every queued startup/retry before putting intentional stops
        // behind it. In-flight settings no longer have authority to restart.
        pmdCommands.replacePending(with: hadStartCommands ?
            [PolarH10Profile.cmdECGStop, PolarH10Profile.cmdACCStop] : [])
        if let p = peripheral, let data = pmdData { p.setNotifyValue(false, for: data) }
        pumpPMDCommands()
    }

    /// Zero out all connection-specific state. Does NOT touch `state`, retry backoff,
    /// or `userDisconnected` — those are managed by the callers.
    /// Clears only GATT state (characteristics, stream flags). Keeps `peripheral` alive
    /// so the caller can attempt a direct reconnect without scanning.
    private func clearCharacteristics() {
        reconnectTask?.cancel()
        reconnectTask = nil
        pmdCommandTask?.cancel()
        watchdogTask?.cancel()
        pmdWatchdogTask?.cancel()
        pmdControl        = nil
        pmdData           = nil
        hrChar            = nil
        battChar          = nil
        batteryLevel      = nil
        pmdStreamsStarted  = false
        ecgSettings       = nil
        accSettings       = nil
        pmdConnectionEpoch &+= 1
        pmdCommands.reset()
        pmdRecovery.end()
        pmdSessionStartedUptime = nil
        pmdStartupPending = false
        lastECGStartCmd = nil
        inSlowRetry = false
        lastACCStartCmd   = nil
        lastRRIntervalAt  = nil
        lastRRIntervalUptime = nil
        lastPlausibleBPMAt = nil
        lastPlausibleBPMUptime = nil
        lastForwardedBeatUptime = nil
        sensorContact    = nil
        inStandby        = false
        standbyEnteredUptime = nil
        recoveryCommands.endConnection()
        rrRecovery.endConnection()
        connectionEstablishedAt = nil
        connectionEstablishedUptime = nil
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
        guard !userDisconnected,
              centralManager.state == .poweredOn, let p = peripheral else { return }
        if recoveryReconnectPending {
            switch connectionRecovery.reconcileCancellation(linkState: p.state, at: Date(),
                                                             uptime: ProcessInfo.processInfo.systemUptime) {
            case .wait: break
            case .retryCancellation:
                BLEDiag.log("RR recovery reconciling missing cancellation callback")
                centralManager.cancelPeripheralConnection(p)
            case .rearm: handleUnexpectedDisconnect(p, error: nil)
            case .waitForSystem: handleUnexpectedDisconnect(p, error: nil, systemIsReconnecting: true)
            }
            return
        }
        switch state {
        case .connected, .standby: break
        case .connecting:
            // A legitimate pending connect has no expiry, even after days.
            // Only repair the case where the OS no longer has one armed.
            if connectionRecovery.shouldRearm(linkState: p.state, at: Date(),
                                              uptime: ProcessInfo.processInfo.systemUptime) {
                BLEDiag.log("CONNECT maintenance — rearming lost pending request")
                armPendingConnect(p)
            }
            return
        default: return
        }
        if p.state == .disconnected {
            handleUnexpectedDisconnect(p, error: nil)
        } else if p.state == .connected {
            applyRecordingRecovery(rrRecovery.evaluate(at: Date(), uptime: ProcessInfo.processInfo.systemUptime))
            evaluatePMDWatchdog()
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
            emitRecordingGap()
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
            connectionRecovery.cancellationRequested(at: Date(), uptime: ProcessInfo.processInfo.systemUptime)
            pmdCommandTask?.cancel()
            pmdCommands.reset()
            centralManager.cancelPeripheralConnection(p)
        }
    }

    private func acceptsConnectionCallback(_ p: CBPeripheral, uptime receivedUptime: TimeInterval) -> Bool {
        guard peripheral === p, !userDisconnected else { return false }
        if recoveryReconnectPending {
            checkRecordingRecovery()
            return false
        }
        guard p.state == .connected, let connectionEstablishedUptime else { return false }
        return receivedUptime >= connectionEstablishedUptime
    }

    // MARK: - PMD stream maintenance

    private func startPMDWatchdog() {
        pmdWatchdogTask?.cancel()
        pmdWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.evaluatePMDWatchdog()
            }
        }
    }

    /// Invoked on HR/PMD delivery and lifecycle checks as well as a best-effort
    /// timer. Background recovery does not require a foreground timer tick.
    private func evaluatePMDWatchdog() {
        pumpPMDCommands()
        guard case .connected = state, !userDisconnected, !inStandby,
              !recoveryReconnectPending, peripheral?.state == .connected,
              pmdStreamsStarted, !pmdStartupPending,
              let ecg = lastECGStartCmd, let acc = lastACCStartCmd else { return }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let rrFlowing = lastRRIntervalUptime.map { uptime - $0 < 5 } ?? false
        let action = pmdRecovery.evaluate(at: now, uptime: uptime, isConnected: true,
                                          inStandby: inStandby, rrFlowing: rrFlowing)
        let commands: [Data]
        switch action {
        case .keepWaiting: return
        case .retryECGStart, .slowRetryECG: commands = [ecg]
        case .retryACCStart: commands = [acc]
        case .retryBothPMD: commands = [ecg, acc]
        case .slowRetry(let both): commands = both ? [ecg, acc] : [acc]
        }
        if action == .slowRetryECG || action == .slowRetry(both: false) || action == .slowRetry(both: true) {
            if !inSlowRetry {
                inSlowRetry = true
                lastError = "Sensor stream stalled — still retrying in the background"
            }
        }
        BLEDiag.log("PMD recovery \(action) background=\(UIApplication.shared.applicationState == .background)")
        pmdCommands.enqueue(commands)
        pumpPMDCommands()
    }

    private func notePMDSampleReceived(_ stream: PMDStreamRecovery.Stream, at receivedAt: Date,
                                      uptime: TimeInterval) -> Bool {
        guard pmdRecovery.received(stream, at: receivedAt, uptime: uptime) else { return false }
        pmdCommands.removePendingStart(measurement: stream == .ecg ?
            PolarH10Profile.typeECGMeas : PolarH10Profile.typeACCMeas)
        if inSlowRetry, ecgStreamLive, accStreamLive {
            inSlowRetry = false
            if lastError == "Sensor stream stalled — still retrying in the background" { lastError = nil }
            BLEDiag.log("PMD streams recovered")
        }
        return true
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
        emitRecordingGap()
        state = .disconnected(reason: error?.localizedDescription ?? "Disconnected")

        // Persistent, no-timeout pending reconnect — no scan, no give-up. iOS
        // completes it the instant the strap advertises again (worn / back in
        // range). This is what makes reconnection seamless: the app is always
        // ready and never needs a manual scan.
        guard !userDisconnected else { return }
        if systemIsReconnecting {
            BLEDiag.log("CONNECT system auto-reconnect pending id=\(p.identifier)")
            state = .connecting(name: supportedName(p) ?? "Polar H10")
            connectionRecovery.requested(at: Date(), uptime: ProcessInfo.processInfo.systemUptime)
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
            defer { self.diagnosticStateSubject.send() }
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
                self.emitRecordingGap()
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
        let connectedUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            guard !self.userDisconnected,
                  self.peripheral?.identifier == peripheral.identifier,
                  let name = self.supportedName(peripheral) else {
                self.rejectPeripheral(peripheral, source: "didConnect")
                return
            }
            guard peripheral.state == .connected,
                  connectedUptime >= (self.connectionEstablishedUptime ?? 0) else { return }
            // Auto-reconnect may have completed before its delayed disconnect
            // event. Always initialize the new connection independently.
            self.clearCharacteristics()
            self.emitRecordingGap()
            // A live connection outdates any earlier failure — most visibly the
            // "No Polar H10 found (30 s)" scan timeout, which otherwise stays
            // on screen under a green connected card.
            self.lastError = nil
            self.inStandby = false      // worn again — leaving off-body standby
            self.pairing.remember(id: peripheral.identifier, name: name)
            BLEDiag.log("CONNECTED id=\(peripheral.identifier) name=\(name)")
            self.connectionRecovery.connectionSucceeded()
            self.connectionEstablishedAt = connectedAt
            self.connectionEstablishedUptime = connectedUptime
            self.discoveryRetryCount = 0
            self.recentConnectFailures.removeAll()
            self.state = .connected(name: name)
            self.rrRecovery.beginConnection(at: connectedAt, uptime: connectedUptime)
            self.recoveryCommands.beginConnection()
            self.discoverServices()
            self.startWatchdog()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let failedAt = Date()
        let failedUptime = ProcessInfo.processInfo.systemUptime
        let nsError = error as NSError?
        print("❌ BLE: failed to connect — \(error?.localizedDescription ?? "unknown")"
              + (nsError.map { " (\($0.domain) \($0.code))" } ?? ""))
        Task { @MainActor in
            guard self.canceledPeripheralIDs.remove(peripheral.identifier) == nil,
                  self.supportedName(peripheral) != nil,
                  self.connectionRecovery.acceptsFailure(
                    targetID: self.peripheral?.identifier, failedID: peripheral.identifier,
                    userDisconnected: self.userDisconnected, linkState: peripheral.state,
                    at: failedAt, connectedAt: self.connectionEstablishedAt,
                    uptime: failedUptime, connectedUptime: self.connectionEstablishedUptime) else { return }
            self.clearCharacteristics()   // keep the peripheral for a re-arm
            if let error { self.noteDiagnosticError(error) }

            let now = Date()
            let invalidParameters = BLEConnectionParameters.isInvalidParameters(error)
            let switchedToBasic = self.connectionParameters.rejected(error, for: peripheral.identifier)
            if invalidParameters {
                self.recentConnectFailures.removeAll()
            } else {
                self.recentConnectFailures.append(now)
            }
            self.recentConnectFailures.removeAll { now.timeIntervalSince($0) > 300 }
            let span = self.recentConnectFailures.first.map { now.timeIntervalSince($0) } ?? 0
            let looksLikeContention = ConnectionFailurePattern.looksLikeContention(
                recentFailureCount: self.recentConnectFailures.count, windowSeconds: span, error: error)
            BLEDiag.log("connect failed: \(nsError.map { "\($0.domain) \($0.code)" } ?? "unknown")"
                       + (looksLikeContention ? " — repeated in \(Int(span))s" : ""))

            if switchedToBasic {
                BLEDiag.log("CONNECT parameters rejected — immediate basic fallback id=\(peripheral.identifier)")
            }
            self.lastError = ConnectionFailurePattern.message(for: error, usingBasicRetry: switchedToBasic,
                recentFailureCount: self.recentConnectFailures.count, windowSeconds: span)
            // Keep the current selected H10, including a first connection.
            // A scan fallback could otherwise switch back to the old strap.
            let delay = switchedToBasic ? 0 : self.connectionRecovery.failedAttemptDelay()
            // The first basic request is registered immediately, including in
            // the background. Subsequent basic failures back off locally; the
            // regular path keeps using the system-owned delayed request.
            self.armPendingConnect(peripheral, delay: delay)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let disconnectedAt = Date()
        let disconnectedUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            self.handleDisconnectEvent(peripheral, disconnectedAt: disconnectedAt,
                                       disconnectedUptime: disconnectedUptime,
                                       systemIsReconnecting: false, error: error)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    timestamp: CFAbsoluteTime, isReconnecting: Bool,
                                    error: Error?) {
        let disconnectedAt = Date(timeIntervalSinceReferenceDate: timestamp)
        let disconnectedUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            self.handleDisconnectEvent(peripheral, disconnectedAt: disconnectedAt,
                                       disconnectedUptime: disconnectedUptime,
                                       systemIsReconnecting: isReconnecting, error: error)
        }
    }

    private func handleDisconnectEvent(_ p: CBPeripheral, disconnectedAt: Date?,
                                       disconnectedUptime: TimeInterval,
                                       systemIsReconnecting: Bool, error: Error?) {
        let wasCanceled = canceledPeripheralIDs.remove(p.identifier) != nil
        let action = BLEConnectionRecovery.disconnectAction(
            isCurrent: peripheral?.identifier == p.identifier && supportedName(p) != nil,
            userDisconnected: userDisconnected, wasCanceled: wasCanceled,
            linkState: p.state, systemIsReconnecting: systemIsReconnecting,
            disconnectedAt: disconnectedAt, connectedAt: connectionEstablishedAt,
            disconnectedUptime: disconnectedUptime, connectedUptime: connectionEstablishedUptime)
        switch action {
        case .ignore: return
        case .waitForSystem:
            if let error { noteDiagnosticError(error) }
            handleUnexpectedDisconnect(p, error: error, systemIsReconnecting: true)
        case .reconnect:
            if let error { noteDiagnosticError(error) }
            handleUnexpectedDisconnect(p, error: error)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        if let error { print("❌ BLE: service discovery error — \(error)") }
        Task { @MainActor in
            guard self.acceptsConnectionCallback(peripheral, uptime: receivedUptime) else { return }
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
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        if let error { print("❌ BLE: char discovery error — \(error)") }
        Task { @MainActor in
            guard self.acceptsConnectionCallback(peripheral, uptime: receivedUptime),
                  peripheral.services?.contains(where: { $0 === service }) == true else { return }
            guard error == nil, let chars = service.characteristics else {
                self.retryOrGiveUpOnDiscoveryFailure(peripheral)
                return
            }
            for c in chars {
                switch c.uuid {
                case PolarH10Profile.pmdControl:
                    if let old = self.pmdControl, old !== c {
                        self.pmdCommandTask?.cancel()
                        self.pmdCommands.reset()
                        self.pmdStreamsStarted = false
                    }
                    self.pmdControl = c
                    print("✅ BLE: PMD control char found")
                case PolarH10Profile.pmdData:
                    if let old = self.pmdData, old !== c { self.pmdStreamsStarted = false }
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
        let receivedUptime = ProcessInfo.processInfo.systemUptime

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
                let hasSamples = (parsed as? ECGFrame).map { !$0.samplesUV.isEmpty }
                    ?? (parsed as? ACCFrame).map { !$0.samples.isEmpty } ?? false
                captureAudit?.recordBLE(stream, rrCount: 0, valid: hasSamples, at: receivedAt)
            }
            Task { @MainActor in
                guard self.acceptsConnectionCallback(peripheral, uptime: receivedUptime),
                      characteristic === self.pmdData,
                      !self.inStandby, let sessionStartedUptime = self.pmdSessionStartedUptime,
                      receivedUptime >= sessionStartedUptime,
                      self.rrRecovery.acceptsPacket(at: receivedAt, uptime: receivedUptime) else { return }
                if sealed { self.rawChunkReadySubject.send(()) }
                if let ecg = parsed as? ECGFrame, !ecg.samplesUV.isEmpty {
                    guard self.notePMDSampleReceived(.ecg, at: receivedAt, uptime: receivedUptime) else { return }
                    self.ecgSubject.send(ecg.samplesUV.map { Float($0) })
                } else if let acc = parsed as? ACCFrame, !acc.samples.isEmpty {
                    guard self.notePMDSampleReceived(.acc, at: receivedAt, uptime: receivedUptime) else { return }
                    self.accSubject.send(acc.samples)
                }
                self.applyRecordingRecovery(self.rrRecovery.receivedPacket(at: receivedAt, uptime: receivedUptime))
                self.evaluatePMDWatchdog()
            }

        case PolarH10Profile.pmdControl:
            guard data.count >= 4, data[0] == 0xF0 else { return }
            let opCode = data[1], measurement = data[2], status = data[3]
            Task { @MainActor in
                guard self.acceptsConnectionCallback(peripheral, uptime: receivedUptime),
                      characteristic === self.pmdControl else { return }
                guard let transaction = self.pmdCommands.complete(
                    opCode: opCode, measurement: measurement, at: receivedAt, uptime: receivedUptime) else { return }
                defer { self.evaluatePMDWatchdog() }
                // A standby/resume may have replaced pending commands while
                // this transaction was on the wire. It can release the queue,
                // but cannot apply settings/errors to the newer session.
                guard transaction.generation == self.pmdCommands.generation else { return }
                BLEDiag.log("PMD result op=\(opCode) type=\(measurement) status=\(status)")
                if opCode == PolarH10Profile.opGetSettings, self.pmdStartupPending,
                   !self.inStandby, let parsed = PolarH10Profile.parseAvailableSettings(data) {
                    if parsed.measType == PolarH10Profile.typeECGMeas {
                        self.ecgSettings = parsed.settings
                    } else if parsed.measType == PolarH10Profile.typeACCMeas {
                        self.accSettings = parsed.settings
                    }
                } else if opCode == PolarH10Profile.opStart, status != 0, !self.inStandby {
                    self.diagnosticErrorDomain = .pmd
                    self.diagnosticErrorCode = Int(status)
                    self.diagnosticErrorAt = receivedAt
                    self.diagnosticStateSubject.send()
                    self.lastError = "PMD start error type=0x\(String(measurement, radix: 16)) status=0x\(String(status, radix: 16))"
                }
            }

        case PolarH10Profile.hrMeasurement:
            let sealed = recordRaw(.hr, data: data, receivedAt: receivedAt,
                                   deviceTimestampNs: nil)
            if sealed {
                Task { @MainActor in self.rawChunkReadySubject.send(()) }
            }
            let frame = PolarH10Profile.parseHRFrame(data)
            captureAudit?.recordBLE(.hr, rrCount: frame?.rrIntervalsMs.count ?? 0,
                                    valid: frame != nil,
                                    validRRCount: frame?.rrIntervalsMs.filter(RRSignalValidity.isValid).count ?? 0,
                                    at: receivedAt)
            if let frame {
                Task { @MainActor in
                    guard self.acceptsConnectionCallback(peripheral, uptime: receivedUptime),
                          characteristic === self.hrChar,
                          let name = self.supportedName(peripheral) else { return }
                    guard self.rrRecovery.acceptsHeartRate(at: receivedAt, uptime: receivedUptime) else { return }
                    let recoveryAction = self.rrRecovery.receivedHeartRate(frame, at: receivedAt, uptime: receivedUptime,
                        inStandby: self.inStandby, ecgLive: self.ecgStreamLive)
                    defer {
                        self.applyRecordingRecovery(recoveryAction)
                        self.evaluatePMDWatchdog()
                    }
                    // RR liveness for the PMD watchdog: this characteristic is
                    // independent of both PMD streams, so it can prove the
                    // link is alive while ECG and ACC are both stalled.
                    let hasValidRR = frame.rrIntervalsMs.contains(where: RRSignalValidity.isValid)
                    if hasValidRR {
                        self.lastRRIntervalAt = receivedAt
                        self.lastRRIntervalUptime = receivedUptime
                    }
                    if (30...220).contains(frame.bpm) {
                        self.lastPlausibleBPMAt = receivedAt
                        self.lastPlausibleBPMUptime = receivedUptime
                    }
                    self.sensorContact = frame.contact
                    // Paused for off-body: keep watching the contact bit over the
                    // lightweight HR link and resume the moment the strap is worn
                    // again. Don't forward off-body beats into the pipeline.
                    if self.inStandby {
                        // Contact bit when reported; otherwise a run of
                        // physiologically consistent beats — see StandbyResumeGate.
                        let inStandbyFor = self.standbyEnteredUptime.map {
                            receivedUptime - $0
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
                            self.lastForwardedBeatUptime = receivedUptime
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
                    if hasValidRR {
                        self.lastForwardedBeatUptime = receivedUptime
                    }
                    self.hrSubject.send(frame)
                }
            }

        case PolarH10Profile.batteryLevel:
            guard let byte = data.first else { return }
            let level = Int(byte)
            Task { @MainActor in
                guard self.acceptsConnectionCallback(peripheral, uptime: receivedUptime),
                      characteristic === self.battChar else { return }
                self.batteryLevel = level
                self.alertIfBatteryCritical(level)
            }

        default: break
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            guard self.acceptsConnectionCallback(peripheral, uptime: receivedUptime) else { return }
            if let error { self.noteDiagnosticError(error) }
            if characteristic === self.hrChar {
                if let error { BLEDiag.log("HR notification error: \(error.localizedDescription)") }
                self.performRecoveryCommand(self.recoveryCommands.hrNotificationStateUpdated())
                self.checkRecordingRecovery()
            } else if characteristic === self.pmdControl || characteristic === self.pmdData {
                if let error { BLEDiag.log("PMD notification error: \(error.localizedDescription)") }
                self.evaluatePMDWatchdog()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber,
                                error: Error?) {
        let receivedAt = Date()
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            guard self.acceptsConnectionCallback(peripheral, uptime: receivedUptime) else { return }
            if error == nil {
                self.applyRecordingRecovery(self.rrRecovery.receivedPacket(at: receivedAt, uptime: receivedUptime))
            } else {
                self.checkRecordingRecovery()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            guard self.acceptsConnectionCallback(peripheral, uptime: receivedUptime),
                  characteristic === self.pmdControl,
                  let transaction = self.pmdCommands.inFlight,
                  transaction.sentUptime.map({ receivedUptime >= $0 }) == true,
                  transaction.generation == self.pmdCommands.generation else { return }
            // ATT write acknowledgement is not the sensor's PMD response.
            // Even a write error is bounded by the transaction timeout; a
            // delayed ACK must not complete a different PMD transaction.
            if let error {
                self.noteDiagnosticError(error)
                BLEDiag.log("PMD write error: \(error.localizedDescription)")
            }
            self.evaluatePMDWatchdog()
        }
    }
}
