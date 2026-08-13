import CoreBluetooth
import Combine
import Foundation
import UserNotifications

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
enum ACCWatchdogPolicy {

    enum Action: Equatable {
        /// Nothing wrong (or a retry was just issued) — check again next tick.
        case keepWaiting
        /// ECG is flowing, ACC has been silent past the threshold, a retry slot
        /// remains, and enough time has passed since the last retry — reissue
        /// the ACC start command.
        case retryACCStart
        /// Retry budget exhausted with ACC still silent — stop trying until the
        /// next full stream restart (reconnect or standby/resume cycle), which
        /// rearms the watchdog with a fresh budget.
        case giveUp
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
        timeSinceLastACCSample: TimeInterval,
        timeSinceLastRetry: TimeInterval?,
        retriesUsed: Int,
        stallThreshold: TimeInterval,
        retryGap: TimeInterval,
        maxRetries: Int
    ) -> Action {
        guard isConnected, !inStandby else { return .keepWaiting }
        // Both streams silent → the connection is the problem, not a lost ACC
        // start. Stay quiet and let the reconnect/standby machinery handle it.
        guard ecgFlowing else { return .keepWaiting }
        guard timeSinceLastACCSample >= stallThreshold else { return .keepWaiting }
        guard retriesUsed < maxRetries else { return .giveUp }
        if let timeSinceLastRetry, timeSinceLastRetry < retryGap { return .keepWaiting }
        return .retryACCStart
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
    var discoveredDevices: [BLEDevice] = []
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

    // MARK: Private

    private var centralManager:        CBCentralManager!
    private var peripheral:            CBPeripheral?
    private var pmdControl:            CBCharacteristic?
    private var pmdData:               CBCharacteristic?
    private var hrChar:                CBCharacteristic?
    private var battChar:              CBCharacteristic?
    private var peripheralMap:         [UUID: CBPeripheral] = [:]
    private var connectionTimeoutTask: Task<Void, Never>?
    private var scanTimeoutTask:       Task<Void, Never>?
    private var settingsQueryTask:     Task<Void, Never>?
    private var reconnectTask:         Task<Void, Never>?  // cancellable, replaces asyncAfter
    private var watchdogTask:          Task<Void, Never>?  // detects silent drops
    private var accWatchdogTask:       Task<Void, Never>?  // detects a stalled ACC stream while ECG flows

    private var ecgSettings: [UInt8: [UInt16]]?
    private var accSettings: [UInt8: [UInt16]]?

    // ACC watchdog liveness/retry state — see ACCWatchdogPolicy and evaluateACCWatchdog().
    private(set) var lastECGSampleAt: Date?

    /// ECG frames arrived within the last 5 s — direct evidence the strap is
    /// worn, used when firmware doesn't report the HR contact flag.
    var ecgStreamLive: Bool {
        lastECGSampleAt.map { Date().timeIntervalSince($0) < 5 } ?? false
    }
    private var lastACCSampleAt: Date?
    private var lastACCRetryAt:  Date?
    private var accRetryCount:   Int = 0
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
    private static let accWatchdogMaxRetries:  Int          = 3
    private static let accWatchdogPollInterval: TimeInterval = 2.0

    private let bleQueue       = DispatchQueue(label: "com.wythin.ble", qos: .userInitiated)
    private let savedDeviceKey = "wythin.polar.uuid"
    private var pmdStreamsStarted = false

    // Backoff state — grows 2s → 4s → 8s → 16s → 30s on repeated unexpected disconnects.
    private var reconnectDelay: TimeInterval = 2.0

    // When true, the next didDisconnectPeripheral callback is expected (we triggered it)
    // and should NOT auto-reconnect. Cleared immediately after use.
    private var suppressNextDisconnect = false

    // When true, auto-scan on BT-power-on is skipped (user intentionally disconnected).
    private var userDisconnected = false

    // When true, we're in off-body standby: streaming stopped, a no-timeout
    // pending connect is armed. Cleared on (re)connect and on manual disconnect.
    private var inStandby = false

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

    /// Start scanning for a Polar H10. Cancels any pending reconnect timers.
    /// Clears the device list so the UI shows fresh results.
    func startScanning() {
        userDisconnected = false       // explicit scan request resets the "stay idle" flag
        print("🔵 BLE: startScanning — central state: \(centralManager.state.rawValue)")

        guard centralManager.state == .poweredOn else {
            // BT not ready yet — set scanning so centralManagerDidUpdateState retries
            state = .scanning
            return
        }

        lastError = nil
        discoveredDevices = []
        peripheralMap = [:]
        connectionTimeoutTask?.cancel()
        scanTimeoutTask?.cancel()
        reconnectTask?.cancel()

        // If a connection is in progress, cancel it first so we start clean.
        if let p = peripheral {
            suppressNextDisconnect = true
            centralManager.cancelPeripheralConnection(p)
        }
        clearConnectionState()
        centralManager.stopScan()

        // ── Step 1: check if H10 is already OS-connected (another app, background restore).
        // This covers the common case where Polar Flow or a previous session holds the connection.
        let alreadyConnected = centralManager.retrieveConnectedPeripherals(withServices: [
            PolarH10Profile.heartRateService,
            PolarH10Profile.pmdService,
        ])
        if let p = alreadyConnected.first {
            print("✅ BLE: device already OS-connected — \(p.name ?? "?")")
            peripheralMap[p.identifier] = p
            let name = p.name ?? "Polar H10"
            discoveredDevices = [BLEDevice(id: p.identifier, name: name, rssi: -65)]
            state = .connecting(name: name)
            doConnect(p)
            return
        }

        // ── Step 2: scan.
        // Scan with nil (no service filter) so iOS delivers ALL advertising devices.
        // Service-UUID filtering works only if the H10 includes the UUID in its ad
        // packet — some Polar H10 firmware versions omit it, so a service filter
        // silently drops the device before didDiscover is called.
        // We filter for Polar devices by name in didDiscover instead.
        state = .scanning
        print("🔵 BLE: scanning (all devices, Polar name filter in didDiscover)…")
        // AllowDuplicates keeps didDiscover firing for every advertisement, so
        // RSSI (and the nearest-first sort) stays live as the phone moves.
        // Battery cost is fine: the scan is foreground, user-initiated, and
        // bounded by the 30 s timeout below.
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        scanTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard case .scanning = self.state else { return }
            self.centralManager.stopScan()
            self.state = .idle
            self.lastError = "No Polar H10 found (30 s). Make sure it is powered on and nearby."
        }
    }

    func stopScanning() {
        scanTimeoutTask?.cancel()
        centralManager.stopScan()
        if case .scanning = state { state = .idle }
    }

    /// Seamless auto-connect to the already-paired strap. Arms a persistent,
    /// no-timeout connect so iOS reconnects the moment the strap is worn again —
    /// no scan, no tap, no give-up. Safe to call repeatedly (launch, foreground,
    /// BT power-on, disconnect). No-op if the user explicitly disconnected, we're
    /// paused/connected/connecting, BT isn't ready, or no strap is saved yet.
    func ensureAutoConnect() {
        guard !userDisconnected, !inStandby,
              centralManager.state == .poweredOn else { return }
        switch state {
        case .connected, .connecting, .standby: return
        default: break
        }
        guard let uuidStr = UserDefaults.standard.string(forKey: savedDeviceKey),
              let uuid = UUID(uuidString: uuidStr) else { return }

        // Adopt an already-OS-connected strap (e.g. after state restoration).
        if let p = centralManager.retrieveConnectedPeripherals(withServices: [
            PolarH10Profile.heartRateService, PolarH10Profile.pmdService,
        ]).first(where: { $0.identifier == uuid }) {
            print("✅ BLE: auto-connect — adopting OS-connected strap")
            peripheralMap[p.identifier] = p
            state = .connecting(name: p.name ?? "Polar H10")
            doConnect(p)
            return
        }
        // Otherwise arm a no-timeout pending connect that fulfils on advertise.
        if let p = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first {
            print("🔵 BLE: auto-connect — armed persistent pending connect")
            peripheralMap[p.identifier] = p
            armPendingConnect(p)
        }
    }

    /// Connect to a device the user tapped in the list.
    func connectToDevice(_ device: BLEDevice) {
        print("🔵 BLE: connectToDevice — '\(device.name)'")
        centralManager.stopScan()
        scanTimeoutTask?.cancel()

        // Prefer the peripheral object captured during scanning over re-retrieval,
        // because retrieved peripherals may have stale state on older iOS.
        let p = peripheralMap[device.id]
               ?? centralManager.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let p else {
            lastError = "\(device.name) is no longer reachable. Tap Scan to try again."
            state = .idle
            return
        }
        state = .connecting(name: device.name)
        doConnect(p)
    }

    /// Intentional user-initiated disconnect. Does not trigger auto-reconnect.
    func disconnect() {
        guard let p = peripheral else { return }
        print("🔵 BLE: user disconnect")
        userDisconnected = true
        inStandby = false
        suppressNextDisconnect = true
        connectionTimeoutTask?.cancel()
        scanTimeoutTask?.cancel()
        reconnectTask?.cancel()
        settingsQueryTask?.cancel()
        stopPMDStreams()
        centralManager.cancelPeripheralConnection(p)
        clearConnectionState()
        reconnectDelay = 2.0
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
        inStandby = true
        connectionTimeoutTask?.cancel()
        reconnectTask?.cancel()
        watchdogTask?.cancel()
        accWatchdogTask?.cancel()
        connectionGapSubject.send()      // discard buffered off-body beats
        stopPMDStreams()                 // stop ECG/ACC; keep HR for contact
        pmdStreamsStarted = false        // allow a clean restart on resume
        state = .standby(name: p.name ?? "Polar H10")
    }

    /// Resume from off-body standby — the strap is worn again (contact restored).
    /// Restart the ECG/ACC streams and mark the link live.
    private func resumeFromStandby(name: String) {
        guard inStandby, peripheral != nil else { return }
        print("🌙 BLE: resuming from standby — strap worn again")
        inStandby = false
        state = .connected(name: name)
        startPMDStreams()
        startWatchdog()
    }

    // MARK: - Private helpers

    /// Register a no-timeout pending connection: unlike `doConnect`, no 15 s
    /// timeout is armed, so iOS keeps the request queued indefinitely and
    /// connects when the peripheral next advertises (strap put back on).
    private func armPendingConnect(_ p: CBPeripheral) {
        print("🌙 BLE: armed pending reconnect (no timeout) — waiting for strap-on")
        peripheral = p
        p.delegate = self
        pmdStreamsStarted = false
        ecgSettings = nil
        accSettings = nil
        centralManager.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    private func doConnect(_ p: CBPeripheral) {
        print("🔵 BLE: doConnect — '\(p.name ?? "?")'  p.state=\(p.state.rawValue)")
        peripheral = p
        p.delegate = self
        // Reset stream state so startPMDStreams runs fresh after this connection.
        pmdStreamsStarted = false
        ecgSettings = nil
        accSettings = nil
        // NotifyOnDisconnection ensures the app receives didDisconnectPeripheral
        // even when suspended — critical for detecting drops caused by other BT
        // devices connecting to the iPhone.
        centralManager.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])

        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard case .connecting = self.state else { return }
            print("⏱️ BLE: connection timed out — falling back to scan")
            // Cancel the pending connect without triggering auto-reconnect.
            self.suppressNextDisconnect = true
            if let p = self.peripheral {
                self.centralManager.cancelPeripheralConnection(p)
            }
            self.clearConnectionState()
            self.reconnectDelay = 2.0   // timeout ≠ dropped connection; reset backoff
            self.lastError = "H10 not responding. Is it powered on and in range?"
            // Restart scan so the device list becomes visible for manual retry.
            self.startScanning()
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
        print("🔵 BLE: starting ECG — \(ecg.hexLog)")
        p.writeValue(ecg, for: ctrl, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let ctrl = self.pmdControl, let p = self.peripheral else { return }
            print("🔵 BLE: starting ACC — \(acc.hexLog)")
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

    /// Zero out all connection-specific state. Does NOT touch `state`, `reconnectDelay`,
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
                guard case .connected = self.state,
                      let p = self.peripheral,
                      p.state != .connected else { continue }
                print("🔴 BLE watchdog: silent disconnect detected — reconnecting")
                self.handleUnexpectedDisconnect(p, error: nil)
            }
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
        print("🔵 BLE: ACC watchdog armed — stall threshold \(Int(Self.accStallThreshold))s, max \(Self.accWatchdogMaxRetries) retries")

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
        let timeSinceACC = lastACCSampleAt.map { now.timeIntervalSince($0) } ?? .infinity
        let timeSinceRetry = lastACCRetryAt.map { now.timeIntervalSince($0) }

        let action = ACCWatchdogPolicy.decide(
            isConnected: true,
            inStandby: inStandby,
            ecgFlowing: ecgFlowing,
            timeSinceLastACCSample: timeSinceACC,
            timeSinceLastRetry: timeSinceRetry,
            retriesUsed: accRetryCount,
            stallThreshold: Self.accStallThreshold,
            retryGap: Self.accRetryGap,
            maxRetries: Self.accWatchdogMaxRetries
        )

        switch action {
        case .keepWaiting:
            break

        case .retryACCStart:
            accRetryCount += 1
            lastACCRetryAt = now
            print("🟡 BLE: ACC watchdog — no ACC samples for \(Int(timeSinceACC))s while ECG flowing — stall detected")
            print("🔵 BLE: ACC watchdog — reissuing ACC start (attempt \(accRetryCount)/\(Self.accWatchdogMaxRetries))")
            p.writeValue(accCmd, for: ctrl, type: .withResponse)

        case .giveUp:
            print("🔴 BLE: ACC watchdog — retry budget exhausted (\(Self.accWatchdogMaxRetries)/\(Self.accWatchdogMaxRetries)) — giving up until next reconnect/standby cycle")
            lastError = "ACC stream stalled — breathing metrics unavailable until reconnect"
            accWatchdogTask?.cancel()
        }
    }

    /// Records ACC liveness. If the watchdog had been retrying, logs the
    /// recovery and resets the retry budget so a later stall gets a full fresh
    /// set of retries.
    private func noteACCSampleReceived() {
        lastACCSampleAt = Date()
        if accRetryCount > 0 {
            print("✅ BLE: ACC watchdog — ACC stream recovered after \(accRetryCount) retry attempt(s)")
        }
        accRetryCount  = 0
        lastACCRetryAt = nil
    }

    // MARK: - Unexpected disconnect handler

    /// Shared logic for both watchdog-detected and delegate-reported unexpected drops.
    /// Keeps the peripheral reference and attempts a direct reconnect (no scan needed —
    /// iOS will reconnect to the known peripheral as soon as it's available).
    private func handleUnexpectedDisconnect(_ p: CBPeripheral, error: Error?) {
        connectionTimeoutTask?.cancel()
        reconnectTask?.cancel()
        clearCharacteristics()          // keep `peripheral` for the pending reconnect
        connectionGapSubject.send()
        state = .disconnected(reason: error?.localizedDescription ?? "Disconnected")

        // Persistent, no-timeout pending reconnect — no scan, no give-up. iOS
        // completes it the instant the strap advertises again (worn / back in
        // range). This is what makes reconnection seamless: the app is always
        // ready and never needs a manual scan.
        guard !userDisconnected else { return }
        armPendingConnect(p)
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
                    if UserDefaults.standard.string(forKey: self.savedDeviceKey) != nil {
                        self.ensureAutoConnect()
                    } else {
                        self.startScanning()
                    }
                }
            case .unauthorized:
                self.state = .unauthorized
            case .unsupported:
                self.state = .unsupported
            case .poweredOff, .resetting:
                // BT went away — cancel timers, clean up, wait for poweredOn
                self.connectionTimeoutTask?.cancel()
                self.scanTimeoutTask?.cancel()
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
                as? [CBPeripheral],
              let p = peripherals.first else { return }
        p.delegate = self
        Task { @MainActor in
            self.peripheralMap[p.identifier] = p
            if p.state == .connected {
                // Already connected — just attach
                self.peripheral = p
                self.pmdStreamsStarted = false
                self.state = .connected(name: p.name ?? "Polar H10")
                self.discoverServices()
            } else {
                // Was connecting — try again via doConnect so timeout is set correctly
                self.state = .connecting(name: p.name ?? "Polar H10")
                self.doConnect(p)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        // Resolve device name: prefer peripheral.name (cached by iOS) then
        // the ad-packet local name. Polar H10 always advertises "Polar H10".
        let name = peripheral.name
                   ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
                   ?? ""

        // Filter: only Polar devices or devices advertising the HR service UUID.
        // This is more reliable than a service-UUID scan filter because some H10
        // firmware versions don't include the HR UUID in the ad packet, so iOS
        // would silently drop them before didDiscover is called.
        let adServiceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isPolar   = name.localizedCaseInsensitiveContains("Polar") ||
                        name.localizedCaseInsensitiveContains("H10")
        let hasHRUUID = adServiceUUIDs.contains(PolarH10Profile.heartRateService)
        guard isPolar || hasHRUUID else { return }

        let displayName = name.isEmpty ? "Polar H10" : name
        let rssiVal = RSSI.intValue
        let uuid    = peripheral.identifier

        Task { @MainActor in
            // With AllowDuplicates on, this fires for every ad packet — log
            // only the first sighting to keep the console readable.
            if self.peripheralMap[uuid] == nil {
                print("📡 BLE: found '\(displayName)' RSSI \(rssiVal) dB  \(uuid)")
            }
            self.peripheralMap[uuid] = peripheral

            self.discoveredDevices = DeviceRanking.merge(
                self.discoveredDevices, id: uuid, name: displayName, rssi: rssiVal)

            // Auto-connect when the previously-used device is found
            let savedUUID = UserDefaults.standard.string(forKey: self.savedDeviceKey)
            guard uuid.uuidString == savedUUID else { return }
            guard case .scanning = self.state else { return }  // don't interrupt an active connection
            print("✅ BLE: saved device found — auto-connecting")
            self.scanTimeoutTask?.cancel()
            self.centralManager.stopScan()
            self.state = .connecting(name: displayName)
            self.doConnect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        print("✅ BLE: connected to '\(peripheral.name ?? "?")'")
        Task { @MainActor in
            self.connectionTimeoutTask?.cancel()
            self.inStandby = false      // worn again — leaving off-body standby
            UserDefaults.standard.set(peripheral.identifier.uuidString,
                                       forKey: self.savedDeviceKey)
            self.reconnectDelay = 2.0   // successful connection resets backoff
            self.state = .connected(name: peripheral.name ?? "Polar H10")
            self.discoverServices()
            self.startWatchdog()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        print("❌ BLE: failed to connect — \(error?.localizedDescription ?? "unknown")")
        Task { @MainActor in
            self.connectionTimeoutTask?.cancel()
            self.clearCharacteristics()   // keep the peripheral for a re-arm
            self.lastError = "Could not connect: \(error?.localizedDescription ?? "unknown error")"
            // For a paired strap, re-arm the persistent pending connect instead of
            // giving up to a scan — stays seamless. Only scan if nothing is saved.
            if !self.userDisconnected,
               UserDefaults.standard.string(forKey: self.savedDeviceKey) != nil {
                self.armPendingConnect(peripheral)
            } else {
                self.clearConnectionState()
                self.startScanning()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        print("⚠️ BLE: disconnected — \(error?.localizedDescription ?? "clean")")
        Task { @MainActor in
            // If we triggered this disconnect ourselves (intentional or timeout fallback),
            // the caller already handled state/cleanup — just reset the flag and return.
            if self.suppressNextDisconnect {
                self.suppressNextDisconnect = false
                // Off-body standby: now that the cancel has completed, arm the
                // low-power pending reconnect that fulfils on strap-on.
                if self.inStandby {
                    self.armPendingConnect(peripheral)
                }
                return
            }
            // Unexpected drop — reconnect directly without scanning.
            self.handleUnexpectedDisconnect(peripheral, error: error)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        if let error { print("❌ BLE: service discovery error — \(error)") }
        Task { @MainActor in
            guard error == nil, let services = peripheral.services else { return }
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
            guard error == nil, let chars = service.characteristics else { return }
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
        guard error == nil, let data = characteristic.value else { return }

        switch characteristic.uuid {

        case PolarH10Profile.pmdData:
            let parsed = PolarH10Profile.parsePMDFrame(data)
            Task { @MainActor in
                if let ecg = parsed as? ECGFrame {
                    self.lastECGSampleAt = Date()
                    self.ecgSubject.send(ecg.samplesUV.map { Float($0) })
                } else if let acc = parsed as? ACCFrame {
                    self.noteACCSampleReceived()
                    self.accSubject.send(acc.samples)
                }
            }

        case PolarH10Profile.pmdControl:
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
                        self.settingsQueryTask?.cancel()
                        self.launchStreams(ecg: PolarH10Profile.cmdECGStart,
                                           acc: PolarH10Profile.cmdACCStart)
                    }
                }

            case PolarH10Profile.opStart:
                let mt = String(measType, radix: 16, uppercase: true)
                if status == 0x00 {
                    print("✅ BLE: stream start type=0x\(mt) OK")
                } else {
                    let st = String(status, radix: 16, uppercase: true)
                    print("❌ BLE: stream start type=0x\(mt) failed status=0x\(st)")
                    Task { @MainActor in
                        self.lastError = "PMD start error type=0x\(mt) status=0x\(st)"
                    }
                }

            default:
                print("🔵 BLE: PMD response op=0x\(String(opCode, radix:16)) type=0x\(String(measType, radix:16)) status=0x\(String(status, radix:16))")
            }

        case PolarH10Profile.hrMeasurement:
            if let frame = PolarH10Profile.parseHRFrame(data) {
                let name = peripheral.name ?? "Polar H10"
                Task { @MainActor in
                    self.sensorContact = frame.contact
                    // Paused for off-body: keep watching the contact bit over the
                    // lightweight HR link and resume the moment the strap is worn
                    // again. Don't forward off-body beats into the pipeline.
                    if self.inStandby {
                        if frame.contact == true { self.resumeFromStandby(name: name) }
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
                    self.hrSubject.send(frame)
                }
            }

        case PolarH10Profile.batteryLevel:
            let level = Int(data[0])
            Task { @MainActor in
                self.batteryLevel = level
                self.alertIfBatteryCritical(level)
            }

        default: break
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
