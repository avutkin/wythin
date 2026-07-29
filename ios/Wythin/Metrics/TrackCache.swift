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

    private struct File: Codable {
        var version: Int = 1
        var rollups: [DailyRollup] = []
        var macroReads: [String: String] = [:]
    }

    private let fileURL: URL
    private var rollupsByDay: [Date: DailyRollup] = [:]
    private var macroReads: [String: String] = [:]

    init(fileURL: URL = TrackCache.defaultURL) {
        self.fileURL = fileURL
    }

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
            macroReads   = [:]
            return
        }
        rollupsByDay = Dictionary(uniqueKeysWithValues: file.rollups.map { ($0.day, $0) })
        macroReads   = file.macroReads
    }

    private func save() {
        let file = File(rollups: rollupsByDay.values.sorted { $0.day < $1.day },
                        macroReads: macroReads)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Rollups

    func rollups(in range: ClosedRange<Date>) -> [DailyRollup] {
        rollupsByDay.values
            .filter { range.contains($0.day) }
            .sorted { $0.day < $1.day }
    }

    /// Compute any of `days` that are not cached, and always recompute
    /// `today` — a day in progress gains samples as it goes. Returns whether
    /// any stored value changed, so callers can skip redundant work.
    @discardableResult
    func refresh(days: [Date], today: Date,
                 fetchDay: (Date) throws -> [MetricsHistoryPoint]) -> Bool {
        var changed = false
        for day in days {
            if day != today, rollupsByDay[day] != nil { continue }
            guard let points = try? fetchDay(day) else { continue }
            let rollup = DailyRollupCompute.rollup(day: day, points: points)
            if rollupsByDay[day] != rollup {
                rollupsByDay[day] = rollup   // nil clears a day that lost its data
                changed = true
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
    func fingerprint(for days: [Date]) -> String {
        var hasher = Hasher()
        for day in days.sorted() {
            guard let r = rollupsByDay[day] else { continue }
            hasher.combine(day)
            for v in [r.dc, r.rmssd, r.rsaMs, r.rcmse, r.pip, r.dfa1, r.stressBalance] {
                hasher.combine(v.map { ($0 * 1000).rounded() })
            }
        }
        return String(hasher.finalize(), radix: 36)
    }

    // MARK: Macro reads

    func macroRead(key: String) -> String? { macroReads[key] }

    func setMacroRead(_ text: String, key: String) {
        macroReads[key] = text
        save()
    }
}
