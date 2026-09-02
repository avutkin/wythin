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
                surfacePendingFocusWindow()
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
    /// Delegates to `DeviceIdentity` so this and the insight calls, which read
    /// the id directly, can never mint or read different ones.
    fileprivate static func currentUserID() -> String {
        DeviceIdentity.current
    }

    // MARK: Private

    // MARK: Nudges (SP6 Phase 1 — shadow mode)

    /// Evaluates state shifts on the live stream and records what would have
    /// fired. Nothing is delivered: no notifications, no UI, no permission
    /// prompt. Phase 2 turns delivery on once the thresholds are tuned.
    let nudges = NudgeEngine()

    /// Delivery is opt-in and **off by default**: the thresholds are still
    /// first guesses, so being interrupted has to be something the user
    /// chooses rather than something that starts happening.
    var nudgesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "nudgesEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "nudgesEnabled") }
    }

    /// Options the user has switched off — removed from every menu.
    var disabledInterventions: Set<NudgeInterventionID> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: "nudgeDisabledOptions") ?? []
            return Set(raw.compactMap(NudgeInterventionID.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "nudgeDisabledOptions")
            notifications.refreshCategories(disabled: newValue, pacerHoldsAvailable: false)
        }
    }

    /// Shown as a card while the app is open, instead of a banner.
    var pendingInAppNudge: InAppNudge?
    /// Set by a notification tap; consumed by ContentView.
    var pendingNudgeAction: NudgeAction?
    /// Most recent focus window, surfaced in the past tense on next open.
    var lastFocusWindowAt: Date?
    /// Why nothing fired, for the settings row.
    private(set) var lastNudgeSuppression: NudgeSuppressionReason?

    let notifications: NudgeDelivering = NudgeNotificationService()

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

        let evaluation = nudges.evaluate(baseline: nudgeBaseline,
                                         bleStandby: false,   // standby short-circuits the tick loop
                                         activityInProgress: activeActivity,
                                         now: now)

        guard let evaluation else { return }
        lastNudgeSuppression = evaluation.suppression
        guard let selected = evaluation.selected else { return }
        deliver(selected, at: now)
    }

    /// Freezes today's anchor as soon as a qualifying rest exists, without
    /// waiting for the Live tab to be opened — a morning recorded and never
    /// looked at is still a morning.
    ///
    /// Cheap because it exits on the day check in the overwhelming common case:
    /// once today's anchor exists, this is one fetch every five minutes.
    /// Records last night, once it is over.
    ///
    /// Shares the anchor's five-minute throttle: both are cheap, both are
    /// idempotent, and neither needs to be prompt. `SleepRecorder` decides for
    /// itself whether a night is finished, so calling this at 03:00 is a no-op
    /// rather than a truncated record.
    private func recordSleepIfDue(now: Date) {
        // Throttled, because this sits in the tick loop and the loop runs every
        // two seconds in the foreground. `detectAnchorIfDue` throttles itself
        // internally, so placing this beside it looked right and was not: the
        // whole sleep pipeline — fetch, segment, classify, score — ran thirty
        // times a minute on the main thread. That is the lag.
        guard now.timeIntervalSince(lastSleepCheckAt) >= sleepCheckInterval else { return }
        lastSleepCheckAt = now
        SleepRecorder.recordInBackground(container: modelContainer, now: now)
    }

    private func detectAnchorIfDue(now: Date) {
        guard now.timeIntervalSince(lastAnchorCheckAt) >= anchorCheckInterval else { return }
        lastAnchorCheckAt = now

        let today   = Calendar.current.startOfDay(for: now)
        let context = modelContainer.mainContext
        let stored: [DailyAnchor]
        do {
            stored = try context.fetch(FetchDescriptor<DailyAnchor>())
        } catch {
            // A fetch that threw is not "no anchor today". Reading it as one
            // and inserting would leave a second row for a day that already has
            // one — `DailyAnchor` has no unique constraint on `day` and nothing
            // dedupes, so both would feed `AnchorBaseline.build` from then on.
            // `lastAnchorCheckAt` has already moved, so this retries in five
            // minutes. Same rule as `AnchorBackfill.replay`.
            print("❌ detectAnchorIfDue: anchor fetch — \(error)")
            return
        }
        guard !stored.contains(where: { $0.day == today }) else { return }

        let points = MetricsQualityFilter.filter(tickHistory.filter { $0.timestamp >= today })
        guard let reading = AnchorDetector.detect(points) else { return }

        // Asymmetric on purpose. This path polls every five minutes with nobody
        // watching, so whichever poll first catches a rest past `minSec` would
        // freeze it — landing `durationSec` roughly uniformly in [180, 480) and
        // dropping DC on the short half. The day's anchor would then routinely
        // be a different kind of measurement from the baseline it is scored
        // against. Waiting for `preferredMinSec` costs at most one more poll.
        //
        // `DayPotentialStore.refresh` keeps the 180 s floor: a user who pulled
        // to refresh has asked for whatever this morning actually gave.
        guard reading.durationSec >= AnchorThresholds.preferredMinSec else { return }

        context.insert(DailyAnchor(from: reading))
        try? context.save()
    }

    /// The focus window never pushes — a notification would interrupt the exact
    /// absorbed state it is reporting. Everything else takes a banner when
    /// backgrounded and an in-app card when not.
    private func deliver(_ trigger: NudgeTriggerID, at now: Date) {
        guard nudgesEnabled else { return }

        if trigger == .focusWindow {
            lastFocusWindowAt = now
            return
        }

        let options = NudgeInterventionLibrary.menu(for: trigger,
                                                    disabled: disabledInterventions,
                                                    pacerHoldsAvailable: false)
        guard !options.isEmpty else { return }
        let content = NudgeCopy.render(trigger, options: options)

        if isInForeground {
            pendingInAppNudge = InAppNudge(trigger: trigger, content: content)
        } else {
            Task { await notifications.deliver(content, trigger: trigger) }
        }
    }

    /// Fires a real nudge on demand, to prove the delivery path end to end:
    /// permission, banner, the menu as action buttons, and tap routing.
    ///
    /// Always goes out as a notification with a short delay, so the app can be
    /// backgrounded first — that is the path worth testing, and the one that is
    /// impossible to see while looking at the screen.
    func sendTestNudge(after delay: TimeInterval = 5) async {
        let trigger = NudgeTriggerID.stuckStill
        let options = NudgeInterventionLibrary.menu(for: trigger,
                                                    disabled: disabledInterventions,
                                                    pacerHoldsAvailable: false)
        let base = NudgeCopy.render(trigger, options: options)
        let content = NudgeContent(title: base.title,
                                   body: "\(base.body) (test)",
                                   options: options)
        await notifications.deliver(content, trigger: trigger, after: delay)
    }

    /// Called when the user acts on a nudge, from a notification or the card.
    func actOnNudge(_ action: NudgeAction) {
        pendingInAppNudge = nil
        pendingNudgeAction = action
    }

    /// A focus window is never pushed — a notification would interrupt the very
    /// state it is reporting — so it waits and is shown in the past tense the
    /// next time the app is opened.
    private func surfacePendingFocusWindow() {
        guard nudgesEnabled, let at = lastFocusWindowAt else { return }
        lastFocusWindowAt = nil
        let content = NudgeCopy.render(.focusWindow, options: [])
        let when = Self.focusTimeFormatter.string(from: at)
        pendingInAppNudge = InAppNudge(
            trigger: .focusWindow,
            content: NudgeContent(title: "\(content.title) · \(when)",
                                  body: content.body,
                                  options: []))
    }

    private static let focusTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

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

    /// Internal rather than private so callers that must do bulk work off the
    /// main actor can open their own `ModelContext` on it — see
    /// `AnchorBackfill`. The container is `Sendable`; a context is not.
    let modelContainer: ModelContainer

    /// Today's capacity read. App-owned rather than view-owned so it is
    /// computed once at launch and survives tab switches — the score must be
    /// on the moment the Live tab appears, not computed when it does.
    let dayPotential = DayPotentialStore()

    /// Mirror of the on-disk rollup cache, for `LiveStateStore` to build the
    /// user's baseline from. The Track tab owns its own separate
    /// `TrackCache()` instance (`TrackView.cache`) and remains the only thing
    /// that fetches raw samples for the full 90-day window Track's charts
    /// need; whatever Track has written — this session or a previous one —
    /// is on disk and reachable from here via `load()` + the pure
    /// `rollups(in:)` read.
    ///
    /// This instance also makes one narrow write of its own: `init` calls
    /// `warmLiveBaseline()`, a bounded 14-day launch warm-up, so the Live tab
    /// has a baseline without waiting for the user to ever open Track — see
    /// that method's doc for why. That makes two independent `TrackCache`
    /// instances writing the same file, which is a real hazard: `save()` is
    /// atomic per write but writes each instance's *entire* in-memory
    /// snapshot, so a stale snapshot saved after the other instance wrote
    /// would clobber it. `TrackCache.mergeComputed` (what the warm-up calls
    /// instead of `refresh`) reloads from disk immediately before merging and
    /// saving, and — because both it and `refresh` are synchronous
    /// `@MainActor` methods with no suspension point inside them — nothing
    /// can interleave between that reload and that save. If Track has never
    /// been opened and the warm-up hasn't landed yet either, there is simply
    /// nothing to load, and `LiveBaseline.build` returning nil for an empty
    /// rollup list is the documented cold-start fallback, not an error.
    let trackCache = TrackCache()

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
    private var lastSleepCheckAt: Date = .distantPast
    /// Same cadence as the anchor. A night is written once and never changes,
    /// so there is nothing to gain from looking more often.
    private let sleepCheckInterval: TimeInterval = 300

    private var lastAnchorCheckAt: Date = .distantPast     // throttles anchor detection to ~5 min
    /// Anchors are frozen once a day, so checking every five minutes is generous.
    private let anchorCheckInterval: TimeInterval = 300
    /// Guards `warmLiveBaseline()` to at most once per launch — see its doc.
    private var didWarmLiveBaseline = false
    /// Temporal filter over the per-tick breathing estimates — see
    /// `BreathRateTracker`. Lives here because the metrics engine is pure.
    private var breathTracker = BreathRateTracker()
    /// Accumulates QT across ticks so QTVI has enough beats to mean anything.
    /// Stateful for the same reason `breathTracker` is: the engine is a pure
    /// per-snapshot function, and one ECG window holds ~11 beats where
    /// Berger's index wants hundreds.
    private let qtTracker = QTTracker()
    private var lastBreathTickAt: Date?

    // MARK: Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.sync = SyncService(serverURL: UserDefaults.standard.string(forKey: "serverURL")
            .flatMap(URL.init) ?? URL(string: "https://api.77.42.73.250.sslip.io")!)
        self.metricSync = MetricSyncService(client: sync.client, userID: AppEnvironment.currentUserID(),
                                             container: modelContainer)

        bindBLE()
        loadHistory()
        trackCache.load()
        warmLiveBaseline()
        startUsageTracking()
        prewarmDashboards()
        // Register the notification categories up front: without them a nudge
        // arrives with no menu buttons on it.
        notifications.refreshCategories(disabled: disabledInterventions,
                                        pacerHoldsAvailable: false)
        Task {
            let context = modelContainer.mainContext
            let uploader = SessionUploader(client: sync.client, userID: userID)
            await uploader.flushPending(context: context)
            let activityUploader = ActivityUploader(client: sync.client, userID: userID)
            await activityUploader.flushPending(context: context)
            let usageUploader = UsageUploader(client: sync.client, userID: userID)
            await usageUploader.flushPending(context: context)
            let feltStateUploader = FeltStateLogUploader(client: sync.client, userID: userID)
            await feltStateUploader.flushPending(context: context)
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

    /// Warms everything the tabs read, while the splash is still up, so the
    /// first tap on any of them lands on ready data rather than a cold fetch.
    ///
    /// Ordered deliberately: history first (Today's Potential needs the tick
    /// history to find a rested window), then the anchor pipeline, then the
    /// row sets the Activities and Track tabs open on.
    private func prewarmDashboards() {
        Task { @MainActor in
            // loadHistory() publishes asynchronously; give the anchor pass the
            // history it depends on rather than racing it.
            for _ in 0..<40 where tickHistory.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await dayPotential.refresh(env: self)

            let context = modelContainer.mainContext
            _ = try? context.fetch(FetchDescriptor<ActivityLog>())
            _ = try? context.fetch(FetchDescriptor<DailyAnchor>())
            var sessions = FetchDescriptor<HRVSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
            sessions.fetchLimit = 60
            _ = try? context.fetch(sessions)
        }
    }

    /// One-shot, bounded warm-up so the Live tab's Current State engine has a
    /// baseline without depending on the user ever having opened Track.
    /// `TrackCache.refresh` is the only thing that has ever turned raw
    /// samples into rollups, and its one caller is `TrackView.swift:142` — so
    /// a user who never visits Track, or whose cache was just discarded by a
    /// `rollupComputeVersion` bump, gets `LiveBaseline.build` returning nil
    /// forever and the Live widget silently falling back to its old
    /// LLM-only rendering with nothing on screen to say anything changed.
    ///
    /// Warms the most recent 14 *closed* days (yesterday back 13 more),
    /// deliberately not the full `AnchorBaseline.windowDays` (60):
    /// `LiveBaseline` is prior-blended and already produces a usable — if
    /// `provisional`, see `LivePrior.firmDays` (7) — baseline from a handful
    /// of days, so there is no reason to pay for sixty days of up-to-60,000-
    /// row fetches just to unblock the Live tab at launch. `today` is
    /// excluded on purpose: it is still accumulating, `refresh` is what keeps
    /// it current on every Track appear, and excluding it means this warm-up
    /// never has to decide whether to (permanently, incorrectly) record an
    /// in-progress day as `noDataDays`. Track's own visits keep extending
    /// coverage toward the fuller 90-day window over time, exactly as before
    /// this warm-up existed.
    ///
    /// The SwiftData fetch AND the `DailyRollupCompute` pass (`TrackCache.
    /// computeRollups`) both run inside `Task.detached` on a background
    /// `ModelContext(container)` — `loadHistory()`'s own pattern — because
    /// `TrackCache.refresh` normally does both of those synchronously on
    /// `@MainActor`, and up to 60,000 `HRVSample` rows a day for two weeks on
    /// the main thread at launch is watchdog-kill territory. Only the
    /// finished rollups are published back to the main actor, via
    /// `TrackCache.mergeComputed` (see `trackCache`'s doc for why that method
    /// exists instead of `refresh`).
    /// After a cloud restore: every derived verdict in the rollup cache was
    /// reached against the wiped store — including the sticky `noDataDays`
    /// brand on days that now hold restored samples — so drop them all and
    /// run the launch warm-up again as if this were a fresh start. The
    /// `historyRevision` bump tells open views their fetches are stale.
    func rewarmAfterRestore() {
        trackCache.resetDerived()
        didWarmLiveBaseline = false
        warmLiveBaseline()
        historyRevision += 1
    }

    private func warmLiveBaseline() {
        guard !didWarmLiveBaseline else { return }
        didWarmLiveBaseline = true

        let cal      = Calendar.current
        let today    = cal.startOfDay(for: Date())
        let warmDays = 14
        guard let windowStart = cal.date(byAdding: .day, value: -warmDays, to: today) else { return }
        // Half-open range: excludes `today`, per the doc above.
        let days = TrackRangeBuilder.dayStarts(from: windowStart, to: today, calendar: cal)

        // `trackCache.load()` already ran in `init`, so this is a cheap,
        // synchronous, in-memory check. It skips the background fetch
        // entirely once these days are already cached — the common case on
        // every relaunch after the first, and whenever Track has already
        // been opened this session.
        let pending = trackCache.uncachedDays(days, today: today)
        guard !pending.isEmpty else { return }

        // Each day's end computed up front, on the main actor, so the
        // closure handed to `Task.detached` only has to capture plain
        // `Date`s — not a `Calendar` — across the actor boundary.
        var orderedDays: [Date] = []
        var dayEnds: [Date: Date] = [:]
        for day in pending {
            guard let end = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            orderedDays.append(day)
            dayEnds[day] = end
        }
        guard !orderedDays.isEmpty else { return }

        let container = modelContainer
        Task { @MainActor in
            let (rollups, emptyDays) = await Task.detached {
                let ctx = ModelContext(container)
                return TrackCache.computeRollups(days: orderedDays) { day in
                    guard let end = dayEnds[day] else { return [] }
                    var desc = FetchDescriptor<HRVSample>(
                        predicate: #Predicate { $0.timestamp >= day && $0.timestamp < end },
                        sortBy:    [SortDescriptor(\.timestamp)])
                    // Same bound `TrackView`'s own per-day fetch uses — a
                    // full day of ~2 s ticks is ~43,200 rows.
                    desc.fetchLimit = 60_000
                    return ((try? ctx.fetch(desc)) ?? []).map { MetricsHistoryPoint(from: $0) }
                }
            }.value
            self.trackCache.mergeComputed(rollups: rollups, emptyDays: emptyDays)
        }
    }

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
    private let offBodyStandbySeconds:     TimeInterval = 45   // borderline consensus (score 2)
    // Read together with the 4 s liveness windows in BLEService: the cues go
    // true ~4 s after doffing, plus 5 s of sustained strong agreement lands
    // standby ~10 s after the strap comes off — Alex's chosen budget — in
    // the background too, since every cue is a liveness flag, none needs a
    // metrics tick. The worn-strap safety margin is the bpm cue: a worn H10
    // keeps reporting a heart rate straight through motion-artifact gaps, so
    // the fast path can't assemble on a wearer even at these windows.
    private let offBodyStandbyFastSeconds: TimeInterval = 5    // strong agreement (score ≥ 3)

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

    // ── Off-body detection → low-power standby ────────────────────────────
    // Fuse four cues into a confidence score so no single cue can wrongly
    // trip (false positive) or be missed:
    //   • skin-contact bit — authoritative: worn (−1) / off (+3)
    //   • heart gone — the strap reports bpm 0 (heartbeatLive false), the ECG
    //     stream died, or the last tick graded the waveform poor: +1
    //   • RR intervals stopped arriving (rrIntervalsLive, 6 s window) or the
    //     last tick's RR mostly invalid: +1
    //   • accelerometer dead-still AND heartbeat gone (sleepers are still too,
    //     but their RR keeps flowing): +1
    // score ≥ 2 ⇒ off-body. Strong agreement (≥3) trips in ~8 s of dwell,
    // borderline needs 45 s. Every fast cue is a liveness flag refreshed by
    // the BLE callbacks themselves — deliberately NOT tick-derived, because
    // background ticks run every 30 s and made doffing take a minute to
    // notice. Runs on the 2 s loop cadence with no FFT.
    private func evaluateOffBodyStandby() {
        accMotion = computeAccMotion()
        guard case .connected = ble.state else {
            offBodySince = nil
            return
        }
        let contact = ble.sensorContact
        // DEAD counts as bad, not as absent: when the strap comes off, data
        // stops entirely — and "no data" once read as "no problem".
        let ecgPoor = !ble.heartbeatLive || !ble.ecgStreamLive
                      || latestTick?.ecgQuality?.tier == .poor
        let rrBad   = !ble.rrIntervalsLive
                      || (latestTick?.signalQuality.map { $0 < 0.5 } ?? false)
        let still   = accMotion.map { $0 < self.accStillnessThreshold } ?? false
        let score   = StandbyPolicy.offBodyScore(
            contact: contact, ecgPoor: ecgPoor, rrBad: rrBad, still: still)

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
    }

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
                // The beats either side of a gap are not consecutive, so the
                // QT series cannot span it any more than the RR buffer can.
                self.qtTracker.reset()
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
                    // Whatever breathing resumes later belongs to a different
                    // stretch of time — don't drag the old rate across the gap.
                    self.breathTracker.reset()
                    self.qtTracker.reset()
                    continue
                }

                let inForeground = self.isInForeground

                // Off-body check runs on the 2 s cadence in BOTH foreground and
                // background — it reads stream liveness and an ACC stddev, no
                // FFT. Behind the 30 s throttle below it added up to a minute
                // of latency to standby, blowing the ~20 s doffing budget.
                self.evaluateOffBodyStandby()

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
                var tick = await Task.detached(priority: priority) {
                    MetricsEngine.compute(from: snapshot)
                }.value

                // The spectral pick is an observation, not the answer: track it
                // over time so the chart shows breathing, not estimator noise.
                // Held here rather than inside the engine because the engine is
                // a pure per-snapshot function with no memory of the last tick.
                let dt = Float(Date().timeIntervalSince(self.lastBreathTickAt ?? Date()))
                self.lastBreathTickAt = Date()
                tick.breathBPM = self.breathTracker.update(
                    tick.breathBPM.map { [.init(bpm: $0, confidence: tick.breathConfidence ?? 3)] } ?? [],
                    dt: dt)

                // QT needs the waveform, not the tachogram, and more beats
                // than one window holds — so it accumulates here rather than
                // in the engine. Skipped when the ECG stream is dead, since
                // delineating silence just burns CPU.
                if !snapshot.ecg.isEmpty {
                    tick.qtvi = self.qtTracker.update(
                        ecg: snapshot.ecg,
                        fs: Float(PolarH10Profile.ecgSampleRate),
                        windowEnd: tick.timestamp)
                }

                // Keep the chart history current in BOTH foreground and background
                // so the charts are already up-to-date the instant the app is
                // opened — no post-foreground fetch/refill delay.
                let point = MetricsHistoryPoint(from: tick)
                self.tickHistory.append(point)
                if self.tickHistory.count > self.maxTickHistory + self.trimBatch {
                    self.tickHistory.removeFirst(self.trimBatch)
                }

                // ── Live Activity: lock screen and Dynamic Island ─────────────
                // Throttled inside the controller, so this can fire every tick.
                if let hr = tick.meanBPM {
                    LiveSessionController.shared.update(
                        heartRate: Int(hr.rounded()),
                        hrReserve: nil, zone: nil, strapLost: false)
                }

                // ── Always: shadow nudge engine (SP6 Phase 1) ─────────────────
                // Records what *would* have fired so the thresholds can be tuned
                // against real wear. Delivers nothing to the user.
                self.nudges.ingest(point, now: point.timestamp)
                self.evaluateNudgesIfDue(now: point.timestamp)
                self.detectAnchorIfDue(now: point.timestamp)
                self.recordSleepIfDue(now: point.timestamp)

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
