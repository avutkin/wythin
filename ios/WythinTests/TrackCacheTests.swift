import XCTest
@testable import Wythin

@MainActor
final class TrackCacheTests: XCTestCase {

    private let cal = Calendar.current
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-cache-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func day(_ back: Int) -> Date {
        cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: Date()))!
    }

    /// 200 quality samples for the given day — enough to clear the 150 gate.
    private func samples(_ d: Date, dc: Float = 8) -> [MetricsHistoryPoint] {
        (0..<200).map { i in
            MetricsHistoryPoint(timestamp: d.addingTimeInterval(Double(i) * 2),
                                meanBPM: 60, rmssd: 40, rsaMs: 30, sdnn: 50,
                                dfa1: 1.0, rcmse: 1.4, pip: 55, dc: dc)
        }
    }

    func testRefreshComputesMissingDays() {
        let cache = TrackCache(fileURL: url)
        let days = [day(2), day(1), day(0)]
        let changed = cache.refresh(days: days, today: day(0)) { samples($0) }
        XCTAssertTrue(changed)
        XCTAssertEqual(cache.rollups(in: day(2)...day(0)).count, 3)
    }

    func testRefreshDoesNotRefetchCachedPastDays() {
        let cache = TrackCache(fileURL: url)
        let days = [day(2), day(1), day(0)]
        _ = cache.refresh(days: days, today: day(0)) { samples($0) }

        var fetched: [Date] = []
        _ = cache.refresh(days: days, today: day(0)) { d in
            fetched.append(d)
            return samples(d)
        }
        // Only today is recomputed; closed past days are trusted.
        XCTAssertEqual(fetched, [day(0)])
    }

    func testTodayIsAlwaysRecomputed() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 6) }
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 10) }
        let r = cache.rollups(in: day(0)...day(0)).first
        XCTAssertEqual(r?.dc ?? 0, 10, accuracy: 0.001)
    }

    func testDaysBelowTheQualityGateAreNotStored() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(1)], today: day(0)) { _ in [] }
        XCTAssertTrue(cache.rollups(in: day(1)...day(1)).isEmpty)
    }

    // MARK: negative caching

    /// A day that computes to nil — strap off, or under the 150-tick gate —
    /// must be remembered as such. Without this a user who wore the strap 30
    /// of the last 90 days re-ran 60 fetches on every period switch and every
    /// swipe, for the life of the install.
    func testDaysThatComputeToNilAreNotRefetched() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(2), day(1)], today: day(0)) { _ in [] }

        var fetched: [Date] = []
        _ = cache.refresh(days: [day(2), day(1)], today: day(0)) { d in
            fetched.append(d)
            return []
        }
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertTrue(cache.uncachedDays([day(2), day(1)], today: day(0)).isEmpty)
    }

    /// The knowledge has to survive relaunch, like the rollups do — otherwise
    /// every cold start pays the full re-fetch again.
    func testNoDataDaysPersistAcrossInstances() {
        let a = TrackCache(fileURL: url)
        _ = a.refresh(days: [day(1)], today: day(0)) { _ in [] }

        let b = TrackCache(fileURL: url)
        b.load()
        var fetched: [Date] = []
        _ = b.refresh(days: [day(1)], today: day(0)) { d in
            fetched.append(d)
            return []
        }
        XCTAssertTrue(fetched.isEmpty)
    }

    /// Today is exempt: a day in progress gains samples as it goes, so a
    /// morning with nothing on the strap must not lock the day out until
    /// midnight.
    func testNegativelyCachedTodayIsStillRecomputed() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0)], today: day(0)) { _ in [] }
        XCTAssertTrue(cache.rollups(in: day(0)...day(0)).isEmpty)

        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 7) }
        XCTAssertEqual(cache.rollups(in: day(0)...day(0)).first?.dc ?? 0, 7, accuracy: 0.001)

        // And it comes back out of the negative set, so it is not skipped once
        // it has real data.
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 9) }
        XCTAssertEqual(cache.rollups(in: day(0)...day(0)).first?.dc ?? 0, 9, accuracy: 0.001)
    }

    /// A day that is still `today` when it first computes to nil must not be
    /// left in `noDataDays` once midnight passes and it becomes a genuinely
    /// past day. Before the fix, an empty "today" was negatively cached like
    /// any other nil day — harmless while it stayed `today` (the skip path
    /// only applies to `day != today`), but the moment it rolled over into
    /// the past it matched the skip path and was silently dropped forever,
    /// even though the user wore the strap all day.
    func testRolledOverTodayIsRecomputed() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0)], today: day(0)) { _ in [] }
        XCTAssertTrue(cache.rollups(in: day(0)...day(0)).isEmpty)

        // Midnight passes: day(0) is no longer "today", and the strap
        // recorded real samples during it.
        let tomorrow = day(-1)
        _ = cache.refresh(days: [day(0)], today: tomorrow) { samples($0, dc: 8) }

        XCTAssertEqual(cache.rollups(in: day(0)...day(0)).first?.dc ?? 0, 8, accuracy: 0.001)
    }

    /// A day that is still ahead of `today` (has not happened yet) must never
    /// be negatively cached, for the same reason `today` itself is exempt: it
    /// can still gain samples once it arrives. `TrackView` fetches through
    /// the end of the current period, which routinely includes days after
    /// `today` — e.g. the rest of the current week. This test fails against
    /// the pre-fix code, which negatively caches any nil day regardless of
    /// whether it is in the future.
    func testFutureDayThatLaterGainsDataIsNotPermanentlyBlanked() {
        let cache = TrackCache(fileURL: url)
        let future = [day(-1), day(-2), day(-3)] // tomorrow, +2, +3 — all ahead of "today".
        _ = cache.refresh(days: future, today: day(0)) { _ in [] }

        // Time passes: those days are now closed, and the strap recorded
        // real samples during them.
        let laterToday = day(-4)
        _ = cache.refresh(days: future, today: laterToday) { samples($0) }

        XCTAssertEqual(cache.rollups(in: day(-1)...day(-3)).count, 3)
    }

    /// Negative caching must be invisible to `fingerprint`, or the release
    /// that introduces it would invalidate every stored macro read and re-bill
    /// an LLM call for every period the user has ever opened.
    func testNegativeCachingDoesNotChangeTheFingerprint() {
        let withNoData = TrackCache(fileURL: url)
        _ = withNoData.refresh(days: [day(2), day(1)], today: day(0)) { d in
            d == self.day(1) ? self.samples(d) : []
        }

        let otherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: otherURL) }
        let realOnly = TrackCache(fileURL: otherURL)
        _ = realOnly.refresh(days: [day(1)], today: day(0)) { samples($0) }

        XCTAssertEqual(withNoData.fingerprint(for: [day(2), day(1)]),
                       realOnly.fingerprint(for: [day(2), day(1)]))
    }

    /// A cache file written by a build that predates `noDataDays` must still
    /// load. Swift's synthesized decoder throws on a missing key regardless of
    /// the property's default, and `load()` reads a throw as corruption — so
    /// without lenient decoding the upgrade would silently wipe every cached
    /// rollup and force a full 90-day recompute on first open.
    func testFileWrittenBeforeNoDataDaysStillLoads() throws {
        let seed = TrackCache(fileURL: url)
        _ = seed.refresh(days: [day(1)], today: day(0)) { samples($0, dc: 8) }
        seed.setMacroRead("Steady week.", key: "week|1|abc")

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(json["noDataDays"], "fixture must start with the new key present")
        json.removeValue(forKey: "noDataDays")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reopened = TrackCache(fileURL: url)
        reopened.load()
        XCTAssertEqual(reopened.rollups(in: day(1)...day(1)).count, 1)
        XCTAssertEqual(reopened.macroRead(key: "week|1|abc"), "Steady week.")
    }

    // MARK: rollup compute versioning

    /// A cache file whose `computeVersion` is stale (or missing entirely —
    /// every file written before this lever existed) must discard its
    /// rollups on load, so a stricter `MetricsQualityFilter` — or any future
    /// change to the rollup computation — actually takes effect for existing
    /// users instead of being masked forever by an immutable per-day cache.
    func testStaleComputeVersionDiscardsRollupsOnLoad() throws {
        let seed = TrackCache(fileURL: url)
        _ = seed.refresh(days: [day(1)], today: day(0)) { samples($0) }
        XCTAssertEqual(seed.rollups(in: day(1)...day(1)).count, 1)

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(json["computeVersion"], "fixture must start with the key present")
        json["computeVersion"] = (json["computeVersion"] as! Int) - 1

        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reopened = TrackCache(fileURL: url)
        reopened.load()
        XCTAssertTrue(reopened.rollups(in: day(1)...day(1)).isEmpty)

        // And the day is treated as genuinely uncached, not negatively
        // cached — it can be refetched and recomputed under the new rule.
        var fetched: [Date] = []
        _ = reopened.refresh(days: [day(1)], today: day(0)) { d in
            fetched.append(d)
            return samples(d)
        }
        XCTAssertEqual(fetched, [day(1)])
        XCTAssertEqual(reopened.rollups(in: day(1)...day(1)).count, 1)
    }

    /// A cache file missing the `computeVersion` key altogether — any file
    /// written before this lever shipped — must be treated exactly like a
    /// stale version, not like a decode failure that wipes everything
    /// (including `macroReads`, which this lever leaves untouched).
    func testMissingComputeVersionKeyIsTreatedAsStale() throws {
        let seed = TrackCache(fileURL: url)
        _ = seed.refresh(days: [day(1)], today: day(0)) { samples($0) }
        seed.setMacroRead("Steady week.", key: "week|1|abc")

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "computeVersion")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reopened = TrackCache(fileURL: url)
        reopened.load()
        XCTAssertTrue(reopened.rollups(in: day(1)...day(1)).isEmpty)
        // macroReads is not touched by the version check itself; it survives
        // decoding and is left to self-invalidate via `fingerprint(for:)`.
        XCTAssertEqual(reopened.macroRead(key: "week|1|abc"), "Steady week.")
    }

    /// A cache written by the current build carries the current
    /// `computeVersion` and must keep its rollups across a reload — the
    /// common case, where nothing about the computation has changed.
    func testCurrentComputeVersionKeepsRollupsOnLoad() {
        let a = TrackCache(fileURL: url)
        _ = a.refresh(days: [day(1)], today: day(0)) { samples($0) }

        let b = TrackCache(fileURL: url)
        b.load()
        XCTAssertEqual(b.rollups(in: day(1)...day(1)).count, 1)
    }

    func testUncachedDaysExcludesTodayAndKnownDays() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(3)], today: day(0)) { samples($0) }   // has data
        _ = cache.refresh(days: [day(2)], today: day(0)) { _ in [] }       // no data

        // day(1) has never been computed; day(0) is today and always recomputed.
        XCTAssertEqual(cache.uncachedDays([day(3), day(2), day(1), day(0)], today: day(0)),
                       [day(1)])
    }

    func testRollupsAreReturnedAscending() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0), day(2), day(1)], today: day(0)) { samples($0) }
        let days = cache.rollups(in: day(2)...day(0)).map(\.day)
        XCTAssertEqual(days, [day(2), day(1), day(0)])
    }

    func testPersistsAcrossInstances() {
        let a = TrackCache(fileURL: url)
        _ = a.refresh(days: [day(1)], today: day(0)) { samples($0) }

        let b = TrackCache(fileURL: url)
        b.load()
        XCTAssertEqual(b.rollups(in: day(1)...day(1)).count, 1)
    }

    func testCorruptFileRebuildsSilently() {
        try! Data("not json".utf8).write(to: url)
        let cache = TrackCache(fileURL: url)
        cache.load()
        XCTAssertTrue(cache.rollups(in: day(30)...day(0)).isEmpty)

        // And it can still be written to afterwards.
        _ = cache.refresh(days: [day(1)], today: day(0)) { samples($0) }
        XCTAssertEqual(cache.rollups(in: day(1)...day(1)).count, 1)
    }

    func testFingerprintIsStableForUnchangedValues() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(1)], today: day(0)) { samples($0) }
        XCTAssertEqual(cache.fingerprint(for: [day(1)]), cache.fingerprint(for: [day(1)]))
    }

    func testFingerprintChangesWhenValuesChange() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 6) }
        let before = cache.fingerprint(for: [day(0)])
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 10) }
        XCTAssertNotEqual(before, cache.fingerprint(for: [day(0)]))
    }

    /// Today's rollup is rewritten on every Track appear (`refresh` always
    /// recomputes `today`). If those repeat writes produce identical values,
    /// the fingerprint must not change — otherwise the macro-read cache
    /// misses on every screen open, re-billing an LLM call each time.
    func testFingerprintStableAcrossIdenticalTodayRefreshes() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0) }
        let before = cache.fingerprint(for: [day(0)])
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0) }
        XCTAssertEqual(before, cache.fingerprint(for: [day(0)]))
    }

    /// Pins `fingerprint` to a specific value derived from a fixed fixture,
    /// independent of `Date()` or any process state. A seeded-per-launch hash
    /// (Swift's `Hasher`) would fail this test nondeterministically across
    /// runs; a canonical, process-stable hash always returns this exact
    /// string for this exact data.
    func testFingerprintIsProcessStableForKnownFixture() {
        let fixedDay = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [fixedDay], today: fixedDay.addingTimeInterval(-86_400)) {
            samples($0)
        }
        XCTAssertEqual(cache.fingerprint(for: [fixedDay]), "3p2r5yc14g975")

        // Sanity check: the pinned value is genuinely derived from the data —
        // changing one input changes the fingerprint.
        let otherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: otherURL) }
        let other = TrackCache(fileURL: otherURL)
        _ = other.refresh(days: [fixedDay], today: fixedDay.addingTimeInterval(-86_400)) {
            samples($0, dc: 99)
        }
        XCTAssertNotEqual(other.fingerprint(for: [fixedDay]),
                          cache.fingerprint(for: [fixedDay]))
    }

    func testMacroReadsRoundTrip() {
        let a = TrackCache(fileURL: url)
        a.setMacroRead("Steady week.", key: "week|123|abc")

        let b = TrackCache(fileURL: url)
        b.load()
        XCTAssertEqual(b.macroRead(key: "week|123|abc"), "Steady week.")
        XCTAssertNil(b.macroRead(key: "week|123|different"))
    }

    // MARK: macro-read pruning (housekeeping B1)

    /// Writing past the cap prunes the store back down, but the entry that
    /// was *just* written — the page currently being viewed — must survive
    /// its own write: it always holds the newest recency counter, so pruning
    /// (which evicts the oldest) can never pick it.
    func testMacroReadPruningKeepsTheCapAndTheJustWrittenEntry() throws {
        let cache = TrackCache(fileURL: url)
        let total = TrackCache.macroReadCap + 10
        for i in 0..<total {
            cache.setMacroRead("read \(i)", key: "key\(i)")
        }

        XCTAssertEqual(cache.macroRead(key: "key\(total - 1)"), "read \(total - 1)")
        XCTAssertNil(cache.macroRead(key: "key0"))

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let macroReads = try XCTUnwrap(json["macroReads"] as? [String: Any])
        XCTAssertEqual(macroReads.count, TrackCache.macroReadCap)
    }

    /// Eviction is by **write** recency, not read recency: a read is a pure
    /// lookup and does not protect an entry from the next prune, no matter
    /// how recently it happened. This is the honest replacement for a prior
    /// read-bump that looked like it protected "keepMe" here but, in the
    /// real app, never survived the `load()` that `TrackView` runs on every
    /// page change — so the bump was always discarded before it could do
    /// anything, and "keepMe" was pruned exactly as if never read.
    func testReadingAnEntryDoesNotProtectItFromTheNextPrune() {
        let cache = TrackCache(fileURL: url)
        let cap = TrackCache.macroReadCap

        // "keepMe" is written first, so it holds the very lowest recency of
        // anything in the store.
        cache.setMacroRead("kept", key: "keepMe")
        for i in 0..<(cap - 1) {
            cache.setMacroRead("filler \(i)", key: "filler\(i)")
        }
        // Store is now exactly at the cap — nothing pruned yet.

        // A read does not change write order.
        XCTAssertEqual(cache.macroRead(key: "keepMe"), "kept")

        // One more write tips the store over the cap by one, forcing exactly
        // one eviction: "keepMe", the least-recently-*written* entry, despite
        // the read above.
        cache.setMacroRead("tips it over", key: "fillerLast")

        XCTAssertNil(cache.macroRead(key: "keepMe"))
        // "filler0" was written after "keepMe", so it survives.
        XCTAssertEqual(cache.macroRead(key: "filler0"), "filler 0")
    }

    /// Exercises the cache the way `TrackView` actually does: `load()` is
    /// called between operations (it runs at the top of every
    /// `loadRollups()`, i.e. on every page change), replacing in-memory
    /// state wholesale from disk. This is the scenario the original
    /// read-recency bug lived in — an in-memory-only bump on read looked
    /// like it protected an entry, but the very next `load()` discarded it
    /// before anything could persist it, so the entry was pruned regardless.
    /// Write-recency has no such gap: `seq` is carried on every `save()`, so
    /// pruning order is identical whether or not a `load()` happens in
    /// between.
    func testPruningOrderIsUnaffectedByLoadBetweenOperations() {
        let cache = TrackCache(fileURL: url)
        let cap = TrackCache.macroReadCap

        cache.setMacroRead("kept", key: "keepMe")
        for i in 0..<(cap - 1) {
            cache.setMacroRead("filler \(i)", key: "filler\(i)")
        }
        // Simulate paging back to "keepMe"'s page: TrackView reloads from
        // disk first, then reads.
        cache.load()
        XCTAssertEqual(cache.macroRead(key: "keepMe"), "kept")

        // Another page change: reload again, then write past the cap.
        cache.load()
        cache.setMacroRead("tips it over", key: "fillerLast")

        // Reload once more, as the next page visit would, and confirm the
        // eviction that happened before this load() actually persisted:
        // "keepMe" is gone despite having been read, "filler0" (written
        // after it) survives.
        cache.load()
        XCTAssertNil(cache.macroRead(key: "keepMe"))
        XCTAssertEqual(cache.macroRead(key: "filler0"), "filler 0")
    }

    /// A cache file written by a build that predates the recency counter has
    /// `macroReads` as a flat `[String: String]` rather than `{text, seq}`
    /// objects. It must still load — the same lenient-decode contract
    /// `testFileWrittenBeforeNoDataDaysStillLoads` proves for `noDataDays` —
    /// rather than being treated as corrupt and wiping the whole cache.
    func testMacroReadsInTheOldFlatStringFormatStillLoad() throws {
        let legacy: [String: Any] = [
            "rollups": [],
            "macroReads": ["week|123|abc": "Steady week."],
            "noDataDays": [],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        let cache = TrackCache(fileURL: url)
        cache.load()
        XCTAssertEqual(cache.macroRead(key: "week|123|abc"), "Steady week.")
    }

    // MARK: launch warm-up (bootstrap defect — AppEnvironment.warmLiveBaseline)

    /// Pins the actual defect: `LiveStateStore.recomputeState` calls
    /// `LiveBaseline.build` on whatever `TrackCache` holds, and until now the
    /// *only* thing that ever put rollups into an empty cache was
    /// `TrackCache.refresh`, called solely from `TrackView`. A user who never
    /// opens Track — or whose cache was just wiped by a `rollupComputeVersion`
    /// bump — got `LiveBaseline.build(rollups: []) == nil` forever, with the
    /// Live tab silently falling back to its old rendering.
    ///
    /// `computeRollups` + `mergeComputed` are the launch-time replacement:
    /// this proves that, starting from a cache with nothing on disk, running
    /// them is enough on its own to make `LiveBaseline.build` succeed —
    /// without going anywhere near `refresh` or `TrackView`. Fails to compile
    /// against the pre-fix code, which has neither method.
    func testWarmUpProducesABaselineFromAnEmptyCache() {
        let cache = TrackCache(fileURL: url)
        cache.load()   // fresh install / post-upgrade: nothing on disk yet

        let days = (1...14).map { day($0) }
        let (rollups, emptyDays) = TrackCache.computeRollups(days: days) { d in self.samples(d) }
        XCTAssertEqual(rollups.count, 14, "every warmed day clears the quality gate in this fixture")
        XCTAssertTrue(emptyDays.isEmpty)

        cache.mergeComputed(rollups: rollups, emptyDays: emptyDays)

        XCTAssertNotNil(LiveBaseline.build(rollups: cache.rollups(in: day(14)...day(0))),
                        "an empty cache must be able to produce a baseline after the warm-up runs")
    }

    /// A day that computes to no data must still be remembered by the
    /// warm-up path, the same way `refresh` remembers it — otherwise every
    /// relaunch re-fetches days the strap was never worn on, forever.
    func testWarmUpRecordsEmptyDaysSoTheyAreNotRefetched() {
        let cache = TrackCache(fileURL: url)
        cache.load()

        let (rollups, emptyDays) = TrackCache.computeRollups(days: [day(3), day(2)]) { _ in [] }
        XCTAssertTrue(rollups.isEmpty)
        cache.mergeComputed(rollups: rollups, emptyDays: emptyDays)

        XCTAssertTrue(cache.uncachedDays([day(3), day(2)], today: day(0)).isEmpty)
    }

    /// `AppEnvironment.trackCache` and `TrackView`'s own `TrackCache` instance
    /// are two independent writers over the same file. `mergeComputed`
    /// reloads from disk immediately before merging + saving specifically so
    /// this can't happen: a stale in-memory snapshot merging and saving would
    /// otherwise clobber whatever the other instance wrote in between.
    func testMergeComputedDoesNotClobberADifferentInstancesConcurrentWrite() {
        let warm = TrackCache(fileURL: url)
        warm.load()   // both instances start from the same empty file

        // Stands in for TrackView opening in between the warm-up's fetch
        // finishing and its merge landing.
        let track = TrackCache(fileURL: url)
        _ = track.refresh(days: [day(5)], today: day(0)) { samples($0) }

        let (rollups, emptyDays) = TrackCache.computeRollups(days: [day(1)]) { samples($0) }
        warm.mergeComputed(rollups: rollups, emptyDays: emptyDays)

        let reopened = TrackCache(fileURL: url)
        reopened.load()
        XCTAssertEqual(reopened.rollups(in: day(5)...day(5)).count, 1, "Track's write must survive")
        XCTAssertEqual(reopened.rollups(in: day(1)...day(1)).count, 1, "the warm-up's own write must land too")
    }
}
