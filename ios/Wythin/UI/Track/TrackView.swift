import SwiftUI
import SwiftData

/// The Track tab: period-paged macro trends for the seven key metrics.
///
/// Nothing here reads raw `HRVSample`s for display — all-day recording writes
/// ~43,200 rows a day, so the screen goes through `TrackCache`'s daily rollups
/// and only ever fetches raw samples one uncached day at a time.
struct TrackView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext)      private var ctx

    @Query(sort: \ActivityLog.startedAt, order: .reverse) private var activities: [ActivityLog]

    @State private var period:  TrackPeriod = .week
    @State private var offset:  Int         = 0
    @State private var selectedBucket: Date?
    @State private var isLoading = false
    @State private var rollups:  [DailyRollup] = []
    @State private var macroText: String?
    @State private var macroLoading = false
    @State private var cache = TrackCache()

    private var today: Date { Calendar.current.startOfDay(for: .now) }
    /// Identity of the page currently on screen — the same string `.task(id:)`
    /// keys on. Used to guard against a superseded request's response landing
    /// after a newer page has already been requested.
    private var currentPageKey: String { "\(period.rawValue)-\(offset)" }
    private var range: TrackRange { TrackRangeBuilder.range(period: period, offset: offset, today: today) }
    private var priorRange: TrackRange {
        TrackRangeBuilder.range(period: period, offset: offset + 1, today: today)
    }

    /// Every metric's series for the current page, in display order.
    private var seriesList: [(spec: TrackMetricSpec, series: TrackSeries)] {
        TrackMetrics.all.map { spec in
            (spec, TrackSeriesBuilder.series(spec: spec, range: range, priorRange: priorRange,
                                             rollups: rollups, asOf: today))
        }
    }

    private var consistency: ConsistencySummary {
        ConsistencyBuilder.build(
            range: range,
            activities: activities.map { ActivitySpan(startedAt: $0.startedAt, endedAt: $0.endedAt) },
            rollups: rollups,
            today: today)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        TrackPeriodBar(period: $period, offset: $offset, label: range.label)

                        if isLoading {
                            ProgressView()
                                .tint(Theme.accent)
                                .padding(.vertical, 60)
                        } else {
                            MacroReadCard(text: macroText, isLoading: macroLoading)

                            ForEach(seriesList, id: \.spec.id) { pair in
                                TrackMetricChartCard(spec: pair.spec, series: pair.series,
                                                     period: period, selectedBucket: $selectedBucket)
                            }

                            ConsistencyCard(summary: consistency, period: period)
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(.top, 8)
                }
                // Swiping pages periods; the current page is the newest, so a
                // leftward swipe past it does nothing.
                .gesture(DragGesture(minimumDistance: 40)
                    .onEnded { g in
                        guard abs(g.translation.width) > abs(g.translation.height) else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if g.translation.width > 0 { offset += 1 }
                            else if offset > 0         { offset -= 1 }
                        }
                    })
            }
            .navigationTitle("TRACK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task(id: currentPageKey) {
            let pageKey = currentPageKey
            selectedBucket = nil
            await loadRollups()
            await loadMacroRead(pageKey: pageKey)
        }
    }

    // MARK: Data

    /// Fills any uncached day in the visible page, plus a 90-day tail so the
    /// personal baseline has data behind it, then reads the page back out.
    private func loadRollups() async {
        isLoading = rollups.isEmpty
        cache.load()

        let cal = Calendar.current
        // The visible page may be 7 days, but the personal reference line needs
        // 90 — without this tail every chart would silently read "typical".
        let baselineStart = cal.date(byAdding: .day,
                                     value: -TrackSeriesBuilder.baselineWindowDays,
                                     to: today) ?? range.start
        let fetchStart = min(range.start, baselineStart)
        let fetchEnd   = max(range.end, cal.date(byAdding: .day, value: 1, to: today) ?? range.end)
        let needed = TrackRangeBuilder.dayStarts(from: fetchStart, to: fetchEnd, calendar: cal)

        cache.refresh(days: needed, today: today) { day in
            let end = cal.date(byAdding: .day, value: 1, to: day)!
            var desc = FetchDescriptor<HRVSample>(
                predicate: #Predicate { $0.timestamp >= day && $0.timestamp < end },
                sortBy: [SortDescriptor(\.timestamp)])
            // One day of ticks at ~2 s is ~43k rows — bounded, unlike the
            // whole-window fetch this screen used to do.
            desc.fetchLimit = 60_000
            return ((try? ctx.fetch(desc)) ?? []).map { MetricsHistoryPoint(from: $0) }
        }

        rollups = cache.rollups(in: fetchStart...(needed.last ?? fetchStart))
        isLoading = false
    }

    /// `pageKey` is this request's page identity, captured by the caller at
    /// `.task(id:)` start. `loadMacroRead` awaits a network call and
    /// `macroRead` swallows every error (including `CancellationError`) via
    /// `try?`, so a superseded request can still complete and, without this
    /// guard, overwrite the current page's text with its own stale result.
    /// Checking `Task.isCancelled` would not be enough — a request that
    /// finishes *after* cancellation was observed still reaches this point —
    /// so the write is gated on page identity instead.
    private func loadMacroRead(pageKey: String) async {
        guard pageKey == currentPageKey else { return }
        macroText = nil
        // Same consent gate the uploaders read (AppEnvironment.swift:291);
        // defaults to on when the key was never written.
        guard UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true else { return }
        macroLoading = true
        let text = await macroRead(for: period, range: range, series: seriesList,
                                   cache: cache,
                                   client: APIClient(baseURL: env.serverURL))
        guard pageKey == currentPageKey else { return }
        macroText = text
        macroLoading = false
    }
}
