import Foundation

/// On-disk cache backing the Track screen: one `DailyRollup` per local day,
/// plus the LLM macro reads keyed to the ranges they describe.
///
/// Deliberately **not** a SwiftData `@Model`. The cache is derived and always
/// rebuildable, it is small enough (~180 days × a dozen doubles) to hold in
/// memory whole so queries buy nothing, and adding a model to the schema risks
/// tripping the `catch` at `WythinApp.swift:21`, which deletes the entire
/// store on migration failure. A convenience cache must not share a fault line
/// with the user's history.
@MainActor
final class TrackCache {

    /// One cached macro read plus the recency it was last touched at.
    ///
    /// `seq` is a monotonically increasing counter, not a timestamp: the
    /// codebase has had trouble with non-deterministic wall-clock values in
    /// tests, and a counter orders "which entry is oldest" exactly as well as
    /// a timestamp would for pruning purposes.
    private struct MacroReadEntry: Codable {
        let text: String
        let seq:  Int
    }

    private struct File: Codable {
        var rollups: [DailyRollup]
        var macroReads: [String: MacroReadEntry]
        /// Days that were computed and produced no rollup — the strap was off,
        /// or the day fell under `DailyRollupCompute.minTicks`. Persisted
        /// alongside the rollups so the knowledge survives relaunch: without
        /// it a user who wore the strap 30 of the last 90 days re-fetched the
        /// other 60 on every period switch and every swipe, forever.
        var noDataDays: [Date]

        init(rollups: [DailyRollup] = [],
             macroReads: [String: MacroReadEntry] = [:], noDataDays: [Date] = []) {
            self.rollups    = rollups
            self.macroReads = macroReads
            self.noDataDays = noDataDays
        }

        /// Decoded field by field with `decodeIfPresent` so a file written by
        /// an older build — which has no `noDataDays` key, or whose
        /// `macroReads` is still a flat `[String: String]` predating the
        /// recency counter — still loads. Swift's synthesized decoder throws
        /// on a missing key or a shape mismatch regardless of the property's
        /// default, and `load()` treats a throw as corruption and empties the
        /// whole cache — which would force exactly the full 90-day recompute
        /// `noDataDays` exists to prevent, just to migrate a field that has
        /// nothing to do with rollups.
        ///
        /// `version` was deleted rather than made real: every field here
        /// already migrates itself independently on its own missing-key or
        /// wrong-shape case, which is strictly more forgiving than a single
        /// version number that would wipe the *entire* cache — rollups
        /// included — on any field it didn't recognize.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rollups = try c.decodeIfPresent([DailyRollup].self, forKey: .rollups) ?? []
            // `decode` (not `decodeIfPresent`) under `try?`: a missing key and
            // a shape mismatch both simply fail this attempt and fall through
            // to the next one, rather than needing separate handling.
            if let entries = try? c.decode([String: MacroReadEntry].self, forKey: .macroReads) {
                macroReads = entries
            } else if let legacy = try? c.decode([String: String].self, forKey: .macroReads) {
                // Pre-recency-counter shape: a flat [String: String]. Every
                // migrated entry gets seq 0 — they are all equally "oldest",
                // which is exactly right the first time pruning ever runs.
                macroReads = legacy.mapValues { MacroReadEntry(text: $0, seq: 0) }
            } else {
                macroReads = [:]
            }
            noDataDays = try c.decodeIfPresent([Date].self, forKey: .noDataDays) ?? []
        }
    }

    private let fileURL: URL
    private var rollupsByDay: [Date: DailyRollup] = [:]
    private var noDataDays: Set<Date> = []
    private var macroReads: [String: MacroReadEntry] = [:]
    /// Next recency value to hand out. Seeded past whatever was loaded from
    /// disk so a fresh write is always the most recent, even across relaunch.
    private var nextSeq = 1

    /// Cap on stored macro reads. Every page — period × range × reference
    /// state × day — mints its own key, and the *current* page's key changes
    /// daily as today's rollup shifts its fingerprint, so yesterday's key for
    /// that same page is orphaned every single day with nothing else to prune
    /// it. 60 comfortably covers a user paging back many weeks/months across
    /// all three periods while keeping the file small.
    static let macroReadCap = 60

    init(fileURL: URL = TrackCache.defaultURL) {
        self.fileURL = fileURL
    }

    /// Revision of everything that shapes a macro read's *text* rather than
    /// its data: the payload the app sends, the server's `_format_macro_trend`
    /// wording, and `_MACRO_TREND_SYSTEM_PROMPT`.
    ///
    /// **Bump this whenever any of those change.** Macro reads are persisted
    /// indefinitely and keyed on the rollup values behind them, so a period
    /// whose data never changes again — every past week, forever — would
    /// otherwise keep serving text generated by the old prompt long after the
    /// new one shipped, with no way for the user to reach it.
    ///
    /// 1 — original release.
    /// 2 — macro-trend metric names overlaid with the app's own card names
    ///     (`_MACRO_TREND_METRIC_NAMES`), so the read stops calling Energy
    ///     Reserve "vagal tone" while the Vagal Tone card sits below it.
    static let macroReadRevision = 2

    nonisolated static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("track-cache.json")
    }

    // MARK: Persistence

    /// A corrupt or unreadable file is treated as an empty cache — it is
    /// derived data, so rebuilding costs time but never correctness.
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            rollupsByDay = [:]
            noDataDays   = []
            macroReads   = [:]
            nextSeq      = 1
            return
        }
        rollupsByDay = Dictionary(uniqueKeysWithValues: file.rollups.map { ($0.day, $0) })
        noDataDays   = Set(file.noDataDays)
        macroReads   = file.macroReads
        nextSeq      = (macroReads.values.map(\.seq).max() ?? 0) + 1
    }

    private func save() {
        let file = File(rollups: rollupsByDay.values.sorted { $0.day < $1.day },
                        macroReads: macroReads,
                        noDataDays: noDataDays.sorted())
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Rollups

    func rollups(in range: ClosedRange<Date>) -> [DailyRollup] {
        rollupsByDay.values
            .filter { range.contains($0.day) }
            .sorted { $0.day < $1.day }
    }

    /// Days in `days` that `refresh` would actually have to fetch: not cached
    /// as a rollup, and not already known to have no data.
    ///
    /// `today` is excluded even though `refresh` always recomputes it — it is
    /// one day's fetch, not a stall, and callers use this to decide whether
    /// the work ahead is worth putting a spinner up for.
    func uncachedDays(_ days: [Date], today: Date) -> [Date] {
        days.filter { $0 != today && rollupsByDay[$0] == nil && !noDataDays.contains($0) }
    }

    /// Compute any of `days` that are not cached, and always recompute
    /// `today` — a day in progress gains samples as it goes. Returns whether
    /// any stored value changed, so callers can skip redundant work.
    ///
    /// "Not cached" means neither a stored rollup nor a **negative** entry. A
    /// day that computes to nil — strap off, or under the 150-tick quality
    /// gate — is recorded in `noDataDays`, so it is fetched at most once
    /// instead of on every period switch and every swipe for the rest of the
    /// user's life. `today` is exempt from both, since a day in progress can
    /// still cross the gate later in the afternoon — and so, for the same
    /// reason, is any day still ahead of `today`: only a day that is already
    /// closed (`day < today`) is ever added to `noDataDays`.
    @discardableResult
    func refresh(days: [Date], today: Date,
                 fetchDay: (Date) throws -> [MetricsHistoryPoint]) -> Bool {
        var changed = false
        for day in days {
            if day != today, rollupsByDay[day] != nil || noDataDays.contains(day) { continue }
            guard let points = try? fetchDay(day) else { continue }
            if let rollup = DailyRollupCompute.rollup(day: day, points: points) {
                if rollupsByDay[day] != rollup {
                    rollupsByDay[day] = rollup
                    changed = true
                }
                // Today can gain data after having had none.
                if noDataDays.remove(day) != nil { changed = true }
            } else {
                // Clears a day that lost its data, and remembers the verdict —
                // but only once the day is closed. `today` and any day still
                // ahead of it can still gain samples later (the strap goes on
                // this afternoon, or the day simply hasn't happened yet), so
                // negatively caching them would blank them forever once they
                // roll into the past: `refresh` only re-fetches `today`, and a
                // day that was never `today` while cached never gets another
                // chance.
                if rollupsByDay.removeValue(forKey: day) != nil { changed = true }
                if day < today, noDataDays.insert(day).inserted { changed = true }
            }
        }
        if changed { save() }
        return changed
    }

    /// A hash of the *values* covering `days`, used to key cached macro reads.
    ///
    /// It must be a value hash rather than a write counter: today's rollup is
    /// rewritten on every Track appear, and a counter would invalidate the
    /// cache each time — re-billing an LLM call per screen open.
    ///
    /// It must also be **process-stable**: Swift's `Hasher` is seeded per
    /// process launch (Apple's docs say its output is "not guaranteed to be
    /// equal across different executions of your program"), but `macroReads`
    /// is persisted to disk and read back on a later launch. A `Hasher`-based
    /// fingerprint would key identical, unchanged data differently after
    /// every relaunch, missing the persisted cache every time — the exact
    /// failure this design point exists to prevent, just triggered by a
    /// restart instead of a write counter. FNV-1a over a canonical string has
    /// no such seed, so the result depends only on the data.
    func fingerprint(for days: [Date]) -> String {
        var parts: [String] = []
        for day in days.sorted() {
            // Days with no rollup contribute nothing, whether they were never
            // computed or are negatively cached in `noDataDays`. Negative
            // caching therefore cannot shift a fingerprint — the same real
            // values always hash the same, so it does not silently invalidate
            // every stored macro read on the release that introduces it.
            guard let r = rollupsByDay[day] else { continue }
            parts.append(String(day.timeIntervalSince1970))
            for v in [r.dc, r.rmssd, r.rsaMs, r.rcmse, r.pip, r.dfa1, r.stressBalance] {
                // `nil` gets its own token so a missing value can never
                // collide with a real quantized value or an empty field.
                if let v {
                    parts.append(String((v * 1000).rounded()))
                } else {
                    parts.append("nil")
                }
            }
        }
        return Self.fnv1a(parts.joined(separator: "|"))
    }

    /// FNV-1a (64-bit) over UTF-8 bytes. Deterministic across processes,
    /// platforms, and Swift versions — unlike `Hasher`, which is randomly
    /// seeded per launch. See `fingerprint(for:)`.
    private static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    // MARK: Macro reads

    /// Also refreshes the entry's recency, in memory, so a page the user
    /// keeps returning to is not pruned out from under them just because
    /// other pages have been written more often since. Not itself persisted
    /// — the next `setMacroRead` anywhere will carry it to disk — so this
    /// stays a cheap dictionary update rather than a write on every read.
    func macroRead(key: String) -> String? {
        guard let entry = macroReads[key] else { return nil }
        macroReads[key] = MacroReadEntry(text: entry.text, seq: nextSeq)
        nextSeq += 1
        return entry.text
    }

    func setMacroRead(_ text: String, key: String) {
        macroReads[key] = MacroReadEntry(text: text, seq: nextSeq)
        nextSeq += 1
        pruneMacroReads()
        save()
    }

    /// Evicts the least-recently-touched entries once the store exceeds
    /// `macroReadCap`. The entry just written above always holds the highest
    /// `seq` of anything in the dictionary, so it can never be among the ones
    /// removed here — pruning cannot evict the page currently being viewed.
    private func pruneMacroReads() {
        let over = macroReads.count - Self.macroReadCap
        guard over > 0 else { return }
        let oldest = macroReads.sorted { $0.value.seq < $1.value.seq }.prefix(over)
        for (key, _) in oldest { macroReads.removeValue(forKey: key) }
    }
}
