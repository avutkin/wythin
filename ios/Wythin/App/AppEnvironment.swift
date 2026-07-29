import Foundation
import SwiftData
import Combine

// MARK: - WaveformDisplay
//
// Separate @Observable so 30-fps waveform updates don't invalidate views
// that only care about 2-s metric ticks (charts, rings, etc.).

@Observable
final class WaveformDisplay {
    var ecg: [Float] = []
    var acc: [Float] = []
    var rr:  [Float] = []
}

// MARK: - AppEnvironment
//
// Single dependency container injected at the root.
// All services are long-lived and share state.

@MainActor
@Observable
final class AppEnvironment {

    // MARK: Services

    let ble        = BLEService()
    let dataBuffer = DataBuffer()
    let sync:        SyncService
    let metricSync:  MetricSyncService

    // MARK: Waveform display (updated at ~30 fps, isolated so chart views stay at 2 s)

    let waveform = WaveformDisplay()

    // MARK: Session state (updated at ~2 s)

    var currentSession:  HRVSession?
    var latestTick:      MetricsTick?

    // MARK: Cross-tab navigation

    /// Set by any tab to request ContentView switch the selected tab.
    /// ContentView observes this and resets it to nil after acting on it.
    var pendingTabRequest: AppTab? = nil

    /// Lightweight scalar-only history for charts. Capped at 24 h of 2-s ticks.
    /// Uses a ring-buffer trim strategy (batch removal every trimBatch ticks)
    /// to avoid O(n) removeFirst on every append once the buffer is full.
    var tickHistory: [MetricsHistoryPoint] = []

    /// Bumped when `tickHistory` is bulk-(re)loaded — the initial async load and
    /// the foreground merge — but NOT on live 2-s appends. Lets the today charts
    /// refresh exactly when history lands, without re-rendering all 9 charts every
    /// tick (which the 15 s snapshot cadence deliberately avoids).
    var historyRevision: Int = 0

    // Usage telemetry: foreground interval start + a poll task watching the
    // strap connection for ECG-recording (connect→disconnect) intervals.
    private var foregroundStart: Date? = Date()
    private var usageRecordingTask: Task<Void, Never>?

    var isInForeground: Bool = true {
        didSet {
            if !isInForeground {
                // Flush pending writes immediately when leaving foreground
                // so data isn't lost if the OS terminates the process.
                if pendingSaveCount > 0 {
                    try? modelContainer.mainContext.save()
                    pendingSaveCount = 0
                }
                // Record the just-ended foreground interval as a usage event.
                if let start = foregroundStart {
                    logUsageEvent(type: "foreground", start: start)
                    foregroundStart = nil
                }
            } else {
                foregroundStart = Date()
                // Returning to foreground — merge any samples saved during background
                // into tickHistory so intraday charts show the full picture.
                reloadRecentHistory()
                retryPendingInsights()
                // Make sure the paired strap is (re)armed for seamless auto-connect.
                ble.ensureAutoConnect()
                // tickHistory is kept current in the background now, so refresh the
                // charts from it immediately on open (no fetch/refill wait).
                historyRevision += 1
            }
        }
    }

    // MARK: Config (persisted)

    var serverURL: URL {
        get {
            let s = UserDefaults.standard.string(forKey: "serverURL") ?? "https://api.77.42.73.250.sslip.io"
            return URL(string: s) ?? URL(string: "https://api.77.42.73.250.sslip.io")!
        }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: "serverURL") }
    }

    var userID: String { AppEnvironment.currentUserID() }

    /// Static so it can be read during `init`, before `self` is fully formed
    /// (the `userID` computed property can't be called that early).
    fileprivate static func currentUserID() -> String {
        if let id = UserDefaults.standard.string(forKey: "userID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "userID")
        return id
    }

    // MARK: Private

    // MARK: Nudges (SP6 Phase 1 — shadow mode)

    /// Evaluates state shifts on the live stream and records what would have
    /// fired. Nothing is delivered: no notifications, no UI, no permission
    /// prompt. Phase 2 turns delivery on once the thresholds are tuned.
    let nudges = NudgeEngine()

    private var nudgeBaseline: AnchorBaseline?
    private var nudgeBaselineAt: Date?
    private var lastNudgeEvalAt = Date.distantPast

    /// Anchors change once a day at most, so rebuilding hourly is generous.
    private let nudgeBaselineTTL: TimeInterval = 3600

    private func evaluateNudgesIfDue(now: Date) {
        guard now.timeIntervalSince(lastNudgeEvalAt) >= NudgeEngine.evaluationInterval else { return }
        lastNudgeEvalAt = now
        refreshNudgeBaselineIfStale(now: now)

        let context = modelContainer.mainContext
        let activeActivity = (try? context.fetch(FetchDescriptor<ActivityLog>()))?
            .contains(where: \.isActive) ?? false

        nudges.evaluate(baseline: nudgeBaseline,
                        bleStandby: false,          // standby short-circuits the tick loop
                        activityInProgress: activeActivity,
                        now: now)
    }

    private func refreshNudgeBaselineIfStale(now: Date) {
        if let at = nudgeBaselineAt, now.timeIntervalSince(at) < nudgeBaselineTTL { return }
        nudgeBaselineAt = now

        let context = modelContainer.mainContext
        guard let anchors = try? context.fetch(FetchDescriptor<DailyAnchor>()) else { return }

        // Today is excluded so the baseline is what came *before* now, matching
        // how the day-potential score builds it.
        let today = Calendar.current.startOfDay(for: now)
        let history = anchors.map(\.reading).filter { $0.day < today }
        let hour = Double(Calendar.current.component(.hour, from: now))
        nudgeBaseline = AnchorBaseline.build(history: history, todayHour: hour, now: now)
    }

    private let modelContainer: ModelContainer

    /// Main-actor context for stores that own their own persistence
    /// (e.g. `DayPotentialStore` reading and writing `DailyAnchor`).
    var modelContext: ModelContext { modelContainer.mainContext }
    private var autoSession:    HRVSession?
    private var cancellables = Set<AnyCancellable>()
    private var metricsTask:  Task<Void, Never>?
    private var displayTask:  Task<Void, Never>?

    private let maxTickHistory  = 43_200   // 24 h at 2 s/tick
    private let trimBatch       = 600      // trim this many entries at once (amortises O(n) shift)
    private let saveInterval    = 30       // persist to disk every 60 s (30 ticks × 2 s)
    private var pendingSaveCount = 0       // ticks accumulated since last save
    private var lastSaveAt: Date = .distantPast   // wall-clock cap so bg saves land ≤2 min
    private var lastBackgroundTick: Date = .distantPast  // throttles bg computation to 30 s
    private var lastMetricSyncAt: Date = .distantPast     // throttles cloud sync attempts to ~120 s

    // MARK: Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.sync = SyncService(serverURL: UserDefaults.standard.string(forKey: "serverURL")
            .flatMap(URL.init) ?? URL(string: "https://api.77.42.73.250.sslip.io")!)
        self.metricSync = MetricSyncService(client: sync.client, userID: AppEnvironment.currentUserID(),
                                             container: modelContainer)

        bindBLE()
        loadHistory()
        startUsageTracking()
        Task {
            let context = modelContainer.mainContext
            let uploader = SessionUploader(client: sync.client, userID: userID)
            await uploader.flushPending(context: context)
            let activityUploader = ActivityUploader(client: sync.client, userID: userID)
            await activityUploader.flushPending(context: context)
            let usageUploader = UsageUploader(client: sync.client, userID: userID)
            await usageUploader.flushPending(context: context)
        }
    }

    // MARK: Session control

    func startSession(context: ModelContext) {
        // End auto-session cleanly before switching to explicit
        if let bg = autoSession {
            bg.endedAt = Date()
            try? context.save()
        }
        autoSession = nil

        let session = HRVSession()
        context.insert(session)
        currentSession = session
        sync.beginSession(userID: userID)
    }

    func endSession(context: ModelContext) {
        guard let session = currentSession else { return }
        session.endedAt = Date()
        // Summarise
        let samples = session.samples
        if !samples.isEmpty {
            session.avgRSAms     = samples.compactMap(\.rsaMs).average()
            session.avgCoherence = samples.compactMap(\.coherence).average()
        }
        do {
            try context.save()
        } catch {
            print("❌ Failed to save session: \(error)")
        }
        currentSession = nil
        autoSession = nil
        Task {
            do {
                try await sync.uploadSession(session)
            } catch {
                print("❌ Failed to upload session: \(error)")
            }
        }
    }

    // MARK: Private — History loading

    private func loadHistory() {
        // Fetch + map up to ~43k rows OFF the main thread so app launch isn't
        // blocked; publish on the main actor and bump the revision so the today
        // charts fill the instant the data lands (no wait for the 15 s poll).
        let container = modelContainer
        let cutoff    = Date().addingTimeInterval(-86_400)
        let limit     = maxTickHistory
        Task { @MainActor in
            let pts: [MetricsHistoryPoint] = await Task.detached {
                let ctx = ModelContext(container)
                var descriptor = FetchDescriptor<HRVSample>(
                    predicate: #Predicate { $0.timestamp >= cutoff },
                    sortBy:    [SortDescriptor(\.timestamp)]
                )
                descriptor.fetchLimit = limit
                let samples = (try? ctx.fetch(descriptor)) ?? []
                return samples.map { MetricsHistoryPoint(from: $0) }
            }.value
            self.tickHistory = pts
            self.historyRevision += 1
        }
    }

    /// Merge samples written during background into tickHistory.
    /// Called when the app returns to foreground so live charts stay complete.
    private func reloadRecentHistory() {
        let context   = modelContainer.mainContext
        // Only fetch samples newer than the last point we already have.
        let afterDate = tickHistory.last?.timestamp ?? Date().addingTimeInterval(-86_400)
        var descriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp > afterDate },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        descriptor.fetchLimit = maxTickHistory
        let newSamples = (try? context.fetch(descriptor)) ?? []
        guard !newSamples.isEmpty else { return }
        let pts = newSamples.map { MetricsHistoryPoint(from: $0) }
        tickHistory.append(contentsOf: pts)
        if tickHistory.count > maxTickHistory + trimBatch {
            tickHistory.removeFirst(tickHistory.count - maxTickHistory)
        }
        historyRevision += 1
    }

    /// Retry any activities that finished without a generated insight,
    /// e.g. because the device was offline when the activity ended.
    private func retryPendingInsights() {
        let context = modelContainer.mainContext
        Task { await InsightGenerator(client: sync.client).flushPending(context: context) }
    }

    // MARK: BLE → DataBuffer → MetricsEngine pipeline

    // Off-body detector: timestamp when sustained bad/absent signal began.
    // After `offBodyStandbySeconds` of continuous off-body ticks we drop the
    // strap into low-power standby (auto-reconnects when worn again).
    private var offBodySince: Date?
    private let offBodyStandbySeconds:     TimeInterval = 60   // borderline consensus (score 2)
    private let offBodyStandbyFastSeconds: TimeInterval = 20   // strong agreement (score ≥ 3)

    // Accelerometer motion: worn straps always jitter a little (breathing,
    // ballistocardiogram, posture); a strap set down is dead-still. Rolling
    // window of recent per-axis samples → mean per-axis stddev = motion level.
    private var accWindow: [SIMD3<Float>] = []
    private let accWindowMax = 200
    /// Live motion level (mean per-axis stddev of recent ACC). Surfaced in the
    /// BLE sheet for calibration. nil until enough samples.
    var accMotion: Float? = nil
    /// Below this, the sensor is treated as physically still. Calibrated against
    /// the live readout: off-body on a table measures ~1.8–1.9, so 3.0 sits above
    /// that with margin and below normal worn motion.
    private let accStillnessThreshold: Float = 3.0

    /// Mean per-axis standard deviation of the rolling ACC window — the live
    /// motion level. nil until enough samples have accumulated.
    private func computeAccMotion() -> Float? {
        let w = accWindow
        guard w.count >= 30 else { return nil }
        func std(_ vals: [Float]) -> Float {
            let m = vals.reduce(0, +) / Float(vals.count)
            let v = vals.reduce(Float(0)) { $0 + ($1 - m) * ($1 - m) } / Float(vals.count)
            return v.squareRoot()
        }
        return (std(w.map(\.x)) + std(w.map(\.y)) + std(w.map(\.z))) / 3
    }

    // MARK: - Usage telemetry

    /// Buffer a usage event (foreground interval / ECG-recording wear) locally
    /// and kick an upload. No-op when cloud sync is off or the interval is empty.
    func logUsageEvent(type: String, start: Date) {
        let syncOn = UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true
        guard syncOn else { return }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        guard durationMs > 0 else { return }
        let ctx = modelContainer.mainContext
        ctx.insert(UsageEventLog(eventType: type, ts: start, durationMs: durationMs))
        try? ctx.save()
        let uploader = UsageUploader(client: sync.client, userID: userID)
        Task { await uploader.flushPending(context: ctx) }
    }

    /// Poll the strap connection ~every 5 s to record ECG-recording
    /// (connect→disconnect) intervals as usage events.
    private func startUsageTracking() {
        usageRecordingTask?.cancel()
        usageRecordingTask = Task { @MainActor [weak self] in
            var recordingStart: Date? = nil
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                let connected: Bool
                if case .connected = self.ble.state { connected = true } else { connected = false }
                if connected, recordingStart == nil {
                    recordingStart = Date()
                } else if !connected, let start = recordingStart {
                    self.logUsageEvent(type: "ecg_recording", start: start)
                    recordingStart = nil
                }
            }
        }
    }

    private func bindBLE() {
        // Forward ECG frames to buffer
        ble.ecgSubject
            .sink { [weak self] samples in
                guard let self else { return }
                Task { await self.dataBuffer.appendECG(samples) }
            }
            .store(in: &cancellables)

        // Forward ACC frames (+ keep a rolling window for off-body motion detection)
        ble.accSubject
            .sink { [weak self] xyz in
                guard let self else { return }
                self.accWindow.append(contentsOf: xyz.map {
                    SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
                })
                if self.accWindow.count > self.accWindowMax {
                    self.accWindow.removeFirst(self.accWindow.count - self.accWindowMax)
                }
                Task { await self.dataBuffer.appendACC(xyz: xyz) }
            }
            .store(in: &cancellables)

        // Forward RR intervals + BPM
        ble.hrSubject
            .sink { [weak self] frame in
                guard let self else { return }
                Task {
                    await self.dataBuffer.appendRR(frame.rrIntervalsMs)
                    await self.dataBuffer.appendBPM(Float(frame.bpm))
                }
            }
            .store(in: &cancellables)

        // A connection gap (unexpected drop, silent watchdog-detected drop, or BT
        // power cycling) invalidates every buffered signal: RR/ECG/ACC around the
        // gap don't represent a continuous recording, and the first RR interval(s)
        // delivered after resuming can reflect elapsed time across the gap rather
        // than a real beat-to-beat interval. Drop everything rather than let a
        // few bad samples sit in the 1200-beat HRV window for up to ~20 minutes.
        ble.connectionGapSubject
            .sink { [weak self] in
                guard let self else { return }
                Task { await self.dataBuffer.clear() }
            }
            .store(in: &cancellables)

        // ── Metrics tick ─────────────────────────────────────────────────────
        // Foreground: every 2 s — full fidelity, updates live UI.
        // Background: every 30 s — throttled to save battery, still records to disk.
        // The app stays alive in background because the bluetooth-central background
        // mode keeps it running while BLE data arrives.
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { break }

                // Off-body standby: ECG/ACC streams are paused, so there's no live
                // data to process. Skip so stale/empty buckets never reach the
                // charts; BLEService resumes automatically when the strap is worn.
                if case .standby = self.ble.state {
                    // The strap is off: stillness and load stretches are broken,
                    // and whatever resumes later is a new run.
                    self.nudges.interrupt()
                    continue
                }

                let inForeground = self.isInForeground

                // In background, only process every 30 s to avoid unnecessary
                // FFT/PSD computation draining the battery.
                if !inForeground {
                    let elapsed = Date().timeIntervalSince(self.lastBackgroundTick)
                    guard elapsed >= 30 else { continue }
                    self.lastBackgroundTick = Date()
                }

                let snapshot = await self.dataBuffer.snapshot()

                // Use lower CPU priority in background so BLE callbacks stay responsive.
                let priority: TaskPriority = inForeground ? .userInitiated : .utility
                let tick = await Task.detached(priority: priority) {
                    MetricsEngine.compute(from: snapshot)
                }.value

                // ── Off-body detection → low-power standby ────────────────────
                // Fuse four cues into a confidence score so no single cue can
                // wrongly trip (false positive) or be missed:
                //   • skin-contact bit — authoritative: worn (−1) / off (+3)
                //   • ECG poor — lead-off OR white noise (no QRS): +1
                //   • RR mostly invalid (signalQuality < 0.5): +1
                //   • accelerometer dead-still (worn straps always jitter): +1
                // score ≥ 2 ⇒ off-body. A strong score (≥3 — contact reports off,
                // or all signal cues agree) trips fast (~20 s); a borderline
                // consensus needs the full ~60 s. "contact = worn" (−1) suppresses
                // false positives when only one cue fires, yet the signal cues can
                // still override a stuck "contact = true" (score reaches 2).
                accMotion = computeAccMotion()
                let contact = ble.sensorContact
                let ecgPoor = tick.ecgQuality?.tier == .poor
                let rrBad   = (tick.signalQuality ?? 1) < 0.5
                let still   = accMotion.map { $0 < self.accStillnessThreshold } ?? false

                var score = 0
                if contact == false { score += 3 } else if contact == true { score -= 1 }
                if ecgPoor { score += 1 }
                if rrBad   { score += 1 }
                if still   { score += 1 }

                if score >= 2 {
                    let since = offBodySince ?? Date()
                    offBodySince = since
                    let needed = score >= 3 ? offBodyStandbyFastSeconds : offBodyStandbySeconds
                    if Date().timeIntervalSince(since) >= needed {
                        ble.enterStandby()
                        offBodySince = nil
                    }
                } else {
                    offBodySince = nil
                }

                // Keep the chart history current in BOTH foreground and background
                // so the charts are already up-to-date the instant the app is
                // opened — no post-foreground fetch/refill delay.
                let point = MetricsHistoryPoint(from: tick)
                self.tickHistory.append(point)
                if self.tickHistory.count > self.maxTickHistory + self.trimBatch {
                    self.tickHistory.removeFirst(self.trimBatch)
                }

                // ── Always: shadow nudge engine (SP6 Phase 1) ─────────────────
                // Records what *would* have fired so the thresholds can be tuned
                // against real wear. Delivers nothing to the user.
                self.nudges.ingest(point, now: point.timestamp)
                self.evaluateNudgesIfDue(now: point.timestamp)

                // ── Foreground-only: live table + live cloud stream ───────────
                if inForeground {
                    self.latestTick = tick
                    self.sync.sendTick(tick, userID: self.userID)
                }

                // ── Best-effort: incremental cloud sync (opt-in, throttled ~120 s) ──
                // No-ops internally when the user hasn't enabled cloud sync.
                if Date().timeIntervalSince(self.lastMetricSyncAt) >= 120 {
                    self.lastMetricSyncAt = Date()
                    Task { await self.metricSync.syncIfEnabled() }
                }

                // ── Always: persist to SwiftData ──────────────────────────────
                // Background samples are merged into tickHistory when app resumes
                // (see reloadRecentHistory called from isInForeground.didSet).
                let context = self.modelContainer.mainContext
                if self.currentSession == nil && self.autoSession == nil {
                    let bg = HRVSession()
                    bg.notes = "auto"
                    context.insert(bg)
                    self.autoSession = bg
                }
                let activeSession = self.currentSession ?? self.autoSession!
                activeSession.samples.append(HRVSample(from: tick))
                self.pendingSaveCount += 1
                // Save every `saveInterval` ticks OR at least every 2 minutes of
                // wall-clock — so background data (30 s ticks) reaches disk within
                // ~2 min instead of ~15, and re-opening shows recent data.
                if self.pendingSaveCount >= self.saveInterval
                    || Date().timeIntervalSince(self.lastSaveAt) >= 120 {
                    try? context.save()
                    self.pendingSaveCount = 0
                    self.lastSaveAt = Date()
                }
            }
        }

        // ── Waveform display at ~10 fps ───────────────────────────────────────
        // 100 ms (10 fps) is imperceptible for waveform scrolling and cuts
        // MainActor wakeups by 67% vs the previous 33 ms (30 fps).
        // The TimelineView inside ECG/ACC views drives its own Canvas redraws
        // independently; only the data buffer refresh rate changes here.
        // Writes go to `waveform` (separate @Observable) so invalidation is
        // scoped only to TodayLiveSection, not DayScrollView or charts.
        displayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isInForeground else { continue }
                let ecg = await self.dataBuffer.ecgDisplay(samples: 650)
                let acc = await self.dataBuffer.accDisplay(samples: 600)
                let rr  = await self.dataBuffer.rrDisplay()
                // Three synchronous assignments on MainActor — coalesced into one
                // SwiftUI render pass by the observation system.
                self.waveform.ecg = ecg
                self.waveform.acc = acc
                self.waveform.rr  = rr
            }
        }
    }
}

// MARK: - Helpers

private extension Array where Element == Float {
    func average() -> Float? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Float(count)
    }
}
