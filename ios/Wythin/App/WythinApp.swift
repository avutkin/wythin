import SwiftUI
import SwiftData

@main
struct WythinApp: App {

    private let container: ModelContainer

    /// Exists only so notification taps have somewhere to land — the app is
    /// otherwise a pure SwiftUI `@main` with no delegate.
    @UIApplicationDelegateAdaptor(WythinAppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase
    @State private var env: AppEnvironment
    @State private var showSplash = true

    init() {
        let schema = Schema([HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self, ActivityLog.self, DailyAnchor.self, UsageEventLog.self, FeltStateLog.self, SleepWindowOverride.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        // Attempt to open the store; if the schema can't migrate, set the store
        // ASIDE and recreate so the app still launches — but never delete it.
        // A sidecar copy can be migrated or mined later; deleted history is
        // gone. (2026-08-09: the delete-and-recreate that used to live here
        // erased a phone's entire local history after builds from two branches
        // left the store on a schema neither could open. Its cleanup also
        // targeted "default.store.wal" — SQLite's sidecars are "-wal"/"-shm",
        // not dot extensions, so the real WAL was never removed either.)
        let c: ModelContainer
        do {
            c = try ModelContainer(for: schema, configurations: [config])
        } catch {
            let fm    = FileManager.default
            let url   = config.url
            let stamp = Int(Date.now.timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: url.path + suffix)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = URL(fileURLWithPath: url.path + ".incompatible-\(stamp)" + suffix)
                try? fm.moveItem(at: src, to: dst)
            }
            c = try! ModelContainer(for: schema, configurations: [config])
        }
        container = c
        _env = State(initialValue: AppEnvironment(modelContainer: c))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(env)
                    .modelContainer(container)
                    .preferredColorScheme(.dark)

                if showSplash {
                    SplashView {
                        showSplash = false
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showSplash)
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            env.isInForeground = (newPhase == .active)
            // An after-window closes ten minutes after its session, long after
            // the code that stored the session has finished. Coming back to the
            // app is when we can finally fill it in.
            if newPhase == .active {
                ActivityLog.backfillMissingWindows(context: container.mainContext)
                // The version re-derive, if one is owed. Detached and chunked;
                // never on the main context — that is what killed build 98.
                ActivityLog.migrateInBackground(container: container)
                // Last night, if it has not been written down yet. Deliberately
                // here and not only in the tick loop: that loop runs on arriving
                // metric ticks, so it needs the strap connected. Opening the app
                // at breakfast — strap on the nightstand — is exactly when a
                // person wants to see the night, and the samples are already on
                // disk. Idempotent, so both paths are safe.
                env.recordSleepInBackground()
            }
        }
    }
}

// MARK: - App Tab

enum AppTab: Hashable { case train, activities, live, track, settings }

// MARK: - Root Tab View

struct ContentView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: AppTab = .live
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    // The version lives inside backfillMissingWindows; this flag must not
    // second-guess it. It was pinned at "V2" and is already true for every
    // existing install, so the v3 bump inside the function was unreachable and
    // no pre-existing activity ever gained its exercise fields. Renamed rather
    // than reset so the gate opens once and the function's own version counter
    // becomes the single source of truth from here on.
    @AppStorage("didRunActivityBackfill") private var didRunActivityBackfill = false
    // One-time cloud-sync disclosure (sync is on by default; the notice gives an
    // explicit, informed choice on first launch after onboarding).
    @AppStorage("didShowCloudSyncNotice") private var didShowCloudSyncNotice = false
    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = true
    @State private var showCloudNotice = false
    @State private var nudgePractice: NudgePractice?

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                mainApp
            } else {
                OnboardingFlow {
                    withAnimation(.easeInOut(duration: 0.35)) { hasCompletedOnboarding = true }
                }
                .transition(.opacity)
            }
        }
        .task {
            // One-time: fill Stress Balance (and other post-hoc fields) on
            // sessions logged before those fields existed.
            // Called on every launch: the function is idempotent and versions
            // itself internally, so it is cheap when there is nothing to do and
            // correct when a new field has been added.
            // A force-quit mid-session leaves a Live Activity stranded on the
            // lock screen with a heart rate that will never change again.
            if (try? modelContext.fetch(FetchDescriptor<ActivityLog>()))?
                .contains(where: { $0.isActive }) != true {
                LiveSessionController.shared.endAnyOrphaned()
            }
            // Before the backfill, not after: a store restored from the server
            // arrives with window averages and nothing derived, and the
            // backfill is what computes the rest.
            if cloudSyncEnabled {
                await ActivityRestore.restoreIfEmpty(context: modelContext,
                                                     client: APIClient(baseURL: env.serverURL),
                                                     userID: env.userID)
            }
            ActivityLog.backfillMissingWindows(context: modelContext)
            ActivityLog.migrateInBackground(container: modelContext.container)
            didRunActivityBackfill = true
        }
        // ── Self check-ins ─────────────────────────────────────────────────
        // On its own node, not on the tab view that already presents the
        // cloud notice and the nudge cover: two sheets on one view fail
        // silently. `canPresent` keeps it behind onboarding and the notice.
        .task { env.checkIns.appDidBecomeActive() }
        .onAppear { env.checkIns.canPresent = hasCompletedOnboarding && didShowCloudSyncNotice }
        .onChange(of: hasCompletedOnboarding) { _, _ in refreshCheckInGate() }
        .onChange(of: didShowCloudSyncNotice) { _, _ in refreshCheckInGate() }
        .sheet(item: Binding(get: { env.checkIns.presented },
                             set: { if $0 == nil { env.checkIns.skipPresented() } })) { prompt in
            CheckInSheet(prompt: prompt,
                         needsNotificationOptIn: env.checkIns.needsNotificationOptIn,
                         onDone: { env.checkIns.save($0, for: prompt) },
                         onSkip: { env.checkIns.skipPresented() },
                         onAllowNotifications: { env.checkIns.allowNotifications() })
        }
    }

    /// The gate opens a beat after the cloud notice closes, so the check-in
    /// sheet is not presented while that one is still animating away.
    private func refreshCheckInGate() {
        let open = hasCompletedOnboarding && didShowCloudSyncNotice
        if open {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { env.checkIns.canPresent = true }
        } else {
            env.checkIns.canPresent = false
        }
    }

    private var mainApp: some View {
        TabView(selection: $selectedTab) {
            PracticeHubView()
                .tag(AppTab.train)
            ActivitiesView()
                .tag(AppTab.activities)
            LiveView()
                .tag(AppTab.live)
            TrackView()
                .tag(AppTab.track)
            SettingsView()
                .tag(AppTab.settings)
        }
        .tint(Theme.accent)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Stopping used to be possible only from the Activities tab, so an
                // activity started from a nudge kept running while you were
                // anywhere else with no way to end it. This rides above the tab bar
                // on every screen except Activities, which has the full banner.
                if selectedTab != .activities {
                    RunningActivityToast { selectedTab = .activities }
                }
                AppTabBar(selected: $selectedTab)
            }
        }
        .onChange(of: env.pendingTabRequest) { _, newValue in
            guard let tab = newValue else { return }
            selectedTab = tab
            env.pendingTabRequest = nil
        }
        .onAppear {
            if !didShowCloudSyncNotice { showCloudNotice = true }
        }
        .sheet(isPresented: $showCloudNotice) {
            CloudSyncNoticeView(
                onKeepOn:  { cloudSyncEnabled = true;  didShowCloudSyncNotice = true; showCloudNotice = false },
                onTurnOff: { cloudSyncEnabled = false; didShowCloudSyncNotice = true; showCloudNotice = false }
            )
            .interactiveDismissDisabled()
        }
        // ── Nudges ────────────────────────────────────────────────────────
        .overlay(alignment: .top) {
            if let nudge = env.pendingInAppNudge {
                NudgeCardView(
                    nudge: nudge,
                    onPick: { option in
                        env.actOnNudge(NudgeAction(trigger: nudge.trigger, intervention: option))
                    },
                    onDismiss: { env.pendingInAppNudge = nil })
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: env.pendingInAppNudge)
        .onAppear {
            // A tap can arrive before any view is listening, so the router
            // buffers it and replays on connect.
            NudgeRouter.shared.handler = { action in env.pendingNudgeAction = action }
            NudgeRouter.shared.onDismiss = { _ in env.pendingInAppNudge = nil }
        }
        .onChange(of: env.pendingNudgeAction) { _, action in
            guard let action else { return }
            env.pendingNudgeAction = nil
            present(action)
        }
        .fullScreenCover(item: $nudgePractice) { practice in
            switch practice {
            case .resonance: ResonanceSessionView()
            case .observe:   NudgeTimerView(kind: .observe)
            case .stretch:   NudgeTimerView(kind: .stretch)
            }
        }
    }

    /// Which practice a nudge asked for. Walking is not a screen — it starts a
    /// live activity and sends the user outside.
    enum NudgePractice: String, Identifiable {
        case resonance, observe, stretch
        var id: String { rawValue }
    }

    private func present(_ action: NudgeAction) {
        switch action.intervention {
        case .resonance, .sighing, .box:
            // Sighing and box need pacer holds that do not exist yet; the menu
            // filters them out, so this is resonance in practice.
            nudgePractice = .resonance
        case .observe:
            nudgePractice = .observe
        case .stretch:
            nudgePractice = .stretch
        case .walk:
            _ = ActivityLogging.begin(type: .walk, subtype: nil, customName: nil,
                                      targetMinutes: NudgeInterventionLibrary
                                          .intervention(.walk).minutes,
                                      context: modelContext,
                                      client: env.sync.client)
            selectedTab = .activities
        }
    }
}

// MARK: - Cloud Sync Notice (one-time consent)

private struct CloudSyncNoticeView: View {
    let onKeepOn:  () -> Void
    let onTurnOff: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Your data syncs to the cloud")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            VStack(spacing: 12) {
                Text("Wythin syncs your metrics — heart rate, Inner Noise, and the rest — to your private account so you can explore them from Claude Code.")
                Text("Your data is tied to your account and only reachable with your personal token. You can turn this off anytime in Settings — then everything stays on this device.")
            }
            .font(.system(size: 14))
            .foregroundStyle(Theme.dim)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.horizontal, 28)
            Spacer()
            VStack(spacing: 10) {
                Button(action: onKeepOn) {
                    Text("Keep sync on")
                        .font(Theme.monoBody).foregroundStyle(Theme.bg)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button(action: onTurnOff) {
                    Text("Keep my data on this device only")
                        .font(Theme.monoBody).foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Custom Tab Bar

struct AppTabBar: View {
    @Binding var selected: AppTab

    var body: some View {
        HStack(spacing: 0) {
            // Left pair
            TabBarButton(tab: .train,      icon: "figure.mind.and.body",      label: "Library",   selected: $selected)
            TabBarButton(tab: .activities, icon: "list.bullet.clipboard",     label: "Activities", selected: $selected)

            // Live — prominent center button (position 3 of 5)
            Button { selected = .live } label: {
                ZStack {
                    Circle()
                        .fill(selected == .live ? Theme.accent : Theme.card)
                        .frame(width: 56, height: 56)
                        .shadow(color: selected == .live ? Theme.accent.opacity(0.35) : .clear,
                                radius: 10, y: 3)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(selected == .live ? Color.black : Theme.dim)
                }
                .offset(y: -10)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: selected)

            // Right pair
            TabBarButton(tab: .track,    icon: "chart.line.uptrend.xyaxis", label: "Track",    selected: $selected)
            TabBarButton(tab: .settings, icon: "gear",                      label: "Settings", selected: $selected)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background {
            Theme.bg
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Theme.border.frame(height: 0.5)
                }
        }
    }
}

private struct TabBarButton: View {
    let tab:    AppTab
    let icon:   String
    let label:  String
    @Binding var selected: AppTab

    /// Slightly wider than tall: the wide symbols (the chart, the seated
    /// figure) are then held by their width and the tall ones (the clipboard)
    /// by their height, which lands every icon within ~1pt of the same
    /// drawn height without any one of them looking stretched.
    private let iconBox = (width: CGFloat(26), height: CGFloat(22))

    var isSelected: Bool { selected == tab }

    var body: some View {
        Button { selected = tab } label: {
            VStack(spacing: 4) {
                // Every symbol fitted to one box, rather than set at one point
                // size. At a shared 20pt these drew anywhere from 17.7pt to
                // 23.7pt tall — the clipboard a third taller than the seated
                // figure — and because an HStack of VStacks centres each item
                // on its own height, that also left the four labels on four
                // different baselines. Fitting to a box fixes both: one
                // apparent size, one baseline.
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconBox.width, height: iconBox.height)
                Text(label)
                    .font(Theme.monoLabel)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.dim)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Running activity toast

/// The recent heart-rate trace the toast draws, as points in the unit square.
///
/// Pure so it can be tested: x is time across the window, y is heart rate
/// between the window's own minimum and maximum. A flat trace sits at half
/// height rather than collapsing onto the floor.
enum HeartRateTrace {
    static func normalised(samples: [(Date, Float?)], window: TimeInterval,
                           now: Date = .now) -> [CGPoint] {
        let cutoff = now.addingTimeInterval(-window)
        let recent = samples.compactMap { ts, bpm -> (Date, Float)? in
            guard let bpm, ts >= cutoff, ts <= now else { return nil }
            return (ts, bpm)
        }
        guard recent.count >= 2,
              let lo = recent.map(\.1).min(), let hi = recent.map(\.1).max() else { return [] }
        let span = hi - lo
        return recent.map { ts, bpm in
            CGPoint(x: 1 - now.timeIntervalSince(ts) / window,
                    y: span > 0 ? CGFloat((bpm - lo) / span) : 0.5)
        }
    }
}

/// A floating card above the tab bar on every screen but Activities, so a
/// session that is recording is impossible to forget about.
///
/// The strip this replaces was a flat row in the tab bar's own colour with a
/// static dot: it read as part of the chrome. This one floats, breathes, and
/// carries the last minute and a half of heart rate as a trace, with the
/// current value — the evidence that the strap is still being read, not just
/// a label saying so. Tapping it opens Activities, where the live row holds
/// the score and the STOP.
private struct RunningActivityToast: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var entries: [ActivityLog]

    let onTap: () -> Void

    @State private var now = Date.now
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// How much heart rate the trace shows.
    static let traceWindow: TimeInterval = 90

    private var active: [ActivityLog] { ActivityLogging.activeEntries(in: entries) }

    private var trace: [CGPoint] {
        HeartRateTrace.normalised(samples: env.tickHistory.suffix(120).map { ($0.timestamp, $0.meanBPM) },
                                  window: Self.traceWindow, now: now)
    }

    var body: some View {
        if let entry = active.first {
            let elapsed = now.timeIntervalSince(entry.startedAt)
            let target = entry.targetMinutes.map { TimeInterval($0) * 60 }
            let reached = target.map { elapsed >= $0 } ?? false
            let tint = reached ? Theme.accent : Theme.warn

            Button(action: onTap) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(entry.activityTypeEnum.color.opacity(0.15))
                            .frame(width: 34, height: 34)
                        Image(systemName: entry.activityTypeEnum.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(entry.activityTypeEnum.color)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            PulsingDot(color: tint)
                            Text(entry.displayName.uppercased())
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            if active.count > 1 {
                                Text("+\(active.count - 1)")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                        HStack(spacing: 4) {
                            Text(reached ? "TARGET REACHED" : "RECORDING")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .tracking(0.8)
                                .foregroundStyle(tint)
                            Text("· tap to open")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(mmss(elapsed))
                                .font(Theme.mono(15))
                                .foregroundStyle(tint)
                                .monospacedDigit()
                            if let target {
                                Text("/ " + mmss(target))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                                    .monospacedDigit()
                            }
                        }
                        HStack(spacing: 5) {
                            TraceLine(points: trace, tint: Theme.rsa)
                                .frame(width: 64, height: 16)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(MetricFormat.bpm(env.latestTick?.meanBPM))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .monospacedDigit()
                                Text("bpm")
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .buttonStyle(.plain)
            .onReceive(ticker) { now = $0 }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func mmss(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// A sparkline of unit-square points, with the newest sample marked.
private struct TraceLine: View {
    let points: [CGPoint]
    let tint:   Color

    private func at(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: size.height - p.y * (size.height - 3) - 1.5)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if points.count >= 2 {
                Path { path in
                    path.move(to: at(points[0], in: geo.size))
                    for p in points.dropFirst() { path.addLine(to: at(p, in: geo.size)) }
                }
                .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                Circle()
                    .fill(tint)
                    .frame(width: 4, height: 4)
                    .position(at(points[points.count - 1], in: geo.size))
            } else {
                // Nothing yet, or the strap is not being read: a dotted
                // baseline says "no trace" rather than drawing an empty box.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h / 2))
                    path.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(Theme.dim.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
    }
}
