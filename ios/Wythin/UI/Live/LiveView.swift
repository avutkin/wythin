import SwiftUI
import SwiftData
import UIKit
import Combine

// MARK: - Live View

struct LiveView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.modelContext) var ctx
    @State private var showBLESheet  = false
    @State private var keepAwake     = false
    @State private var days:      [Date] = LiveView.makeDays()
    @State private var pageIndex: Int    = LiveView.dayCount - 1   // today
    // Shared chart window for every chart on every day-page; persisted.
    @AppStorage("liveChartWindow") private var chartWindow: TimeWindow = .h24
    @Environment(\.scenePhase) private var scenePhase

    // 90-day window: index 0 = oldest, last = today. Rebuilt on day-change /
    // foreground so the "today" page rolls over at midnight without an app restart.
    static let dayCount = 90
    static func makeDays() -> [Date] {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (0..<dayCount).map { cal.date(byAdding: .day, value: -$0, to: today)! }.reversed()
    }

    private var todayIndex:   Int  { days.count - 1 }
    private var isToday:      Bool { pageIndex == todayIndex }
    private var selectedDate: Date { days[pageIndex] }

    private func goBack()    { if pageIndex > 0 { pageIndex -= 1 } }
    private func goForward() { if !isToday      { pageIndex += 1 } }

    /// If the calendar day has advanced (e.g. crossed midnight while backgrounded),
    /// rebuild the day window; if we were on "today", follow it to the new today so
    /// the first morning reading shows on today's page, not yesterday's.
    private func refreshForDayChange() {
        let newDays = LiveView.makeDays()
        guard newDays.last != days.last else { return }
        let wasToday = (pageIndex == days.count - 1)
        days = newDays
        if wasToday { pageIndex = newDays.count - 1 }
    }

    private var currentQuality: CombinedSignalQuality? {
        ECGQualityCompute.combinedTier(
            rrSignalQuality: env.latestTick?.signalQuality,
            ecgResult:       env.latestTick?.ecgQuality
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ── Date navigator lives OUTSIDE TabView so it never
                    //    conflicts with the inner ScrollViews.
                    DateNavigator(
                        date:      selectedDate,
                        isToday:   isToday,
                        window:    $chartWindow,
                        onBack:    goBack,
                        onForward: goForward
                    )

                    // ── One page per day. TabView handles horizontal swiping
                    //    natively; SwiftUI disambiguates H vs V gestures for us.
                    TabView(selection: $pageIndex) {
                        ForEach(0..<LiveView.dayCount, id: \.self) { i in
                            DayScrollView(date: days[i], window: chartWindow)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .navigationTitle("LIVE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        keepAwake.toggle()
                        UIApplication.shared.isIdleTimerDisabled = keepAwake
                    } label: {
                        Image(systemName: keepAwake ? "sun.max.fill" : "sun.max")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(keepAwake ? Theme.accent : Theme.dim)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    BLENavButton(state: env.ble.state,
                                 bpm: env.latestTick?.meanBPM,
                                 quality: currentQuality) {
                        showBLESheet = true
                    }
                }
            }
            .sheet(isPresented: $showBLESheet) {
                BLEConnectionSheet(ble: env.ble, quality: currentQuality, motion: env.accMotion)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshForDayChange() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                refreshForDayChange()
            }
            .task {
                // Runs on appear and self-heals every 60 s while Live is visible —
                // catches the midnight rollover even if scenePhase or the day-change
                // notification don't fire (backgrounded / coalesced / other tab).
                while !Task.isCancelled {
                    refreshForDayChange()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }
}

// MARK: - Day Scroll View

/// One page in the TabView — a plain vertical ScrollView for a single day.
/// Manages its own history fetch so the parent stays lightweight.
private struct DayScrollView: View {
    let date: Date
    let window: TimeWindow

    @Environment(AppEnvironment.self) var env
    @Environment(\.modelContext) var ctx
    // Snapshot arrays feeding the (expensive) charts. Deliberately NOT read from
    // env.tickHistory in `body`: the today page's body re-evaluates every 2 s
    // (it reads env.latestTick for the live card/table), and if the charts were
    // fed live data they would re-render all 9 Swift Charts on every tick — the
    // periodic scroll hitch. Instead these refresh on a ~15 s cadence (today) or
    // once on load (past days); MetricsChartsView is `.equatable()` so the 2 s
    // body re-evals don't touch it while this snapshot is unchanged.
    @State private var chartRaw:      [MetricsHistoryPoint] = []
    @State private var chartFiltered: [MetricsHistoryPoint] = []
    @State private var chartDayAvg:   MetricsTick?          = nil
    // The last 7 recorded days before this page's day — the metrics grid's
    // comparison target. Built once per page from cached rollups.
    @State private var reference:     LiveDayReference?     = nil
    @State private var liveStore      = LiveStateStore()
    @State private var potentialStore = DayPotentialStore()

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    /// Half-open [startOfDay, nextDay) for `date` — computed once instead of
    /// calling Calendar.isDateInToday per history element.
    private var dayRange: Range<Date>? {
        let cal   = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        return start..<end
    }

    var body: some View {
        LogoRefreshableScrollView(enabled: isToday, onRefresh: {
            // The local half (name, feeling, WHY) reads only stored rollups
            // and tick history already in memory, so it recomputes
            // synchronously here rather than waiting on the network calls
            // below — without this, pulling down did nothing for it at all
            // whenever the poll loop wasn't already running (BLE off at
            // launch), despite the empty-state copy telling the user to.
            liveStore.recomputeState(env: env)
            // Pull down on today's page to force an immediate update; otherwise
            // the state refreshes automatically at most every 5 minutes.
            await liveStore.refresh(env: env, force: true)
            await potentialStore.refresh(env: env, force: true)
        }) {
            VStack(spacing: 12) {

                // ── Autonomic state (today only) ────────────────────
                if isToday {
                    LiveStateWidget(store: liveStore, potentialStore: potentialStore)
                        .padding(.horizontal)
                    CurrentStateCard(tick: env.latestTick,
                                     baselineRmssd: liveStore.baseline?.stat(for: .rmssd)?.mean)
                        .padding(.horizontal)
                }

                // ── Metrics table ───────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(isToday ? "LIVE" : "DAY AVERAGE")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                        Spacer()
                        if reference != nil {
                            Text(isToday ? "today vs 7-day" : "vs 7-day")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim.opacity(0.6))
                        }
                    }
                    .padding(.horizontal)
                    MetricsTableView(
                        tick:      isToday ? env.latestTick : chartDayAvg,
                        dayAvg:    isToday ? chartDayAvg    : nil,
                        reference: reference
                    )
                    .padding(.horizontal)
                }

                // ── Historical metric charts ────────────────────────
                if !chartFiltered.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("METRICS HISTORY")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                            .padding(.horizontal)
                        MetricsChartsView(history: chartFiltered, rawHistory: chartRaw, date: date, window: window)
                            .equatable()
                    }
                } else if !isToday {
                    Text("No data for this day")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                }


            }
            .padding(.top, 8)
            // The paged day-TabView doesn't forward the app tab bar's bottom
            // safe-area inset, so add clearance or the last section (the
            // collapsible SIGNAL QUALITY header) hides under the menu.
            .padding(.bottom, 72)
        }
        .task(id: date) {
            if isToday {
                // Refresh the charts immediately, then on a slow cadence. The live
                // card/table still update every 2 s via env.latestTick; the charts
                // don't need 2 s granularity and re-rendering 9 Swift Charts that
                // often is what made scrolling hitch.
                refreshLiveCharts()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { break }
                    refreshLiveCharts()
                }
            } else {
                // Debounce: if the user swipes past this day within 150 ms, the
                // task is cancelled during the sleep and the fetch never fires —
                // keeps fast swiping smooth and avoids piling up background fetches
                // for days you only pass through.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await loadDayHistory()
            }
        }
        // History is now loaded asynchronously at launch and merged on foreground;
        // refresh today's charts the instant it lands rather than waiting for the
        // next 15 s poll (bumps only on bulk loads, not on live 2 s appends).
        .onChange(of: env.historyRevision) {
            if isToday { refreshLiveCharts() }
        }
    }

    // MARK: - Data helpers

    /// Snapshots today's live history into the chart @State on a slow cadence.
    /// Reads env.tickHistory OUTSIDE `body` (from the .task loop) so it does not
    /// register a body dependency — the 9 charts stay off the 2 s tick path.
    @MainActor
    private func refreshLiveCharts() {
        guard let range = dayRange else { return }
        let raw      = env.tickHistory.filter { range.contains($0.timestamp) }
        let filtered = MetricsQualityFilter.filter(raw)
        chartRaw      = raw
        chartFiltered = filtered
        chartDayAvg   = dayAverageTick(from: filtered)
        loadReferenceIfNeeded()
    }

    /// Loads a past day's history off the main thread. The synchronous 43k-row
    /// SwiftData fetch used to run in `onAppear` on the main thread, blocking the
    /// horizontal swipe animation; here it runs on a background ModelContext and
    /// only the (Sendable) plain-struct result is handed back to the main actor.
    @MainActor
    private func loadDayHistory() async {
        guard chartRaw.isEmpty else { return }   // already loaded for this day
        let container = ctx.container
        let cal   = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }

        let result: ([MetricsHistoryPoint], [MetricsHistoryPoint]) = await Task.detached {
            let bg = ModelContext(container)
            var desc = FetchDescriptor<HRVSample>(
                predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
                sortBy:    [SortDescriptor(\.timestamp)]
            )
            desc.fetchLimit = 43_200
            let pts = ((try? bg.fetch(desc)) ?? []).map { MetricsHistoryPoint(from: $0) }
            return (pts, MetricsQualityFilter.filter(pts))
        }.value

        guard !Task.isCancelled else { return }
        chartRaw      = result.0
        chartFiltered = result.1
        chartDayAvg   = dayAverageTick(from: result.1)
        loadReferenceIfNeeded()
    }

    /// Builds the 7-recorded-day reference for this page from cached rollups.
    /// Rollups only change on day boundaries and bulk syncs, so once per page
    /// is enough — the guard also keeps the 15 s chart cadence off the cache.
    @MainActor
    private func loadReferenceIfNeeded() {
        guard reference == nil else { return }
        env.trackCache.load()
        let start  = Calendar.current.startOfDay(for: date)
        let cutoff = Calendar.current.date(byAdding: .day, value: -180, to: start) ?? .distantPast
        reference  = LiveDayComparison.reference(
            rollups: env.trackCache.rollups(in: cutoff...start),
            before:  start
        )
    }

    private func dayAverageTick(from history: [MetricsHistoryPoint]) -> MetricsTick? {
        guard !history.isEmpty else { return nil }
        func avg(_ vals: [Float]) -> Float? {
            vals.isEmpty ? nil : vals.reduce(0, +) / Float(vals.count)
        }
        return MetricsTick(
            timestamp:       history.last?.timestamp ?? .now,
            meanBPM:         avg(history.compactMap(\.meanBPM)),
            sdnn:            avg(history.compactMap(\.sdnn)),
            rmssd:           avg(history.compactMap(\.rmssd)),
            pnn50:           avg(history.compactMap(\.pnn50)),
            vti:             avg(history.compactMap(\.rmssd)).map { $0 > 0 ? log($0) : 0 },
            ulfPower:        avg(history.compactMap(\.ulfPower)),
            vlfPower:        avg(history.compactMap(\.vlfPower)),
            lfPower:         avg(history.compactMap(\.lfPower)),
            hfPower:         avg(history.compactMap(\.hfPower)),
            lfHF:            avg(history.compactMap(\.lfHF)),
            rsaMs:           avg(history.compactMap(\.rsaMs)),
            rsaIdx:          nil,
            breathBPM:       avg(history.compactMap(\.breathBPM)),
            breathHz:        nil,
            regularity:      nil,
            coherenceScore:  avg(history.compactMap(\.coherence)),
            cbi:             avg(history.compactMap(\.cbi)),
            dfa1:            avg(history.compactMap(\.dfa1)),
            signalQuality:   avg(history.compactMap(\.signalQuality)),
            ecgQuality:      nil,
            rcmse:           avg(history.compactMap(\.rcmse)),
            pip:             avg(history.compactMap(\.pip)),
            ials:            avg(history.compactMap(\.ials)),
            dc:              avg(history.compactMap(\.dc)),
            breathPhases:    nil,
            psdFreqs:        nil,
            psdValues:       nil,
            coherenceFreqs:  nil,
            coherenceValues: nil
        )
    }
}

// MARK: - Today Live Section
//
// Reads env.waveform (30 fps) and env.latestTick (2 s).
// Extracted from DayScrollView so waveform-rate redraws don't invalidate
// the chart area — DayScrollView.body now only runs at the 2-s tick rate.

private struct TodayLiveSection: View {
    @Environment(AppEnvironment.self) var env

    var body: some View { EmptyView() }
}

// MARK: - Date Navigator

private struct DateNavigator: View {
    let date:      Date
    let isToday:   Bool
    @Binding var window: TimeWindow
    let onBack:    () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            Text(dateLabel)
                .font(Theme.monoBody)
                .foregroundStyle(Theme.text)
            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isToday ? Theme.dim.opacity(0.3) : Theme.text)
            }
            .disabled(isToday)

            Spacer()

            // Shared window selector — applies to every chart on the page.
            HStack(spacing: 3) {
                ForEach(TimeWindow.allCases) { w in
                    Button(w.rawValue) {
                        withAnimation(.easeInOut(duration: 0.15)) { window = w }
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(w == window ? Color.black : Theme.dim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(w == window ? Theme.accent : Color.clear)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var dateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "TODAY" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE  MMM d"
        return fmt.string(from: date).uppercased()
    }
}

// MARK: - Live Stream Scope

/// Rolling windows of the raw ECG and ACC streams feeding the diagnostics
/// scope in the Bluetooth sheet. Subscribes for the sheet's lifetime only —
/// the buffers die with the sheet, nothing accumulates in the background.
@MainActor
@Observable
final class StreamScope {
    /// Last 4 s of ECG at 130 Hz, in µV.
    private(set) var ecg: [Float] = []
    /// Last 4 s of movement intensity at 200 Hz: the magnitude of the
    /// gravity-free ACC residual, in mg. One line instead of three axes —
    /// "how much am I moving" is the question this strip answers; which
    /// direction is a debugging concern the sheet doesn't need.
    private(set) var accMag: [Float] = []
    /// Running gravity estimate; seeded from the first sample so the strip
    /// doesn't open with a full-scale settling transient.
    private var gravity: SIMD3<Float>? = nil

    var motionState: MotionCompute.MotionState {
        MotionCompute.state(rms: MotionCompute.rms(accMag.suffix(100)))
    }

    /// Movements registered since the sheet opened, newest first (last 3 kept).
    private(set) var movementEvents: [(at: Date, peak: Float)] = []
    private(set) var movementCount = 0
    private var detector = MotionEventDetector()

    static let ecgWindow = PolarH10Profile.ecgSampleRate * 4
    static let accWindow = PolarH10Profile.accSampleRate * 4

    private var bag = Set<AnyCancellable>()

    init(ble: BLEService) {
        // Both subjects publish from the main actor (BLEService hops before
        // sending), so mutating here is main-thread safe.
        ble.ecgSubject
            .sink { [weak self] samples in
                guard let self else { return }
                ecg.append(contentsOf: samples)
                if ecg.count > Self.ecgWindow { ecg.removeFirst(ecg.count - Self.ecgWindow) }
            }
            .store(in: &bag)
        ble.accSubject
            .sink { [weak self] xyz in
                guard let self else { return }
                for s in xyz {
                    let f = SIMD3<Float>(Float(s.x), Float(s.y), Float(s.z))
                    var g = gravity ?? f
                    let hp = MotionCompute.highPassStep(gravity: &g, sample: f)
                    gravity = g
                    let magnitude = (hp.x * hp.x + hp.y * hp.y + hp.z * hp.z).squareRoot()
                    accMag.append(magnitude)
                    if let event = detector.step(magnitude: magnitude) {
                        movementEvents.insert((at: Date(), peak: event.peak), at: 0)
                        if movementEvents.count > 3 { movementEvents.removeLast() }
                    }
                    movementCount = detector.count
                }
                if accMag.count > Self.accWindow { accMag.removeFirst(accMag.count - Self.accWindow) }
            }
            .store(in: &bag)
    }
}

/// One oscilloscope strip: right-anchored polylines over a shared auto-scaled
/// y-range, a recessive midline, and a dot legend when there's more than one
/// series. Shows a waiting state until the first samples land — which is
/// itself diagnostic: a strip that never fills means that stream is dead.
private struct ScopeStrip: View {
    struct Series {
        let label:  String?
        let color:  Color
        let points: [Float]
    }

    let title:    String
    let detail:   String
    let capacity: Int
    let series:   [Series]
    /// nil → autoscale to the window (right for ECG, which is inherently AC);
    /// set → a stable scale, so the same movement always looks the same size
    /// and stillness reads as a genuinely flat line, with the midline at zero.
    var fixedRange: ClosedRange<Float>? = nil
    /// Soft area fill under the trace — for single-series intensity strips
    /// where "amount" reads better as a filled shape than a bare line.
    var filled: Bool = false
    /// With a fixedRange: let the top stretch when the data exceeds it, so a
    /// big movement is never clipped flat — the range's upper bound stays the
    /// FLOOR of the scale (stillness always looks the same), not a ceiling.
    var expandsToFit: Bool = false

    private var isEmpty: Bool { series.allSatisfy { $0.points.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                if series.count > 1 {
                    ForEach(series.indices, id: \.self) { i in
                        if let label = series[i].label {
                            HStack(spacing: 4) {
                                Circle().fill(series[i].color).frame(width: 6, height: 6)
                                Text(label)
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.6))
            }

            ZStack {
                if isEmpty {
                    Text("waiting for stream…")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.7))
                } else {
                    Canvas { ctx, size in
                        let ymin: Float, ymax: Float
                        if let range = fixedRange {
                            ymin = range.lowerBound
                            if expandsToFit,
                               let peak = series.flatMap(\.points).max(),
                               peak > range.upperBound {
                                ymax = peak * 1.05
                            } else {
                                ymax = range.upperBound
                            }
                        } else {
                            let all = series.flatMap(\.points)
                            guard let lo = all.min(), let hi = all.max() else { return }
                            let pad = max((hi - lo) * 0.08, 1)
                            ymin = lo - pad; ymax = hi + pad
                        }
                        let step = size.width / CGFloat(max(capacity - 1, 1))

                        // Recessive guide: midline for centered traces, the
                        // baseline itself for bottom-anchored intensity strips.
                        let guideY = (fixedRange?.lowerBound == 0) ? size.height - 0.5
                                                                   : size.height / 2
                        var grid = Path()
                        grid.move(to: CGPoint(x: 0, y: guideY))
                        grid.addLine(to: CGPoint(x: size.width, y: guideY))
                        ctx.stroke(grid, with: .color(Theme.border.opacity(0.6)), lineWidth: 1)

                        for s in series where !s.points.isEmpty {
                            var path = Path()
                            let x0 = size.width - CGFloat(s.points.count - 1) * step
                            for (i, raw) in s.points.enumerated() {
                                let v = min(max(raw, ymin), ymax)
                                let x = x0 + CGFloat(i) * step
                                let y = size.height *
                                        CGFloat(1 - (v - ymin) / max(ymax - ymin, .leastNonzeroMagnitude))
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else      { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                            if filled {
                                var area = path
                                let lastX = x0 + CGFloat(s.points.count - 1) * step
                                area.addLine(to: CGPoint(x: lastX, y: size.height))
                                area.addLine(to: CGPoint(x: x0, y: size.height))
                                area.closeSubpath()
                                ctx.fill(area, with: .color(s.color.opacity(0.13)))
                            }
                            ctx.stroke(path, with: .color(s.color),
                                       style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        }
                    }
                }
            }
            .frame(height: 88)
            .frame(maxWidth: .infinity)
            .background(Theme.bg.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - BLE Connection Sheet

struct BLEConnectionSheet: View {
    let ble:     BLEService
    let quality: CombinedSignalQuality?
    let motion:  Float?
    @Environment(\.dismiss) private var dismiss
    @State private var scope: StreamScope? = nil

    private static let eventTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(ble: BLEService, quality: CombinedSignalQuality? = nil, motion: Float? = nil) {
        self.ble     = ble
        self.quality = quality
        self.motion  = motion
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        if let quality { signalQualityCard(quality) }
                        // Always present — an empty "waiting for stream…" strip
                        // when nothing flows IS the diagnostic; hiding the card
                        // on disconnect/standby just made the charts feel gone.
                        liveStreamsCard
                        actionSection
                        if let err = ble.lastError { errorCard(err) }
                    }
                    .padding()
                }
                .task {
                    if scope == nil { scope = StreamScope(ble: ble) }
                }
            }
            .navigationTitle("BLUETOOTH")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.14))
                    .frame(width: 50, height: 50)
                Image(systemName: stateIcon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(stateColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(stateTitle)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                Text(stateSubtitle)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                // Diagnostic: always show raw CB state so the user can tell us
                // whether Bluetooth is actually on and available.
                Text(ble.cbStateDescription)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.6))
            }
            Spacer()
        }
        .cardStyle()
    }

    private func signalQualityCard(_ q: CombinedSignalQuality) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SIGNAL QUALITY")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(q.tier.color).frame(width: 7, height: 7)
                    Text(q.tier.label)
                        .font(Theme.monoBody)
                        .foregroundStyle(q.tier.color)
                }
            }
            HStack {
                Text("RR artifacts")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(q.rrArtifactPercent.map { "\($0)%" } ?? "—")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
            }
            HStack {
                Text("ECG waveform")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(q.ecgReason ?? "—")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
            }
            HStack {
                Text("Skin contact")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(SkinContactPolicy.label(contact: ble.sensorContact,
                                             ecgLive: ble.ecgStreamLive))
                    .font(Theme.monoBody)
                    .foregroundStyle(ble.sensorContact == false ? Theme.warn : Theme.text)
            }
            HStack {
                Text("Motion")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(motion.map { String(format: "%.1f", $0) } ?? "—")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
            }
            if q.tier != .good {
                Divider().background(Theme.border)
                Text("Improving signal quality")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                ForEach(Self.improvementTips, id: \.self) { tip in
                    Text("•  \(tip)")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.text.opacity(0.85))
                }
            }
        }
        .cardStyle()
    }

    private static let improvementTips = [
        "Limit movement during measurement",
        "Ensure the chest strap is moist",
        "Ensure the strap is tightened appropriately",
        "Check and replace worn-out chest straps",
        "Check and replace HR monitor batteries that are low",
    ]

    @ViewBuilder
    private var actionSection: some View {
        if case .connected(let name) = ble.state {
            connectedCard(name: name)
        } else {
            deviceScanSection
        }
    }

    private func connectedCard(name: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(name.uppercased())
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.accent)
                    if let bat = ble.batteryLevel {
                        HStack(spacing: 5) {
                            Image(systemName: batteryIcon(bat))
                                .foregroundStyle(bat > 20 ? Theme.accent : Theme.warn)
                                .font(.caption)
                            Text("\(bat)%")
                                .font(Theme.monoLabel)
                                .foregroundStyle(BatteryAlertPolicy.isCritical(bat)
                                                 ? Theme.warn : Theme.dim)
                        }
                    }
                }
                Spacer()
                Button("Disconnect") { ble.disconnect() }
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.warn.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.warn.opacity(0.3), lineWidth: 0.5)
                    )
            }

            if BatteryAlertPolicy.isCritical(ble.batteryLevel) {
                lowBatteryBanner
            }
        }
        .cardStyle()
    }

    /// Stays up as long as the cell reads below 5% — the once-a-day push in
    /// BLEService is the nudge; this is the standing reminder.
    private var lowBatteryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "battery.25percent")
                .foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("BATTERY BELOW 5%")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.warn)
                Text("Replace the CR2025 coin cell soon — the strap can die mid-session.")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.warn.opacity(0.35), lineWidth: 1)
        )
    }

    /// Raw stream scope — the fastest way to see whether the strap is actually
    /// delivering ECG and ACC, as opposed to the state label saying so.
    private var liveStreamsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let scope {
                ScopeStrip(
                    title: "ECG",
                    detail: "130 Hz · last 4 s · µV",
                    capacity: StreamScope.ecgWindow,
                    series: [.init(label: nil, color: Theme.accent, points: scope.ecg)]
                )
                ScopeStrip(
                    title: "MOVEMENT",
                    detail: "all axes combined · scale fits peaks · last 4 s",
                    capacity: StreamScope.accWindow,
                    series: [.init(label: nil, color: Theme.rsa, points: scope.accMag)],
                    fixedRange: 0...60,
                    filled: true,
                    expandsToFit: true
                )
                if !scope.accMag.isEmpty {
                    HStack(spacing: 10) {
                        motionChip(scope.motionState)
                        Spacer()
                        Text("movements: \(scope.movementCount)")
                            .font(Theme.monoLabel)
                            .foregroundStyle(scope.movementCount > 0 ? Theme.text : Theme.dim)
                            .contentTransition(.numericText())
                    }
                    // The receipt: each registered movement, with its size —
                    // wave your arm, watch the row appear.
                    ForEach(scope.movementEvents, id: \.at) { event in
                        HStack(spacing: 8) {
                            Circle().fill(Theme.rsa).frame(width: 5, height: 5)
                            Text(Self.eventTime.string(from: event.at))
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                            Text("movement registered · peak \(Int(event.peak)) mg")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.text.opacity(0.85))
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    /// The affirmation layer: what the strap thinks you're doing, in words —
    /// so "did it feel that?" is answered without reading the trace.
    private func motionChip(_ state: MotionCompute.MotionState) -> some View {
        let (label, color): (String, Color) = switch state {
        case .still:  ("STILL",         Theme.accent)
        case .subtle: ("SUBTLE MOTION", Theme.breathe)
        case .moving: ("MOVING",        Theme.rsa)
        }
        return Text(label)
            .font(Theme.monoLabel)
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(color.opacity(0.09))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }

    private var deviceScanSection: some View {
        VStack(spacing: 12) {
            Button {
                if case .scanning = ble.state { ble.stopScanning() }
                else { ble.startScanning() }
            } label: {
                HStack(spacing: 10) {
                    if case .scanning = ble.state {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Theme.accent)
                            .scaleEffect(0.75)
                        Text("SCANNING…  TAP TO STOP")
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text("SCAN FOR DEVICES")
                    }
                }
                .font(Theme.monoBody)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.accent.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                )
            }

            if !ble.discoveredDevices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(ble.discoveredDevices) { device in
                        DeviceRow(
                            device: device,
                            isConnecting: {
                                if case .connecting(let n) = ble.state { return n == device.name }
                                return false
                            }(),
                            // In a crowded room your own strap (on your chest, phone
                            // in hand) is almost always the strongest signal.
                            isNearest: ble.discoveredDevices.count > 1
                                       && device.id == ble.discoveredDevices.first?.id
                        ) {
                            ble.connectToDevice(device)
                        }
                        if device.id != ble.discoveredDevices.last?.id {
                            Divider().background(Theme.border).padding(.horizontal, 12)
                        }
                    }
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.border, lineWidth: 0.5)
                )
            } else if case .scanning = ble.state {
                Text("Looking for Polar H10…")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }

            if UserDefaults.standard.string(forKey: "wythin.polar.uuid") != nil {
                Button {
                    UserDefaults.standard.removeObject(forKey: "wythin.polar.uuid")
                    ble.disconnect()
                } label: {
                    Text("Forget saved device")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
                .font(.caption)
            Text(message)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.warn)
                .lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(Theme.warn.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.warn.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var stateColor: Color {
        switch ble.state {
        case .connected:             return Theme.accent
        case .scanning, .connecting: return Theme.warn
        case .disconnected:          return Theme.warn.opacity(0.7)
        default:                     return Theme.dim
        }
    }

    private var stateIcon: String {
        switch ble.state {
        case .connected:   return "checkmark.circle.fill"
        case .scanning:    return "dot.radiowaves.left.and.right"
        case .connecting:  return "arrow.triangle.2.circlepath"
        case .unauthorized: return "lock.slash"
        default:           return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var stateTitle: String {
        switch ble.state {
        case .idle:              return "Not Connected"
        case .scanning:          return "Scanning…"
        case .connecting(let n): return "Connecting to \(n)"
        case .connected(let n):  return n
        case .disconnected:      return "Disconnected"
        case .standby(let n):    return n
        case .unauthorized:      return "No Bluetooth Permission"
        case .unsupported:       return "Bluetooth Unavailable"
        }
    }

    private var stateSubtitle: String {
        switch ble.state {
        case .idle:              return "Tap Scan to find your Polar H10"
        case .scanning:          return "Searching (Heart Rate service filter)…"
        case .connecting:        return "Establishing connection…"
        case .connected:         return "ECG + ACC streaming"
        case .disconnected(let r): return r
        case .standby:           return "Strap off — will reconnect when worn"
        case .unauthorized:      return "Allow Bluetooth in iPhone Settings"
        case .unsupported:       return "This device doesn't support BLE"
        }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case 75...: return "battery.100"
        case 50...: return "battery.75"
        case 25...: return "battery.50"
        default:    return "battery.25"
        }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device:       BLEDevice
    let isConnecting: Bool
    var isNearest:    Bool = false
    let onConnect:    () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text)
                    if isNearest {
                        Text("NEAREST")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 5) {
                    Text(device.rssiDots)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(rssiColor)
                    Text("\(device.rssi) dBm  ·  \(device.rssiLabel)")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            if isConnecting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.accent)
                    .scaleEffect(0.8)
            } else {
                Button("CONNECT", action: onConnect)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isNearest ? Theme.accent.opacity(0.06) : Color.clear)
    }

    private var rssiColor: Color {
        switch device.rssi {
        case (-50)...: return Theme.accent
        case (-70)...: return Theme.warn
        default:       return Theme.dim
        }
    }
}

// MARK: - Sub-components

// MARK: - Metrics Table

private struct MetricsTableView: View {
    let tick:      MetricsTick?       // live tick (today) or the day average (past days)
    let dayAvg:    MetricsTick?       // today's running average; nil on past days
    let reference: LiveDayReference?  // last 7 recorded days before the viewed day

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        // `LiveMetric`'s declaration order — the app's canonical display
        // order, shared with the Track charts and the Live history charts.
        // Calm Power and Pulse have no Track chart, so they follow the rest.
        LazyVGrid(columns: cols, spacing: 10) {
            tile("Stress Balance",      "SNS",    "%",   .stressBalance, stressBalance) { String(format: "%.0f", $0) }
            tile("Conscious Breathing", "RSA",    "ms",  .rsa,           { $0?.rsaMs })  { String(format: "%.1f", $0) }
            tile("Harmony",             "DFA α1", "",    .dfa1,          { $0?.dfa1 })   { String(format: "%.2f", $0) }
            tile("Vagal Tone",          "DC",     "ms",  .dc,            { $0?.dc })     { String(format: "%.1f", $0) }
            tile("Energy Reserve",      "HRV",    "ms",  .rmssd,         { $0?.rmssd })  { String(format: "%.1f", $0) }
            tile("Inner Noise",         "PIP",    "%",   .pip,           { $0?.pip })    { String(format: "%.1f", $0) }
            tile("Adaptive Capacity",   "RCMSE",  "",    .rcmse,         { $0?.rcmse })  { String(format: "%.2f", $0) }
            tile("Calm Power",          "VTI",    "",    .vti,           { $0?.vti })    { String(format: "%.2f", $0) }
            tile("Pulse",               "HR",     "bpm", .hr,            { $0?.meanBPM }) { String(format: "%.0f", $0) }
        }
    }

    /// One tile's plumbing: on today, `tick` is live and `dayAvg` is the day;
    /// on past days `tick` IS the day and there is no "now".
    private func tile(_ label: String, _ tech: String, _ unit: String,
                      _ metric: LiveMetric,
                      _ value: (MetricsTick?) -> Float?,
                      _ fmt: (Float) -> String) -> LiveDeltaTile {
        let current  = value(tick)
        let dayValue = dayAvg != nil ? value(dayAvg) : current

        let delta = dayValue.flatMap { d in
            reference.flatMap { LiveDayDelta.compute(value: d, metric: metric, reference: $0) }
        }

        // Live vs today's average — today only, and only once the day average
        // is non-degenerate.
        var nowPercent: Float?    = nil
        var nowBeneficial: Bool?  = nil
        if dayAvg != nil, let c = current, let d = dayValue, abs(d) > 1e-6 {
            nowPercent = (c - d) / abs(d) * 100
            let dir = LiveDayComparison.direction(for: metric)
            nowBeneficial = dir.benefit(Double(c)) > dir.benefit(Double(d))
        }

        return LiveDeltaTile(
            label:      label,
            techLabel:  tech,
            unit:       unit,
            valueText:  current.map(fmt) ?? "—",
            todayText:  dayAvg != nil ? dayValue.map(fmt) : nil,
            refText:    reference?.stat(for: metric).map { fmt($0.mean) },
            delta:      delta,
            nowPercent: nowPercent,
            nowBeneficial: nowBeneficial
        )
    }

    /// Breathing-robust 0–100 stress dial (SNS %), the same signal the Stress
    /// Balance chart plots — NOT the raw LF/HF ratio, which misleads during
    /// slow breathing.
    private func stressBalance(_ t: MetricsTick?) -> Float? {
        guard let t else { return nil }
        return AutonomicCompute.balance(rmssd: t.rmssd, lf: t.lfPower, hf: t.hfPower,
                                        breathBPM: t.breathBPM, meanBPM: t.meanBPM,
                                        baselineRmssd: nil).map { $0.sns * 100 }
    }
}

// MARK: - Preview

#Preview("Live View - Connected") {
    LiveView()
        .environment(createMockEnvironment())
}

@MainActor
private func createMockEnvironment() -> AppEnvironment {
    let config    = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: HRVSession.self, configurations: config)
    let env = AppEnvironment(modelContainer: container)
    env.ble.state       = .connected(name: "Polar H10")
    env.waveform.ecg    = generateMockECG()
    env.latestTick      = MetricsTick(
        timestamp: Date(), meanBPM: 72.5, sdnn: 45.3, rmssd: 38.7,
        pnn50: 22.1, vti: 12.5, ulfPower: 25, vlfPower: 550, lfPower: 850, hfPower: 1200, lfHF: 0.71,
        rsaMs: 42.0, rsaIdx: 1.41, breathBPM: 6.2, breathHz: 0.103,
        regularity: 0.85, coherenceScore: 0.76, cbi: 0.82, dfa1: 1.02, signalQuality: 0.97,
        ecgQuality: ECGQualityResult(tier: .good, reason: "clean"),
        rcmse: 1.45, pip: 54.2, ials: 0.51, dc: 7.2,
        breathPhases: nil, psdFreqs: nil, psdValues: nil,
        coherenceFreqs: nil, coherenceValues: nil
    )
    return env
}

private func generateMockECG() -> [Float] {
    (0..<650).map { i in
        let t = Float(i) / 650.0
        let p = (t * 5.8).truncatingRemainder(dividingBy: 1.0)
        var v: Float = 0
        if p < 0.15 { v = 50 * sin(p * .pi / 0.15) }
        else if p < 0.35 {
            let q = (p - 0.25) / 0.1
            if      q < 0.3  { v = -100 * sin(q * .pi / 0.3) }
            else if q < 0.7  { v =  800 * sin((q - 0.3) * .pi / 0.4) }
            else              { v = -200 * sin((q - 0.7) * .pi / 0.3) }
        } else if p < 0.7 { v = 150 * sin((p - 0.5) * .pi / 0.2) }
        return v + Float.random(in: -15...15)
    }
}

// MARK: - Logo Pull-to-Refresh

/// Vertical ScrollView with a custom pull-to-refresh whose indicator is the
/// Wythin logo: it rotates with the pull and spins continuously while
/// refreshing. Uses scroll-offset detection (not a gesture) so it never fights
/// the horizontal day-paging TabView, and it only reacts to downward overscroll
/// so normal scrolling doesn't re-evaluate the (heavy) content.
struct LogoRefreshableScrollView<Content: View>: View {
    var enabled: Bool = true
    let onRefresh: () async -> Void
    let content: Content

    init(enabled: Bool = true,
         onRefresh: @escaping () async -> Void,
         @ViewBuilder content: () -> Content) {
        self.enabled   = enabled
        self.onRefresh = onRefresh
        self.content   = content()
    }

    @State private var pull: CGFloat = 0
    @State private var isRefreshing = false

    private let threshold       = 72.0
    private let indicatorHeight = 60.0
    private let logoSize        = 26.0
    private let space           = "wythinLogoRefresh"

    private var progress: Double { min(1, Double(pull) / threshold) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Zero-height anchor at the very top: its minY in the scroll
                // space is 0 at rest and grows as the user overscrolls down.
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RefreshOffsetKey.self,
                        value: proxy.frame(in: .named(space)).minY)
                }
                .frame(height: 0)

                // Revealed band that holds the spinning logo while refreshing.
                Color.clear.frame(height: isRefreshing ? indicatorHeight : 0)

                content
            }
        }
        .coordinateSpace(name: space)
        .overlay(alignment: .top) {
            if enabled {
                let y = isRefreshing
                    ? indicatorHeight / 2 - logoSize / 2
                    : min(max(0, Double(pull)), 140) / 2 - logoSize / 2
                RefreshLogo(spinning: isRefreshing,
                            pullAngle: progress * 270,
                            opacity:  isRefreshing ? 1 : progress,
                            size: logoSize)
                    .offset(y: y)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isRefreshing)
        .onPreferenceChange(RefreshOffsetKey.self) { value in
            guard enabled else { return }
            let p = max(0, value)              // ignore normal (upward) scrolling
            if p != pull { pull = p }
            if !isRefreshing && p > threshold { trigger() }
        }
    }

    private func trigger() {
        isRefreshing = true
        Task {
            await onRefresh()
            isRefreshing = false
        }
    }
}

/// The Wythin logo used as the refresh indicator. Owns its own spin animation
/// so keeping it turning doesn't re-evaluate the scroll view's content.
private struct RefreshLogo: View {
    let spinning:  Bool
    let pullAngle: Double
    let opacity:   Double
    let size:      Double

    @State private var spin = false

    var body: some View {
        Image("WythinLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Theme.accent)
            .rotationEffect(.degrees(spinning ? (spin ? 360 : 0) : pullAngle))
            .opacity(opacity)
            .onChange(of: spinning) { _, now in
                if now {
                    spin = false
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                        spin = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { spin = false }
                }
            }
    }
}

private struct RefreshOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
