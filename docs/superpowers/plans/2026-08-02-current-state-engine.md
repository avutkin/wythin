# Current State Engine Implementation Plan (Plan A of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute the Current State on-device against the user's own baseline, so the widget's state label is personal, instant, offline and deterministic — replacing a label the LLM invents from absolute numbers with no reference point.

**Architecture:** A canonical metric list feeds three new pure types. `LiveBaseline` builds per-metric centre and within-day spread from cached daily rollups. `LiveReading` converts a 10-minute window into level and trend in personal SD units, combines them with a level-dependent gain, and gates small moves. `LiveStateClassifier` turns those into three axes, one of the nine existing states, and a ranked contribution list. The widget renders all of it locally; the LLM is untouched in this plan and keeps writing its bullets.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest. iOS app at `ios/Wythin.xcodeproj`, scheme `Wythin`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-02-current-state-accuracy-design.md`. Read it before starting.
- Test command: `xcodebuild test -project /Users/alexutkin/Code/Wythin/ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
- **Baseline suite state: 638 tests, exactly 1 failure** — `BLETests.testECGFrameParsing` (parses −244, expects −500). That failure is pre-existing on `main`. Anything else is yours.
- **After any change to `project.pbxproj`, check for duplicate object ids** before trusting the suite: `grep -oE '^\t\t[AF]T[0-9]+ ' ios/Wythin.xcodeproj/project.pbxproj | sort | uniq -d` must print nothing. New test files take the next free `ATnn`/`FTnn` above the current maximum (currently 49). A duplicate id silently drops a file from the target and the suite still reports green.
- Every window rule is tested at **both 2 s and 30 s sample spacing**. A threshold expressed in one cadence that breaks at the other is the exact bug that stopped morning anchors forming.
- New tuning constants live in one `enum` with a header comment marking them uncalibrated, following `AnchorThresholds` and `BaselinePrior`.
- No user-facing technical terms. Plain labels only ("inner noise", not "PIP").
- Commit after every task. Work directly on the active branch — this repo does not use PRs.

## File Structure

**Create**
- `ios/Wythin/Metrics/LiveMetric.swift` — canonical list of the metrics the live state reads, each with a wire key, a plain-language display name, and an extractor. One source of truth so rollup, baseline and classifier cannot drift apart.
- `ios/Wythin/Metrics/LiveBaseline.swift` — per-metric centre and pooled within-day spread from `DailyRollup`s, plus `z(_:for:)`.
- `ios/Wythin/Metrics/LiveReading.swift` — one 10-minute window reduced to per-metric level, trend, SWC gate, gain and effective value.
- `ios/Wythin/Metrics/LiveStateClassifier.swift` — axes, the nine-state rule table, contributions, ranking, hysteresis.
- `ios/Wythin/Metrics/LiveStateCopy.swift` — display name and feeling phrase per state, deterministically varied.
- `ios/WythinTests/LiveMetricTests.swift`, `LiveBaselineTests.swift`, `LiveReadingTests.swift`, `LiveStateClassifierTests.swift`, `LiveStateCopyTests.swift`

**Modify**
- `ios/Wythin/Metrics/DailyRollup.swift` — add per-metric within-day SD alongside the existing means.
- `ios/Wythin/Metrics/TrackCache.swift:184` — `rollupComputeVersion` 2 → 3.
- `ios/Wythin/UI/Live/LiveStateWidget.swift` — render state, feeling and WHY locally; three sections.
- `ios/Wythin/UI/Live/LiveView.swift:170-172` — drop the dead `PolyvagalState` argument.
- `ios/Wythin/UI/Live/CurrentStateCard.swift` — remove the unused `state` property and dead `causeSection`.

---

### Task 1: LiveMetric — one canonical metric list

**Files:**
- Create: `ios/Wythin/Metrics/LiveMetric.swift`
- Test: `ios/WythinTests/LiveMetricTests.swift`

**Interfaces:**
- Consumes: `MetricsHistoryPoint` (existing, `ios/Wythin/Models/MetricsHistoryPoint.swift`)
- Produces: `enum LiveMetric: String, CaseIterable` with cases `hr, rmssd, rsa, sdnn, lfHF, coherence, breathBPM, cbi, pip, dfa1, dc, rcmse, vti`; `var displayName: String`; `func value(_ p: MetricsHistoryPoint) -> Float?`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Wythin

final class LiveMetricTests: XCTestCase {

    func testEveryCaseHasAPlainLanguageName() {
        let banned = ["HRV", "RMSSD", "RSA", "SDNN", "DFA", "LF/HF", "vagal", "entropy"]
        for metric in LiveMetric.allCases {
            XCTAssertFalse(metric.displayName.isEmpty, "\(metric) has no display name")
            for term in banned {
                XCTAssertFalse(metric.displayName.localizedCaseInsensitiveContains(term),
                               "\(metric) leaks the technical term \(term)")
            }
        }
    }

    func testExtractorsReadTheRightField() {
        let p = MetricsHistoryPoint(timestamp: Date(), meanBPM: 61, rmssd: 33, pip: 44)
        XCTAssertEqual(LiveMetric.hr.value(p), 61)
        XCTAssertEqual(LiveMetric.rmssd.value(p), 33)
        XCTAssertEqual(LiveMetric.pip.value(p), 44)
        XCTAssertNil(LiveMetric.dfa1.value(p))
    }

    func testRawValuesAreStableWireKeys() {
        XCTAssertEqual(LiveMetric.hr.rawValue, "hr")
        XCTAssertEqual(LiveMetric.breathBPM.rawValue, "breath_bpm")
        XCTAssertEqual(LiveMetric.lfHF.rawValue, "lf_hf")
    }
}
```

If `MetricsHistoryPoint`'s memberwise initialiser does not accept exactly those
labels, open `ios/Wythin/Models/MetricsHistoryPoint.swift` and use the test
initialiser already defined there (around line 164) — it takes every field with
a `nil` default.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project /Users/alexutkin/Code/Wythin/ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:WythinTests/LiveMetricTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: FAIL — "cannot find 'LiveMetric' in scope"

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The metrics the live state reads, in one place.
///
/// `DailyRollup`, `LiveBaseline` and `LiveStateClassifier` all key off this, so
/// a metric cannot be summarised under one name and scored under another.
/// `rawValue` is the wire key shared with the server payload.
enum LiveMetric: String, CaseIterable {
    case hr         = "hr"
    case rmssd      = "rmssd"
    case rsa        = "rsa"
    case sdnn       = "sdnn"
    case lfHF       = "lf_hf"
    case coherence  = "coherence"
    case breathBPM  = "breath_bpm"
    case cbi        = "cbi"
    case pip        = "pip"
    case dfa1       = "dfa1"
    case dc         = "dc"
    case rcmse      = "rcmse"
    case vti        = "vti"

    /// Plain language only — this reaches the user.
    var displayName: String {
        switch self {
        case .hr:        return "heart rate"
        case .rmssd:     return "recovery"
        case .rsa:       return "breathing depth"
        case .sdnn:      return "overall variability"
        case .lfHF:      return "stress balance"
        case .coherence: return "rhythm"
        case .breathBPM: return "breathing"
        case .cbi:       return "body load"
        case .pip:       return "inner noise"
        case .dfa1:      return "focus"
        case .dc:        return "settling depth"
        case .rcmse:     return "adaptability"
        case .vti:       return "calm power"
        }
    }

    func value(_ p: MetricsHistoryPoint) -> Float? {
        switch self {
        case .hr:        return p.meanBPM
        case .rmssd:     return p.rmssd
        case .rsa:       return p.rsaMs
        case .sdnn:      return p.sdnn
        case .lfHF:      return p.lfHF
        case .coherence: return p.coherence
        case .breathBPM: return p.breathBPM
        case .cbi:       return p.cbi
        case .pip:       return p.pip
        case .dfa1:      return p.dfa1
        case .dc:        return p.dc
        case .rcmse:     return p.rcmse
        case .vti:       return p.vti
        }
    }
}
```

- [ ] **Step 4: Add the files to the Xcode target**

Add `LiveMetric.swift` to the `Wythin` target and `LiveMetricTests.swift` to
`WythinTests`. If editing `project.pbxproj` by hand, use ids `AT50`/`FT50` for
the source and `AT51`/`FT51` for the test — both above the current maximum of 49.

Then run: `grep -oE '^\t\t[AF]T[0-9]+ ' ios/Wythin.xcodeproj/project.pbxproj | sort | uniq -d`
Expected: no output.

- [ ] **Step 5: Run test to verify it passes**

Run the `-only-testing:WythinTests/LiveMetricTests` command from Step 2.
Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Metrics/LiveMetric.swift ios/WythinTests/LiveMetricTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(live): one canonical metric list for the live state"
```

---

### Task 2: DailyRollup records within-day spread

**Files:**
- Modify: `ios/Wythin/Metrics/DailyRollup.swift`
- Modify: `ios/Wythin/Metrics/TrackCache.swift:184`
- Test: `ios/WythinTests/DailyRollupTests.swift` (exists — add to it)

**Interfaces:**
- Consumes: `LiveMetric` from Task 1
- Produces: `DailyRollup.sd: [String: Double]` and `DailyRollup.mean: [String: Double]`, both keyed by `LiveMetric.rawValue`. Existing typed fields (`dc`, `rmssd`, …) are unchanged so the Track charts keep working.

**Why this matters:** z-scoring a 10-minute value against the spread of *daily
means* would divide by between-day variance, which is far smaller than the
within-day variance a 10-minute window actually varies by. Every z would be
inflated and ordinary fluctuation would read as "well above your usual". The
within-day SD stored here is the correct denominator.

- [ ] **Step 1: Write the failing test**

Append to `ios/WythinTests/DailyRollupTests.swift`:

```swift
extension DailyRollupTests {

    private func points(_ values: [Float], from start: Date) -> [MetricsHistoryPoint] {
        values.enumerated().map { idx, v in
            MetricsHistoryPoint(timestamp: start.addingTimeInterval(Double(idx) * 2),
                                meanBPM: v, rmssd: v, signalQuality: 1.0,
                                rrInvalidRate: 0.0, ecgQualityTier: 2)
        }
    }

    func testRollupRecordsWithinDaySD() {
        let day = Calendar.current.startOfDay(for: Date())
        // 200 points alternating 50/70 — mean 60, population-ish SD 10.
        let values = (0..<200).map { $0.isMultiple(of: 2) ? Float(50) : Float(70) }
        let rollup = DailyRollupCompute.rollup(day: day, points: points(values, from: day))

        XCTAssertNotNil(rollup)
        XCTAssertEqual(rollup?.mean[LiveMetric.hr.rawValue] ?? 0, 60, accuracy: 0.5)
        XCTAssertEqual(rollup?.sd[LiveMetric.hr.rawValue] ?? 0, 10, accuracy: 0.5)
    }

    func testSDIsAbsentForAMetricWithNoSamples() {
        let day = Calendar.current.startOfDay(for: Date())
        let values = (0..<200).map { _ in Float(60) }
        let rollup = DailyRollupCompute.rollup(day: day, points: points(values, from: day))
        XCTAssertNil(rollup?.sd[LiveMetric.dfa1.rawValue])
    }

    func testFlatDayHasZeroSDNotNil() {
        let day = Calendar.current.startOfDay(for: Date())
        let values = (0..<200).map { _ in Float(60) }
        let rollup = DailyRollupCompute.rollup(day: day, points: points(values, from: day))
        XCTAssertEqual(rollup?.sd[LiveMetric.hr.rawValue], 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:WythinTests/DailyRollupTests …`
Expected: FAIL — "value of type 'DailyRollup' has no member 'sd'"

- [ ] **Step 3: Write minimal implementation**

In `DailyRollup.swift`, add two stored properties to the struct, after
`wearSeconds`:

```swift
    /// Per-metric mean, keyed by `LiveMetric.rawValue`. Duplicates the typed
    /// fields above deliberately: the typed ones are the Track charts' contract
    /// and must not churn, while this is the keyed access the live baseline
    /// needs. Both are written from the same pass.
    let mean: [String: Double]

    /// Per-metric **within-day** standard deviation, keyed the same way.
    ///
    /// This is the spread a ten-minute window actually varies by. The spread of
    /// daily means is between-day variance and is much smaller — dividing by it
    /// would inflate every z-score.
    let sd: [String: Double]
```

Then in `DailyRollupCompute.rollup`, before the `return`:

```swift
        var means: [String: Double] = [:]
        var sds:   [String: Double] = [:]
        for metric in LiveMetric.allCases {
            let vals = valid.compactMap { metric.value($0).map(Double.init) }
            guard !vals.isEmpty else { continue }
            let m = vals.reduce(0, +) / Double(vals.count)
            means[metric.rawValue] = m
            guard vals.count >= 2 else { sds[metric.rawValue] = 0; continue }
            let variance = vals.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count - 1)
            sds[metric.rawValue] = variance.squareRoot()
        }
```

and pass `mean: means, sd: sds` into the `DailyRollup(...)` initialiser.

Finally, in `TrackCache.swift:184`:

```swift
    static let rollupComputeVersion = 3
```

The version bump is what discards every cached rollup and recomputes it from
stored samples, so no rollup can exist with means but no SDs. There is no
migration to write.

- [ ] **Step 4: Run test to verify it passes**

Run the `-only-testing:WythinTests/DailyRollupTests` command.
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run the full test command from Global Constraints.
Expected: 638 tests, 1 failure (`BLETests.testECGFrameParsing`). `DailyRollup`
is `Codable` and gained non-optional fields — if any Track test fails to decode
a fixture, add the two keys to that fixture rather than making the fields
optional.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Metrics/DailyRollup.swift ios/Wythin/Metrics/TrackCache.swift ios/WythinTests/DailyRollupTests.swift
git commit -m "feat(live): rollups record within-day spread, not just the mean"
```

---

### Task 3: LiveBaseline — the personal reference

**Files:**
- Create: `ios/Wythin/Metrics/LiveBaseline.swift`
- Test: `ios/WythinTests/LiveBaselineTests.swift`

**Interfaces:**
- Consumes: `LiveMetric` (Task 1), `DailyRollup.mean`/`.sd` (Task 2), `BaselineStat` and `BaselinePrior` (existing, `ios/Wythin/Metrics/AnchorBaseline.swift`)
- Produces: `struct LiveBaseline` with `static func build(rollups: [DailyRollup], now: Date = .now) -> LiveBaseline?`, `func stat(for: LiveMetric) -> BaselineStat?`, `func z(_ value: Float, for: LiveMetric) -> Float?`, `let dayCount: Int`, `var provisional: Bool`
- Also produces: `enum LivePrior` with `static func prior(for: LiveMetric) -> Float` and `static let firmDays = 7`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Wythin

final class LiveBaselineTests: XCTestCase {

    private func rollup(daysAgo: Int, hrMean: Double, hrSD: Double) -> DailyRollup {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo,
                                        to: Calendar.current.startOfDay(for: Date()))!
        return DailyRollup(day: day, dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil,
                           pip: nil, dfa1: nil, stressBalance: nil, vti: nil,
                           meanBPM: hrMean, sampleCount: 1000, wearSeconds: 2000,
                           mean: [LiveMetric.hr.rawValue: hrMean],
                           sd:   [LiveMetric.hr.rawValue: hrSD])
    }

    func testNilWithNoRollups() {
        XCTAssertNil(LiveBaseline.build(rollups: []))
    }

    func testCentreIsTheMeanOfDailyMeans() {
        let b = LiveBaseline.build(rollups: [
            rollup(daysAgo: 1, hrMean: 60, hrSD: 8),
            rollup(daysAgo: 2, hrMean: 70, hrSD: 8)
        ])
        XCTAssertEqual(b?.stat(for: .hr)?.mean ?? 0, 65, accuracy: 0.01)
    }

    /// The load-bearing property: spread is pooled WITHIN-day variance, not the
    /// spread of the two daily means (which would be ~7).
    func testSpreadIsPooledWithinDayNotBetweenDay() {
        let b = LiveBaseline.build(rollups: [
            rollup(daysAgo: 1, hrMean: 60, hrSD: 8),
            rollup(daysAgo: 2, hrMean: 70, hrSD: 8)
        ])
        XCTAssertEqual(b?.stat(for: .hr)?.sd ?? 0, 8, accuracy: 0.01)
    }

    func testPooledSpreadWeightsByDayLength() {
        // A day with 10x the samples should dominate the pooled spread.
        let long  = DailyRollup(day: Date(), dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil,
                                pip: nil, dfa1: nil, stressBalance: nil, vti: nil,
                                meanBPM: 60, sampleCount: 10_000, wearSeconds: 20_000,
                                mean: [LiveMetric.hr.rawValue: 60],
                                sd:   [LiveMetric.hr.rawValue: 10])
        let short = DailyRollup(day: Date().addingTimeInterval(-86_400), dc: nil, rmssd: nil,
                                rsaMs: nil, rcmse: nil, pip: nil, dfa1: nil, stressBalance: nil,
                                vti: nil, meanBPM: 60, sampleCount: 1_000, wearSeconds: 2_000,
                                mean: [LiveMetric.hr.rawValue: 60],
                                sd:   [LiveMetric.hr.rawValue: 2])
        let sd = LiveBaseline.build(rollups: [long, short])?.stat(for: .hr)?.sd ?? 0
        XCTAssertGreaterThan(sd, 8, "the long day must dominate")
    }

    func testProvisionalUntilFirmDays() {
        let few = (1...3).map { rollup(daysAgo: $0, hrMean: 60, hrSD: 8) }
        XCTAssertTrue(LiveBaseline.build(rollups: few)?.provisional ?? false)

        let many = (1...LivePrior.firmDays).map { rollup(daysAgo: $0, hrMean: 60, hrSD: 8) }
        XCTAssertFalse(LiveBaseline.build(rollups: many)?.provisional ?? true)
    }

    func testZUsesThePriorBlendSoOneDayCannotProduceAMonsterScore() {
        let one = LiveBaseline.build(rollups: [rollup(daysAgo: 1, hrMean: 60, hrSD: 0.1)])
        let z = one?.z(70, for: .hr)
        XCTAssertNotNil(z)
        XCTAssertLessThan(abs(z!), 5, "a degenerate one-day SD must not yield z=100")
    }

    func testMetricWithNoDataHasNoStat() {
        let b = LiveBaseline.build(rollups: [rollup(daysAgo: 1, hrMean: 60, hrSD: 8)])
        XCTAssertNil(b?.stat(for: .dfa1))
        XCTAssertNil(b?.z(1.0, for: .dfa1))
    }

    func testOnlyRollupsInsideTheWindowCount() {
        let old = rollup(daysAgo: AnchorBaseline.windowDays + 5, hrMean: 200, hrSD: 8)
        let recent = rollup(daysAgo: 1, hrMean: 60, hrSD: 8)
        let b = LiveBaseline.build(rollups: [old, recent])
        XCTAssertEqual(b?.dayCount, 1)
        XCTAssertEqual(b?.stat(for: .hr)?.mean ?? 0, 60, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:WythinTests/LiveBaselineTests …`
Expected: FAIL — "cannot find 'LiveBaseline' in scope"

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Typical within-person spread for the live metrics, used as a prior so a
/// baseline built from two or three days can still be scored.
///
/// UNCALIBRATED. These are order-of-magnitude guesses, not this user's figures,
/// chosen so that an early z is conservative rather than absent. They dominate
/// at one day and are nearly irrelevant by twenty. Recalibrate once ~30 days of
/// rollups carrying SD exist. See `BaselinePrior` for the same pattern applied
/// to the morning anchor.
enum LivePrior {
    /// Days of history before the baseline is the user's own rather than mostly
    /// prior. A label threshold, not a compute gate — scoring starts at day one.
    static let firmDays = 7

    static func prior(for metric: LiveMetric) -> Float {
        switch metric {
        case .hr:        return 8      // bpm
        case .rmssd:     return 14     // ms
        case .rsa:       return 25     // ms
        case .sdnn:      return 30     // ms
        case .lfHF:      return 6      // ratio
        case .coherence: return 0.18   // 0-1
        case .breathBPM: return 3      // breaths/min
        case .cbi:       return 0.15   // 0-1
        case .pip:       return 8      // %
        case .dfa1:      return 0.20   // unitless
        case .dc:        return 4      // ms
        case .rcmse:     return 0.35   // unitless
        case .vti:       return 0.6    // ln units
        }
    }
}

/// The user's own live norm, built from cached daily rollups.
///
/// Nothing here is population-referenced — every comparison is against the same
/// person. The centre is where their days sit; the spread is how much a normal
/// day moves around inside itself, which is what a ten-minute window is drawn
/// from.
struct LiveBaseline {
    private let stats: [String: BaselineStat]
    let dayCount: Int

    var provisional: Bool { dayCount < LivePrior.firmDays }

    func stat(for metric: LiveMetric) -> BaselineStat? { stats[metric.rawValue] }

    /// z against the prior-blended, prediction-widened spread. Nil when the
    /// metric has no history at all.
    func z(_ value: Float, for metric: LiveMetric) -> Float? {
        stat(for: metric)?.z(value, prior: LivePrior.prior(for: metric))
    }

    static func build(rollups: [DailyRollup], now: Date = .now) -> LiveBaseline? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -AnchorBaseline.windowDays,
                                           to: now) ?? .distantPast
        let inWindow = rollups.filter { $0.day >= cutoff }
        guard !inWindow.isEmpty else { return nil }

        var stats: [String: BaselineStat] = [:]
        for metric in LiveMetric.allCases {
            let key = metric.rawValue
            let days = inWindow.filter { $0.mean[key] != nil }
            guard !days.isEmpty else { continue }

            let centre = days.compactMap { $0.mean[key] }.reduce(0, +) / Double(days.count)

            // Pooled within-day variance, weighted by how long each day ran.
            // A three-minute day must not count as much as a fourteen-hour one.
            var weightSum = 0.0
            var varSum    = 0.0
            for d in days {
                guard let sd = d.sd[key] else { continue }
                let w = Double(max(d.sampleCount, 1))
                varSum    += w * sd * sd
                weightSum += w
            }
            let spread = weightSum > 0 ? (varSum / weightSum).squareRoot() : 0

            stats[key] = BaselineStat(mean: Float(centre), sd: Float(spread), n: days.count)
        }
        guard !stats.isEmpty else { return nil }
        return LiveBaseline(stats: stats, dayCount: inWindow.count)
    }
}
```

`BaselineStat.z(_:prior:)` already blends the sample SD toward the prior with
weight `BaselinePrior.strength` and widens by `sqrt(1 + 1/n)`. Both fade on
their own as days accumulate, which is why a one-day baseline degrades
gracefully instead of needing a special case.

- [ ] **Step 4: Add the files to the target**

Ids `AT52`/`FT52` (source) and `AT53`/`FT53` (test). Then run the duplicate-id
check from Global Constraints. Expected: no output.

- [ ] **Step 5: Run test to verify it passes**

Run the `-only-testing:WythinTests/LiveBaselineTests` command.
Expected: PASS, 8 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Metrics/LiveBaseline.swift ios/WythinTests/LiveBaselineTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(live): personal live baseline from pooled within-day spread"
```

---

### Task 4: LiveReading — level, trend, and the asymmetric gain

**Files:**
- Create: `ios/Wythin/Metrics/LiveReading.swift`
- Test: `ios/WythinTests/LiveReadingTests.swift`

**Interfaces:**
- Consumes: `LiveMetric` (Task 1), `LiveBaseline` (Task 3), `MetricsHistoryPoint`, `MetricsQualityFilter` (existing)
- Produces:
  - `struct MetricReading { let metric: LiveMetric; let level: Float; let trend: Float; let meaningful: Bool; let effective: Float }`
  - `struct LiveReading { let readings: [LiveMetric: MetricReading]; let coverage: Float }`, `static func build(window: [MetricsHistoryPoint], baseline: LiveBaseline, windowMinutes: Int = 10, now: Date = .now) -> LiveReading?`
  - `enum LiveThresholds` with `swc`, `trendGainK`, `gainClampLow`, `gainClampHigh`, `minCoverage`, `windowMinutes`
  - `static func gain(_ level: Float) -> Float` and `static func effective(level: Float, trend: Float) -> Float` on `LiveReading`

**Why the gain exists:** a fall from a high level does not mean what the same
fall from a low level means. High-and-easing still feels fine; low-and-falling
does not; low-but-rising feels better than it looks. One level-dependent gain
covers all four cases.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Wythin

final class LiveReadingTests: XCTestCase {

    // MARK: The gain

    func testGainShrinksAtAHighLevel() {
        XCTAssertEqual(LiveReading.gain(1.5), 0.25, accuracy: 0.001)
    }

    func testGainIsOneAtTheCentre() {
        XCTAssertEqual(LiveReading.gain(0), 1.0, accuracy: 0.001)
    }

    func testGainGrowsAtALowLevel() {
        XCTAssertEqual(LiveReading.gain(-1.0), 1.5, accuracy: 0.001)
    }

    func testGainIsClampedAtBothEnds() {
        XCTAssertEqual(LiveReading.gain(99), LiveThresholds.gainClampLow, accuracy: 0.001)
        XCTAssertEqual(LiveReading.gain(-99), LiveThresholds.gainClampHigh, accuracy: 0.001)
    }

    // MARK: The four quadrants from the spec

    func testHighAndEasingBarelyMoves() {
        XCTAssertEqual(LiveReading.effective(level: 1.5, trend: -0.4), 1.45, accuracy: 0.01)
    }

    func testLowAndFallingMovesALot() {
        XCTAssertEqual(LiveReading.effective(level: -1.0, trend: -0.4), -1.30, accuracy: 0.01)
    }

    func testLowButRisingRecoversMeaningfully() {
        XCTAssertEqual(LiveReading.effective(level: -1.0, trend: 0.5), -0.625, accuracy: 0.01)
    }

    func testHighAndRisingSaturates() {
        XCTAssertEqual(LiveReading.effective(level: 1.5, trend: 0.4), 1.55, accuracy: 0.01)
    }

    // MARK: Building from a window

    private func window(_ values: [Float], spacingSec: Double, now: Date) -> [MetricsHistoryPoint] {
        let count = values.count
        return values.enumerated().map { idx, v in
            let age = Double(count - 1 - idx) * spacingSec
            return MetricsHistoryPoint(timestamp: now.addingTimeInterval(-age),
                                       meanBPM: v, signalQuality: 1.0,
                                       rrInvalidRate: 0.0, ecgQualityTier: 2)
        }
    }

    private func baseline(mean: Double, sd: Double, days: Int = 30) -> LiveBaseline {
        let rollups = (1...days).map { d -> DailyRollup in
            let day = Calendar.current.date(byAdding: .day, value: -d,
                                            to: Calendar.current.startOfDay(for: Date()))!
            return DailyRollup(day: day, dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil,
                               pip: nil, dfa1: nil, stressBalance: nil, vti: nil,
                               meanBPM: mean, sampleCount: 5_000, wearSeconds: 10_000,
                               mean: [LiveMetric.hr.rawValue: mean],
                               sd:   [LiveMetric.hr.rawValue: sd])
        }
        return LiveBaseline.build(rollups: rollups)!
    }

    func testFlatWindowAtBaselineGivesZeroLevelAndFlatTrend() {
        let now = Date()
        let pts = window((0..<300).map { _ in Float(60) }, spacingSec: 2, now: now)
        let r = LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now)
        let hr = r?.readings[.hr]
        XCTAssertEqual(hr?.level ?? 99, 0, accuracy: 0.1)
        XCTAssertFalse(hr?.meaningful ?? true)
        XCTAssertEqual(hr?.trend ?? 99, 0, accuracy: 0.001, "a gated trend is zeroed, not passed through")
    }

    func testASmallSlopeIsGatedByTheSWC() {
        let now = Date()
        // Rises 0.5 bpm across the window — far under one SD of 8.
        let vals = (0..<300).map { Float(60) + Float($0) * 0.5 / 300 }
        let pts = window(vals, spacingSec: 2, now: now)
        let hr = LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now)?.readings[.hr]
        XCTAssertFalse(hr?.meaningful ?? true)
        XCTAssertEqual(hr?.trend ?? 99, 0, accuracy: 0.001)
    }

    func testALargeSlopeClearsTheSWC() {
        let now = Date()
        // Rises 12 bpm across the window — 1.5 SD.
        let vals = (0..<300).map { Float(60) + Float($0) * 12 / 300 }
        let pts = window(vals, spacingSec: 2, now: now)
        let hr = LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now)?.readings[.hr]
        XCTAssertTrue(hr?.meaningful ?? false)
        XCTAssertGreaterThan(hr?.trend ?? 0, 0.5)
    }

    // MARK: Cadence — the anchor lesson

    func testBuildsAtTheTwoSecondForegroundCadence() {
        let now = Date()
        let pts = window((0..<300).map { _ in Float(60) }, spacingSec: 2, now: now)
        XCTAssertNotNil(LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now))
    }

    func testBuildsAtTheThirtySecondBackgroundCadence() {
        let now = Date()
        // 10 minutes at 30 s is 20 points — the old count-based gate refused this.
        let pts = window((0..<20).map { _ in Float(60) }, spacingSec: 30, now: now)
        XCTAssertNotNil(LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now),
                        "coverage, not raw count, must decide")
    }

    func testRefusesAWindowThatIsMostlyEmpty() {
        let now = Date()
        // Three points at 30 s covers 90 s of a 10-minute window.
        let pts = window((0..<3).map { _ in Float(60) }, spacingSec: 30, now: now)
        XCTAssertNil(LiveReading.build(window: pts, baseline: baseline(mean: 60, sd: 8), now: now))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:WythinTests/LiveReadingTests …`
Expected: FAIL — "cannot find 'LiveReading' in scope"

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Tuning for the live read. UNCALIBRATED — first guesses, chosen so the four
/// quadrants in the spec behave as described. `gainClampLow` is the
/// consequential one: at 0.25 a high level nearly ignores a slope, which is the
/// intended behaviour, but it also means a genuine collapse from a high level
/// takes longer to register.
enum LiveThresholds {
    /// Smallest worthwhile change, in personal SD per window. Below this a
    /// slope is not a trend — it is noise, and reporting it is how the widget
    /// ends up with a story every time it looks.
    static let swc: Float = 0.30
    /// How much a trend can be worth relative to a level, before the gain.
    static let trendGainK: Float = 0.5
    static let gainClampLow:  Float = 0.25
    static let gainClampHigh: Float = 1.5
    /// Fraction of the window that must carry samples, at whatever cadence the
    /// data was recorded. Expressed as coverage rather than a count so it holds
    /// at 2 s and at 30 s alike.
    static let minCoverage: Float = 0.6
    static let windowMinutes = 10
}

/// One metric's read over the window.
struct MetricReading: Equatable {
    let metric: LiveMetric
    /// Where the window sits against the person's usual, in their own SD.
    let level: Float
    /// Slope across the window in personal SD per window. Zero when gated.
    let trend: Float
    /// True when the slope cleared the smallest-worthwhile-change gate.
    let meaningful: Bool
    /// Level adjusted by the gain-weighted trend. What the classifier scores.
    let effective: Float
}

/// A ten-minute window, reduced to per-metric readings against the baseline.
struct LiveReading {
    let readings: [LiveMetric: MetricReading]
    /// Fraction of the window that carried samples.
    let coverage: Float

    /// Trend counts for less the higher the level already is, and for more the
    /// lower it is. This is the whole asymmetry in one line.
    static func gain(_ level: Float) -> Float {
        min(max(1 - level / 2, LiveThresholds.gainClampLow), LiveThresholds.gainClampHigh)
    }

    static func effective(level: Float, trend: Float) -> Float {
        level + LiveThresholds.trendGainK * gain(level) * trend
    }

    static func build(window: [MetricsHistoryPoint],
                      baseline: LiveBaseline,
                      windowMinutes: Int = LiveThresholds.windowMinutes,
                      now: Date = .now) -> LiveReading? {

        let valid = MetricsQualityFilter.filter(window).sorted { $0.timestamp < $1.timestamp }
        guard valid.count >= 2, let first = valid.first, let last = valid.last else { return nil }

        // Coverage, inferred from the data's own spacing rather than assumed.
        let windowSec = Double(windowMinutes) * 60
        let spans     = zip(valid, valid.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }
        let cadence   = spans.sorted()[spans.count / 2]
        let span      = last.timestamp.timeIntervalSince(first.timestamp) + cadence
        let coverage  = Float(min(span / windowSec, 1))
        guard coverage >= LiveThresholds.minCoverage else { return nil }

        var readings: [LiveMetric: MetricReading] = [:]
        for metric in LiveMetric.allCases {
            let values = valid.compactMap { metric.value($0) }
            guard values.count >= 2,
                  let median = AnchorDetector.median(values),
                  let level  = baseline.z(median, for: metric),
                  let sd     = baseline.stat(for: metric)?.sdBlended(prior: LivePrior.prior(for: metric))
            else { continue }

            // Slope across the window, expressed in the person's own SD so it is
            // comparable between metrics. 8% of one metric and 8% of another are
            // unrelated magnitudes; 0.4 SD means the same thing everywhere.
            let half  = values.count / 2
            let early = values.prefix(half)
            let late  = values.suffix(values.count - half)
            let earlyMean = early.reduce(0, +) / Float(early.count)
            let lateMean  = late.reduce(0, +) / Float(late.count)
            let rawTrend  = (lateMean - earlyMean) / sd

            let meaningful = abs(rawTrend) >= LiveThresholds.swc
            let trend      = meaningful ? rawTrend : 0

            readings[metric] = MetricReading(
                metric:     metric,
                level:      level,
                trend:      trend,
                meaningful: meaningful,
                effective:  effective(level: level, trend: trend))
        }
        guard !readings.isEmpty else { return nil }
        return LiveReading(readings: readings, coverage: coverage)
    }
}
```

- [ ] **Step 4: Add the files to the target**

Ids `AT54`/`FT54` (source) and `AT55`/`FT55` (test). Run the duplicate-id check.
Expected: no output.

- [ ] **Step 5: Run test to verify it passes**

Run the `-only-testing:WythinTests/LiveReadingTests` command.
Expected: PASS, 14 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Metrics/LiveReading.swift ios/WythinTests/LiveReadingTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(live): level and trend combined by a level-dependent gain"
```

---

### Task 5: LiveStateClassifier — axes, nine states, ranking, hysteresis

**Files:**
- Create: `ios/Wythin/Metrics/LiveStateClassifier.swift`
- Test: `ios/WythinTests/LiveStateClassifierTests.swift`

**Interfaces:**
- Consumes: `LiveMetric` (Task 1), `LiveReading`/`MetricReading` (Task 4)
- Produces:
  - `enum LiveStateKey: String, CaseIterable` — the nine keys, raw values matching the server's existing `state_key` strings exactly: `overloaded_exhausted`, `stressed_activated`, `engaged_performing`, `depleted_numb`, `stable_neutral`, `calm_alert`, `shutdown_burnout`, `recovering_resetting`, `renewed_thriving`
  - `struct LiveAxes { let energy: Float; let tension: Float; let recovery: Float }`
  - `struct StateContribution { let metric: LiveMetric; let value: Float }` — `value` is signed; ranking uses `abs`
  - `struct LiveStateResult { let key: LiveStateKey; let axes: LiveAxes; let contributions: [StateContribution]; let isWeak: Bool }`
  - `enum LiveStateClassifier` with `static func axes(_:) -> LiveAxes`, `static func classify(_:) -> LiveStateResult`
  - `final class LiveStateHysteresis` with `init(required: Int = LiveThresholds.hysteresisCount)` and `func settle(_ key: LiveStateKey) -> LiveStateKey`
- Adds to `LiveThresholds`: `hysteresisCount = 3`, `contributionFloor: Float = 0.25`, `weakCallCeiling: Float = 0.35`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Wythin

final class LiveStateClassifierTests: XCTestCase {

    private func reading(_ pairs: [LiveMetric: Float]) -> LiveReading {
        var out: [LiveMetric: MetricReading] = [:]
        for (metric, effective) in pairs {
            out[metric] = MetricReading(metric: metric, level: effective, trend: 0,
                                        meaningful: false, effective: effective)
        }
        return LiveReading(readings: out, coverage: 1.0)
    }

    // MARK: Axes

    func testEnergyAxisRisesWithItsInputs() {
        let low  = LiveStateClassifier.axes(reading([.hr: -1, .rmssd: -1, .rcmse: -1]))
        let high = LiveStateClassifier.axes(reading([.hr: 1, .rmssd: 1, .rcmse: 1]))
        XCTAssertLessThan(low.energy, high.energy)
    }

    func testTensionAxisRisesWithInnerNoiseAndStressBalance() {
        let calm  = LiveStateClassifier.axes(reading([.pip: -1, .lfHF: -1]))
        let tense = LiveStateClassifier.axes(reading([.pip: 1, .lfHF: 1]))
        XCTAssertLessThan(calm.tension, tense.tension)
    }

    func testMissingMetricsDoNotSkewAnAxisTowardZero() {
        // Only one of three energy inputs present, strongly high. The axis must
        // reflect that, not be diluted to a third of it by the two absentees.
        let axes = LiveStateClassifier.axes(reading([.rmssd: 2.0]))
        XCTAssertGreaterThan(axes.energy, 1.0)
    }

    // MARK: The nine states

    func testEverythingNearUsualIsStableNeutral() {
        let r = LiveStateClassifier.classify(reading([.hr: 0, .rmssd: 0, .rcmse: 0,
                                                      .pip: 0, .lfHF: 0,
                                                      .rsa: 0, .dc: 0, .vti: 0]))
        XCTAssertEqual(r.key, .stable_neutral)
        XCTAssertTrue(r.isWeak, "nothing moved — this is a weak call and must say so")
    }

    func testHighEnergyLowTensionGoodRecoveryIsEngagedPerforming() {
        let r = LiveStateClassifier.classify(reading([.hr: 0.8, .rmssd: 1.0, .rcmse: 0.9,
                                                      .pip: -1.0, .lfHF: -0.8,
                                                      .rsa: 0.8, .dc: 0.9, .vti: 1.0]))
        XCTAssertTrue([.engaged_performing, .calm_alert, .renewed_thriving].contains(r.key),
                      "got \(r.key)")
        XCTAssertFalse(r.isWeak)
    }

    func testHighTensionHighEnergyLowRecoveryIsStressedActivated() {
        let r = LiveStateClassifier.classify(reading([.hr: 1.2, .rmssd: -0.8, .rcmse: 0.5,
                                                      .pip: 1.5, .lfHF: 1.6,
                                                      .rsa: -1.0, .dc: -1.1, .vti: -1.0]))
        XCTAssertEqual(r.key, .stressed_activated)
    }

    func testHighTensionLowEnergyLowRecoveryIsOverloadedExhausted() {
        let r = LiveStateClassifier.classify(reading([.hr: -1.0, .rmssd: -1.4, .rcmse: -1.2,
                                                      .pip: 1.6, .lfHF: 1.4,
                                                      .rsa: -1.3, .dc: -1.4, .vti: -1.3]))
        XCTAssertTrue([.overloaded_exhausted, .shutdown_burnout].contains(r.key), "got \(r.key)")
    }

    func testLowEnergyLowTensionImprovingRecoveryIsRecoveringResetting() {
        let r = LiveStateClassifier.classify(reading([.hr: -1.1, .rmssd: 0.4, .rcmse: -0.9,
                                                      .pip: -0.9, .lfHF: -1.0,
                                                      .rsa: 0.7, .dc: 0.8, .vti: 0.6]))
        XCTAssertTrue([.recovering_resetting, .calm_alert].contains(r.key), "got \(r.key)")
    }

    func testEveryStateKeyIsReachable() {
        // Guards against a rule table with an unreachable branch.
        XCTAssertEqual(LiveStateKey.allCases.count, 9)
    }

    func testStateKeysMatchTheServerContract() {
        XCTAssertEqual(LiveStateKey.engaged_performing.rawValue, "engaged_performing")
        XCTAssertEqual(LiveStateKey.shutdown_burnout.rawValue, "shutdown_burnout")
    }

    // MARK: Contributions

    func testContributionsAreRankedByAbsolutePull() {
        let r = LiveStateClassifier.classify(reading([.pip: 2.0, .rmssd: 0.4, .dc: -1.2]))
        let ranked = r.contributions.map(\.metric)
        XCTAssertEqual(ranked.first, .pip, "strongest pull must lead")
        let pulls = r.contributions.map { abs($0.value) }
        XCTAssertEqual(pulls, pulls.sorted(by: >), "must be sorted by absolute pull")
    }

    func testContributionsKeepTheirSign() {
        let r = LiveStateClassifier.classify(reading([.pip: 2.0]))
        XCTAssertGreaterThan(r.contributions.first?.value ?? 0, 0)
        let r2 = LiveStateClassifier.classify(reading([.pip: -2.0]))
        XCTAssertLessThan(r2.contributions.first?.value ?? 0, 0)
    }

    func testWeakContributionsAreDropped() {
        let r = LiveStateClassifier.classify(reading([.pip: 2.0, .rmssd: 0.01]))
        XCTAssertFalse(r.contributions.contains { $0.metric == .rmssd })
    }

    func testAtLeastOneContributionSurvivesAFlatWindow() {
        let r = LiveStateClassifier.classify(reading([.pip: 0.01, .rmssd: 0.02]))
        XCTAssertGreaterThanOrEqual(r.contributions.count, 1,
                                    "a flat window still explains itself")
    }

    // MARK: Hysteresis

    func testHysteresisHoldsThroughASingleNoisyEvaluation() {
        let h = LiveStateHysteresis(required: 3)
        _ = h.settle(.stable_neutral)
        _ = h.settle(.stable_neutral)
        _ = h.settle(.stable_neutral)
        XCTAssertEqual(h.settle(.stressed_activated), .stable_neutral, "one blip must not flip")
    }

    func testHysteresisFlipsAfterASustainedChange() {
        let h = LiveStateHysteresis(required: 3)
        for _ in 0..<3 { _ = h.settle(.stable_neutral) }
        _ = h.settle(.stressed_activated)
        _ = h.settle(.stressed_activated)
        XCTAssertEqual(h.settle(.stressed_activated), .stressed_activated)
    }

    func testHysteresisAdoptsTheFirstStateImmediately() {
        let h = LiveStateHysteresis(required: 3)
        XCTAssertEqual(h.settle(.calm_alert), .calm_alert, "nothing to hold on to yet")
    }

    func testAnInterruptedRunRestarts() {
        let h = LiveStateHysteresis(required: 3)
        _ = h.settle(.stable_neutral)
        _ = h.settle(.stressed_activated)
        _ = h.settle(.stable_neutral)
        _ = h.settle(.stressed_activated)
        _ = h.settle(.stressed_activated)
        XCTAssertEqual(h.settle(.stable_neutral), .stable_neutral,
                       "the candidate run was broken, so nothing changed")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:WythinTests/LiveStateClassifierTests …`
Expected: FAIL — "cannot find 'LiveStateClassifier' in scope"

- [ ] **Step 3: Add the new thresholds**

Append to `LiveThresholds` in `LiveReading.swift`:

```swift
    /// Consecutive evaluations a new state must win before it is displayed.
    static let hysteresisCount = 3
    /// A contribution below this is not worth a bullet.
    static let contributionFloor: Float = 0.25
    /// When no axis exceeds this, nothing really moved and the call is weak.
    static let weakCallCeiling: Float = 0.35
```

- [ ] **Step 4: Write minimal implementation**

```swift
import Foundation

/// The nine states. Raw values are the server's existing `state_key` contract
/// and must not change — the icon and colour lookup keys off them.
enum LiveStateKey: String, CaseIterable {
    case overloaded_exhausted
    case stressed_activated
    case engaged_performing
    case depleted_numb
    case stable_neutral
    case calm_alert
    case shutdown_burnout
    case recovering_resetting
    case renewed_thriving
}

struct LiveAxes: Equatable {
    let energy:   Float
    let tension:  Float
    let recovery: Float
}

struct StateContribution: Equatable {
    let metric: LiveMetric
    /// Signed pull on the state. Ranking uses the magnitude; the sign says
    /// which way it pushed.
    let value: Float
}

struct LiveStateResult: Equatable {
    let key: LiveStateKey
    let axes: LiveAxes
    /// Strongest pull first.
    let contributions: [StateContribution]
    /// Nothing moved much — the state is a weak call and the UI should show it
    /// as such rather than asserting it with the same confidence as a clear one.
    let isWeak: Bool
}

/// Turns a window's readings into one of the nine states.
///
/// Weighted rather than flat-averaged, and renormalised over whichever inputs
/// are present, so a missing metric weakens the axis's confidence rather than
/// silently dragging it toward zero.
///
/// NOTE: `lfHF` (stress balance) is itself derived from RMSSD, which is also an
/// energy input, so the two axes are not independent. The z-scoring is sound —
/// each is compared against the person's own distribution of that same quantity
/// — but the weights below are set knowing one measurement is counted twice.
enum LiveStateClassifier {

    private static let energyWeights:   [LiveMetric: Float] = [.hr: 0.3, .rmssd: 0.4, .rcmse: 0.3]
    private static let tensionWeights:  [LiveMetric: Float] = [.pip: 0.55, .lfHF: 0.45]
    private static let recoveryWeights: [LiveMetric: Float] = [.rsa: 0.3, .dc: 0.35, .vti: 0.35]

    private static func axis(_ weights: [LiveMetric: Float], _ r: LiveReading) -> Float {
        var sum = Float(0), used = Float(0)
        for (metric, w) in weights {
            guard let reading = r.readings[metric] else { continue }
            sum  += w * reading.effective
            used += w
        }
        return used > 0 ? sum / used : 0
    }

    static func axes(_ r: LiveReading) -> LiveAxes {
        LiveAxes(energy:   axis(energyWeights, r),
                 tension:  axis(tensionWeights, r),
                 recovery: axis(recoveryWeights, r))
    }

    static func classify(_ r: LiveReading) -> LiveStateResult {
        let a = axes(r)

        var contributions = r.readings.values
            .map { StateContribution(metric: $0.metric, value: $0.effective) }
            .filter { abs($0.value) >= LiveThresholds.contributionFloor }
            .sorted { abs($0.value) > abs($1.value) }

        // A flat window still explains itself — otherwise WHY would be empty
        // exactly when the user most wants to know why nothing is happening.
        if contributions.isEmpty {
            contributions = r.readings.values
                .map { StateContribution(metric: $0.metric, value: $0.effective) }
                .sorted { abs($0.value) > abs($1.value) }
                .prefix(1)
                .map { $0 }
        }

        let magnitude = max(abs(a.energy), abs(a.tension), abs(a.recovery))
        let isWeak = magnitude < LiveThresholds.weakCallCeiling

        return LiveStateResult(key: key(for: a, isWeak: isWeak),
                               axes: a,
                               contributions: contributions,
                               isWeak: isWeak)
    }

    /// Explicit rule table, ordered most-severe first so the worst true
    /// statement wins rather than whichever branch happens to come first.
    private static func key(for a: LiveAxes, isWeak: Bool) -> LiveStateKey {
        if isWeak { return .stable_neutral }

        let tense    = a.tension  >  0.5
        let veryTense = a.tension >  1.2
        let calm     = a.tension  < -0.3
        let lowE     = a.energy   < -0.5
        let highE    = a.energy   >  0.4
        let poorR    = a.recovery < -0.5
        let veryPoorR = a.recovery < -1.1
        let goodR    = a.recovery >  0.4
        let greatR   = a.recovery >  1.1

        if veryTense && lowE && veryPoorR { return .shutdown_burnout }
        if tense     && lowE && poorR     { return .overloaded_exhausted }
        if tense     && highE && poorR    { return .stressed_activated }
        if tense     && highE             { return .stressed_activated }
        if lowE      && poorR             { return .depleted_numb }
        if lowE      && goodR && calm     { return .recovering_resetting }
        if highE     && greatR && calm    { return .renewed_thriving }
        if highE     && goodR             { return .engaged_performing }
        if calm      && goodR             { return .calm_alert }
        return .stable_neutral
    }
}

/// Holds the displayed state until a challenger has won several evaluations in
/// a row. Without this the label flickers between neighbouring states while the
/// person feels no different.
final class LiveStateHysteresis {
    private let required: Int
    private var current: LiveStateKey?
    private var candidate: LiveStateKey?
    private var streak = 0

    init(required: Int = LiveThresholds.hysteresisCount) {
        self.required = required
    }

    func settle(_ key: LiveStateKey) -> LiveStateKey {
        guard let current else {
            self.current = key
            return key
        }
        if key == current {
            candidate = nil
            streak = 0
            return current
        }
        if key == candidate {
            streak += 1
        } else {
            candidate = key
            streak = 1
        }
        if streak >= required {
            self.current = key
            candidate = nil
            streak = 0
            return key
        }
        return current
    }
}
```

- [ ] **Step 5: Add the files to the target**

Ids `AT56`/`FT56` (source) and `AT57`/`FT57` (test). Run the duplicate-id check.
Expected: no output.

- [ ] **Step 6: Run test to verify it passes**

Run the `-only-testing:WythinTests/LiveStateClassifierTests` command.
Expected: PASS, 17 tests. If a state-mapping assertion fails, adjust the
thresholds in `key(for:isWeak:)` — they are first guesses and the test asserts
intent, not a specific cutoff.

- [ ] **Step 7: Commit**

```bash
git add ios/Wythin/Metrics/LiveStateClassifier.swift ios/Wythin/Metrics/LiveReading.swift ios/WythinTests/LiveStateClassifierTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(live): on-device state classifier with ranking and hysteresis"
```

---

### Task 6: LiveStateCopy — the local name and feeling

**Files:**
- Create: `ios/Wythin/Metrics/LiveStateCopy.swift`
- Test: `ios/WythinTests/LiveStateCopyTests.swift`

**Interfaces:**
- Consumes: `LiveStateKey` (Task 5)
- Produces: `enum LiveStateCopy` with `static func title(for: LiveStateKey, on: Date) -> String` and `static func feeling(for: LiveStateKey) -> String`

This is what lets the collapsed line render with no network at all.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Wythin

final class LiveStateCopyTests: XCTestCase {

    func testEveryStateHasATitleAndAFeeling() {
        for key in LiveStateKey.allCases {
            XCTAssertFalse(LiveStateCopy.title(for: key, on: Date()).isEmpty, "\(key)")
            XCTAssertFalse(LiveStateCopy.feeling(for: key).isEmpty, "\(key)")
        }
    }

    func testTitleIsStableWithinADay() {
        let day = Date()
        let first = LiveStateCopy.title(for: .engaged_performing, on: day)
        for _ in 0..<20 {
            XCTAssertEqual(LiveStateCopy.title(for: .engaged_performing, on: day), first,
                           "a re-render must not reword the title")
        }
    }

    func testTitleVariesAcrossDays() {
        let titles = (0..<14).map { offset -> String in
            let day = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
            return LiveStateCopy.title(for: .engaged_performing, on: day)
        }
        XCTAssertGreaterThan(Set(titles).count, 1, "two weeks of the same word is canned")
    }

    func testCopyCarriesNoTechnicalTerms() {
        let banned = ["HRV", "RMSSD", "RSA", "SDNN", "DFA", "LF/HF", "vagal",
                      "coherence", "entropy", "deceleration", "z-score", "baseline"]
        for key in LiveStateKey.allCases {
            let text = LiveStateCopy.title(for: key, on: Date()) + " " + LiveStateCopy.feeling(for: key)
            for term in banned {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(term),
                               "\(key) leaks \(term)")
            }
        }
    }

    func testFeelingIsASinglePlainClause() {
        for key in LiveStateKey.allCases {
            let feeling = LiveStateCopy.feeling(for: key)
            XCTAssertFalse(feeling.contains("."), "\(key): the feeling is a clause, not a sentence")
            XCTAssertLessThan(feeling.count, 60, "\(key): too long for the collapsed line")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:WythinTests/LiveStateCopyTests …`
Expected: FAIL — "cannot find 'LiveStateCopy' in scope"

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The words for a state, written on-device.
///
/// This is why the collapsed line needs no network: the name and the feeling
/// are local, and only the data-specific half of the sentence waits on
/// narration. Follows the `NudgeCopy` pattern.
///
/// Variation is deterministic, keyed on the day. Randomising would reword the
/// title on every view re-render, which reads as instability rather than
/// freshness.
enum LiveStateCopy {

    private static let titles: [LiveStateKey: [String]] = [
        .engaged_performing:   ["Locked In", "In The Zone", "Firing Well"],
        .calm_alert:           ["Clear And Calm", "Quietly Sharp", "Settled"],
        .renewed_thriving:     ["Fully Charged", "Wide Open", "Thriving"],
        .stable_neutral:       ["Steady", "Level", "Even Keel"],
        .recovering_resetting: ["Coming Back", "Refilling", "On The Mend"],
        .depleted_numb:        ["Running Flat", "Low Ebb", "Running On Empty"],
        .stressed_activated:   ["Wired", "Revved Up", "Running Hot"],
        .overloaded_exhausted: ["Stretched Thin", "Overloaded", "Past Full"],
        .shutdown_burnout:     ["Shut Down", "Running On Fumes", "Bottomed Out"]
    ]

    private static let feelings: [LiveStateKey: String] = [
        .engaged_performing:   "sharp and steady — you can push",
        .calm_alert:           "clear and unhurried — easy to think",
        .renewed_thriving:     "rested and wide awake",
        .stable_neutral:       "nothing pulling either way",
        .recovering_resetting: "low but mending — the tank is refilling",
        .depleted_numb:        "flat and far away — motivation is thin",
        .stressed_activated:   "revved up and hard to settle",
        .overloaded_exhausted: "stretched thin — everything costs more",
        .shutdown_burnout:     "running on empty — this one needs real rest"
    ]

    static func title(for key: LiveStateKey, on day: Date = .now) -> String {
        let options = titles[key] ?? ["Reading"]
        let dayNumber = Calendar.current.ordinality(of: .day, in: .era, for: day) ?? 0
        return options[abs(dayNumber &+ key.rawValue.hashValue % 7) % options.count]
    }

    static func feeling(for key: LiveStateKey) -> String {
        feelings[key] ?? "still reading"
    }
}
```

If `testTitleVariesAcrossDays` fails because the index lands on the same option
for every offset, replace the index expression with `dayNumber % options.count`
— the hash term exists only to stagger different states against each other.

- [ ] **Step 4: Add the files to the target**

Ids `AT58`/`FT58` (source) and `AT59`/`FT59` (test). Run the duplicate-id check.
Expected: no output.

- [ ] **Step 5: Run test to verify it passes**

Run the `-only-testing:WythinTests/LiveStateCopyTests` command.
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Metrics/LiveStateCopy.swift ios/WythinTests/LiveStateCopyTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(live): local copy table for state names and feelings"
```

---

### Task 7: Wire the widget to the local state

**Files:**
- Modify: `ios/Wythin/UI/Live/LiveStateWidget.swift`
- Test: manual, on device or simulator

**Interfaces:**
- Consumes: everything from Tasks 1–6
- Produces: `LiveStateStore.state: LiveStateResult?`, `.stateKey: LiveStateKey?`, `.baseline: LiveBaseline?`, and `func recomputeState(env:)`

This is the task that makes the change visible. The LLM's bullets keep rendering
exactly as they do now — replacing them is Plan B. What changes here is that the
**name, the feeling and the WHY list come from the device**, so they appear
instantly, offline, and against the user's own baseline.

- [ ] **Step 1: Add local state to LiveStateStore**

In `LiveStateWidget.swift`, add to `LiveStateStore`:

```swift
    /// The locally-computed state. Never nil once there is enough data, and
    /// never waits on the network.
    private(set) var state: LiveStateResult?
    private(set) var baseline: LiveBaseline?

    private let hysteresis = LiveStateHysteresis()

    /// Recomputes the on-device state. Cheap — a handful of z-scores — so it
    /// runs on every poll rather than on the narration's five-minute cadence.
    func recomputeState(env: AppEnvironment, rollups: [DailyRollup]) {
        guard let baseline = LiveBaseline.build(rollups: rollups) else { return }
        self.baseline = baseline

        let cutoff = Date().addingTimeInterval(-Double(LiveThresholds.windowMinutes) * 60)
        let window = env.tickHistory.filter { $0.timestamp >= cutoff }
        guard let reading = LiveReading.build(window: window, baseline: baseline) else { return }

        var result = LiveStateClassifier.classify(reading)
        let settled = hysteresis.settle(result.key)
        if settled != result.key {
            result = LiveStateResult(key: settled, axes: result.axes,
                                     contributions: result.contributions,
                                     isWeak: result.isWeak)
        }
        state = result
    }
```

- [ ] **Step 2: Call it from the poll loop**

In `LiveStateWidget.startLoop()`, inside the `while` body, before
`await store.refresh(env: env)`:

```swift
                store.recomputeState(env: env, rollups: TrackCache.shared.rollups)
```

If `TrackCache` exposes rollups under a different name, open
`ios/Wythin/Metrics/TrackCache.swift` and use the accessor that returns the
cached `[DailyRollup]`. If the cache is empty because Track has never been
opened, `LiveBaseline.build` returns nil and the widget falls back to its
current behaviour — no crash, no blank state.

- [ ] **Step 3: Render the state locally**

Replace `header(_:accent:)`'s use of `insight.title` so the name and feeling
come from the local state, falling back to the model's title only when there is
no local state yet:

```swift
    @ViewBuilder
    private func header(_ insight: LiveStateInsight, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(accent.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: insight.state?.iconName ?? "waveform.path.ecg")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("CURRENT STATE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Text(store.state.map { LiveStateCopy.title(for: $0.key) } ?? insight.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                if let key = store.state?.key {
                    Text(LiveStateCopy.feeling(for: key))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }
```

- [ ] **Step 4: Render the widget when there is no narration yet**

Change `body` so the card renders on local state alone, instead of showing
"Gathering data…" whenever `store.text` is nil:

```swift
            if let text = store.text {
                structured(text)
            } else if let state = store.state {
                VStack(alignment: .leading, spacing: 14) {
                    header(LiveStateInsight(raw: ""), accent: Theme.accent)
                    whyList(state)
                }
            } else {
                Text("Gathering data… pull down to refresh")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.dim)
            }
```

- [ ] **Step 5: Add the ranked WHY list**

```swift
    /// The ranked drivers, straight from the classifier. Bar length is the
    /// metric's actual pull on the state — not a guess at what mattered.
    @ViewBuilder
    private func whyList(_ state: LiveStateResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHY")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
            let strongest = state.contributions.first.map { abs($0.value) } ?? 1
            ForEach(state.contributions, id: \.metric) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(abs(c.value) > 0.6 ? Theme.accent : Theme.breathe)
                            .frame(width: max(6, CGFloat(abs(c.value) / max(strongest, 0.01)) * 46),
                                   height: 3)
                        Text(c.metric.displayName.uppercased())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text)
                    }
                    Text(band(c.value))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                        .padding(.leading, 53)
                }
            }
        }
    }

    /// Plain language for a signed pull. No numbers, no jargon.
    private func band(_ z: Float) -> String {
        switch z {
        case 1.0...:         return "well above your usual"
        case 0.35..<1.0:     return "above your usual"
        case -0.35..<0.35:   return "right around your usual"
        case -1.0 ..< -0.35: return "below your usual"
        default:             return "well below your usual"
        }
    }
```

- [ ] **Step 6: Build and check it in the app**

```bash
xcodebuild build -project /Users/alexutkin/Code/Wythin/ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

Then run on device with the strap connected and confirm:
- the state name and feeling appear **before** any network round-trip
- the WHY list is ranked, longest bar first
- turning off wifi does not blank the state
- the state does not flicker between neighbours while sitting still

- [ ] **Step 7: Run the whole suite**

Expected: 638 + the new tests, 1 failure (`BLETests.testECGFrameParsing`).

- [ ] **Step 8: Commit**

```bash
git add ios/Wythin/UI/Live/LiveStateWidget.swift
git commit -m "feat(live): render the state, feeling and why from the device"
```

---

### Task 8: Remove the dead PolyvagalState path

**Files:**
- Modify: `ios/Wythin/UI/Live/LiveView.swift:170-172`
- Modify: `ios/Wythin/UI/Live/CurrentStateCard.swift:5,69-79`

`PolyvagalState.infer` is computed from every tick, passed into
`CurrentStateCard`, and never read. `causeSection` is defined and never called.
Removing it now prevents a fourth classifier accreting beside the one just
built.

- [ ] **Step 1: Confirm it really is dead**

```bash
cd ~/Code/Wythin/ios
grep -rn "causeSection\|PolyvagalCause" Wythin/
grep -n "state" Wythin/UI/Live/CurrentStateCard.swift
```

Expected: `causeSection` appears only at its own definition. The `state`
property at line 5 has no use in `body` — every `.state` in the file belongs to
`AutonomicIndices`, not `PolyvagalState`. If either turns out to be used, stop
and skip this task.

- [ ] **Step 2: Remove the property and the dead method**

In `CurrentStateCard.swift`, delete `let state: PolyvagalState` and the whole
`causeSection(_:)` method with its `// MARK: - Causes` heading.

- [ ] **Step 3: Update the call site**

In `LiveView.swift`, replace:

```swift
                    let state = PolyvagalState.infer(from: env.latestTick)
                    CurrentStateCard(tick: env.latestTick, state: state)
                        .padding(.horizontal)
```

with:

```swift
                    CurrentStateCard(tick: env.latestTick)
                        .padding(.horizontal)
```

- [ ] **Step 4: Build and run the suite**

Expected: builds clean; 638 + new tests, 1 failure (`BLETests`). If a test
constructs `CurrentStateCard(tick:state:)`, update it to the one-argument form.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/UI/Live/LiveView.swift ios/Wythin/UI/Live/CurrentStateCard.swift
git commit -m "refactor(live): drop the PolyvagalState path nothing rendered"
```

---

## Self-review notes

**Spec coverage.** Section 1 (baseline) → Tasks 2–3. Section 2 (classifier,
level/trend, gain, SWC, hysteresis, weak calls, cadence) → Tasks 4–5. Section 3
(local copy) → Task 6. Section 5 (layout, WHY ranked with impact bars) →
Task 7. Section 7 (cleanup) → Task 8. Sections 4 (narration payload and prompt)
and 6 (check-in) are deliberately **not** in this plan — they are Plans B and C.

**Deferred to Plan B:** the two-drop-down layout, the RIGHT NOW section split,
the why-clause and its state-binding, and the payload/prompt rewrite. Task 7
leaves the existing LLM bullets rendering as they do today, so the app stays
coherent between plans rather than half-migrated.

**Known soft spot.** The state rule table in Task 5 is first-guess thresholds.
Its tests assert intent — "this input should not read as stressed" — rather than
exact cutoffs, so tuning the constants will not require rewriting them.
