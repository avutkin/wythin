# Anchor Cadence Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the daily morning anchor detectable from background-recorded data, standardise it to the first 5 minutes of the qualifying rest, detect it without the Live tab being open, and rebuild the history it silently lost.

**Architecture:** `AnchorDetector` currently splits samples into runs on any wall-clock gap over 6 s. That constant assumes the 2 s foreground tick rate, but `AppEnvironment` throttles to 30 s in background, so background stretches become single-point runs and no anchor can ever form. The fix replaces the wall-clock gap rule with a cadence-agnostic one: a run breaks when the *raw* stream between two accepted samples contains rejected samples (you stirred), not when it merely contains no samples (the app was throttled). Detection then moves into the tick loop, and a versioned backfill recomputes stored anchors.

**Tech Stack:** Swift 5, SwiftUI, SwiftData, XCTest, Xcode 16, iOS Simulator.

## Global Constraints

- Target project: `ios/Wythin.xcodeproj`, scheme `Wythin`, test target `WythinTests`.
- `AnchorDetector` and `AnchorThresholds` stay **pure** — no clock beyond the injected `now`, no persistence, no `AppEnvironment` reference. This is what makes them unit-testable.
- Do **not** add stored properties to the `DailyAnchor` `@Model`. It is a live SwiftData schema on a shipped build; new columns mean a migration, and nothing in this plan needs one.
- `AppEnvironment` is `@MainActor`. Anything added to the tick loop runs on the main actor and must stay cheap — it executes every 2 s in foreground.
- Comments explain *why*, not *what*, matching the surrounding files.
- Commit after every task.

## Background: the evidence

Server-side sample counts for the morning of 2026-07-29 (local time, UTC−7):

| Window (local) | samples | mean spacing |
|---|---|---|
| 06:45–06:50 | 9 | ~33 s |
| 07:00–07:05 | 21 | ~14 s |
| 06:20–07:20 | 312 | ~11.5 s |

At 33 s spacing, every consecutive pair exceeds `AnchorThresholds.maxGapSec` (6 s), so `continuousRuns` emits runs of one point, `duration()` returns 0, and the `>= 180 s` filter rejects all of them. The existing tests only ever construct points 2 s apart (`AnchorDetectorTests.swift:18,75`), which is why this never surfaced.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `ios/Wythin/Metrics/AnchorDetector.swift` | Thresholds, run assembly, reading construction | Modify — Tasks 1, 2, 3 |
| `ios/WythinTests/AnchorDetectorTests.swift` | Detector unit tests | Modify — Tasks 1, 2, 3 |
| `ios/Wythin/App/AppEnvironment.swift` | Tick loop; owns persistence | Modify — Task 4 |
| `ios/Wythin/Models/DailyAnchor.swift` | `DailyAnchor` model + `AnchorBackfill` | Modify — Task 5 (`AnchorBackfill` only) |
| `.github/workflows/ios.yml` | CI | Modify — Task 6 |

---

### Task 1: Break runs on stirring, not on sampling cadence

**Files:**
- Modify: `ios/Wythin/Metrics/AnchorDetector.swift:7-24` (thresholds), `:61-79` (`detect`), `:104-117` (`continuousRuns`)
- Test: `ios/WythinTests/AnchorDetectorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `AnchorThresholds.minSamples: Int`, `AnchorThresholds.maxRejectedInGap: Int`, `AnchorThresholds.maxGapCeilingSec: Double`. `AnchorThresholds.maxGapSec` is **removed** — later tasks must not reference it. `AnchorDetector.detect(_:now:)` keeps its exact signature: `static func detect(_ points: [MetricsHistoryPoint], now: Date = .now) -> AnchorReading?`.

**Why this shape:** a hole in the accepted samples means one of two different things. Either no tick was computed (foreground/background throttle, a BLE reconnect) — the rest continued. Or ticks *were* computed and rejected by the point gates — you moved, or the signal went bad, and the rest ended. Only the second is a break. Walking the raw stream once and counting rejections between accepted samples distinguishes them, and makes the rule independent of tick rate.

- [ ] **Step 1: Write the failing test**

Add to `ios/WythinTests/AnchorDetectorTests.swift`. Note the new `spacing` parameter on the existing helper — replace the helper wholesale with this version, keeping every existing test working (the default `spacing: 2` preserves current behaviour):

```swift
    /// Builds `minutes` of still, clean ticks starting at `hour` on a fixed day.
    /// `spacing` is the tick interval — 2 s is foreground, 30 s is background.
    private func stillPoints(minutes: Double,
                             hour: Int,
                             motion: Float? = 5,
                             hr: Float = 60,
                             vti: Float = 3.6,
                             spacing: Double = 2) -> [MetricsHistoryPoint] {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20)
        comps.hour = hour
        let start = cal.date(from: comps)!
        let count = Int((minutes * 60) / spacing)
        return (0..<count).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * spacing),
                                meanBPM: hr, vti: vti, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: motion,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
    }

    // MARK: - Cadence

    func testFindsAnchorInBackgroundCadenceData() {
        // 30 s ticks are what the app records whenever it is not foregrounded.
        let a = AnchorDetector.detect(stillPoints(minutes: 10, hour: 7, spacing: 30))
        XCTAssertNotNil(a, "a 10-minute rest recorded at 30 s ticks must anchor")
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(a?.confidence, .high)
    }

    func testStirringBreaksTheRun() {
        // Six clean minutes, then movement, then six more. Neither half is
        // rejected, but they are two rests — and the mover must not be medianed in.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let moving = (0..<30).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(360 + Double(i) * 2),
                                meanBPM: 95, vti: 2.4, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 400,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let after = (0..<180).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(420 + Double(i) * 2),
                                meanBPM: 75, vti: 3.0, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 7) + moving + after)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001,
                       "the first rest is the anchor; the 75 bpm stretch is a separate run")
    }

    func testRejectsRunWithTooFewSamples() {
        // 4 minutes at 60 s ticks is 4 samples — long enough in wall-clock, but a
        // median over four points is not a median.
        XCTAssertNil(AnchorDetector.detect(stillPoints(minutes: 4, hour: 7, spacing: 60)))
    }

    func testLongOutageSplitsEvenWithNothingRejected() {
        // App killed for 20 minutes: no samples at all in the hole, so nothing is
        // rejected — the ceiling is what stops the two sides being merged.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let before = (0..<60).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 2),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let after = (0..<60).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(1320 + Double(i) * 2),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        XCTAssertNil(AnchorDetector.detect(before + after),
                     "two 2-minute halves across a 20-minute outage are not one 24-minute rest")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:WythinTests/AnchorDetectorTests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO | xcpretty
```
Expected: `testFindsAnchorInBackgroundCadenceData` FAILS (`XCTAssertNotNil failed`), `testStirringBreaksTheRun` FAILS (restingHR is not 60 — currently the 30 s rule already splits it, so this one may pass by accident; it must still pass after the change), `testRejectsRunWithTooFewSamples` FAILS (`XCTAssertNil failed` is *not* expected here — at 60 s spacing today's rule already returns nil, so it passes now and must keep passing), `testLongOutageSplitsEvenWithNothingRejected` PASSES already. Record which ones actually fail; `testFindsAnchorInBackgroundCadenceData` is the one that must go red.

- [ ] **Step 3: Replace the gap thresholds**

In `ios/Wythin/Metrics/AnchorDetector.swift`, replace the `maxGapSec` declaration (currently `:22-23`) with:

```swift
    /// Rejected samples tolerated inside a run before it counts as broken. A
    /// stir of one or two ticks is not the end of a rest; a sustained one is.
    /// Expressed in samples rather than seconds so the rule holds at both the
    /// 2 s foreground and the 30 s background tick rate.
    static let maxRejectedInGap: Int = 2
    /// Wall-clock hole beyond which two stretches are separate rests however
    /// clean they are — nothing was rejected because nothing was recorded
    /// (app killed, strap off, BLE dropped).
    static let maxGapCeilingSec: Double = 120
    /// A run must carry this many samples whatever its span. At 30 s ticks a
    /// 3-minute run is 6 points, and a median over fewer is not a median.
    static let minSamples: Int = 6
```

- [ ] **Step 4: Rewrite `detect` and `continuousRuns`**

Replace `detect` (`:61-79`) with:

```swift
    static func detect(_ points: [MetricsHistoryPoint], now: Date = .now) -> AnchorReading? {
        // Sorted but NOT pre-filtered: `continuousRuns` needs to see the rejected
        // samples, because a rejected sample is what distinguishes "the rest
        // ended" from "the tick loop was throttled".
        let all = points.sorted { $0.timestamp < $1.timestamp }
        guard !all.isEmpty else { return nil }

        let runs = continuousRuns(all).filter { run in
            run.count >= AnchorThresholds.minSamples
                && duration(run) >= AnchorThresholds.minSec
                && passesRunGates(run)
        }
        guard !runs.isEmpty else { return nil }

        let cal = Calendar.current
        let morning = runs.first { run in
            cal.component(.hour, from: run[0].timestamp) < AnchorThresholds.morningCutoffHour
        }
        guard let run = morning ?? runs.first else { return nil }

        return reading(from: run, late: morning == nil)
    }
```

Replace `continuousRuns` (`:104-117`) with:

```swift
    /// One pass over the raw stream. A sample that fails the point gates is not
    /// dropped silently — it is counted, because it is evidence the rest ended.
    ///
    /// Note the caller applies `MetricsQualityFilter` first, which removes
    /// strap-off samples entirely. Those read as absence rather than rejection
    /// here, which is right: taking the strap off is not stirring. The
    /// `maxGapCeilingSec` ceiling is what catches a long removal.
    private static func continuousRuns(_ all: [MetricsHistoryPoint]) -> [[MetricsHistoryPoint]] {
        var runs: [[MetricsHistoryPoint]] = []
        var current: [MetricsHistoryPoint] = []
        var rejectedSinceLast = 0

        for p in all {
            guard passesPointGates(p) else {
                rejectedSinceLast += 1
                continue
            }
            if let last = current.last {
                let hole = p.timestamp.timeIntervalSince(last.timestamp)
                if rejectedSinceLast > AnchorThresholds.maxRejectedInGap
                    || hole > AnchorThresholds.maxGapCeilingSec {
                    runs.append(current)
                    current = []
                }
            }
            rejectedSinceLast = 0
            current.append(p)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 2 command.
Expected: PASS, all 11 tests in `AnchorDetectorTests` (7 pre-existing + 4 new). If `testPrefersMorningWindowOverLaterOne` or `testRejectsMotion` regressed, the point-gate call moved incorrectly — `passesPointGates` must be called inside `continuousRuns` and nowhere else in `detect`.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Metrics/AnchorDetector.swift ios/WythinTests/AnchorDetectorTests.swift
git commit -m "fix(anchor): break runs on stirring, not on tick cadence

The 6 s gap rule assumed the 2 s foreground tick rate, so the 30 s
background rate split every rest into single-point runs and no anchor
could ever form from backgrounded data."
```

---

### Task 2: Stop discarding rows that predate the quality fields

**Files:**
- Modify: `ios/Wythin/Metrics/AnchorDetector.swift:12` (remove `minSignalQuality`), `:83-91` (`passesPointGates`), `:139-143` (confidence)
- Test: `ios/WythinTests/AnchorDetectorTests.swift`

**Interfaces:**
- Consumes: `AnchorThresholds.minSamples` from Task 1.
- Produces: `AnchorThresholds.minSignalQuality` is **removed**. No signature changes.

**Why:** `MetricsEngine.swift:152` defines `signalQuality` as `1 - invalidRate`, so `signalQuality >= 0.9` and `rrInvalidRate <= 0.05` are the same measurement at two different strictnesses — the second always wins. But they are not redundant in the way that sounds: both are `guard let`, so a row carrying only one of the two is dropped outright. Rows written before `rrInvalidRate` and `ecgQualityTier` existed carry `nil` there, so Task 5's backfill would silently discard exactly the history it is meant to recover.

- [ ] **Step 1: Write the failing test**

Add to `ios/WythinTests/AnchorDetectorTests.swift`:

```swift
    // MARK: - Legacy rows

    /// Builds a clean 10-minute morning run with the quality fields set
    /// individually, so rows that predate a field can be simulated.
    private func legacyPoints(signalQuality: Float?,
                              rrInvalidRate: Float?,
                              ecgQualityTier: Int?) -> [MetricsHistoryPoint] {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        return (0..<300).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 2),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: signalQuality,
                                rrInvalidRate: rrInvalidRate,
                                ecgQualityTier: ecgQualityTier)
        }
    }

    func testAcceptsRowsCarryingOnlySignalQuality() {
        let a = AnchorDetector.detect(
            legacyPoints(signalQuality: 0.98, rrInvalidRate: nil, ecgQualityTier: 2))
        XCTAssertNotNil(a, "signalQuality is 1 - rrInvalidRate; one of the two is enough")
    }

    func testRejectsRowsWhoseOnlyQualitySignalIsBad() {
        // signalQuality 0.80 means a 20% invalid rate — over the 5% ceiling.
        XCTAssertNil(AnchorDetector.detect(
            legacyPoints(signalQuality: 0.80, rrInvalidRate: nil, ecgQualityTier: 2)))
    }

    func testRejectsRowsWithNoQualitySignalAtAll() {
        XCTAssertNil(AnchorDetector.detect(
            legacyPoints(signalQuality: nil, rrInvalidRate: nil, ecgQualityTier: 2)))
    }

    func testAbsentECGTierAnchorsAtLowConfidence() {
        let a = AnchorDetector.detect(
            legacyPoints(signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: nil))
        XCTAssertNotNil(a, "an absent tier means the row predates the field, not a poor ECG")
        XCTAssertEqual(a?.confidence, .low, "and it is paid for in confidence")
    }

    func testPoorECGTierIsStillRejected() {
        XCTAssertNil(AnchorDetector.detect(
            legacyPoints(signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 0)))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:WythinTests/AnchorDetectorTests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO | xcpretty
```
Expected: `testAcceptsRowsCarryingOnlySignalQuality` and `testAbsentECGTierAnchorsAtLowConfidence` FAIL with `XCTAssertNotNil failed`. The three rejection tests pass already.

- [ ] **Step 3: Delete the redundant threshold**

In `ios/Wythin/Metrics/AnchorDetector.swift`, delete this line (currently `:12`):

```swift
    static let minSignalQuality: Float = 0.9
```

- [ ] **Step 4: Rewrite `passesPointGates`**

Replace `passesPointGates` (`:83-91`) with:

```swift
    private static func passesPointGates(_ p: MetricsHistoryPoint) -> Bool {
        // `signalQuality` is defined as `1 - rrInvalidRate` (MetricsEngine), so
        // the two fields are one measurement stored twice. Rows written before
        // `rrInvalidRate` existed carry only `signalQuality` — require whichever
        // is present rather than both, or backfilled history is thrown away for
        // being old rather than for being bad.
        guard let invalid = p.rrInvalidRate ?? p.signalQuality.map({ 1 - $0 }),
              invalid <= AnchorThresholds.maxInvalidRate else { return false }
        // An absent tier means the row predates the field, not that the ECG was
        // poor. Tolerated, and paid for in confidence — exactly as absent
        // `motion` is.
        if let tier = p.ecgQualityTier, tier < AnchorThresholds.minECGTier { return false }
        guard p.vti != nil, p.meanBPM != nil else { return false }
        if let m = p.motion, m > AnchorThresholds.stillnessSD { return false }
        if let b = p.breathBPM, !AnchorThresholds.breathRange.contains(b) { return false }
        return true
    }
```

- [ ] **Step 5: Downgrade confidence when the ECG tier is unknown**

In `reading(from:late:)`, add the `ecgKnown` check next to `motionKnown` (currently `:133`) and fold it into the confidence ladder (`:139-143`):

```swift
        let motionKnown = run.contains { $0.motion != nil }
        let ecgKnown    = run.contains { $0.ecgQualityTier != nil }

        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: start))
                 + Double(cal.component(.minute, from: start)) / 60

        let confidence: AnchorConfidence
        if !motionKnown || !ecgKnown     { confidence = .low }
        else if longEnoughForDC && !late { confidence = .high }
        else                             { confidence = .medium }
```

`AnchorReading.motionKnown` and `DailyAnchor.motionKnown` are unchanged — `ecgKnown` deliberately stays local so no SwiftData migration is needed.

- [ ] **Step 6: Run the tests to verify they pass**

Run the Step 2 command.
Expected: PASS, all 16 tests. `testFallsBackToHRStabilityWhenMotionUnknown` still expects `.low` and still gets it.

- [ ] **Step 7: Commit**

```bash
git add ios/Wythin/Metrics/AnchorDetector.swift ios/WythinTests/AnchorDetectorTests.swift
git commit -m "fix(anchor): accept rows that predate the quality fields

signalQuality and rrInvalidRate are the same measurement, but both were
guard-let, so a row carrying one and not the other was dropped for being
old rather than bad. An absent ECG tier now costs confidence, not the row."
```

---

### Task 3: Standardise the anchor to the first 5 minutes of the rest

**Files:**
- Modify: `ios/Wythin/Metrics/AnchorDetector.swift` — add `anchorWindowSec` to `AnchorThresholds`, rewrite `reading(from:late:)` (`:124-157`), add `leadingWindow`
- Test: `ios/WythinTests/AnchorDetectorTests.swift`

**Interfaces:**
- Consumes: `AnchorThresholds.minSamples` (Task 1), the `ecgKnown` confidence rung (Task 2).
- Produces: `AnchorThresholds.anchorWindowSec: Double`. `AnchorReading.durationSec` keeps its existing meaning — the length of the whole qualifying rest, which is what `DayPotentialStore` sends as `anchorDurationMin`, and `longEnoughForDC` keeps gating on it. Everything that *describes the reading* moves to the window: the medians, and also `motionKnown`/`ecgKnown`, which feed confidence. A confidence rating must describe the span that actually produced the numbers — if the window that yielded the medians carried no motion data, stillness was unverified for that reading however well-instrumented the rest of the run was. `passesRunGates` moves to the window for the same reason, so both checks mean the same span.

**Why:** a 12-minute rest and a 70-minute rest currently produce medians over wildly different spans, so day-to-day comparability drifts with whatever the morning allowed — which defeats the standardisation the anchor exists for. DC still gates on the *run* length, not the window, because DC is a phase-rectified statistic that needs the longer record to be stable; that check must not start failing just because the median window is capped.

- [ ] **Step 1: Write the failing test**

Add to `ios/WythinTests/AnchorDetectorTests.swift`:

```swift
    // MARK: - Window standardisation

    func testAnchorsOnTheFirstFiveMinutesOfALongRest() {
        // Five minutes at 60 bpm, then twenty-five more at 80. Still throughout —
        // one run — but only the standardised head may reach the median.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let points = (0..<900).map { i -> MetricsHistoryPoint in
            let t = Double(i) * 2
            return MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(t),
                                       meanBPM: t <= 300 ? 60 : 80,
                                       vti: t <= 300 ? 3.6 : 3.0,
                                       dc: 7.5, pip: 42, dfa1: 1.0,
                                       breathBPM: 13, motion: 5,
                                       signalQuality: 0.98, rrInvalidRate: 0.01,
                                       ecgQualityTier: 2)
        }
        let a = AnchorDetector.detect(points)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001,
                       "the 80 bpm tail is outside the 300 s window")
        XCTAssertEqual(a?.lnRMSSD ?? 0, 3.6, accuracy: 0.001)
        XCTAssertEqual(a?.durationSec ?? 0, 1798, accuracy: 1,
                       "durationSec still reports the whole rest, not the window")
        XCTAssertNotNil(a?.dc, "DC gates on the run length, not the window")
        XCTAssertEqual(a?.confidence, .high)
    }

    func testShortRestStillUsesEverythingItHas() {
        // Under 300 s there is no tail to trim — behaviour is unchanged.
        let a = AnchorDetector.detect(stillPoints(minutes: 4, hour: 7))
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.durationSec ?? 0, 238, accuracy: 1)
        XCTAssertNil(a?.dc)
        XCTAssertEqual(a?.confidence, .medium)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:WythinTests/AnchorDetectorTests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO | xcpretty
```
Expected: `testAnchorsOnTheFirstFiveMinutesOfALongRest` FAILS — `restingHR` comes back near 73 (the median across the whole 30 minutes), not 60.

- [ ] **Step 3: Add the window threshold**

In `AnchorThresholds`, immediately after `preferredMinSec`, add:

```swift
    /// The span the medians are taken over, however long the rest ran. A
    /// 12-minute rest and a 70-minute rest must produce comparable numbers,
    /// which they cannot if the median follows whatever the morning allowed.
    static let anchorWindowSec: Double = 300
```

- [ ] **Step 4: Median over the leading window**

Replace `reading(from:late:)` (`:124-157`) with:

```swift
    private static func reading(from run: [MetricsHistoryPoint], late: Bool) -> AnchorReading? {
        // The whole qualifying rest — this is what the provenance line reports,
        // and what DC's stability requirement is judged on.
        let dur = duration(run)

        // The standardised head of it — this is what the medians see.
        let window = leadingWindow(run)
        guard window.count >= AnchorThresholds.minSamples,
              let lnRMSSD  = median(window.compactMap { $0.vti }),
              let restingHR = median(window.compactMap { $0.meanBPM }),
              let start = window.first?.timestamp else { return nil }

        // DC is a phase-rectified statistic — it needs the longer record to be
        // stable, so a short rest drops it rather than reporting it noisily.
        let longEnoughForDC = dur >= AnchorThresholds.preferredMinSec
        let motionKnown = window.contains { $0.motion != nil }
        let ecgKnown    = window.contains { $0.ecgQualityTier != nil }

        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: start))
                 + Double(cal.component(.minute, from: start)) / 60

        let confidence: AnchorConfidence
        if !motionKnown || !ecgKnown     { confidence = .low }
        else if longEnoughForDC && !late { confidence = .high }
        else                             { confidence = .medium }

        return AnchorReading(
            startedAt:   start,
            durationSec: dur,
            hour:        hour,
            lnRMSSD:     lnRMSSD,
            dc:          longEnoughForDC ? median(window.compactMap { $0.dc }) : nil,
            restingHR:   restingHR,
            pip:         median(window.compactMap { $0.pip }),
            dfa1:        median(window.compactMap { $0.dfa1 }),
            breathBPM:   median(window.compactMap { $0.breathBPM }),
            late:        late,
            motionKnown: motionKnown,
            confidence:  confidence)
    }

    /// The first `anchorWindowSec` of a run. Shorter runs are returned whole —
    /// they have no tail to trim.
    private static func leadingWindow(_ run: [MetricsHistoryPoint]) -> [MetricsHistoryPoint] {
        guard let start = run.first?.timestamp else { return run }
        let cutoff = start.addingTimeInterval(AnchorThresholds.anchorWindowSec)
        return Array(run.prefix { $0.timestamp <= cutoff })
    }
```

Note the confidence ladder is unchanged from Task 2 — it is repeated here only because the whole function is being replaced.

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 2 command.
Expected: PASS, all 18 tests. `testFindsCleanMorningWindow` (6 minutes at 60 bpm) is unaffected because its whole run is one value.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Metrics/AnchorDetector.swift ios/WythinTests/AnchorDetectorTests.swift
git commit -m "feat(anchor): median over the first 5 minutes of the rest

A 12-minute rest and a 70-minute rest were medianed over their whole
span, so comparability drifted with whatever the morning allowed.
durationSec still reports the full rest; DC still gates on it."
```

---

### Task 4: Detect the anchor from the tick loop

**Files:**
- Modify: `ios/Wythin/App/AppEnvironment.swift` — add state near `:263`, add `detectAnchorIfDue(now:)` near `:162`, call it at `:589`
- Test: manual — this is an integration point, not a pure function. The detector's own behaviour is already covered by Tasks 1–3.

**Interfaces:**
- Consumes: `AnchorDetector.detect(_:now:)` as modified by Tasks 1–3.
- Produces: nothing other tasks depend on. `DayPotentialStore.refresh` is **not** modified — its inline detection stays as the immediate path for pull-to-refresh, and its `stored.first { $0.day == today }` check means whichever runs first wins. Both are `@MainActor`, so they cannot interleave.

**Why:** detection currently only happens inside `DayPotentialStore.refresh`, driven by `LiveStateWidget`'s 20 s task and `LiveView`'s pull-to-refresh (`LiveView.swift:162`). A morning you record but never open the Live tab for produces no anchor at all.

- [ ] **Step 1: Add the throttle state**

In `ios/Wythin/App/AppEnvironment.swift`, next to the other tick-loop throttles (currently `:262-264`), add:

```swift
    private var lastAnchorCheckAt: Date = .distantPast     // throttles anchor detection to ~5 min
```

- [ ] **Step 2: Add the detection hook**

Immediately after `evaluateNudgesIfDue(now:)` (which ends at `:180`), add:

```swift
    /// Freezes today's anchor as soon as a qualifying rest exists, without
    /// waiting for the Live tab to be opened — a morning recorded and never
    /// looked at is still a morning.
    ///
    /// Cheap because it exits on the day check in the overwhelming common case:
    /// once today's anchor exists, this is one fetch every five minutes.
    private func detectAnchorIfDue(now: Date) {
        guard now.timeIntervalSince(lastAnchorCheckAt) >= anchorCheckInterval else { return }
        lastAnchorCheckAt = now

        let today   = Calendar.current.startOfDay(for: now)
        let context = modelContainer.mainContext
        let stored  = (try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []
        guard !stored.contains(where: { $0.day == today }) else { return }

        let points = MetricsQualityFilter.filter(tickHistory.filter { $0.timestamp >= today })
        guard let reading = AnchorDetector.detect(points, now: now) else { return }
        context.insert(DailyAnchor(from: reading))
        try? context.save()
    }

    /// Anchors are frozen once a day, so checking every five minutes is generous.
    private let anchorCheckInterval: TimeInterval = 300
```

- [ ] **Step 3: Call it from the tick loop**

In the metrics tick loop, directly after the existing nudge lines (currently `:588-589`):

```swift
                self.nudges.ingest(point, now: point.timestamp)
                self.evaluateNudgesIfDue(now: point.timestamp)
```

add:

```swift
                self.detectAnchorIfDue(now: point.timestamp)
```

- [ ] **Step 4: Build and run the existing suite**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO | xcpretty
```
Expected: builds clean, all `WythinTests` pass. If the whole-target run surfaces pre-existing failures unrelated to the anchor, note them for Task 6 rather than fixing them here.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/App/AppEnvironment.swift
git commit -m "feat(anchor): detect today's anchor from the tick loop

Detection only ran inside DayPotentialStore, so a morning recorded and
never looked at produced no anchor."
```

---

### Task 5: Rebuild the history the old detector discarded

**Files:**
- Modify: `ios/Wythin/Models/DailyAnchor.swift:64-86` (`AnchorBackfill` only — the `@Model` is untouched)
- Test: manual verification on device, plus the existing `AnchorBaselineTests` must stay green.

**Interfaces:**
- Consumes: `AnchorDetector.detect(_:now:)` as modified by Tasks 1–3.
- Produces: `AnchorBackfill.flagKey` becomes `"anchorBackfillVersion"` (an `Int`, was a `Bool` under `"anchorBackfillCompleted"`), plus `AnchorBackfill.version: Int`. `runIfNeeded(context:defaults:)` keeps its signature.

**Why:** every anchor in the store was produced by the old detector, so past days are both missing (background-recorded days produced nothing) and inconsistent (foreground-dense days were medianed over their whole run). The baseline is built from those, so `PotentialScore` is comparing today against a distorted norm. `HRVSample` rows are never pruned — there is no retention job in the codebase — so days whose samples still exist can be recomputed exactly.

- [ ] **Step 1: Version the flag and recompute**

Replace the body of `AnchorBackfill` (`:64-86`) with:

```swift
enum AnchorBackfill {

    /// Versioned rather than boolean: whenever the detector's output changes,
    /// stored anchors have to be recomputed or they sit in the same baseline as
    /// anchors built by different rules, which is worse than having neither.
    static let flagKey = "anchorBackfillVersion"
    /// 2 — cadence-aware run splitting, tolerant quality gates, 300 s window.
    static let version = 2

    @MainActor
    static func runIfNeeded(context: ModelContext, defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: flagKey) < version else { return }
        defer { defaults.set(version, forKey: flagKey) }

        // Fetched directly rather than through sessions: continuous background
        // samples hang off an auto-created session, and an orphaned sample would
        // otherwise be invisible here.
        let samples = (try? context.fetch(FetchDescriptor<HRVSample>())) ?? []
        guard !samples.isEmpty else { return }

        let cal = Calendar.current
        let byDay = Dictionary(grouping: samples.map { MetricsHistoryPoint(from: $0) }) {
            cal.startOfDay(for: $0.timestamp)
        }

        // Recompute only days we can still recompute. A day whose raw samples
        // are gone keeps whatever was stored — a stale anchor beats no anchor,
        // and there is nothing to rebuild it from.
        let stored = (try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []
        for anchor in stored where byDay[anchor.day] != nil {
            context.delete(anchor)
        }

        for (_, dayPoints) in byDay {
            guard let reading = AnchorDetector.detect(MetricsQualityFilter.filter(dayPoints)) else { continue }
            context.insert(DailyAnchor(from: reading))
        }
        try? context.save()
    }
}
```

The old `"anchorBackfillCompleted"` key is abandoned deliberately: `defaults.integer(forKey: "anchorBackfillVersion")` returns `0` for every existing install, so the rebuild runs exactly once for everyone.

- [ ] **Step 2: Update the doc comment above the enum**

Replace the comment block at `:60-63` with:

```swift
/// Replay of stored samples into anchors, so a user with months of history does
/// not start from an empty baseline — and so a change to the detector does not
/// leave old anchors sitting in the same baseline as new ones.
```

- [ ] **Step 3: Build and run the suite**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO | xcpretty
```
Expected: builds clean, all tests pass.

- [ ] **Step 4: Verify on device**

Install on the phone with real history and open the Live tab. Confirm:
- The strip no longer reads `TODAY'S POTENTIAL · WAITING FOR A STILL MOMENT` on a morning where the strap was worn at rest.
- Expanding it shows an anchor start time in the morning and a plausible duration.
- The streak dots fill in for past days that previously had none.
- `baselineAnchors` in the expanded view is larger than before the change.

Record the before/after anchor count — that is the measure of how much history the gap rule was discarding.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Models/DailyAnchor.swift
git commit -m "fix(anchor): versioned backfill, recompute recoverable days

Every stored anchor came from the old detector, so the baseline today's
score is judged against is both thin and inconsistent."
```

---

### Task 6: Run the whole test target in CI

**Files:**
- Modify: `.github/workflows/ios.yml:27` (the `-only-testing` flag)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**Why:** CI runs `-only-testing:WythinTests/MetricsTests`, so `AnchorDetectorTests`, `AnchorBaselineTests`, `PotentialScoreTests`, `NudgeTriggersTests` and 27 other test files have never run in CI. Every test written in Tasks 1–3 would be invisible there.

- [ ] **Step 1: Run the full target locally first**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO | xcpretty
```
Expected: everything passes. If anything fails that Tasks 1–5 did not touch, stop and report it — a pre-existing failure is a finding, and silently skipping it would put the workflow back where it started.

- [ ] **Step 2: Drop the filter**

In `.github/workflows/ios.yml`, delete this line from the `Build & run unit tests (simulator)` step:

```yaml
            -only-testing:WythinTests/MetricsTests \
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ios.yml
git commit -m "ci(ios): run the whole WythinTests target

Only MetricsTests ran, so 31 other test files — the anchor, baseline,
score and nudge suites among them — never executed in CI."
```

---

## Out of scope, deliberately

Two findings from the investigation are **not** addressed here, because neither can be settled without data this plan does not produce:

1. **`AnchorThresholds.stillnessSD = 20` is uncalibrated.** Its own header comment says so. It is the SD of the ACC vector magnitude, a different statistic from the off-body detector's mean per-axis SD (`AppEnvironment.accStillnessThreshold = 3.0`, calibrated against real readings where an off-body strap measures 1.8–1.9). Once Task 5's backfill has run, the stored anchors give a real distribution of worn-still magnitude SD to calibrate against. Do that as a follow-up, with data.

2. **The API buckets by UTC day, the app by local day.** `get_day_summary("2026-07-29")` on a UTC−7 device folds in the previous evening, so app and API numbers disagree for that reason alone. That is an API design question, not an anchor bug.
