# Track Macro Trends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Track tab with a period-based macro-trend view — W / M / 6M bar charts of seven key metrics against a personal baseline, an LLM macro read, and a consistency card.

**Architecture:** A JSON-file cache of one `DailyRollup` per local day sits between SwiftData and the UI, so no view ever fetches raw 2-second samples. Three pure, unit-tested types (`TrackRangeBuilder`, `TrackSeriesBuilder`, `ConsistencyBuilder`) turn rollups into everything the charts render; the SwiftUI layer is thin. The macro read is a fourth `mode` on the existing `POST /v1/insights` endpoint.

**Tech Stack:** Swift 6 / SwiftUI / Swift Charts / SwiftData (iOS), XCTest, FastAPI + Pydantic + pytest (server).

**Spec:** `docs/superpowers/specs/2026-07-28-track-macro-trends-design.md`

## Global Constraints

- **New Swift files must be registered in `ios/Wythin.xcodeproj/project.pbxproj` by hand.** The project is not filesystem-synchronized (no `PBXFileSystemSynchronizedRootGroup`). Every new file needs four entries. Task 1 walks through it once in full; later tasks reference that procedure.
- **ID allocation.** App-target IDs use `A<n>`/`F<n>`; the highest currently used is `A231`/`F231`. Test-target IDs use `AT<n>`/`FT<n>`; the highest is `AT22`/`FT22`. This plan allocates `A240`–`A252` / `F240`–`F252` and `AT30`–`AT34` / `FT30`–`FT34`.
- **iOS build:** `cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40`
- **iOS tests:** `cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/<TestClass> 2>&1 | tail -30`
- **Server tests:** `cd /Users/alexutkin && .venv313/bin/pytest server/tests/test_insights.py -v` — use `.venv313`, never `.venv` (which is Python 3.9).
- **Metric vocabulary is single-sourced.** Labels, tech labels, units, `BenefitDirection`, formatters, and `why` copy come from `activityMetricDefs` (`ios/Wythin/UI/Activities/ActivityMetricsGrid.swift:49`). Never retype them.
- **Theme only.** Colours and fonts come from `Theme` (`ios/Wythin/UI/Design/Theme.swift`). No literal hex or `.system(size:)` outside it.
- **Never send raw samples off-device.** The macro-read payload carries aggregate daily means only.

---

## File Structure

**New — `ios/Wythin/Metrics/`** (pure logic, fully unit-tested)

| File | Responsibility |
|---|---|
| `DailyRollup.swift` | `DailyRollup` value type + `DailyRollupCompute`: one day of samples → one rollup |
| `TrackCache.swift` | The Track disk cache: rollups + cached macro reads in one JSON file, incremental refresh |
| `TrackPeriod.swift` | `TrackPeriod`, `TrackBucket`, `TrackRange`, `TrackRangeBuilder`: period paging and range maths |
| `TrackMetricSpec.swift` | The 7 metric specs, wrapping `ActivityMetricDef` |
| `TrackSeriesBuilder.swift` | rollups + range → `TrackSeries` (bars, average, delta, baseline, overlay, summary) |
| `ConsistencySummary.swift` | activities + rollups + range → practice/wear buckets and totals |

**New — `ios/Wythin/UI/Track/`** (thin views)

| File | Responsibility |
|---|---|
| `TrackPeriodBar.swift` | W·M·6M toggle + `‹ range ›` navigator |
| `TrackMetricChartCard.swift` | One metric's bar chart card |
| `ConsistencyCard.swift` | Practice + wear card |
| `MacroReadCard.swift` | LLM macro read card |
| `TrackView.swift` | Screen shell: state, data loading, composition |

**Modified:** `WythinApp.swift`, `PracticeHubView.swift`, `APIClient.swift`, `HRVRingView.swift`, `server/models.py`, `server/routers/insights.py`, `project.pbxproj`.

**Deleted:** `ios/Wythin/UI/History/HistoryView.swift` (and with it `TrackTab`, `TrackWindow`, `TrackMetric`, `DailySummary`, `TrackDailyChartCard`, `SessionRow`; `TrainSessionRow` moves to Train).

---

### Task 1: DailyRollup — one day of samples → one rollup

**Files:**
- Create: `ios/Wythin/Metrics/DailyRollup.swift`
- Test: `ios/WythinTests/DailyRollupTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `MetricsHistoryPoint`, `MetricsQualityFilter` (`ios/Wythin/Models/MetricsHistoryPoint.swift`); `AutonomicCompute.balance(rmssd:lf:hf:breathBPM:meanBPM:baselineRmssd:) -> AutonomicIndices?` (`ios/Wythin/Metrics/AutonomicCompute.swift:54`).
- Produces:
  - `struct DailyRollup: Codable, Equatable, Identifiable` with `let day: Date`, optional `Double` fields `dc, rmssd, rsaMs, rcmse, pip, dfa1, stressBalance, vti, meanBPM`, `let sampleCount: Int`, `let wearSeconds: Double`, and `var id: Date { day }`.
  - `enum DailyRollupCompute` with `static let minTicks = 150`, `static let tickSeconds: Double = 2`, `static func rollup(day: Date, points: [MetricsHistoryPoint]) -> DailyRollup?`, and `static func stressBalance(_ pt: MetricsHistoryPoint) -> Double?`.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/DailyRollupTests.swift`:

```swift
import XCTest
@testable import Wythin

final class DailyRollupTests: XCTestCase {

    private let cal = Calendar.current
    private lazy var day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))

    /// A sample that passes MetricsQualityFilter (sdnn > 5, rmssd > 3, 35 <= bpm <= 210).
    private func good(_ i: Int,
                      dc: Float? = 8,
                      rmssd: Float? = 40,
                      pip: Float? = 55) -> MetricsHistoryPoint {
        MetricsHistoryPoint(
            timestamp: day.addingTimeInterval(Double(i) * 2),
            meanBPM: 60, rmssd: rmssd, rsaMs: 30, sdnn: 50,
            lfHF: 1.2, coherence: 0.5, breathBPM: 12, cbi: 0.5,
            dfa1: 1.0, rcmse: 1.4, pip: pip, dc: dc, motion: 5)
    }

    /// Fails the quality filter: sdnn below 5.
    private func bad(_ i: Int) -> MetricsHistoryPoint {
        MetricsHistoryPoint(
            timestamp: day.addingTimeInterval(Double(i) * 2),
            meanBPM: 60, rmssd: 40, rsaMs: 30, sdnn: 1,
            dfa1: 1.0, rcmse: 1.4, pip: 55, dc: 8)
    }

    func testBelowMinimumTicksProducesNoRollup() {
        let pts = (0..<149).map { good($0) }
        XCTAssertNil(DailyRollupCompute.rollup(day: day, points: pts))
    }

    func testExactlyMinimumTicksProducesARollup() {
        let pts = (0..<150).map { good($0) }
        XCTAssertNotNil(DailyRollupCompute.rollup(day: day, points: pts))
    }

    func testLowQualitySamplesDoNotCountTowardTheGate() {
        // 100 good + 100 bad = 200 total but only 100 valid, below the 150 gate.
        let pts = (0..<100).map { good($0) } + (100..<200).map { bad($0) }
        XCTAssertNil(DailyRollupCompute.rollup(day: day, points: pts))
    }

    func testFieldsAreMeansOfValidSamples() {
        // Half the days at dc 6, half at dc 10 → mean 8.
        let pts = (0..<200).map { good($0, dc: $0 < 100 ? 6 : 10) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        XCTAssertEqual(r.dc!, 8.0, accuracy: 0.001)
        XCTAssertEqual(r.rmssd!, 40.0, accuracy: 0.001)
        XCTAssertEqual(r.sampleCount, 200)
    }

    func testNilFieldsAreIgnoredNotTreatedAsZero() {
        // dc present on 100 of 200 samples; the mean must be over the present ones.
        let pts = (0..<200).map { good($0, dc: $0 < 100 ? 6 : nil) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        XCTAssertEqual(r.dc!, 6.0, accuracy: 0.001)
    }

    func testFieldIsNilWhenNoSampleHasIt() {
        let pts = (0..<200).map { good($0, dc: nil) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        XCTAssertNil(r.dc)
    }

    func testWearSecondsCountsValidSamplesOnly() {
        let pts = (0..<200).map { good($0) } + (200..<300).map { bad($0) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        XCTAssertEqual(r.wearSeconds, 400, accuracy: 0.001)   // 200 × 2 s
    }

    func testStressBalanceIsDerivedAndAveraged() {
        let pts = (0..<200).map { good($0) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        let single = try! XCTUnwrap(DailyRollupCompute.stressBalance(pts[0]))
        XCTAssertEqual(try! XCTUnwrap(r.stressBalance), single, accuracy: 0.001)
        XCTAssertTrue((0...100).contains(single))
    }

    func testRoundTripsThroughCodable() {
        let pts = (0..<200).map { good($0) }
        let r = try! XCTUnwrap(DailyRollupCompute.rollup(day: day, points: pts))
        let data = try! JSONEncoder().encode(r)
        XCTAssertEqual(try! JSONDecoder().decode(DailyRollup.self, from: data), r)
    }
}
```

- [ ] **Step 2: Register the test file in the Xcode project**

`ios/Wythin.xcodeproj/project.pbxproj` needs four edits per file. Open it and make these, matching the surrounding formatting exactly (tabs, not spaces):

1. In the `PBXBuildFile` section (near line 108, beside the other `AT*` entries):
```
		AT30 /* DailyRollupTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FT30 /* DailyRollupTests.swift */; };
```
2. In the `PBXFileReference` section (beside the other `FT*` entries):
```
		FT30 /* DailyRollupTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DailyRollupTests.swift; sourceTree = "<group>"; };
```
3. In the `GTESTS /* WythinTests */` group's `children` array (near line 494):
```
				FT30 /* DailyRollupTests.swift */,
```
4. In the test target's `PBXSourcesBuildPhase` `files` array (the one containing `AT16 /* StreakComputeTests.swift in Sources */`, near line 712):
```
				AT30 /* DailyRollupTests.swift in Sources */,
```

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/DailyRollupTests 2>&1 | tail -30
```
Expected: compile failure — `cannot find 'DailyRollupCompute' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/Wythin/Metrics/DailyRollup.swift`:

```swift
import Foundation

/// One local day's average of every metric the Track screen charts.
///
/// Track never reads raw `HRVSample`s: all-day recording writes a tick every
/// ~2 s (43,200 rows/day), so six months is ~7.8M rows. Rollups collapse that
/// to one small record per day, computed once and cached on disk.
struct DailyRollup: Codable, Equatable, Identifiable {
    /// Start of the local day this rollup covers.
    let day: Date

    let dc:            Double?
    let rmssd:         Double?
    let rsaMs:         Double?
    let rcmse:         Double?
    let pip:           Double?
    let dfa1:          Double?
    let stressBalance: Double?
    /// Not charted today, but free to keep and awkward to backfill later.
    let vti:           Double?
    let meanBPM:       Double?

    /// Quality-passing ticks behind these averages.
    let sampleCount: Int
    /// Wear time implied by `sampleCount`, in seconds.
    let wearSeconds: Double

    var id: Date { day }
}

enum DailyRollupCompute {

    /// A day needs five minutes of quality data (150 ticks at ~2 s) before it
    /// is charted at all. Matches the gate the old Track view applied.
    static let minTicks = 150

    /// Nominal seconds represented by one compute tick.
    static let tickSeconds: Double = 2

    /// Nil when the day has fewer than `minTicks` quality samples.
    ///
    /// Filtering happens here rather than at the call site so the gate is
    /// counted against valid ticks, never raw ones.
    static func rollup(day: Date, points: [MetricsHistoryPoint]) -> DailyRollup? {
        let valid = MetricsQualityFilter.filter(points)
        guard valid.count >= minTicks else { return nil }

        func mean(_ extract: (MetricsHistoryPoint) -> Double?) -> Double? {
            let vals = valid.compactMap(extract)
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }

        return DailyRollup(
            day:           day,
            dc:            mean { $0.dc.map(Double.init) },
            rmssd:         mean { $0.rmssd.map(Double.init) },
            rsaMs:         mean { $0.rsaMs.map(Double.init) },
            rcmse:         mean { $0.rcmse.map(Double.init) },
            pip:           mean { $0.pip.map(Double.init) },
            dfa1:          mean { $0.dfa1.map(Double.init) },
            stressBalance: mean(stressBalance),
            vti:           mean { $0.vti.map(Double.init) },
            meanBPM:       mean { $0.meanBPM.map(Double.init) },
            sampleCount:   valid.count,
            wearSeconds:   Double(valid.count) * tickSeconds
        )
    }

    /// Stress Balance is the breathing-robust 0–100 arousal dial, not a raw
    /// LF/HF ratio — there is no stored field for it, so it is derived per
    /// tick exactly as `ActivityMetricsGrid.swift:58` does, then averaged.
    static func stressBalance(_ pt: MetricsHistoryPoint) -> Double? {
        AutonomicCompute.balance(rmssd: pt.rmssd, lf: pt.lfPower, hf: pt.hfPower,
                                 breathBPM: pt.breathBPM, meanBPM: pt.meanBPM,
                                 baselineRmssd: nil)
            .map { Double($0.sns) * 100 }
    }
}
```

- [ ] **Step 5: Register the implementation file in the Xcode project**

Same four edits as Step 2, using app-target IDs and the `GAPP_MET /* Metrics */` group (near line 361) plus the **app** target's `PBXSourcesBuildPhase` (the one containing `A127 /* MetricsHistoryPoint.swift in Sources */`, near line 643):

```
		A240 /* DailyRollup.swift in Sources */ = {isa = PBXBuildFile; fileRef = F240 /* DailyRollup.swift */; };
		F240 /* DailyRollup.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DailyRollup.swift; sourceTree = "<group>"; };
				F240 /* DailyRollup.swift */,
				A240 /* DailyRollup.swift in Sources */,
```

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/DailyRollupTests 2>&1 | tail -30
```
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/DailyRollup.swift ios/WythinTests/DailyRollupTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(track): DailyRollup — one day of samples to one cached record"
```

---

### Task 2: TrackCache — JSON persistence and incremental refresh

**Files:**
- Create: `ios/Wythin/Metrics/TrackCache.swift`
- Test: `ios/WythinTests/TrackCacheTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DailyRollup`, `DailyRollupCompute` (Task 1).
- Produces:
  - `@MainActor final class TrackCache` with:
    - `init(fileURL: URL = TrackCache.defaultURL)`
    - `static var defaultURL: URL`
    - `func load()`
    - `func rollups(in range: ClosedRange<Date>) -> [DailyRollup]` — ascending by day
    - `func refresh(days: [Date], today: Date, fetchDay: (Date) throws -> [MetricsHistoryPoint]) -> Bool` — returns whether anything changed
    - `func fingerprint(for days: [Date]) -> String`
    - `func macroRead(key: String) -> String?`
    - `func setMacroRead(_ text: String, key: String)`

**Why `fetchDay` is a closure:** it keeps SwiftData entirely out of this type, so every branch is unit-testable. `TrackView` (Task 11) supplies the real day-scoped `FetchDescriptor`.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/TrackCacheTests.swift`:

```swift
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

    func testMacroReadsRoundTrip() {
        let a = TrackCache(fileURL: url)
        a.setMacroRead("Steady week.", key: "week|123|abc")

        let b = TrackCache(fileURL: url)
        b.load()
        XCTAssertEqual(b.macroRead(key: "week|123|abc"), "Steady week.")
        XCTAssertNil(b.macroRead(key: "week|123|different"))
    }
}
```

- [ ] **Step 2: Register the test file**

Follow the four-edit procedure from Task 1 Step 2, with `AT31` / `FT31` and `TrackCacheTests.swift`.

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/TrackCacheTests 2>&1 | tail -30
```
Expected: compile failure — `cannot find 'TrackCache' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/Wythin/Metrics/TrackCache.swift`:

```swift
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

    static var defaultURL: URL {
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
```

- [ ] **Step 5: Register the implementation file**

Four edits per Task 1 Step 5, using `A241` / `F241`, `TrackCache.swift`, the `GAPP_MET /* Metrics */` group, and the app target's sources phase.

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/TrackCacheTests 2>&1 | tail -30
```
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/TrackCache.swift ios/WythinTests/TrackCacheTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(track): TrackCache — JSON rollup cache with incremental refresh"
```

---

### Task 3: TrackPeriod — period paging and range maths

**Files:**
- Create: `ios/Wythin/Metrics/TrackPeriod.swift`
- Test: `ios/WythinTests/TrackPeriodTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `enum TrackPeriod: String, CaseIterable, Identifiable { case week = "W", month = "M", sixMonth = "6M" }`
  - `struct TrackBucket: Equatable, Identifiable { let start: Date; let end: Date; let label: String; var id: Date { start } }` — `start` inclusive, `end` exclusive.
  - `struct TrackRange: Equatable { let period: TrackPeriod; let offset: Int; let start: Date; let end: Date; let buckets: [TrackBucket]; let label: String }` — `start` inclusive, `end` exclusive.
  - `enum TrackRangeBuilder { static func range(period:offset:today:calendar:) -> TrackRange; static var dayFormatter/monthFormatter ... }`

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/TrackPeriodTests.swift`:

```swift
import XCTest
@testable import Wythin

final class TrackPeriodTests: XCTestCase {

    /// Fixed calendar so weekday boundaries and DST are deterministic.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2   // Monday
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: Week

    func testWeekCoversMondayThroughSunday() {
        // 2026-07-28 is a Tuesday.
        let r = TrackRangeBuilder.range(period: .week, offset: 0,
                                        today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(r.buckets.count, 7)
        XCTAssertEqual(r.start, cal.startOfDay(for: date(2026, 7, 27)))   // Monday
        XCTAssertEqual(r.buckets.last!.start, cal.startOfDay(for: date(2026, 8, 2)))
    }

    func testWeekOffsetGoesBackSevenDays() {
        let now  = TrackRangeBuilder.range(period: .week, offset: 0, today: date(2026, 7, 28), calendar: cal)
        let prev = TrackRangeBuilder.range(period: .week, offset: 1, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(cal.dateComponents([.day], from: prev.start, to: now.start).day, 7)
        XCTAssertEqual(prev.buckets.count, 7)
    }

    func testWeekSpanningDSTStillHasSevenBuckets() {
        // US DST starts Sunday 2026-03-08; that week is 167 hours long.
        let r = TrackRangeBuilder.range(period: .week, offset: 0,
                                        today: date(2026, 3, 4), calendar: cal)
        XCTAssertEqual(r.buckets.count, 7)
    }

    // MARK: Month

    func testMonthHasOneBucketPerDay() {
        let r = TrackRangeBuilder.range(period: .month, offset: 0,
                                        today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(r.buckets.count, 31)
        XCTAssertEqual(r.start, cal.startOfDay(for: date(2026, 7, 1)))
    }

    func testFebruaryLengthsAreCorrect() {
        let common = TrackRangeBuilder.range(period: .month, offset: 0,
                                             today: date(2026, 2, 15), calendar: cal)
        XCTAssertEqual(common.buckets.count, 28)

        let leap = TrackRangeBuilder.range(period: .month, offset: 0,
                                           today: date(2024, 2, 15), calendar: cal)
        XCTAssertEqual(leap.buckets.count, 29)
    }

    func testMonthOffsetCrossesTheYearBoundary() {
        let r = TrackRangeBuilder.range(period: .month, offset: 1,
                                        today: date(2026, 1, 15), calendar: cal)
        XCTAssertEqual(r.start, cal.startOfDay(for: date(2025, 12, 1)))
        XCTAssertEqual(r.buckets.count, 31)
    }

    // MARK: Six months

    func testSixMonthHasSixMonthlyBucketsEndingThisMonth() {
        let r = TrackRangeBuilder.range(period: .sixMonth, offset: 0,
                                        today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(r.buckets.count, 6)
        XCTAssertEqual(r.buckets.first!.start, cal.startOfDay(for: date(2026, 2, 1)))
        XCTAssertEqual(r.buckets.last!.start, cal.startOfDay(for: date(2026, 7, 1)))
        XCTAssertEqual(r.buckets.last!.label, "JUL")
    }

    func testSixMonthOffsetDoesNotOverlap() {
        let now  = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: date(2026, 7, 28), calendar: cal)
        let prev = TrackRangeBuilder.range(period: .sixMonth, offset: 1, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(prev.end, now.start)
        XCTAssertEqual(prev.buckets.first!.start, cal.startOfDay(for: date(2025, 8, 1)))
    }

    // MARK: Buckets and labels

    func testBucketEndIsExclusiveAndContiguous() {
        let r = TrackRangeBuilder.range(period: .week, offset: 0,
                                        today: date(2026, 7, 28), calendar: cal)
        for (a, b) in zip(r.buckets, r.buckets.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
        }
        XCTAssertEqual(r.buckets.last!.end, r.end)
    }

    func testLabelsAreHumanReadable() {
        let w = TrackRangeBuilder.range(period: .week, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(w.label, "JUL 27 – AUG 2")

        let m = TrackRangeBuilder.range(period: .month, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(m.label, "JULY 2026")

        let s = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.label, "FEB – JUL 2026")
    }

    func testDayBucketLabels() {
        let w = TrackRangeBuilder.range(period: .week, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(w.buckets.map(\.label), ["M", "T", "W", "T", "F", "S", "S"])

        let m = TrackRangeBuilder.range(period: .month, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(m.buckets.first!.label, "1")
        XCTAssertEqual(m.buckets.last!.label, "31")
    }
}
```

- [ ] **Step 2: Register the test file**

Four edits per Task 1 Step 2, with `AT32` / `FT32` and `TrackPeriodTests.swift`.

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/TrackPeriodTests 2>&1 | tail -30
```
Expected: compile failure — `cannot find 'TrackRangeBuilder' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/Wythin/Metrics/TrackPeriod.swift`:

```swift
import Foundation

/// The three windows the Track screen pages through.
enum TrackPeriod: String, CaseIterable, Identifiable {
    case week     = "W"
    case month    = "M"
    case sixMonth = "6M"

    var id: String { rawValue }

    /// Wire value for the macro-read insight payload.
    var apiValue: String {
        switch self {
        case .week:     return "week"
        case .month:    return "month"
        case .sixMonth: return "six_month"
        }
    }

    /// What one bar covers — used for pluralised copy.
    var bucketNoun: (singular: String, plural: String) {
        self == .sixMonth ? ("month", "months") : ("day", "days")
    }
}

/// One x-axis slot: a single day (W, M) or a calendar month (6M).
/// `start` is inclusive, `end` exclusive.
struct TrackBucket: Equatable, Identifiable {
    let start: Date
    let end:   Date
    let label: String

    var id: Date { start }
}

/// One page of a period. `offset` 0 is the current page; 1 is one page back.
/// `start` is inclusive, `end` exclusive.
struct TrackRange: Equatable {
    let period:  TrackPeriod
    let offset:  Int
    let start:   Date
    let end:     Date
    let buckets: [TrackBucket]
    let label:   String

    /// Every local day the page covers — what `TrackCache.refresh` needs.
    var days: [Date] {
        var out: [Date] = []
        var d = start
        let cal = Calendar.current
        while d < end {
            out.append(d)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    var isCurrent: Bool { offset == 0 }
}

enum TrackRangeBuilder {

    static func range(period: TrackPeriod, offset: Int, today: Date,
                      calendar: Calendar = .current) -> TrackRange {
        switch period {
        case .week:     return week(offset: offset, today: today, calendar: calendar)
        case .month:    return month(offset: offset, today: today, calendar: calendar)
        case .sixMonth: return sixMonth(offset: offset, today: today, calendar: calendar)
        }
    }

    // MARK: Week

    private static func week(offset: Int, today: Date, calendar cal: Calendar) -> TrackRange {
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let start    = cal.date(byAdding: .weekOfYear, value: -offset, to: thisWeek)!
        let end      = cal.date(byAdding: .weekOfYear, value: 1, to: start)!

        let buckets = dayBuckets(from: start, to: end, calendar: cal) { d in
            // Narrow weekday: "M", "T", …
            String(fmt("EEEEE", cal).string(from: d).uppercased().prefix(1))
        }
        let last = cal.date(byAdding: .day, value: -1, to: end)!
        return TrackRange(period: .week, offset: offset, start: start, end: end,
                          buckets: buckets,
                          label: "\(fmt("MMM d", cal).string(from: start).uppercased()) – "
                               + "\(fmt("MMM d", cal).string(from: last).uppercased())")
    }

    // MARK: Month

    private static func month(offset: Int, today: Date, calendar cal: Calendar) -> TrackRange {
        let thisMonth = cal.dateInterval(of: .month, for: today)!.start
        let start     = cal.date(byAdding: .month, value: -offset, to: thisMonth)!
        let end       = cal.date(byAdding: .month, value: 1, to: start)!

        let buckets = dayBuckets(from: start, to: end, calendar: cal) { d in
            String(cal.component(.day, from: d))
        }
        return TrackRange(period: .month, offset: offset, start: start, end: end,
                          buckets: buckets,
                          label: fmt("MMMM yyyy", cal).string(from: start).uppercased())
    }

    // MARK: Six months

    private static func sixMonth(offset: Int, today: Date, calendar cal: Calendar) -> TrackRange {
        let thisMonth = cal.dateInterval(of: .month, for: today)!.start
        let end       = cal.date(byAdding: .month, value: 1 - offset * 6, to: thisMonth)!
        let start     = cal.date(byAdding: .month, value: -6, to: end)!

        var buckets: [TrackBucket] = []
        var m = start
        while m < end {
            let next = cal.date(byAdding: .month, value: 1, to: m)!
            buckets.append(TrackBucket(start: m, end: next,
                                       label: fmt("MMM", cal).string(from: m).uppercased()))
            m = next
        }
        let last = cal.date(byAdding: .month, value: -1, to: end)!
        return TrackRange(period: .sixMonth, offset: offset, start: start, end: end,
                          buckets: buckets,
                          label: "\(fmt("MMM", cal).string(from: start).uppercased()) – "
                               + "\(fmt("MMM yyyy", cal).string(from: last).uppercased())")
    }

    // MARK: Helpers

    /// One bucket per calendar day. Stepping by `.day` rather than adding
    /// 86,400 s keeps DST-shortened and -lengthened days at one bucket each.
    private static func dayBuckets(from start: Date, to end: Date, calendar cal: Calendar,
                                   label: (Date) -> String) -> [TrackBucket] {
        var out: [TrackBucket] = []
        var d = start
        while d < end {
            let next = cal.date(byAdding: .day, value: 1, to: d)!
            out.append(TrackBucket(start: d, end: next, label: label(d)))
            d = next
        }
        return out
    }

    private static func fmt(_ format: String, _ cal: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar   = cal
        f.timeZone   = cal.timeZone
        f.locale     = cal.locale ?? Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
```

- [ ] **Step 5: Register the implementation file**

Four edits per Task 1 Step 5, with `A242` / `F242`, `TrackPeriod.swift`, the `GAPP_MET /* Metrics */` group, and the app target's sources phase.

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/TrackPeriodTests 2>&1 | tail -30
```
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/TrackPeriod.swift ios/WythinTests/TrackPeriodTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(track): TrackPeriod — W/M/6M paging and bucket maths"
```

---

### Task 4: TrackMetricSpec — the seven charted metrics

**Files:**
- Create: `ios/Wythin/Metrics/TrackMetricSpec.swift`
- Test: `ios/WythinTests/TrackMetricSpecTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DailyRollup` (Task 1); `ActivityMetricDef` and the `activityMetricDefs` array (`ios/Wythin/UI/Activities/ActivityMetricsGrid.swift:5,49`); `BenefitDirection` (`ios/Wythin/Metrics/ActivityMetricStats.swift:6`); `Theme`.
- Produces:
  - `struct TrackMetricSpec: Identifiable` with `let def: ActivityMetricDef`, `let rollup: (DailyRollup) -> Double?`, `let color: Color`, `let zeroBased: Bool`, `let fallbackReference: Double`, `let trendKey: String`, and `var id: String { def.label }`.
  - `enum TrackMetrics { static let all: [TrackMetricSpec] }` — exactly 7, in display order.

`TrackMetricSpec` *wraps* `ActivityMetricDef` rather than extending it: that type is consumed by the Activities grid and charts, and adding Track-only chart fields would push presentation concerns into a shared model.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/TrackMetricSpecTests.swift`:

```swift
import XCTest
@testable import Wythin

final class TrackMetricSpecTests: XCTestCase {

    private let rollup = DailyRollup(
        day: Date(timeIntervalSince1970: 1_750_000_000),
        dc: 8, rmssd: 40, rsaMs: 30, rcmse: 1.4, pip: 55, dfa1: 1.0,
        stressBalance: 45, vti: 3.7, meanBPM: 60,
        sampleCount: 200, wearSeconds: 400)

    func testHasExactlySevenMetricsInOrder() {
        XCTAssertEqual(TrackMetrics.all.map(\.def.label), [
            "Vagal Tone", "Energy Reserve", "Conscious Breathing",
            "Adaptive Capacity", "Harmony", "Inner Noise", "Stress Balance",
        ])
    }

    func testExcludesPulseAndCalmPower() {
        let labels = Set(TrackMetrics.all.map(\.def.label))
        XCTAssertFalse(labels.contains("Pulse"))
        XCTAssertFalse(labels.contains("Calm Power"))
    }

    func testEveryExtractorReadsItsField() {
        let values = TrackMetrics.all.map { $0.rollup(rollup) }
        XCTAssertEqual(values, [8, 40, 30, 1.4, 1.0, 55, 45])
    }

    func testTrendKeysAreUniqueAndStressBalanceIsNotLfHf() {
        let keys = TrackMetrics.all.map(\.trendKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        // Sending the 0–100 dial under `lf_hf` would have the server's
        // _METRIC_NAMES gloss it as a raw ratio.
        XCTAssertFalse(keys.contains("lf_hf"))
        XCTAssertTrue(keys.contains("stress_balance"))
    }

    func testIndexMetricsAreNotZeroBased() {
        func spec(_ label: String) -> TrackMetricSpec {
            TrackMetrics.all.first { $0.def.label == label }!
        }
        XCTAssertFalse(spec("Adaptive Capacity").zeroBased)
        XCTAssertFalse(spec("Harmony").zeroBased)
        XCTAssertTrue(spec("Energy Reserve").zeroBased)
    }

    func testDirectionsComeFromTheSharedRegistry() {
        func spec(_ label: String) -> TrackMetricSpec {
            TrackMetrics.all.first { $0.def.label == label }!
        }
        // Inner Noise is `.lower` — a drop must read as an improvement.
        XCTAssertGreaterThan(spec("Inner Noise").def.direction.benefit(40),
                             spec("Inner Noise").def.direction.benefit(60))
        // Harmony is `.target(1.0)`.
        XCTAssertGreaterThan(spec("Harmony").def.direction.benefit(1.0),
                             spec("Harmony").def.direction.benefit(1.4))
    }

    func testWhyCopyIsInheritedNotRetyped() {
        for spec in TrackMetrics.all {
            let shared = activityMetricDefs.first { $0.label == spec.def.label }
            XCTAssertEqual(spec.def.why, shared?.why)
            XCTAssertFalse(spec.def.why.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Register the test file**

Four edits per Task 1 Step 2, with `AT33` / `FT33` and `TrackMetricSpecTests.swift`.

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/TrackMetricSpecTests 2>&1 | tail -30
```
Expected: compile failure — `cannot find 'TrackMetrics' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/Wythin/Metrics/TrackMetricSpec.swift`:

```swift
import SwiftUI

/// One metric as the Track charts need it: the shared `ActivityMetricDef`
/// (label, tech label, unit, benefit direction, formatter, "why" copy) plus
/// the chart-only concerns Track adds.
///
/// It wraps rather than extends `ActivityMetricDef` because that type is
/// consumed by the Activities grid and charts; adding chart-presentation
/// fields to it would leak Track's concerns into a shared model.
struct TrackMetricSpec: Identifiable {
    let def:    ActivityMetricDef
    let rollup: (DailyRollup) -> Double?
    let color:  Color
    /// Whether the y-axis starts at zero. False for index metrics whose values
    /// hover in a narrow band — a zero-based chart of numbers near 1.0 is a
    /// wall of identical bars.
    let zeroBased: Bool
    /// Reference used until there are `TrackSeriesBuilder.minBaselineDays`
    /// of the user's own data.
    let fallbackReference: Double
    /// Key used in the macro-read payload; must match the server's
    /// `_METRIC_NAMES` in `server/routers/insights.py`.
    let trendKey: String

    var id: String { def.label }
}

enum TrackMetrics {

    /// The 7 charted metrics, recovery first and load last. Pulse and Calm
    /// Power are deliberately excluded.
    static let all: [TrackMetricSpec] = [
        .init(def: def("Vagal Tone"),          rollup: { $0.dc },
              color: Theme.accent,  zeroBased: true,  fallbackReference: 6.0,  trendKey: "dc"),
        .init(def: def("Energy Reserve"),      rollup: { $0.rmssd },
              color: Theme.hrv,     zeroBased: true,  fallbackReference: 40.0, trendKey: "rmssd"),
        .init(def: def("Conscious Breathing"), rollup: { $0.rsaMs },
              color: Theme.rsa,     zeroBased: true,  fallbackReference: 40.0, trendKey: "rsa"),
        .init(def: def("Adaptive Capacity"),   rollup: { $0.rcmse },
              color: Theme.ulf,     zeroBased: false, fallbackReference: 1.4,  trendKey: "rcmse"),
        .init(def: def("Harmony"),             rollup: { $0.dfa1 },
              color: Theme.coh,     zeroBased: false, fallbackReference: 1.0,  trendKey: "dfa1"),
        .init(def: def("Inner Noise"),         rollup: { $0.pip },
              color: Theme.breathe, zeroBased: true,  fallbackReference: 55.0, trendKey: "pip"),
        .init(def: def("Stress Balance"),      rollup: { $0.stressBalance },
              color: Theme.warn,    zeroBased: true,  fallbackReference: 50.0, trendKey: "stress_balance"),
    ]

    /// Labels, units, direction and copy are single-sourced from
    /// `activityMetricDefs` so Track and Activities cannot drift.
    private static func def(_ label: String) -> ActivityMetricDef {
        guard let d = activityMetricDefs.first(where: { $0.label == label }) else {
            preconditionFailure("activityMetricDefs is missing \"\(label)\"")
        }
        return d
    }
}
```

- [ ] **Step 5: Register the implementation file**

Four edits per Task 1 Step 5, with `A243` / `F243`, `TrackMetricSpec.swift`, the `GAPP_MET /* Metrics */` group, and the app target's sources phase.

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/TrackMetricSpecTests 2>&1 | tail -30
```
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/TrackMetricSpec.swift ios/WythinTests/TrackMetricSpecTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(track): TrackMetricSpec — 7 charted metrics over the shared registry"
```

---

### Task 5: TrackSeriesBuilder — rollups to chart series

**Files:**
- Create: `ios/Wythin/Metrics/TrackSeriesBuilder.swift`
- Test: `ios/WythinTests/TrackSeriesBuilderTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DailyRollup` (Task 1); `TrackRange`, `TrackBucket`, `TrackPeriod` (Task 3); `TrackMetricSpec` (Task 4); `ActivityMetricDef.benefitDelta(current:base:)` (`ios/Wythin/UI/Activities/ActivityMetricsGrid.swift:25`).
- Produces:
  - `struct TrackBar: Identifiable, Equatable { let bucket: TrackBucket; let value: Double?; let dayCount: Int; var id: Date { bucket.start } }`
  - `struct TrackOverlaySegment: Identifiable, Equatable { let start: Date; let end: Date; let value: Double; var id: Date { start } }`
  - `struct TrackSeries: Equatable { let bars: [TrackBar]; let average: Double?; let deltaPct: Double?; let reference: Double; let referenceIsPersonal: Bool; let overlay: [TrackOverlaySegment]; let betterCount: Int; let presentCount: Int; let summary: String }`
  - `enum TrackSeriesBuilder` with `static let minBaselineDays = 14`, `static let baselineWindowDays = 90`, `static let minDaysPerMonthBucket = 5`, and:
    - `static func bars(spec:range:rollups:) -> [TrackBar]`
    - `static func baseline(spec:rollups:asOf:calendar:) -> (value: Double, isPersonal: Bool)`
    - `static func weeklyOverlay(bars:calendar:) -> [TrackOverlaySegment]`
    - `static func series(spec:range:priorRange:rollups:asOf:calendar:) -> TrackSeries`

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/TrackSeriesBuilderTests.swift`:

```swift
import XCTest
@testable import Wythin

final class TrackSeriesBuilderTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!)
    }

    private func spec(_ label: String) -> TrackMetricSpec {
        TrackMetrics.all.first { $0.def.label == label }!
    }

    /// A rollup with `dc` and `pip` set; other fields nil.
    private func rollup(_ day: Date, dc: Double? = nil, pip: Double? = nil,
                        wearSeconds: Double = 400) -> DailyRollup {
        DailyRollup(day: day, dc: dc, rmssd: nil, rsaMs: nil, rcmse: nil,
                    pip: pip, dfa1: nil, stressBalance: nil, vti: nil, meanBPM: nil,
                    sampleCount: 200, wearSeconds: wearSeconds)
    }

    private func week(_ offset: Int, today: Date) -> TrackRange {
        TrackRangeBuilder.range(period: .week, offset: offset, today: today, calendar: cal)
    }

    // MARK: bars

    func testOneBarPerBucketWithMissingDaysNil() {
        let today = date(2026, 7, 28)                      // Tuesday
        let r = week(0, today: today)                      // Mon 27 Jul – Sun 2 Aug
        let rollups = [rollup(date(2026, 7, 27), dc: 6),
                       rollup(date(2026, 7, 29), dc: 10)]
        let bars = TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups)

        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars[0].value, 6)
        XCTAssertNil(bars[1].value)                        // Tue has no rollup
        XCTAssertEqual(bars[2].value, 10)
        XCTAssertNil(bars[6].value)
    }

    func testMonthlyBucketIsTheUnweightedMeanOfDailyMeans() {
        let today = date(2026, 7, 15)
        let r = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: today, calendar: cal)
        // July: two days, one with 10× the wear time. The mean must be 8, not
        // pulled toward the long day.
        let rollups = [rollup(date(2026, 7, 1), dc: 6, wearSeconds: 40_000),
                       rollup(date(2026, 7, 2), dc: 10, wearSeconds: 4_000),
                       rollup(date(2026, 7, 3), dc: 6),
                       rollup(date(2026, 7, 4), dc: 10),
                       rollup(date(2026, 7, 5), dc: 8)]
        let bars = TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups)
        XCTAssertEqual(bars.last!.value!, 8.0, accuracy: 0.001)
        XCTAssertEqual(bars.last!.dayCount, 5)
    }

    func testMonthWithTooFewValidDaysIsSuppressed() {
        let today = date(2026, 7, 15)
        let r = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: today, calendar: cal)
        let rollups = (1...4).map { rollup(date(2026, 7, $0), dc: 8) }   // 4 < 5
        let bars = TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups)
        XCTAssertNil(bars.last!.value)
    }

    // MARK: baseline

    func testBaselineIsTheMedianOfTheLast90Days() {
        let asOf = date(2026, 7, 28)
        // 20 days: values 1…20 → median 10.5
        let rollups = (1...20).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: Double($0))
        }
        let b = TrackSeriesBuilder.baseline(spec: spec("Vagal Tone"), rollups: rollups,
                                            asOf: asOf, calendar: cal)
        XCTAssertEqual(b.value, 10.5, accuracy: 0.001)
        XCTAssertTrue(b.isPersonal)
    }

    func testBaselineFallsBackBelowFourteenDays() {
        let asOf = date(2026, 7, 28)
        let rollups = (1...13).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: 99)
        }
        let b = TrackSeriesBuilder.baseline(spec: spec("Vagal Tone"), rollups: rollups,
                                            asOf: asOf, calendar: cal)
        XCTAssertEqual(b.value, spec("Vagal Tone").fallbackReference)
        XCTAssertFalse(b.isPersonal)
    }

    func testBaselineIgnoresDaysOlderThanTheWindow() {
        let asOf = date(2026, 7, 28)
        let recent = (1...20).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: 10)
        }
        let ancient = (100...130).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: 1000)
        }
        let b = TrackSeriesBuilder.baseline(spec: spec("Vagal Tone"), rollups: recent + ancient,
                                            asOf: asOf, calendar: cal)
        XCTAssertEqual(b.value, 10, accuracy: 0.001)
    }

    // MARK: delta

    func testDeltaIsBenefitSignedForHigherIsBetter() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 11) }
                    + week(1, today: today).days.map { rollup($0, dc: 10) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.deltaPct!, 10, accuracy: 0.001)
    }

    func testDeltaIsBenefitSignedForLowerIsBetter() {
        let today = date(2026, 7, 28)
        // Inner Noise fell 60 → 54. A fall is an improvement: +10%.
        let rollups = week(0, today: today).days.map { rollup($0, pip: 54) }
                    + week(1, today: today).days.map { rollup($0, pip: 60) }
        let s = TrackSeriesBuilder.series(spec: spec("Inner Noise"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.deltaPct!, 10, accuracy: 0.001)
    }

    func testDeltaIsNilWhenThePriorPeriodIsEmpty() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 11) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertNil(s.deltaPct)
        XCTAssertNotNil(s.average)
    }

    // MARK: summary

    func testSummaryCountsInTheBenefitDirection() {
        let today = date(2026, 7, 28)
        let days  = week(0, today: today).days
        // Baseline needs ≥14 days; give 20 at pip 60, then this week's 7 at 50.
        var rollups = (8...27).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: today)!, pip: 60)
        }
        rollups += days.map { rollup($0, pip: 50) }   // lower = better
        let s = TrackSeriesBuilder.series(spec: spec("Inner Noise"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.presentCount, 7)
        XCTAssertEqual(s.betterCount, 7)
        XCTAssertEqual(s.summary, "7 of 7 days better than your baseline.")
    }

    func testSummarySaysTypicalWhenTheBaselineIsNotPersonal() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.prefix(3).map { rollup($0, dc: 100) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: Array(rollups), asOf: today, calendar: cal)
        XCTAssertEqual(s.summary, "3 of 3 days better than typical.")
    }

    func testSummaryIsSingularForOneDay() {
        let today = date(2026, 7, 28)
        let rollups = [rollup(date(2026, 7, 27), dc: 100)]
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.summary, "1 of 1 day better than typical.")
    }

    func testSummaryForNoData() {
        let today = date(2026, 7, 28)
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: [], asOf: today, calendar: cal)
        XCTAssertEqual(s.summary, "No data this period.")
        XCTAssertNil(s.average)
        XCTAssertTrue(s.overlay.isEmpty)
    }

    // MARK: weekly overlay

    func testMonthSeriesHasWeeklyOverlaySegments() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        let rollups = r.days.map { rollup($0, dc: 8) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"), range: r,
                                          priorRange: TrackRangeBuilder.range(period: .month, offset: 1,
                                                                              today: today, calendar: cal),
                                          rollups: rollups, asOf: today, calendar: cal)
        // July 2026 spans 5 partial ISO weeks.
        XCTAssertEqual(s.overlay.count, 5)
        XCTAssertEqual(s.overlay.first!.value, 8, accuracy: 0.001)
    }

    func testWeekAndSixMonthSeriesHaveNoOverlay() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 8) }
        let w = TrackSeriesBuilder.series(spec: spec("Vagal Tone"), range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertTrue(w.overlay.isEmpty)
    }
}
```

- [ ] **Step 2: Register the test file**

Four edits per Task 1 Step 2, with `AT34` / `FT34` and `TrackSeriesBuilderTests.swift`.

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/TrackSeriesBuilderTests 2>&1 | tail -30
```
Expected: compile failure — `cannot find 'TrackSeriesBuilder' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/Wythin/Metrics/TrackSeriesBuilder.swift`:

```swift
import Foundation

/// One bar: a bucket and the value behind it.
struct TrackBar: Identifiable, Equatable {
    let bucket: TrackBucket
    let value:  Double?
    /// Valid days behind the value — 1 for daily buckets, up to 31 for monthly.
    let dayCount: Int

    var id: Date { bucket.start }
}

/// A short horizontal rule spanning several bars, drawn over the month view so
/// ~30 daily bars stay readable without a number on every one.
struct TrackOverlaySegment: Identifiable, Equatable {
    let start: Date
    let end:   Date
    let value: Double

    var id: Date { start }
}

/// Everything one metric card renders for one page.
struct TrackSeries: Equatable {
    let bars:                [TrackBar]
    let average:             Double?
    /// Benefit-signed change vs the prior page — positive always means better.
    let deltaPct:            Double?
    let reference:           Double
    let referenceIsPersonal: Bool
    let overlay:             [TrackOverlaySegment]
    let betterCount:         Int
    let presentCount:        Int
    let summary:             String
}

enum TrackSeriesBuilder {

    /// Below this many of the user's own days, the reference falls back to a
    /// fixed physiological norm.
    static let minBaselineDays = 14
    static let baselineWindowDays = 90
    /// A monthly bar built on fewer days than this is suppressed rather than
    /// shown as if it were representative.
    static let minDaysPerMonthBucket = 5

    // MARK: Bars

    static func bars(spec: TrackMetricSpec, range: TrackRange,
                     rollups: [DailyRollup]) -> [TrackBar] {
        range.buckets.map { bucket in
            let values = rollups
                .filter { $0.day >= bucket.start && $0.day < bucket.end }
                .compactMap { spec.rollup($0) }

            let minDays = range.period == .sixMonth ? minDaysPerMonthBucket : 1
            guard values.count >= minDays else {
                return TrackBar(bucket: bucket, value: nil, dayCount: values.count)
            }
            // Unweighted mean of daily means: a day is a day, so an 18-hour
            // wear day cannot outweigh a 6-hour one.
            return TrackBar(bucket: bucket,
                            value: values.reduce(0, +) / Double(values.count),
                            dayCount: values.count)
        }
    }

    // MARK: Baseline

    static func baseline(spec: TrackMetricSpec, rollups: [DailyRollup],
                         asOf: Date, calendar cal: Calendar = .current)
    -> (value: Double, isPersonal: Bool) {
        let cutoff = cal.date(byAdding: .day, value: -baselineWindowDays, to: asOf) ?? .distantPast
        let values = rollups
            .filter { $0.day > cutoff && $0.day <= asOf }
            .compactMap { spec.rollup($0) }
            .sorted()

        guard values.count >= minBaselineDays else {
            return (spec.fallbackReference, false)
        }
        let mid = values.count / 2
        let median = values.count.isMultiple(of: 2)
            ? (values[mid - 1] + values[mid]) / 2
            : values[mid]
        return (median, true)
    }

    // MARK: Weekly overlay

    /// Groups daily bars by calendar week and returns the mean of each week's
    /// present values.
    static func weeklyOverlay(bars: [TrackBar],
                              calendar cal: Calendar = .current) -> [TrackOverlaySegment] {
        var groups: [Date: [TrackBar]] = [:]
        for bar in bars {
            let weekStart = cal.dateInterval(of: .weekOfYear, for: bar.bucket.start)?.start
                ?? bar.bucket.start
            groups[weekStart, default: []].append(bar)
        }
        return groups.keys.sorted().compactMap { weekStart in
            let group  = groups[weekStart]!.sorted { $0.bucket.start < $1.bucket.start }
            let values = group.compactMap(\.value)
            guard !values.isEmpty else { return nil }
            return TrackOverlaySegment(start: group.first!.bucket.start,
                                       end:   group.last!.bucket.end,
                                       value: values.reduce(0, +) / Double(values.count))
        }
    }

    // MARK: Series

    static func series(spec: TrackMetricSpec, range: TrackRange, priorRange: TrackRange,
                       rollups: [DailyRollup], asOf: Date,
                       calendar cal: Calendar = .current) -> TrackSeries {
        let bars    = bars(spec: spec, range: range, rollups: rollups)
        let present = bars.compactMap(\.value)
        let average = present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)

        let priorBars    = bars(spec: spec, range: priorRange, rollups: rollups)
        let priorPresent = priorBars.compactMap(\.value)
        let priorAverage = priorPresent.isEmpty
            ? nil : priorPresent.reduce(0, +) / Double(priorPresent.count)

        // Reuses the shared benefit-signed formula so a fall in Inner Noise
        // reads as an improvement.
        let delta = spec.def.benefitDelta(current: average, base: priorAverage)

        let (reference, isPersonal) = baseline(spec: spec, rollups: rollups,
                                               asOf: asOf, calendar: cal)
        let refBenefit  = spec.def.direction.benefit(reference)
        let betterCount = present.filter { spec.def.direction.benefit($0) > refBenefit }.count

        let overlay = range.period == .month ? weeklyOverlay(bars: bars, calendar: cal) : []

        return TrackSeries(
            bars: bars, average: average, deltaPct: delta,
            reference: reference, referenceIsPersonal: isPersonal,
            overlay: overlay, betterCount: betterCount, presentCount: present.count,
            summary: summary(period: range.period, better: betterCount,
                             total: present.count, isPersonal: isPersonal))
    }

    /// "5 of 7 days better than your baseline." — phrased as *better* rather
    /// than *above* because for Inner Noise and Stress Balance a lower value
    /// is the good outcome.
    private static func summary(period: TrackPeriod, better: Int,
                                total: Int, isPersonal: Bool) -> String {
        guard total > 0 else { return "No data this period." }
        let noun = total == 1 ? period.bucketNoun.singular : period.bucketNoun.plural
        let ref  = isPersonal ? "your baseline" : "typical"
        return "\(better) of \(total) \(noun) better than \(ref)."
    }
}
```

- [ ] **Step 5: Register the implementation file**

Four edits per Task 1 Step 5, with `A244` / `F244`, `TrackSeriesBuilder.swift`, the `GAPP_MET /* Metrics */` group, and the app target's sources phase.

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/TrackSeriesBuilderTests 2>&1 | tail -30
```
Expected: `Executed 15 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/TrackSeriesBuilder.swift ios/WythinTests/TrackSeriesBuilderTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(track): TrackSeriesBuilder — bars, baseline, benefit-signed delta"
```

---

### Task 6: ConsistencySummary — practice and wear

**Files:**
- Create: `ios/Wythin/Metrics/ConsistencySummary.swift`
- Test: `ios/WythinTests/ConsistencySummaryTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DailyRollup` (Task 1); `TrackRange`, `TrackBucket` (Task 3); `StreakCompute.evaluate(days:today:calendar:) -> StreakResult` (`ios/Wythin/Metrics/StreakCompute.swift:22`).
- Produces:
  - `struct ActivitySpan: Equatable { let startedAt: Date; let endedAt: Date? }`
  - `struct ConsistencySummary: Equatable` with a nested `struct Bucket: Identifiable, Equatable { let bucket: TrackBucket; let practiceMinutes: Double; let wearHours: Double; var id: Date { bucket.start } }`, plus `let buckets: [Bucket]`, `let sessionCount: Int`, `let totalPracticeMinutes: Double`, `let avgWearHours: Double`, `let streak: StreakResult`.
  - `enum ConsistencyBuilder { static func build(range:activities:rollups:today:calendar:) -> ConsistencySummary }`

Practice comes from `ActivityLog`, **not** `HRVSession`: sessions are auto-created for background all-day recording (`AppEnvironment.swift:464`), so they measure strap wear, not deliberate practice.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ConsistencySummaryTests.swift`:

```swift
import XCTest
@testable import Wythin

final class ConsistencySummaryTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.startOfDay(for: date(y, m, d))
    }

    private func rollup(_ d: Date, wearSeconds: Double) -> DailyRollup {
        DailyRollup(day: d, dc: 8, rmssd: nil, rsaMs: nil, rcmse: nil, pip: nil,
                    dfa1: nil, stressBalance: nil, vti: nil, meanBPM: nil,
                    sampleCount: 200, wearSeconds: wearSeconds)
    }

    private var week: TrackRange {
        TrackRangeBuilder.range(period: .week, offset: 0,
                                today: date(2026, 7, 28), calendar: cal)   // Mon 27 Jul – Sun 2 Aug
    }

    func testPracticeMinutesLandOnTheStartDay() {
        let acts = [ActivitySpan(startedAt: date(2026, 7, 27, 9),
                                 endedAt:   date(2026, 7, 27, 9).addingTimeInterval(20 * 60))]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets[0].practiceMinutes, 20, accuracy: 0.001)
        XCTAssertEqual(s.buckets[1].practiceMinutes, 0, accuracy: 0.001)
        XCTAssertEqual(s.totalPracticeMinutes, 20, accuracy: 0.001)
        XCTAssertEqual(s.sessionCount, 1)
    }

    func testMultipleSessionsOnADayAccumulate() {
        let acts = [
            ActivitySpan(startedAt: date(2026, 7, 27, 9),
                         endedAt: date(2026, 7, 27, 9).addingTimeInterval(10 * 60)),
            ActivitySpan(startedAt: date(2026, 7, 27, 18),
                         endedAt: date(2026, 7, 27, 18).addingTimeInterval(15 * 60)),
        ]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets[0].practiceMinutes, 25, accuracy: 0.001)
        XCTAssertEqual(s.sessionCount, 2)
    }

    func testActivitySpanningMidnightIsAttributedToItsStartDay() {
        let acts = [ActivitySpan(startedAt: date(2026, 7, 27, 23),
                                 endedAt:   date(2026, 7, 28, 0).addingTimeInterval(30 * 60))]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets[0].practiceMinutes, 90, accuracy: 0.001)
        XCTAssertEqual(s.buckets[1].practiceMinutes, 0, accuracy: 0.001)
    }

    func testUnfinishedActivitiesAreIgnored() {
        let acts = [ActivitySpan(startedAt: date(2026, 7, 27, 9), endedAt: nil)]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.sessionCount, 0)
        XCTAssertEqual(s.totalPracticeMinutes, 0, accuracy: 0.001)
    }

    func testActivitiesOutsideTheRangeAreExcluded() {
        let acts = [ActivitySpan(startedAt: date(2026, 7, 20, 9),
                                 endedAt: date(2026, 7, 20, 10))]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.sessionCount, 0)
    }

    func testWearHoursComeFromRollups() {
        let rollups = [rollup(day(2026, 7, 27), wearSeconds: 3600 * 16),
                       rollup(day(2026, 7, 28), wearSeconds: 3600 * 8)]
        let s = ConsistencyBuilder.build(range: week, activities: [], rollups: rollups,
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets[0].wearHours, 16, accuracy: 0.001)
        XCTAssertEqual(s.buckets[1].wearHours, 8, accuracy: 0.001)
        XCTAssertEqual(s.buckets[2].wearHours, 0, accuracy: 0.001)
    }

    func testAverageWearIgnoresDaysWithNoData() {
        let rollups = [rollup(day(2026, 7, 27), wearSeconds: 3600 * 16),
                       rollup(day(2026, 7, 28), wearSeconds: 3600 * 8)]
        let s = ConsistencyBuilder.build(range: week, activities: [], rollups: rollups,
                                         today: day(2026, 7, 28), calendar: cal)
        // 12, not 24/7 — days the strap was off are absent, not zero.
        XCTAssertEqual(s.avgWearHours, 12, accuracy: 0.001)
    }

    func testStreakCountsConsecutivePracticeDays() {
        // Practice on today and the three days before it.
        let acts = (0...3).map { back -> ActivitySpan in
            let d = cal.date(byAdding: .day, value: -back, to: date(2026, 7, 28, 9))!
            return ActivitySpan(startedAt: d, endedAt: d.addingTimeInterval(600))
        }
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.streak.current, 4)
    }

    func testEmptyRangeProducesZeroes() {
        let s = ConsistencyBuilder.build(range: week, activities: [], rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets.count, 7)
        XCTAssertEqual(s.sessionCount, 0)
        XCTAssertEqual(s.avgWearHours, 0, accuracy: 0.001)
        XCTAssertEqual(s.streak.current, 0)
    }
}
```

- [ ] **Step 2: Register the test file**

Four edits per Task 1 Step 2, with `AT35` / `FT35` and `ConsistencySummaryTests.swift`.

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/ConsistencySummaryTests 2>&1 | tail -30
```
Expected: compile failure — `cannot find 'ConsistencyBuilder' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/Wythin/Metrics/ConsistencySummary.swift`:

```swift
import Foundation

/// A value-type view of one `ActivityLog`, so the builder stays pure and
/// testable without a `ModelContext`.
struct ActivitySpan: Equatable {
    let startedAt: Date
    let endedAt:   Date?
}

/// Practice effort and strap coverage for one Track page.
///
/// Wear earns its place beside practice: without it a missing bar in the
/// charts above reads as a physiological event rather than a day the strap
/// was off.
struct ConsistencySummary: Equatable {

    struct Bucket: Identifiable, Equatable {
        let bucket:          TrackBucket
        let practiceMinutes: Double
        let wearHours:       Double

        var id: Date { bucket.start }
    }

    let buckets:              [Bucket]
    let sessionCount:         Int
    let totalPracticeMinutes: Double
    /// Mean over days that have data — days with no rollup are absent, not zero.
    let avgWearHours:         Double
    let streak:               StreakResult
}

enum ConsistencyBuilder {

    /// Practice comes from `ActivityLog`, never `HRVSession`: sessions are
    /// auto-created for background all-day recording, so they measure strap
    /// wear rather than deliberate practice.
    static func build(range: TrackRange, activities: [ActivitySpan],
                      rollups: [DailyRollup], today: Date,
                      calendar cal: Calendar = .current) -> ConsistencySummary {

        // An activity is attributed whole to the day it started on — splitting
        // a session across midnight would report two practices where there was one.
        var minutesByDay: [Date: Double] = [:]
        var practiceDays: Set<Date> = []
        var counted = 0

        for a in activities {
            guard let ended = a.endedAt else { continue }
            let day = cal.startOfDay(for: a.startedAt)
            practiceDays.insert(day)
            guard a.startedAt >= range.start, a.startedAt < range.end else { continue }
            minutesByDay[day, default: 0] += ended.timeIntervalSince(a.startedAt) / 60
            counted += 1
        }

        let wearByDay = Dictionary(uniqueKeysWithValues:
            rollups.map { ($0.day, $0.wearSeconds / 3600) })

        let buckets = range.buckets.map { bucket -> ConsistencySummary.Bucket in
            let days = strideDays(from: bucket.start, to: bucket.end, calendar: cal)
            return ConsistencySummary.Bucket(
                bucket:          bucket,
                practiceMinutes: days.reduce(0) { $0 + (minutesByDay[$1] ?? 0) },
                wearHours:       days.reduce(0) { $0 + (wearByDay[$1] ?? 0) })
        }

        let wornDays = range.days.compactMap { wearByDay[$0] }

        return ConsistencySummary(
            buckets:              buckets,
            sessionCount:         counted,
            totalPracticeMinutes: minutesByDay.values.reduce(0, +),
            avgWearHours:         wornDays.isEmpty
                                    ? 0 : wornDays.reduce(0, +) / Double(wornDays.count),
            streak:               StreakCompute.evaluate(days: practiceDays,
                                                         today: today, calendar: cal))
    }

    private static func strideDays(from start: Date, to end: Date,
                                   calendar cal: Calendar) -> [Date] {
        var out: [Date] = []
        var d = start
        while d < end {
            out.append(d)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}
```

- [ ] **Step 5: Register the implementation file**

Four edits per Task 1 Step 5, with `A245` / `F245`, `ConsistencySummary.swift`, the `GAPP_MET /* Metrics */` group, and the app target's sources phase.

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/ConsistencySummaryTests 2>&1 | tail -30
```
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/ConsistencySummary.swift ios/WythinTests/ConsistencySummaryTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(track): ConsistencySummary — practice minutes and wear coverage"
```

---

### Task 7: Server — macro_trend insight mode

**Files:**
- Modify: `server/models.py:156-190`
- Modify: `server/routers/insights.py:220-240` and `:345-372`
- Test: `server/tests/test_insights.py`

**Interfaces:**
- Consumes: the existing `InsightRequest` / `InsightResponse` models and `get_openai_client` dependency.
- Produces: `POST /insights` accepting `mode: "macro_trend"` with `period`, `range_label`, `trends: dict[str, MacroTrend]`.

- [ ] **Step 1: Write the failing tests**

Append to `server/tests/test_insights.py`:

```python
_MACRO_TREND_PAYLOAD = {
    "mode": "macro_trend",
    "period": "week",
    "range_label": "JUL 27 – AUG 2",
    "trends": {
        "dc": {
            "avg": 8.4, "baseline": 8.2, "delta_pct": 6.0,
            "days_above": 5, "days_total": 7, "direction": "higher",
        },
        "pip": {
            "avg": 52.0, "baseline": 57.0, "delta_pct": 9.0,
            "days_above": 6, "days_total": 7, "direction": "lower",
        },
        "stress_balance": {
            "avg": 44.0, "baseline": 48.0, "delta_pct": 8.0,
            "days_above": 5, "days_total": 7, "direction": "lower",
        },
    },
}


@pytest.mark.asyncio
async def test_macro_trend_success():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="Your recovery markers held steady this week.\n→ Keep the evening breathing."
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_MACRO_TREND_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert "→" in r.json()["text"]


@pytest.mark.asyncio
async def test_macro_trend_requires_trends():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post(
                "/insights",
                json={"mode": "macro_trend", "period": "week", "range_label": "X"},
            )
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_macro_trend_rejects_empty_trends():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post(
                "/insights",
                json={"mode": "macro_trend", "period": "week",
                      "range_label": "X", "trends": {}},
            )
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 422


def test_macro_trend_prompt_uses_friendly_metric_names():
    from server.models import InsightRequest
    from server.routers.insights import _format_macro_trend

    req = InsightRequest(**_MACRO_TREND_PAYLOAD)
    text = _format_macro_trend(req)

    assert "Inner noise" in text                     # not "pip"
    assert "JUL 27 – AUG 2" in text
    assert "5 of 7" in text
    # Stress Balance must not be glossed as a raw LF/HF ratio.
    assert "stress_balance" not in text
    assert "LF/HF" not in text
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd /Users/alexutkin && .venv313/bin/pytest server/tests/test_insights.py -v -k macro_trend
```
Expected: FAIL — `ImportError: cannot import name '_format_macro_trend'`, and the endpoint tests returning 200 (the request falls through to activity mode and 422s on `activity_type`, or errors).

- [ ] **Step 3: Add the request model**

In `server/models.py`, immediately before `class InsightRequest` (line 158), add:

```python
class MacroTrend(BaseModel):
    """One metric's summary over a Track period. All values are computed
    on-device; the model receives them and supplies language only."""
    avg:        float
    baseline:   Optional[float] = None
    # Benefit-signed: positive always means improvement, including for metrics
    # where the raw value fell (Inner Noise, Stress Balance).
    delta_pct:  Optional[float] = None
    days_above: Optional[int] = None
    days_total: Optional[int] = None
    direction:  Optional[str] = None
```

Then inside `InsightRequest`, after the `"day_potential" mode fields` block (after line 188), add:

```python
    # "macro_trend" mode fields
    period:      Optional[str] = None    # "week" | "month" | "six_month"
    range_label: Optional[str] = None
    trends:      Optional[dict[str, MacroTrend]] = None
```

Also update the `mode` field's comment on line 159 to:

```python
    mode: str = "activity"            # "activity" | "live_state" | "day_potential" | "macro_trend"
```

- [ ] **Step 4: Add the metric name, prompt, and formatter**

In `server/routers/insights.py`, add to `_METRIC_NAMES` (after the `"dfa1"` entry, line 239):

```python
    "stress_balance": "Stress balance — breathing-robust 0–100 arousal dial "
                      "(lower = calmer). Not a raw LF/HF ratio; slow paced "
                      "breathing correctly reads as calmer, not more stressed",
```

Then add, after `_format_day_potential` (line 342):

```python
_MACRO_TREND_SYSTEM_PROMPT = (
    "You are an expert physiologist writing the 'macro read' at the top of a "
    "long-term trends screen for a person wearing a chest strap. You are given "
    "each metric's average over the period, the person's own baseline, a "
    "benefit-signed change versus the previous period, and how many buckets "
    "beat the baseline. Every number was computed by the app: never compute, "
    "restate more precisely, or contradict one, and never invent a metric you "
    "were not given.\n\n"
    "Reply in EXACTLY this plain-text structure:\n"
    "Two sentences reading the period as a whole. Name at most three metrics "
    "by their plain-English names. Say what the pattern is, not what each "
    "number was.\n"
    "→ One concrete action for the coming period.\n"
    "→ Optionally one more action.\n\n"
    "delta_pct is benefit-signed: positive always means improvement, including "
    "where the raw value fell. A positive delta on Inner noise or Stress "
    "balance means it went DOWN, which is good — never describe it as a rise.\n"
    "No headings, no bullet characters other than '→', no markdown, no "
    "greeting. Plain, warm, direct. Do not use the words 'HRV', 'RMSSD', "
    "'LF/HF', 'entropy' or 'PIP' — use the plain-English names given."
)


_PERIOD_LABELS = {
    "week":      "this week",
    "month":     "this month",
    "six_month": "these six months",
}


def _format_macro_trend(req: InsightRequest) -> str:
    span = _PERIOD_LABELS.get(req.period or "", "this period")
    unit = "months" if req.period == "six_month" else "days"
    lines = [
        f"Period: {span} ({req.range_label}). Averages are over the "
        f"{unit} in the period; 'vs prior' compares with the previous "
        f"period of the same length."
    ]
    for key, t in (req.trends or {}).items():
        label = _METRIC_NAMES.get(key, key)
        parts = [f"avg={t.avg:.2f}"]
        if t.baseline is not None:
            parts.append(f"baseline={t.baseline:.2f}")
        if t.delta_pct is not None:
            parts.append(f"vs prior={t.delta_pct:+.0f}% (benefit-signed)")
        if t.days_above is not None and t.days_total is not None:
            parts.append(f"{t.days_above} of {t.days_total} {unit} better than baseline")
        lines.append(f"{label}:")
        lines.append("  " + " | ".join(parts))
    return "\n".join(lines)
```

- [ ] **Step 5: Add the endpoint branch**

In `server/routers/insights.py`, inside `generate_insight`, add a branch after the `live_state` branch (after line 370, before the final `else:`):

```python
    elif req.mode == "macro_trend":
        if not req.trends:
            raise HTTPException(status_code=422, detail="trends is required for macro_trend mode")
        system_prompt = _MACRO_TREND_SYSTEM_PROMPT
        user_content = _format_macro_trend(req)
        max_tokens = 180
```

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```bash
cd /Users/alexutkin && .venv313/bin/pytest server/tests/test_insights.py -v
```
Expected: all tests pass, including the four new `macro_trend` cases.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin && git add server/models.py server/routers/insights.py server/tests/test_insights.py
git commit -m "feat(api): macro_trend insight mode for the Track macro read"
```

---

### Task 8: APIClient — macro-trend payload

**Files:**
- Modify: `ios/Wythin/Sync/APIClient.swift` (add near `LiveStateInsightPayload` at line 123, and a method near line 311)
- Test: `ios/WythinTests/PayloadBuilderTests.swift`

**Interfaces:**
- Consumes: `TrackMetricSpec`, `TrackMetrics` (Task 4); `TrackSeries` (Task 5); `TrackPeriod` (Task 3); the existing `APIClient.request(path:method:)` helper and `InsightResponse`.
- Produces:
  - `struct MacroTrendEntry: Codable, Equatable` — `avg, baseline, deltaPct, daysAbove, daysTotal, direction`
  - `struct MacroTrendPayload: Codable` — `mode, period, rangeLabel, trends`, with an `init(period:rangeLabel:series:)` taking `[(spec: TrackMetricSpec, series: TrackSeries)]`
  - `func generateMacroTrendInsight(_ payload: MacroTrendPayload) async throws -> InsightResponse` on `APIClient`

- [ ] **Step 1: Write the failing test**

Append to `ios/WythinTests/PayloadBuilderTests.swift`:

```swift
    // MARK: - MacroTrendPayload

    func testMacroTrendPayloadEncodesSnakeCaseKeys() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let range = TrackRangeBuilder.range(period: .week, offset: 0, today: today)
        let spec  = TrackMetrics.all.first { $0.def.label == "Inner Noise" }!

        let series = TrackSeries(
            bars: [], average: 52, deltaPct: 9, reference: 57,
            referenceIsPersonal: true, overlay: [],
            betterCount: 6, presentCount: 7,
            summary: "6 of 7 days better than your baseline.")

        let payload = MacroTrendPayload(period: .week, rangeLabel: range.label,
                                        series: [(spec, series)])
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(payload)) as! [String: Any]

        XCTAssertEqual(json["mode"] as? String, "macro_trend")
        XCTAssertEqual(json["period"] as? String, "week")
        XCTAssertNotNil(json["range_label"])

        let trends = json["trends"] as! [String: [String: Any]]
        let pip = try XCTUnwrap(trends["pip"])
        XCTAssertEqual(pip["avg"] as? Double, 52)
        XCTAssertEqual(pip["baseline"] as? Double, 57)
        XCTAssertEqual(pip["delta_pct"] as? Double, 9)
        XCTAssertEqual(pip["days_above"] as? Int, 6)
        XCTAssertEqual(pip["days_total"] as? Int, 7)
        XCTAssertEqual(pip["direction"] as? String, "lower")
    }

    func testMacroTrendPayloadSkipsMetricsWithNoAverage() throws {
        let empty = TrackSeries(bars: [], average: nil, deltaPct: nil, reference: 8,
                                referenceIsPersonal: false, overlay: [],
                                betterCount: 0, presentCount: 0,
                                summary: "No data this period.")
        let payload = MacroTrendPayload(
            period: .week, rangeLabel: "X",
            series: [(TrackMetrics.all[0], empty)])
        XCTAssertTrue(payload.trends.isEmpty)
    }

    func testMacroTrendDirectionStrings() throws {
        func direction(_ label: String) -> String? {
            let spec = TrackMetrics.all.first { $0.def.label == label }!
            let s = TrackSeries(bars: [], average: 1, deltaPct: nil, reference: 1,
                                referenceIsPersonal: false, overlay: [],
                                betterCount: 0, presentCount: 1, summary: "")
            return MacroTrendPayload(period: .week, rangeLabel: "X",
                                     series: [(spec, s)]).trends[spec.trendKey]?.direction
        }
        XCTAssertEqual(direction("Vagal Tone"), "higher")
        XCTAssertEqual(direction("Inner Noise"), "lower")
        XCTAssertEqual(direction("Harmony"), "target")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/PayloadBuilderTests 2>&1 | tail -30
```
Expected: compile failure — `cannot find 'MacroTrendPayload' in scope`.

- [ ] **Step 3: Add the payload types**

In `ios/Wythin/Sync/APIClient.swift`, after `LiveStateInsightPayload` (which ends at line 133), add:

```swift
/// One metric's period summary for the macro read. Only aggregate daily means
/// leave the device — never raw samples.
struct MacroTrendEntry: Codable, Equatable {
    let avg:       Double
    let baseline:  Double?
    /// Benefit-signed: positive always means improvement.
    let deltaPct:  Double?
    let daysAbove: Int?
    let daysTotal: Int?
    let direction: String?

    enum CodingKeys: String, CodingKey {
        case avg, baseline, direction
        case deltaPct  = "delta_pct"
        case daysAbove = "days_above"
        case daysTotal = "days_total"
    }
}

struct MacroTrendPayload: Codable {
    let mode:       String
    let period:     String
    let rangeLabel: String
    let trends:     [String: MacroTrendEntry]

    enum CodingKeys: String, CodingKey {
        case mode, period, trends
        case rangeLabel = "range_label"
    }

    /// Metrics with no data for the period are omitted rather than sent as
    /// nulls — the model must never be asked to narrate an absent metric.
    init(period: TrackPeriod, rangeLabel: String,
         series: [(spec: TrackMetricSpec, series: TrackSeries)]) {
        self.mode       = "macro_trend"
        self.period     = period.apiValue
        self.rangeLabel = rangeLabel
        self.trends = Dictionary(uniqueKeysWithValues: series.compactMap { pair in
            guard let avg = pair.series.average else { return nil }
            return (pair.spec.trendKey, MacroTrendEntry(
                avg:       avg,
                baseline:  pair.series.reference,
                deltaPct:  pair.series.deltaPct,
                daysAbove: pair.series.betterCount,
                daysTotal: pair.series.presentCount,
                direction: pair.spec.def.direction.apiValue))
        })
    }
}

extension BenefitDirection {
    /// Wire value for the macro-read payload.
    var apiValue: String {
        switch self {
        case .higher: return "higher"
        case .lower:  return "lower"
        case .target: return "target"
        }
    }
}
```

- [ ] **Step 4: Add the client method**

In `ios/Wythin/Sync/APIClient.swift`, after `generateLiveStateInsight` (which ends around line 318), add:

```swift
    func generateMacroTrendInsight(_ payload: MacroTrendPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(InsightResponse.self, from: data)
    }
```

This mirrors `generateLiveStateInsight` (`APIClient.swift:311-316`) exactly, including its use of the struct's private `session` rather than `URLSession.shared` and its reliance on the JSON decode to fail on an error response. Do not add a status-code check here — that would make this one method behave differently from its three siblings.

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/PayloadBuilderTests 2>&1 | tail -30
```
Expected: all `PayloadBuilderTests` pass, including the three new cases.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Sync/APIClient.swift ios/WythinTests/PayloadBuilderTests.swift
git commit -m "feat(track): MacroTrendPayload and generateMacroTrendInsight"
```

---

### Task 9: TrackPeriodBar and MacroReadCard

**Files:**
- Create: `ios/Wythin/UI/Track/TrackPeriodBar.swift`
- Create: `ios/Wythin/UI/Track/MacroReadCard.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `TrackPeriod`, `TrackRange` (Task 3); `TrackCache` (Task 2); `MacroTrendPayload` (Task 8); `Theme`.
- Produces:
  - `struct TrackPeriodBar: View` — `init(period: Binding<TrackPeriod>, offset: Binding<Int>, label: String)`
  - `struct MacroReadCard: View` — `init(text: String?, isLoading: Bool)`
  - `@MainActor func macroRead(for:range:series:cache:client:) async -> String?` — a free function in `MacroReadCard.swift` that returns cached text or fetches and caches it.

No unit tests: this codebase has no test coverage for SwiftUI views. Verification is build success plus the Simulator check in Task 12.

- [ ] **Step 1: Create the period bar**

Create `ios/Wythin/UI/Track/TrackPeriodBar.swift`:

```swift
import SwiftUI

/// W · M · 6M toggle plus the `‹ range ›` navigator. Changing the period
/// resets paging to the current page — carrying an offset across periods
/// would silently jump the user months away.
struct TrackPeriodBar: View {
    @Binding var period: TrackPeriod
    @Binding var offset: Int
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Spacer()
                ForEach(TrackPeriod.allCases) { p in
                    Button(p.rawValue) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            period = p
                            offset = 0
                        }
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(p == period ? Color.black : Theme.dim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(p == period ? Theme.accent : Color.clear)
                    .clipShape(Capsule())
                }
            }

            HStack {
                arrow("chevron.left", enabled: true) { offset += 1 }
                Spacer()
                Text(label)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.text)
                Spacer()
                arrow("chevron.right", enabled: offset > 0) { offset -= 1 }
            }
        }
        .padding(.horizontal)
    }

    private func arrow(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.dim.opacity(0.3))
                .frame(width: 32, height: 28)
        }
        .disabled(!enabled)
    }
}
```

- [ ] **Step 2: Create the macro read card**

Create `ios/Wythin/UI/Track/MacroReadCard.swift`:

```swift
import SwiftUI

/// Two sentences of LLM read plus one or two `→` actions. Absent entirely on
/// failure — a broken insight is not worth an error message at the top of the
/// screen.
struct MacroReadCard: View {
    let text: String?
    let isLoading: Bool

    var body: some View {
        if isLoading {
            VStack(alignment: .leading, spacing: 8) {
                header
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.surface)
                        .frame(height: 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .padding(.horizontal)
        } else if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header
                ForEach(Array(lines(text).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(line.hasPrefix("→") ? Theme.monoLabel : Theme.monoBody)
                        .foregroundStyle(line.hasPrefix("→") ? Theme.accent : Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .padding(.horizontal)
        }
    }

    private var header: some View {
        Text("MACRO READ")
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.dim)
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Cached text for this page, or a fresh call. Returns nil on any failure so
/// the card simply does not render; the next appear retries.
///
/// The cache key includes a fingerprint of the page's rollup *values*, so
/// paging back to a past period is free while a period whose data actually
/// changed regenerates.
@MainActor
func macroRead(for period: TrackPeriod,
               range: TrackRange,
               series: [(spec: TrackMetricSpec, series: TrackSeries)],
               cache: TrackCache,
               client: APIClient) async -> String? {
    let key = "\(period.apiValue)|\(range.start.timeIntervalSince1970)|\(cache.fingerprint(for: range.days))"
    if let cached = cache.macroRead(key: key) { return cached }

    let payload = MacroTrendPayload(period: period, rangeLabel: range.label, series: series)
    guard !payload.trends.isEmpty,
          let response = try? await client.generateMacroTrendInsight(payload) else { return nil }

    cache.setMacroRead(response.text, key: key)
    return response.text
}
```

- [ ] **Step 3: Register both files in the Xcode project**

First add a `Track` group. In the `PBXGroup` section, beside `GAPP_HIS /* History */` (line 333), add:

```
		GAPP_TRK /* Track */ = {
			isa = PBXGroup;
			children = (
				F246 /* TrackPeriodBar.swift */,
				F247 /* MacroReadCard.swift */,
			);
			path = Track;
			sourceTree = "<group>";
		};
```

Add `GAPP_TRK /* Track */,` to the `GAPP_UI /* UI */` group's `children` array (line 460-470). Then add the usual `PBXBuildFile` / `PBXFileReference` / app sources-phase entries for `A246`/`F246` (`TrackPeriodBar.swift`) and `A247`/`F247` (`MacroReadCard.swift`).

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/UI/Track ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(track): period bar and macro read card"
```

---

### Task 10: TrackMetricChartCard

**Files:**
- Create: `ios/Wythin/UI/Track/TrackMetricChartCard.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `TrackMetricSpec` (Task 4); `TrackSeries`, `TrackBar`, `TrackOverlaySegment` (Task 5); `TrackPeriod`, `TrackBucket` (Task 3); `Theme`.
- Produces: `struct TrackMetricChartCard: View` — `init(spec: TrackMetricSpec, series: TrackSeries, period: TrackPeriod, selectedBucket: Binding<Date?>)`

- [ ] **Step 1: Create the card**

Create `ios/Wythin/UI/Track/TrackMetricChartCard.swift`:

```swift
import SwiftUI
import Charts

/// One metric's bar chart for one page: header average, benefit-signed delta,
/// bars with their values printed on top, and the personal reference line.
struct TrackMetricChartCard: View {
    let spec:   TrackMetricSpec
    let series: TrackSeries
    let period: TrackPeriod
    @Binding var selectedBucket: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            chart
            footer
        }
        .cardStyle()
        .padding(.horizontal)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spec.def.label.uppercased())
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.text)
                    Text(spec.def.techLabel)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
                deltaChip
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(spec.def.format(headerValue))
                        .font(Theme.mono(20))
                        .foregroundStyle(spec.color)
                    if !spec.def.unit.isEmpty {
                        Text(spec.def.unit)
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                    }
                }
                Text(headerCaption)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    /// The selected bar's value when a bar is tapped, otherwise the average.
    private var headerValue: Double? {
        if let sel = selectedBucket,
           let bar = series.bars.first(where: { $0.bucket.start == sel }) {
            return bar.value
        }
        return series.average
    }

    private var headerCaption: String {
        if let sel = selectedBucket,
           let bar = series.bars.first(where: { $0.bucket.start == sel }) {
            return captionFormatter.string(from: bar.bucket.start).uppercased()
        }
        return "AVERAGE"
    }

    private var captionFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = period == .sixMonth ? "MMM yyyy" : "EEE d MMM"
        return f
    }

    @ViewBuilder
    private var deltaChip: some View {
        if let d = series.deltaPct {
            let better = d >= 0
            Text("\(better ? "▲" : "▼") \(abs(d), specifier: "%.0f")% vs prior \(period.priorNoun)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(better ? Theme.accent : Theme.warn)
        }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            RuleMark(y: .value("reference", series.reference))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(Theme.dim.opacity(0.6))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(series.referenceIsPersonal ? "your 90d" : "typical")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.8))
                }

            ForEach(series.bars) { bar in
                if let v = bar.value {
                    BarMark(
                        x: .value("Bucket", bar.bucket.start, unit: xUnit),
                        y: .value(spec.def.label, v),
                        width: .ratio(0.6)
                    )
                    .cornerRadius(2)
                    .foregroundStyle(barColor(bar, value: v))
                    .annotation(position: .top, spacing: 2) {
                        if labelledBuckets.contains(bar.bucket.start) {
                            Text(spec.def.format(v))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }

            // Month view only: weekly averages as short rules, so ~30 bars stay
            // legible without a number on every one.
            ForEach(series.overlay) { seg in
                RuleMark(
                    xStart: .value("start", seg.start),
                    xEnd:   .value("end", seg.end),
                    y:      .value("weekly", seg.value)
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(spec.color)
                .annotation(position: .top, spacing: 1) {
                    Text(spec.def.format(seg.value))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(spec.color)
                }
            }
        }
        .frame(height: 132)
        .chartYScale(domain: yDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: series.bars.map(\.bucket.start)) { value in
                if let d = value.as(Date.self),
                   let bar = series.bars.first(where: { $0.bucket.start == d }),
                   showAxisLabel(bar) {
                    AxisValueLabel {
                        Text(bar.value == nil ? "·" : bar.bucket.label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedBucket },
            set: { newValue in
                guard let d = newValue,
                      let nearest = series.bars.min(by: {
                          abs($0.bucket.start.timeIntervalSince(d))
                              < abs($1.bucket.start.timeIntervalSince(d))
                      }) else { selectedBucket = nil; return }
                selectedBucket = nearest.bucket.start
            }))
        .chartPlotStyle { $0.background(Color.black.opacity(0.2)) }
    }

    private var xUnit: Calendar.Component { period == .sixMonth ? .month : .day }

    private func barColor(_ bar: TrackBar, value: Double) -> Color {
        if selectedBucket == bar.bucket.start { return spec.color }
        // Days that beat the reference stay bright; the rest recede so the
        // line reads at a glance.
        let better = spec.def.direction.benefit(value) > spec.def.direction.benefit(series.reference)
        return spec.color.opacity(better ? 0.9 : 0.45)
    }

    /// W and 6M label every bar. M would need ~30 numbers across ~350pt, so it
    /// labels only the extremes and the most recent, and leans on the weekly
    /// overlay for the rest.
    private var labelledBuckets: Set<Date> {
        let present = series.bars.filter { $0.value != nil }
        guard period == .month else { return Set(present.map(\.bucket.start)) }
        var keep = Set<Date>()
        if let lo = present.min(by: { $0.value! < $1.value! }) { keep.insert(lo.bucket.start) }
        if let hi = present.max(by: { $0.value! < $1.value! }) { keep.insert(hi.bucket.start) }
        if let last = present.last { keep.insert(last.bucket.start) }
        return keep
    }

    private func showAxisLabel(_ bar: TrackBar) -> Bool {
        guard period == .month else { return true }
        // Every fifth day, so a 31-day axis stays readable.
        return Calendar.current.component(.day, from: bar.bucket.start) % 5 == 1
    }

    private var yDomain: ClosedRange<Double> {
        let values = series.bars.compactMap(\.value) + [series.reference]
        let hi = values.max() ?? 1
        let lo = values.min() ?? 0

        if spec.zeroBased {
            // Headroom so the value annotations are not clipped.
            return 0...(hi * 1.25)
        }
        // Index metrics hover in a narrow band; anchoring on the observed
        // spread keeps the differences visible instead of flattening them.
        let spread = max(hi - lo, abs(series.reference) * 0.1)
        return (lo - spread * 0.3)...(hi + spread * 0.6)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(series.summary)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.text.opacity(0.85))
            Text(spec.def.why)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension TrackPeriod {
    /// "vs prior week" / "vs prior month" / "vs prior 6 months"
    var priorNoun: String {
        switch self {
        case .week:     return "week"
        case .month:    return "month"
        case .sixMonth: return "6 months"
        }
    }
}
```

- [ ] **Step 2: Register the file**

Add `A248`/`F248` for `TrackMetricChartCard.swift`: `PBXBuildFile` entry, `PBXFileReference` entry, `F248 /* TrackMetricChartCard.swift */,` in the `GAPP_TRK /* Track */` group, and `A248 /* TrackMetricChartCard.swift in Sources */,` in the app sources phase.

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/UI/Track/TrackMetricChartCard.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(track): bar chart card with value labels and reference line"
```

---

### Task 11: ConsistencyCard

**Files:**
- Create: `ios/Wythin/UI/Track/ConsistencyCard.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ConsistencySummary` (Task 6); `TrackPeriod` (Task 3); `Theme`.
- Produces: `struct ConsistencyCard: View` — `init(summary: ConsistencySummary, period: TrackPeriod)`

- [ ] **Step 1: Create the card**

Create `ios/Wythin/UI/Track/ConsistencyCard.swift`:

```swift
import SwiftUI
import Charts

/// Practice effort and strap coverage for the period. Wear sits beside
/// practice because it explains gaps in the charts above: without it a missing
/// bar reads as a physiological event rather than a day the strap was off.
struct ConsistencyCard: View {
    let summary: ConsistencySummary
    let period:  TrackPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CONSISTENCY")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            row(title: "PRACTICE",
                stats: practiceStats,
                values: summary.buckets.map(\.practiceMinutes),
                color: Theme.accent,
                format: { $0 < 1 ? "" : String(format: "%.0f", $0) })

            row(title: "WEAR",
                stats: String(format: "avg %.1f h/day", summary.avgWearHours),
                values: summary.buckets.map(\.wearHours),
                color: Theme.hrv,
                format: { $0 < 0.5 ? "" : String(format: "%.0f", $0) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .padding(.horizontal)
    }

    private var practiceStats: String {
        let sessions = "\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")"
        let minutes  = String(format: "%.0f min", summary.totalPracticeMinutes)
        let streak   = summary.streak.current > 0 ? "  🔥 \(summary.streak.current)d" : ""
        return "\(sessions)   \(minutes)\(streak)"
    }

    private func row(title: String, stats: String, values: [Double],
                     color: Color, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(stats)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            Chart {
                ForEach(Array(zip(summary.buckets, values)), id: \.0.id) { bucket, value in
                    BarMark(
                        x: .value("Bucket", bucket.bucket.start, unit: xUnit),
                        y: .value(title, value),
                        width: .ratio(0.6)
                    )
                    .cornerRadius(2)
                    .foregroundStyle(value > 0 ? color.opacity(0.85) : Theme.surface)
                    .annotation(position: .top, spacing: 1) {
                        if showLabels {
                            Text(format(value))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .frame(height: 54)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: summary.buckets.map(\.bucket.start)) { value in
                    if let d = value.as(Date.self),
                       let b = summary.buckets.first(where: { $0.bucket.start == d }),
                       showAxisLabel(b.bucket.start) {
                        AxisValueLabel {
                            Text(b.bucket.label)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
        }
    }

    private var xUnit: Calendar.Component { period == .sixMonth ? .month : .day }

    /// Thirty labels do not fit across a phone; the month view drops them.
    private var showLabels: Bool { period != .month }

    private func showAxisLabel(_ d: Date) -> Bool {
        guard period == .month else { return true }
        return Calendar.current.component(.day, from: d) % 5 == 1
    }
}
```

- [ ] **Step 2: Register the file**

Add `A249`/`F249` for `ConsistencyCard.swift` — four edits, `GAPP_TRK /* Track */` group, app sources phase.

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/UI/Track/ConsistencyCard.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(track): consistency card — practice minutes and wear coverage"
```

---

### Task 12: TrackView, wiring, and removing HistoryView

**Files:**
- Create: `ios/Wythin/UI/Track/TrackView.swift`
- Modify: `ios/Wythin/App/WythinApp.swift:103`
- Modify: `ios/Wythin/UI/Train/PracticeHubView.swift:26-72`
- Modify: `ios/Wythin/UI/Live/HRVRingView.swift:46-129`
- Delete: `ios/Wythin/UI/History/HistoryView.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: everything from Tasks 1–11, plus `HRVSample`, `ActivityLog`, `TrainSession`, `AppEnvironment`, `APIConfig`.
- Produces: `struct TrackView: View` (no arguments), replacing `HistoryView`.

- [ ] **Step 1: Create the screen**

Create `ios/Wythin/UI/Track/TrackView.swift`:

```swift
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
        .task(id: "\(period.rawValue)-\(offset)") {
            selectedBucket = nil
            await loadRollups()
            await loadMacroRead()
        }
    }

    // MARK: Data

    /// Fills any uncached day in the visible page, plus a 90-day tail so the
    /// personal baseline has data behind it, then reads the page back out.
    private func loadRollups() async {
        isLoading = rollups.isEmpty
        cache.load()

        let cal = Calendar.current
        let baselineStart = cal.date(byAdding: .day,
                                     value: -TrackSeriesBuilder.baselineWindowDays,
                                     to: today) ?? range.start
        let needed = TrackRange(period: period, offset: offset,
                                start: min(range.start, baselineStart),
                                end: range.end, buckets: [], label: "").days

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

        let lastDay = cal.date(byAdding: .day, value: -1, to: range.end) ?? range.end
        rollups = cache.rollups(in: min(range.start, baselineStart)...max(lastDay, today))
        isLoading = false
    }

    private func loadMacroRead() async {
        macroText = nil
        // Same consent gate the uploaders read (AppEnvironment.swift:291);
        // defaults to on when the key was never written.
        guard UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true else { return }
        macroLoading = true
        defer { macroLoading = false }
        macroText = await macroRead(for: period, range: range, series: seriesList,
                                    cache: cache,
                                    client: APIClient(baseURL: env.serverURL))
    }
}
```

Two details this depends on, both already verified: `APIClient` is a struct with a single stored `baseURL` (`APIClient.swift:207-208`) and is constructed as `APIClient(baseURL:)` in `SyncService.swift:24`. `AppEnvironment.serverURL` (`AppEnvironment.swift:95-100`) is the user-configurable base URL. `APIConfig` holds only `apiKey`, not a base URL — do not reach for it here.

- [ ] **Step 2: Route the tab to TrackView**

In `ios/Wythin/App/WythinApp.swift`, line 103, replace:

```swift
            HistoryView()
                .tag(AppTab.track)
```

with:

```swift
            TrackView()
                .tag(AppTab.track)
```

- [ ] **Step 3: Move the train session list to the Practice tab**

Cut the `TrainSessionRow` struct verbatim from `ios/Wythin/UI/History/HistoryView.swift:599-645` and paste it at the end of `ios/Wythin/UI/Train/PracticeHubView.swift`, changing `private struct TrainSessionRow` to `private struct TrainSessionRow` (it is already private and stays so).

In `PracticeHubView`, add the query near the other properties:

```swift
    @Query(sort: \TrainSession.startedAt, order: .reverse) private var trainSessions: [TrainSession]
```

Add `import SwiftData` at the top of the file if it is not already there. Then add this computed property to `PracticeHubView`:

```swift
    // MARK: Train history

    @ViewBuilder
    private var trainHistory: some View {
        if !trainSessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("HISTORY")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                VStack(spacing: 0) {
                    ForEach(trainSessions) { session in
                        TrainSessionRow(session: session)
                        if session.id != trainSessions.last?.id {
                            Divider().background(Theme.border).padding(.horizontal, 12)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }
```

And render it in the body, immediately after `teachersStrip` (line 47):

```swift
                    teachersStrip

                    trainHistory
```

- [ ] **Step 4: Delete HistoryView and its now-dead dependency**

```bash
cd /Users/alexutkin && rm ios/Wythin/UI/History/HistoryView.swift
```

`HRVRingGrid` (`ios/Wythin/UI/Live/HRVRingView.swift:46-129`) existed only for the NOW section. Confirm it is unused and remove it:

```bash
cd /Users/alexutkin && grep -rn "HRVRingGrid" ios/Wythin --include="*.swift"
```
Expected: only the definition at `HRVRingView.swift:46`. If so, delete lines 44-129 (the `// MARK:` comment through the closing brace of `HRVRingGrid`), keeping `HRVRingView` above it. If the grep shows another consumer, leave it alone.

- [ ] **Step 5: Update the Xcode project**

1. Add `A250`/`F250` for `TrackView.swift` — four edits, `GAPP_TRK /* Track */` group, app sources phase.
2. Remove all four `HistoryView.swift` entries: `A125 /* HistoryView.swift in Sources */ = ...` (line 35), `F125 /* HistoryView.swift */ = ...` (line 156), `F125 /* HistoryView.swift */,` in the `GAPP_HIS` group children (line 336), and `A125 /* HistoryView.swift in Sources */,` in the app sources phase (line 695).
3. Remove the now-empty `GAPP_HIS /* History */` group definition (lines 333-339) and its reference in the `GAPP_UI` children array (line 470).

```bash
cd /Users/alexutkin && rmdir ios/Wythin/UI/History
```

- [ ] **Step 6: Build**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Run the whole test suite**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
cd /Users/alexutkin && .venv313/bin/pytest server/tests/ -q
```
Expected: both green. Nothing referenced `TrackTab`, `TrackWindow`, `TrackMetric` or `DailySummary` outside the deleted file, so no test should need updating — if one fails, fix the reference rather than deleting the assertion.

- [ ] **Step 8: Verify in the Simulator**

Launch the app and confirm, on the Track tab:

1. No NOW rings, no HRV/TRAIN tabs, no HRV session list.
2. `W · M · 6M` toggle switches periods; `‹ ›` pages; the forward arrow is disabled on the current page; horizontal swipe pages too.
3. W shows 7 bars with a number on each; M shows daily bars with weekly-average rules and only min/max/latest numbered; 6M shows 6 monthly bars.
4. Each card shows the period average, a benefit-signed delta, a dashed reference line labelled `your 90d` or `typical`, the "N of M … better than …" line, and the `why` copy.
5. Tapping a bar updates that card's header **and** highlights the same bucket on every other card.
6. The macro read card appears above the charts (or is absent, with no error, if the request failed).
7. The consistency card shows practice and wear rows.
8. The Practice tab shows a HISTORY section with train sessions.

Note any visual issues rather than fixing them silently — the layout numbers (bar widths, label thresholds) are the parts most likely to need a pass on a real device.

- [ ] **Step 9: Commit**

```bash
cd /Users/alexutkin && git add -A ios/
git commit -m "feat(track): macro trends screen replaces HistoryView

Track is now period-paged (W/M/6M) bar charts of seven key metrics against
the user's own 90-day baseline, with an LLM macro read and a consistency
card. Removes the NOW rings, the HRV/TRAIN tabs, and the HRV session list;
train history moves to the Practice tab.

Fixes a silent truncation bug: the old screen fetched raw HRVSamples with an
ascending sort and a 200k row limit, so 30D and 90D rendered only the oldest
~4.6 days of their window."
```

---

## Self-Review

**Spec coverage**

| Spec requirement | Task |
|---|---|
| Fix the 200k ascending-fetch truncation | 12 (day-scoped fetch), 2 (cache) |
| `DailyRollup` fields, quality gate, wear seconds | 1 |
| Stress Balance derived per tick from `AutonomicCompute` | 1 |
| JSON cache in Application Support, not SwiftData | 2 |
| Incremental refresh; today recomputed, past days immutable | 2 |
| Corrupt cache rebuilds silently | 2 |
| Value-hash fingerprint, not a write counter | 2 |
| W / M / 6M periods, paging, swipe | 3, 9, 12 |
| Unweighted mean-of-day-means for monthly bars | 5 |
| Month with <5 valid days suppressed | 5 |
| 90-day median baseline, fallback below 14 days | 5 |
| 7 metrics excluding Pulse and Calm Power, in order | 4 |
| Benefit-signed delta vs prior period | 5 |
| Bars with values on top, no y-axis | 10 |
| Zero-based vs baseline-anchored y-domain | 4 (flag), 10 (domain) |
| Reference line labelled `your 90d` / `typical` | 5, 10 |
| Cross-chart shared selection | 10, 12 |
| Computed summary line + `why` copy below each chart | 5, 10 |
| M-view label density + weekly overlay | 5 (overlay), 10 (labels) |
| Consistency card: practice from `ActivityLog`, wear, streak | 6, 11 |
| `macro_trend` insight mode, `stress_balance` metric name | 7 |
| Aggregates only leave the device | 7 (test), 8 (payload) |
| Macro read cached by period + range + fingerprint | 9 |
| Macro read failure hides the card silently | 9 |
| Train sessions move to `PracticeHubView` | 12 |
| `HistoryView` deleted with its private types | 12 |

**Placeholder scan:** no TBDs, no "add error handling", no "similar to Task N". Two steps (Task 12 Step 1, Task 8 Step 4) explicitly instruct verifying an existing signature before adapting — that is a real instruction with a command attached, not a placeholder.

**Type consistency:** `TrackSeries` is constructed in Task 5 and consumed with identical field names in Tasks 8, 10 and 12. `TrackBar.bucket.start` is the selection key throughout. `spec.def.format` / `spec.def.direction` / `spec.def.why` match `ActivityMetricDef`'s real members. `TrackCache.refresh(days:today:fetchDay:)` is declared in Task 2 and called with those labels in Task 12. `BenefitDirection.apiValue` is added in Task 8 and used only there.

**Gap found and closed during review:** the baseline needs 90 days of rollups but a W page covers 7, so Task 12's `loadRollups` deliberately refreshes a 90-day tail rather than only the visible range — otherwise every reference line would silently fall back to `typical`.
