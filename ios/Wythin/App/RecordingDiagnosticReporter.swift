import Foundation

/// A best-effort timer and direct lifecycle/capture hooks, independent of metric
/// production. Missing reports during suspension remain unknown on the server.
@MainActor
final class RecordingDiagnosticReporter {
    typealias Event = RecordingDiagnosticEvent
    private let identity: () -> (installationID: UUID, launchID: UUID, launchSequence: Int)
    private let appVersion: String
    private let appBuild: String
    private let osVersion: String
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let enabled: () -> Bool
    private let nextSequence: () -> Int
    private let droppedReports: () -> Int
    private let sensor: () -> Event.Sensor
    private let delivery: () -> Event.Delivery
    private let submit: (Event) -> Void
    private var phase: Event.Phase = .unknown
    private var recording = Event.Recording()
    private var computedUptime: TimeInterval?
    private var savedUptime: TimeInterval?
    private var rrStart: TimeInterval?
    private var lastRR: TimeInterval?
    private var rrGeneration: UInt64?
    private var lastEmission: TimeInterval?
    private var pendingState = false
    private var collectionEnabled: Bool
    private var emittedLaunch: (installationID: UUID, launchID: UUID, launchSequence: Int)?
    private var timer: Task<Void, Never>?
    private let memoryMonitor: RecordingMemoryMonitor

    init(installationID: UUID, launchID: UUID, launchSequence: Int,
         appVersion: String, appBuild: String, osVersion: String,
         now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         enabled: @escaping () -> Bool, nextSequence: @escaping () -> Int,
         droppedReports: @escaping () -> Int, sensor: @escaping () -> Event.Sensor,
         delivery: @escaping () -> Event.Delivery, submit: @escaping (Event) -> Void,
         identity: (() -> (installationID: UUID, launchID: UUID, launchSequence: Int))? = nil,
         memoryMonitor: RecordingMemoryMonitor? = nil) {
        self.identity = identity ?? { (installationID, launchID, launchSequence) }
        self.appVersion = Event.technicalVersion(appVersion)
        self.appBuild = Event.technicalVersion(appBuild)
        self.osVersion = Event.technicalVersion(osVersion)
        self.now = now; self.uptime = uptime; self.enabled = enabled
        collectionEnabled = enabled()
        self.nextSequence = nextSequence; self.droppedReports = droppedReports
        self.sensor = sensor; self.delivery = delivery; self.submit = submit
        self.memoryMonitor = memoryMonitor ?? RecordingMemoryMonitor()
    }

    deinit { timer?.cancel() }

    func start(phase: Event.Phase) {
        self.phase = phase
        request(.launch)
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                self?.poll()
            }
        }
    }

    func setPhase(_ value: Event.Phase) { phase = value; request(.lifecycle) }

    func consentChanged() {
        let isEnabled = enabled()
        if isEnabled != collectionEnabled {
            collectionEnabled = isEnabled
            recording = Event.Recording()
            computedUptime = nil; savedUptime = nil
            resetRR(); lastEmission = nil; pendingState = false
            emittedLaunch = nil
        }
        if isEnabled { request(.launch) }
    }

    func sensorStateChanged() {
        let sensor = sensor()
        if !sensor.intended || sensor.connectionState != .connected { resetRR() }
        request(.state)
    }

    func resetRR() { rrStart = nil; lastRR = nil; rrGeneration = nil }

    func receivedRR(uptime received: TimeInterval, generation: UInt64) {
        guard enabled() else { return }
        let sensor = sensor()
        guard sensor.intended, sensor.connectionState == .connected else {
            resetRR()
            return
        }
        if rrGeneration != generation || lastRR.map({ received - $0 > 4 || received < $0 }) ?? true {
            rrStart = received
        }
        rrGeneration = generation; lastRR = received
    }

    func computed(sampleAt: Date) {
        guard enabled() else { return }
        recording.computedCount += 1
        recording.lastComputedAt = now(); recording.lastComputedSampleAt = sampleAt
        computedUptime = uptime()
    }

    func saved(sampleAt: Date) {
        guard enabled() else { return }
        let recovered = recording.saveErrorCode != nil
        recording.savedCount += 1
        recording.lastSavedAt = now(); recording.lastSavedSampleAt = sampleAt
        savedUptime = uptime()
        recording.saveErrorDomain = nil; recording.saveErrorCode = nil
        if recovered { request(.state) }
    }

    func saveFailed(_ error: Error) {
        guard enabled() else { return }
        let ns = error as NSError
        let domain: Event.SaveErrorDomain = ns.domain == NSCocoaErrorDomain ? .cocoa :
            (ns.domain == "NSSQLiteErrorDomain" ? .sqlite : .other)
        let code = Event.errorCode(error)
        let changed = recording.saveErrorDomain != domain || recording.saveErrorCode != code
        recording.failedSaveCount += 1
        recording.saveErrorDomain = domain; recording.saveErrorCode = code
        request(changed ? .saveError : .state)
    }

    func poll() {
        guard enabled() else { return }
        let elapsed = lastEmission.map { uptime() - $0 } ?? .infinity
        if pendingState && elapsed >= 15 { request(.state) }
        else if elapsed >= 60 && (phase == .foreground || sensor().intended) { request(.heartbeat) }
    }

    func request(_ reason: Event.Reason) {
        guard enabled() else { return }
        let identity = identity()
        // Never consume an event sequence for an identity that could not be
        // persisted yet (for example before the first unlock after reboot).
        guard identity.launchSequence > 0 else { return }
        if reason == .launch, let emittedLaunch, emittedLaunch == identity { return }
        let clock = uptime()
        if reason == .state, let lastEmission, clock - lastEmission < 15 {
            pendingState = true
            return
        }
        let sensor = sensor()
        if !sensor.intended || sensor.connectionState != .connected ||
            !sensor.rrLive || lastRR.map({ clock - $0 > 4 || clock < $0 }) ?? true { resetRR() }
        var recording = recording
        recording.computedAgeSeconds = computedUptime.map { max(0, clock - $0) }
        recording.savedAgeSeconds = savedUptime.map { max(0, clock - $0) }
        recording.rrActiveAgeSeconds = rrStart.map { max(0, clock - $0) }
        let sequence = nextSequence()
        guard sequence > 0 else { return }
        memoryMonitor.record(reason, uptime: clock)
        if reason == .launch { emittedLaunch = identity }
        submit(Event(installationId: identity.installationID, launchId: identity.launchID,
            launchSequence: identity.launchSequence, sequence: sequence, observedAt: now(),
            uptimeSeconds: max(0, clock), reason: reason, appVersion: appVersion,
            appBuild: appBuild, osVersion: osVersion, phase: phase, sensor: sensor,
            recording: recording, delivery: delivery(), droppedReports: droppedReports()))
        lastEmission = clock; pendingState = false
    }
}
