# Exercise Response Model — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Exercise sessions (now including Walk) score as Load plus three independent axes — Suppression, Recovery, Efficiency — instead of the mean benefit-signed delta across nine restorative metrics.

**Architecture:** All new computation is pure Swift over plain value types, taking raw `(date, value)` tuples exactly as `ActivityMetricStats` already does, so unit tests never construct a `MetricsHistoryPoint` or touch SwiftData. `ActivityLog` gains stored fields written at session end (alongside the existing `computeHRVWindows`) so the list row can render without re-reading samples. A new `ActivityClass` branch selects the exercise row and detail view; restorative activities fall through to the existing code untouched.

**Tech Stack:** Swift 5, SwiftUI, SwiftData, Swift Charts, XCTest. Xcode 16.

## Global Constraints

- **Exercise only.** Meditation, Breathwork, Meal, Nap, Thermal, Drinks, Work and Custom must render byte-identically to today. Any change to their code path is a defect.
- **No new data capture.** Every signal already exists on `HRVSample` / `MetricsHistoryPoint`.
- **All nine existing metrics stay reachable** under a `▸ Raw metrics (9)` disclosure in the exercise detail view.
- **Copy rules:** Load and raw depth are descriptive only. Recovery is the sole axis with a good/bad direction. Nothing is labelled "poor". Absent values render `—` with a reason, never a guess.
- **Chip direction:** all three axis chips are 0–100 where higher is better.
- **Palette:** use `Theme` only. Series colours — HR `Theme.rsa` (#FB923C), vagal `Theme.hrv` (#818CF8). Intensity domains — moderate `Theme.accent` (#00E5A0), heavy `#FDBA2D`, severe `#F43F5E`. The last two are new; add them to `Theme` as `domainHeavy` and `domainSevere`.
- **Test framework:** XCTest with `@testable import Wythin`. New test files go in `ios/WythinTests/`.
- **Every new `.swift` file must be added to `ios/Wythin.xcodeproj/project.pbxproj`** in the same task that creates it, or the build breaks.
- **Spec:** `docs/superpowers/specs/2026-07-31-exercise-response-model-design.md`. Visual reference: https://claude.ai/code/artifact/3be710f9-7a58-4545-8dae-fb79c3f32f8a

**Deviation from spec §11, deliberate:** the spec places Load inside `ExerciseResponse`. This plan puts it in `ExerciseIntensity` instead, because Load is HR-reserve-derived like `%HRR` and the domain split, and grouping them keeps `ExerciseResponse` a pure assembler.

**Phase 1 does NOT include:** `SessionSegmenter`, break ladder, live break coach, domain pill, the full recovery cascade (T30 / HRR60 / DC detrending / next-morning anchor), session map, trends, or the recommendation engine. Recovery in phase 1 is a single checkpoint — vagal reactivation from the existing 10-minute after-window — and renders as provisional.

## Setup

Before Task 1, create an isolated worktree off the freshly merged `main` (`9334255`). The shared checkout at `~/Code/Wythin` has another session's uncommitted edits to `ActivityDetailView.swift` and `ActivityImpact.swift` — two files this plan modifies. Use the `superpowers:using-git-worktrees` skill.

Run tests with:

```bash
xcodebuild test \
  -project ios/Wythin.xcodeproj \
  -scheme Wythin \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:WythinTests/<TestClassName> \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO | xcpretty
```

Use absolute paths for `-project` if the shell's working directory is uncertain. `WythinTests/BLETests` has a known pre-existing ECG-parse failure — it is red before you start and is not yours to fix.

## File Structure

| File | Responsibility |
|---|---|
| `ios/Wythin/Metrics/ActivityClass.swift` | `.activating` vs `.restorative`, derived from `ActivityType` |
| `ios/Wythin/Metrics/HRCeiling.swift` | personal HR ceiling from 180-day `meanBPM` history |
| `ios/Wythin/Metrics/ExerciseIntensity.swift` | `%HRR` series, α1 domain split, peak/mean, Load impulse |
| `ios/Wythin/Metrics/ExerciseSuppression.swift` | VSI slope with severe-domain exclusion; Efficiency slope |
| `ios/Wythin/Metrics/ExerciseResponse.swift` | assembles Load + three 0–100 axes from the above |
| `ios/Wythin/UI/Activities/ExerciseLogRow.swift` | list row: Load badge, sparkline, three chips |
| `ios/Wythin/UI/Activities/Charts/SessionTimelineChart.swift` | %HRR vs suppression on one axis, filled gap |
| `ios/Wythin/UI/Activities/Charts/IntensityDomainBar.swift` | stacked α1 domain bar |
| `ios/Wythin/UI/Activities/ExerciseDetailView.swift` | exercise detail screen |
| `ios/Wythin/Models/ActivityLog.swift` *(modify)* | Walk merge; stored axis fields; backfill v3 |
| `ios/Wythin/UI/Activities/ActivitiesView.swift` *(modify)* | branch row on `ActivityClass` |
| `ios/Wythin/UI/Design/Theme.swift` *(modify)* | `domainHeavy`, `domainSevere` |

---

### Task 1: Walk merges into Exercise

**Files:**
- Modify: `ios/Wythin/Models/ActivityLog.swift:7-98` (`ActivityType`)
- Test: `ios/WythinTests/ActivityTypeTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `ActivityType.pickerCases` now returns 8 tiles; `ActivityType.fromStored("Walk") == .exercise`; `ActivityType.exercise.subtypes` contains the four walk subtypes.

- [ ] **Step 1: Write the failing tests**

Add to `ActivityTypeTests.swift`:

```swift
// MARK: - Walk merge

func testWalkIsNoLongerAPickerTile() {
    XCTAssertFalse(ActivityType.pickerCases.contains(.walk),
                   "Walk folded into Exercise; it must not spend a tile")
    XCTAssertEqual(ActivityType.pickerCases.count, 8)
}

func testStoredWalkResolvesToExercise() {
    XCTAssertEqual(ActivityType.fromStored("Walk"), .exercise)
}

func testWalkSubtypesMovedOntoExercise() {
    let ex = ActivityType.exercise.subtypes
    for sub in ["Nature Walk", "City Walk", "Hiking", "Treadmill"] {
        XCTAssertTrue(ex.contains(sub), "\(sub) must be reachable under Exercise")
    }
}

func testLegacyWalkEntryKeepsItsSubtypeButShowsAsExercise() {
    let entry = ActivityLog(activityType: "Walk", activitySubtype: "Hiking")
    XCTAssertEqual(entry.activityTypeEnum, .exercise)
    XCTAssertEqual(entry.displayName, "Hiking", "history must not lose its label")
}
```

`testPickerHasExactlyNineTiles` will now fail. Change its expectation to 8 and rename it to `testPickerHasExactlyEightTiles`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:WythinTests/ActivityTypeTests | xcpretty`
Expected: FAIL — `pickerCases` still contains `.walk`; `fromStored("Walk")` returns `.walk`.

- [ ] **Step 3: Implement**

In `ActivityType`, exclude `.walk` from the grid:

```swift
    /// The eight tiles shown in the picker grid — Custom is offered separately
    /// beneath it, and Walk folded into Exercise (its subtypes moved across).
    static var pickerCases: [ActivityType] {
        allCases.filter { $0 != .custom && $0 != .walk }
    }
```

Add the mapping in `fromStored`, beside the existing legacy cases:

```swift
        case "Run":                      return .exercise
        case "Walk":                     return .exercise
        case "Cold Exposure", "Sauna":   return .thermal
        case "Coffee", "Alcohol":        return .drinks
```

`fromStored` returns early via `ActivityType(rawValue:)` for any raw value that still parses, and `"Walk"` does. Guard it before that lookup:

```swift
    static func fromStored(_ raw: String) -> ActivityType {
        if raw == "Walk" { return .exercise }   // merged tile; subtype is retained
        if let type = ActivityType(rawValue: raw) { return type }
        ...
    }
```

Append the walk subtypes to `.exercise`:

```swift
        case .exercise:
            return ["Easy Run", "Tempo Run", "Intervals", "Long Run", "Trail Run",
                    "Yoga", "HIIT", "Power Lifting", "Pilates", "Cycling",
                    "Swimming", "Stretching", "CrossFit", "Boxing",
                    "Rowing", "Climbing", "Martial Arts",
                    "Nature Walk", "City Walk", "Hiking", "Treadmill"]
```

Leave `case walk` in the enum and leave its `icon`, `color` and `subtypes` intact — old rows may still hold it in flight, and `testCurrentTypesStillResolve` iterates `allCases`. That test asserts `fromStored(type.rawValue) == type`, which now fails for `.walk`; exclude `.walk` from its loop with a comment naming the merge.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:WythinTests/ActivityTypeTests | xcpretty`
Expected: PASS, all cases.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Models/ActivityLog.swift ios/WythinTests/ActivityTypeTests.swift
git commit -m "feat(activities): fold Walk into Exercise, freeing a picker tile"
```

---

### Task 2: ActivityClass

**Files:**
- Create: `ios/Wythin/Metrics/ActivityClass.swift`
- Test: `ios/WythinTests/ActivityClassTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ActivityType` from Task 1
- Produces: `enum ActivityClass { case activating, restorative }` and `var ActivityType.activityClass: ActivityClass`

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ActivityClassTests.swift`:

```swift
import XCTest
@testable import Wythin

final class ActivityClassTests: XCTestCase {

    func testExerciseIsActivating() {
        XCTAssertEqual(ActivityType.exercise.activityClass, .activating)
    }

    func testWalkIsActivating() {
        // Walk is merged into Exercise but the case still exists for in-flight rows.
        XCTAssertEqual(ActivityType.walk.activityClass, .activating)
    }

    func testEverythingElseIsRestorative() {
        let restorative: [ActivityType] = [.meditation, .breathwork, .meal, .nap,
                                           .thermal, .drinks, .work, .custom]
        for type in restorative {
            XCTAssertEqual(type.activityClass, .restorative,
                           "\(type.rawValue) must keep the existing nine-metric path")
        }
    }

    func testEveryCaseIsClassified() {
        // A new ActivityType must be a deliberate choice, not a silent default.
        XCTAssertEqual(ActivityType.allCases.count, 10)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:WythinTests/ActivityClassTests | xcpretty`
Expected: FAIL — "value of type 'ActivityType' has no member 'activityClass'".

- [ ] **Step 3: Implement**

Create `ios/Wythin/Metrics/ActivityClass.swift`:

```swift
import Foundation

/// Which scoring model an activity uses.
///
/// Exercise raises heart rate and suppresses variability by design, so the
/// restorative benefit-delta model reads a hard session as a bad one. The two
/// classes exist so that never happens again — and so restorative activities
/// keep their original code path untouched.
enum ActivityClass {
    /// Load with expected vagal withdrawal: scored as Load + Suppression /
    /// Recovery / Efficiency.
    case activating
    /// Scored as the mean benefit-signed change across the nine metrics.
    case restorative
}

extension ActivityType {
    var activityClass: ActivityClass {
        switch self {
        case .exercise, .walk:
            return .activating
        case .meditation, .breathwork, .meal, .nap,
             .thermal, .drinks, .work, .custom:
            return .restorative
        }
    }
}
```

The switch is exhaustive without a `default`, so adding an `ActivityType` becomes a compile error rather than a silent restorative default.

- [ ] **Step 4: Add to the Xcode project and run tests**

Add `ActivityClass.swift` to the `Wythin` target and `ActivityClassTests.swift` to the `WythinTests` target in `project.pbxproj`.

Run: `xcodebuild test ... -only-testing:WythinTests/ActivityClassTests | xcpretty`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Metrics/ActivityClass.swift ios/WythinTests/ActivityClassTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): ActivityClass splits activating from restorative"
```

---

### Task 3: HRCeiling

**Files:**
- Create: `ios/Wythin/Metrics/HRCeiling.swift`
- Test: `ios/WythinTests/HRCeilingTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing
- Produces: `HRCeiling.ceiling(bpm: [Float], restingHR: Float) -> Float`

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/HRCeilingTests.swift`:

```swift
import XCTest
@testable import Wythin

final class HRCeilingTests: XCTestCase {

    func testCeilingIsThe99thPercentile() {
        // 100 values, 100...199. p99 index = Int(0.99 * 99) = 98 → 198.
        let bpm = (100...199).map { Float($0) }
        XCTAssertEqual(HRCeiling.ceiling(bpm: bpm, restingHR: 55), 198, accuracy: 0.001)
    }

    func testOutlierAboveThe99thPercentileIsIgnored() {
        var bpm = (100...199).map { Float($0) }
        bpm.append(240)   // a single artifact spike must not become the ceiling
        let c = HRCeiling.ceiling(bpm: bpm, restingHR: 55)
        XCTAssertLessThan(c, 240)
    }

    func testFloorAppliesWhenHistoryIsThin() {
        // Never seen above 90, but the ceiling must stay usable as a denominator.
        let bpm: [Float] = [70, 75, 80, 85, 90]
        XCTAssertEqual(HRCeiling.ceiling(bpm: bpm, restingHR: 55), 115, accuracy: 0.001)
    }

    func testEmptyHistoryFallsBackToTheFloor() {
        XCTAssertEqual(HRCeiling.ceiling(bpm: [], restingHR: 50), 110, accuracy: 0.001)
    }

    func testImplausibleValuesAreRejected() {
        let bpm: [Float] = [0, 20, 300, 500, 150, 160, 170]
        let c = HRCeiling.ceiling(bpm: bpm, restingHR: 55)
        XCTAssertLessThanOrEqual(c, 220)
        XCTAssertGreaterThanOrEqual(c, 115)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:WythinTests/HRCeilingTests | xcpretty`
Expected: FAIL — "cannot find 'HRCeiling' in scope".

- [ ] **Step 3: Implement**

Create `ios/Wythin/Metrics/HRCeiling.swift`:

```swift
import Foundation

/// The personal upper anchor for %HR-reserve, learned from the wearer's own
/// history rather than assumed from age.
///
/// 220-minus-age has a standard deviation of roughly ±11 bpm, which makes it
/// useless as a per-person denominator. The 99th percentile of what this heart
/// has actually done is both self-calibrating and honest: it rises as fitness
/// and effort rise, and it needs no profile input.
enum HRCeiling {

    /// Plausible instantaneous heart rate. Outside this, treat as artifact.
    static let plausible: ClosedRange<Float> = 30...220

    /// Minimum working span above resting, so the denominator can never
    /// collapse toward zero for someone with little hard-effort history.
    static let minimumSpan: Float = 60

    /// 99th percentile of `bpm`, floored at `restingHR + minimumSpan`.
    /// `bpm` is expected to be the last ~180 days of `meanBPM` samples.
    static func ceiling(bpm: [Float], restingHR: Float) -> Float {
        let floor = restingHR + minimumSpan
        let clean = bpm.filter { plausible.contains($0) }.sorted()
        guard !clean.isEmpty else { return floor }
        let idx = Int(0.99 * Float(clean.count - 1))
        return max(clean[idx], floor)
    }
}
```

- [ ] **Step 4: Add to the Xcode project and run tests**

Add both files to their targets in `project.pbxproj`.

Run: `xcodebuild test ... -only-testing:WythinTests/HRCeilingTests | xcpretty`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Metrics/HRCeiling.swift ios/WythinTests/HRCeilingTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(metrics): HRCeiling — personal HR ceiling from 180-day history"
```

---

### Task 4: ExerciseIntensity — %HRR, domain split, Load

**Files:**
- Create: `ios/Wythin/Metrics/ExerciseIntensity.swift`
- Test: `ios/WythinTests/ExerciseIntensityTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `HRCeiling` (Task 3)
- Produces:
  - `ExerciseIntensity.hrReserve(hr: Float, restingHR: Float, ceiling: Float) -> Double` — 0…1
  - `ExerciseIntensity.load(samples: [(date: Date, hr: Float)], restingHR: Float, ceiling: Float) -> Double`
  - `enum IntensityDomain { case moderate, heavy, severe }`
  - `ExerciseIntensity.domain(dfa1: Double) -> IntensityDomain`
  - `ExerciseIntensity.domainSplit(samples: [(date: Date, dfa1: Double)]) -> [IntensityDomain: TimeInterval]`

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ExerciseIntensityTests.swift`:

```swift
import XCTest
@testable import Wythin

final class ExerciseIntensityTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1000)
    private func t(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }

    // MARK: %HRR

    func testHRReserveIsFractionOfTheSpan() {
        // resting 50, ceiling 190 → span 140. hr 120 → 70/140 = 0.5
        XCTAssertEqual(ExerciseIntensity.hrReserve(hr: 120, restingHR: 50, ceiling: 190),
                       0.5, accuracy: 0.0001)
    }

    func testHRReserveClampsToUnitInterval() {
        XCTAssertEqual(ExerciseIntensity.hrReserve(hr: 40, restingHR: 50, ceiling: 190), 0)
        XCTAssertEqual(ExerciseIntensity.hrReserve(hr: 250, restingHR: 50, ceiling: 190), 1)
    }

    func testHRReserveIsZeroWhenTheSpanCollapses() {
        XCTAssertEqual(ExerciseIntensity.hrReserve(hr: 120, restingHR: 190, ceiling: 190), 0)
    }

    // MARK: Load

    func testLoadOfOneMinuteAtHalfReserve() {
        // x = 0.5, Δt = 1 min → 0.5 · e^(1.8·0.5) = 0.5 · 2.4596 = 1.2298
        let samples = [(date: t(0), hr: Float(120)), (date: t(60), hr: Float(120))]
        XCTAssertEqual(ExerciseIntensity.load(samples: samples, restingHR: 50, ceiling: 190),
                       1.2298, accuracy: 0.001)
    }

    func testLoadIsZeroAtRest() {
        let samples = [(date: t(0), hr: Float(50)), (date: t(600), hr: Float(50))]
        XCTAssertEqual(ExerciseIntensity.load(samples: samples, restingHR: 50, ceiling: 190),
                       0, accuracy: 0.0001)
    }

    func testHarderWorkCostsDisproportionatelyMore() {
        // The exponential weighting must make 10 min hard exceed 20 min easy.
        let easy = (0...20).map { (date: t(Double($0) * 60), hr: Float(85)) }   // x = 0.25
        let hard = (0...10).map { (date: t(Double($0) * 60), hr: Float(155)) }  // x = 0.75
        XCTAssertGreaterThan(ExerciseIntensity.load(samples: hard, restingHR: 50, ceiling: 190),
                             ExerciseIntensity.load(samples: easy, restingHR: 50, ceiling: 190))
    }

    func testLoadNeedsAtLeastTwoSamples() {
        XCTAssertEqual(ExerciseIntensity.load(samples: [(date: t(0), hr: Float(150))],
                                              restingHR: 50, ceiling: 190), 0)
    }

    func testLoadIgnoresLongGapsFromStrapDropout() {
        // A 40-minute gap must not be integrated as 40 minutes of work.
        let samples = [(date: t(0), hr: Float(150)), (date: t(2400), hr: Float(150))]
        XCTAssertEqual(ExerciseIntensity.load(samples: samples, restingHR: 50, ceiling: 190),
                       0, accuracy: 0.0001)
    }

    // MARK: Domains

    func testDomainBoundaries() {
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 1.05), .moderate)
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 0.75), .moderate, "0.75 is the moderate edge")
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 0.74), .heavy)
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 0.50), .heavy, "0.5 is the heavy edge")
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 0.49), .severe)
    }

    func testDomainSplitSumsDurationsPerDomain() {
        let samples: [(date: Date, dfa1: Double)] = [
            (t(0),   1.0),   // moderate for 60 s
            (t(60),  1.0),   // moderate for 60 s
            (t(120), 0.6),   // heavy for 60 s
            (t(180), 0.4),   // severe — last sample carries no forward duration
        ]
        let split = ExerciseIntensity.domainSplit(samples: samples)
        XCTAssertEqual(split[.moderate] ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(split[.heavy] ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(split[.severe] ?? 0, 0, accuracy: 0.001)
    }

    func testDomainSplitIsEmptyForASingleSample() {
        XCTAssertTrue(ExerciseIntensity.domainSplit(samples: [(t(0), 0.9)]).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:WythinTests/ExerciseIntensityTests | xcpretty`
Expected: FAIL — "cannot find 'ExerciseIntensity' in scope".

- [ ] **Step 3: Implement**

Create `ios/Wythin/Metrics/ExerciseIntensity.swift`:

```swift
import Foundation

/// Which physiological domain a moment of exercise sat in, read from the
/// fractal correlation of the heartbeat rather than from a heart-rate zone.
///
/// DFA α1 crosses 0.75 at the aerobic threshold and 0.5 entering the severe
/// domain. Because the boundaries are internal, two people at the same 148 bpm
/// can be in different domains — which a heart-rate zone cannot tell them.
enum IntensityDomain: Hashable {
    case moderate
    case heavy
    case severe
}

/// %HR-reserve, intensity domains and session Load. All pure.
enum ExerciseIntensity {

    /// DFA α1 at or above this is the moderate domain.
    static let moderateFloor: Double = 0.75
    /// DFA α1 at or above this (and below `moderateFloor`) is the heavy domain.
    static let heavyFloor: Double = 0.50

    /// Banister exponential weighting. 1.92 (male) / 1.67 (female) are the
    /// published constants; 1.8 is a fixed compromise because the app holds no
    /// sex. It may become a profile setting later; it is not one now.
    static let loadWeighting: Double = 1.8

    /// Gaps longer than this are strap dropout, not work, and contribute no
    /// load. Background ticks are 30 s, so 90 s tolerates ordinary jitter.
    static let maxGapSeconds: TimeInterval = 90

    /// Fraction of the heart-rate reserve in use, 0…1.
    static func hrReserve(hr: Float, restingHR: Float, ceiling: Float) -> Double {
        let span = Double(ceiling - restingHR)
        guard span > 0 else { return 0 }
        return min(max(Double(hr - restingHR) / span, 0), 1)
    }

    /// Session load: the HR-reserve impulse with Banister exponential weighting,
    /// integrated over the sample series. Unitless; an easy 30-minute walk lands
    /// near 14 and a hard hour near 150.
    static func load(samples: [(date: Date, hr: Float)],
                     restingHR: Float,
                     ceiling: Float) -> Double {
        guard samples.count >= 2 else { return 0 }
        let sorted = samples.sorted { $0.date < $1.date }
        var total = 0.0
        for i in 0..<(sorted.count - 1) {
            let dt = sorted[i + 1].date.timeIntervalSince(sorted[i].date)
            guard dt > 0, dt <= maxGapSeconds else { continue }
            let x = hrReserve(hr: sorted[i].hr, restingHR: restingHR, ceiling: ceiling)
            total += x * exp(loadWeighting * x) * (dt / 60)
        }
        return total
    }

    static func domain(dfa1: Double) -> IntensityDomain {
        if dfa1 >= moderateFloor { return .moderate }
        if dfa1 >= heavyFloor    { return .heavy }
        return .severe
    }

    /// Seconds spent in each domain. Each sample owns the interval forward to
    /// the next one; the final sample carries no forward duration.
    static func domainSplit(samples: [(date: Date, dfa1: Double)]) -> [IntensityDomain: TimeInterval] {
        guard samples.count >= 2 else { return [:] }
        let sorted = samples.sorted { $0.date < $1.date }
        var split: [IntensityDomain: TimeInterval] = [:]
        for i in 0..<(sorted.count - 1) {
            let dt = sorted[i + 1].date.timeIntervalSince(sorted[i].date)
            guard dt > 0, dt <= maxGapSeconds else { continue }
            split[domain(dfa1: sorted[i].dfa1), default: 0] += dt
        }
        return split
    }
}
```

- [ ] **Step 4: Add to the Xcode project and run tests**

Run: `xcodebuild test ... -only-testing:WythinTests/ExerciseIntensityTests | xcpretty`
Expected: PASS, all 11 cases.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Metrics/ExerciseIntensity.swift ios/WythinTests/ExerciseIntensityTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(metrics): ExerciseIntensity — %HRR, DFA a1 domains, Load impulse"
```

---

### Task 5: ExerciseSuppression — the VSI slope

**Files:**
- Create: `ios/Wythin/Metrics/ExerciseSuppression.swift`
- Test: `ios/WythinTests/ExerciseSuppressionTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `IntensityDomain`, `ExerciseIntensity` (Task 4)
- Produces:
  - `struct VSIFit { let slopePer10: Double; let sampleCount: Int }`
  - `ExerciseSuppression.vsi(samples: [(hrrPct: Double, dc: Double, dfa1: Double?)]) -> VSIFit?`
  - `ExerciseSuppression.depth(dcTrough: Double, dcPre: Double) -> Double?`

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ExerciseSuppressionTests.swift`:

```swift
import XCTest
@testable import Wythin

final class ExerciseSuppressionTests: XCTestCase {

    /// lnDC = 2.0 − 0.02·hrr, so the true slope is −0.20 per 10 %HRR.
    private func synthetic(hrr: Double, dfa1: Double? = 1.0)
        -> (hrrPct: Double, dc: Double, dfa1: Double?) {
        (hrrPct: hrr, dc: exp(2.0 - 0.02 * hrr), dfa1: dfa1)
    }

    func testSlopeRecoversAKnownRelationship() {
        let samples = stride(from: 30.0, through: 80.0, by: 5.0).map { synthetic(hrr: $0) }
        let fit = ExerciseSuppression.vsi(samples: samples)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.slopePer10, -0.20, accuracy: 0.0001)
        XCTAssertEqual(fit!.sampleCount, samples.count)
    }

    func testSevereDomainSamplesAreExcludedFromTheFit() {
        // DC floors in the severe domain: the numerator cannot fall further while
        // the denominator keeps climbing, so those points must not enter the fit.
        var samples = stride(from: 30.0, through: 80.0, by: 5.0).map { synthetic(hrr: $0) }
        // Floored DC at very high HRR, tagged severe — must be ignored.
        samples += (85...95).map { (hrrPct: Double($0), dc: 0.05, dfa1: Double?(0.30)) }
        let fit = ExerciseSuppression.vsi(samples: samples)
        XCTAssertEqual(fit!.slopePer10, -0.20, accuracy: 0.0001,
                       "severe-domain points must not steepen the fit")
        XCTAssertEqual(fit!.sampleCount, 11)
    }

    func testSamplesWithUnknownDomainAreKept() {
        // A nil α1 is missing data, not evidence of the severe domain.
        let samples = stride(from: 30.0, through: 80.0, by: 5.0).map {
            synthetic(hrr: $0, dfa1: nil)
        }
        XCTAssertEqual(ExerciseSuppression.vsi(samples: samples)!.slopePer10,
                       -0.20, accuracy: 0.0001)
    }

    func testNonPositiveDCIsRejected() {
        // ln(0) is undefined and ln of a negative is NaN — both must be dropped
        // rather than poisoning the regression.
        var samples = stride(from: 30.0, through: 80.0, by: 5.0).map { synthetic(hrr: $0) }
        samples.append((hrrPct: 60, dc: 0, dfa1: 1.0))
        samples.append((hrrPct: 65, dc: -3, dfa1: 1.0))
        let fit = ExerciseSuppression.vsi(samples: samples)
        XCTAssertEqual(fit!.slopePer10, -0.20, accuracy: 0.0001)
        XCTAssertFalse(fit!.slopePer10.isNaN)
    }

    func testTooFewPointsYieldsNoFit() {
        XCTAssertNil(ExerciseSuppression.vsi(samples: [synthetic(hrr: 40)]))
        XCTAssertNil(ExerciseSuppression.vsi(samples: []))
    }

    func testCollapsedHRRSpanYieldsNoFit() {
        // Every point at the same intensity — the slope is undefined, not zero.
        let samples = (0..<10).map { _ in synthetic(hrr: 55) }
        XCTAssertNil(ExerciseSuppression.vsi(samples: samples))
    }

    func testSteeperSlopeMeansCostlier() {
        let usual = stride(from: 30.0, through: 80.0, by: 5.0).map { synthetic(hrr: $0) }
        let costly = stride(from: 30.0, through: 80.0, by: 5.0).map {
            (hrrPct: $0, dc: exp(2.0 - 0.03 * $0), dfa1: Double?(1.0))
        }
        XCTAssertLessThan(ExerciseSuppression.vsi(samples: costly)!.slopePer10,
                          ExerciseSuppression.vsi(samples: usual)!.slopePer10)
    }

    // MARK: Depth

    func testDepthIsTheFractionOfVagalToneWithdrawn() {
        XCTAssertEqual(ExerciseSuppression.depth(dcTrough: 2.5, dcPre: 10)!,
                       0.75, accuracy: 0.0001)
    }

    func testDepthClampsAndRejectsAnUnusableBaseline() {
        XCTAssertEqual(ExerciseSuppression.depth(dcTrough: 12, dcPre: 10)!, 0,
                       "a trough above baseline is no withdrawal, not negative withdrawal")
        XCTAssertNil(ExerciseSuppression.depth(dcTrough: 2, dcPre: 0))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:WythinTests/ExerciseSuppressionTests | xcpretty`
Expected: FAIL — "cannot find 'ExerciseSuppression' in scope".

- [ ] **Step 3: Implement**

Create `ios/Wythin/Metrics/ExerciseSuppression.swift`:

```swift
import Foundation

/// The fitted relationship between vagal tone and cardiovascular work.
struct VSIFit {
    /// Change in lnDC per 10 percentage points of HR reserve. Negative: vagal
    /// tone falls as intensity rises. A steeper (more negative) slope means
    /// more vagal shutdown was spent to reach the same heart rate.
    let slopePer10: Double
    /// How many samples entered the fit, after exclusions.
    let sampleCount: Int
}

/// Vagal Suppression Index — how deeply the vagus had to be switched off for
/// this load, normalised by internal load.
///
/// Fitted as a slope across the whole session rather than a single
/// trough-versus-peak ratio, for two reasons: a ratio throws away everything
/// between the two points, and it breaks at high intensity, where DC floors
/// near zero while %HRR keeps climbing.
enum ExerciseSuppression {

    /// A regression needs at least this many surviving points to mean anything.
    static let minimumSamples = 4

    /// Below this spread in %HRR the slope is numerically meaningless.
    static let minimumHRRSpan: Double = 5

    /// Slope of lnDC against %HRR, in lnDC per 10 %HRR.
    ///
    /// Severe-domain samples are excluded: DC has floored there, so the
    /// numerator physically cannot fall further while the denominator keeps
    /// growing. Including them measures the floor, not the person. A `nil`
    /// α1 is missing data rather than evidence of the severe domain, so those
    /// samples are kept.
    static func vsi(samples: [(hrrPct: Double, dc: Double, dfa1: Double?)]) -> VSIFit? {
        let usable = samples.filter { s in
            guard s.dc > 0 else { return false }
            if let a = s.dfa1, ExerciseIntensity.domain(dfa1: a) == .severe { return false }
            return true
        }
        guard usable.count >= minimumSamples else { return nil }

        let xs = usable.map(\.hrrPct)
        guard let lo = xs.min(), let hi = xs.max(), hi - lo >= minimumHRRSpan else { return nil }

        let ys = usable.map { log($0.dc) }
        let n  = Double(usable.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n

        var num = 0.0, den = 0.0
        for i in 0..<usable.count {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        guard den > 0 else { return nil }

        return VSIFit(slopePer10: (num / den) * 10, sampleCount: usable.count)
    }

    /// Fraction of pre-session vagal tone withdrawn at the trough, 0…1.
    /// Descriptive only — depth is the size of the stimulus, not its quality.
    static func depth(dcTrough: Double, dcPre: Double) -> Double? {
        guard dcPre > 0 else { return nil }
        return min(max(1 - dcTrough / dcPre, 0), 1)
    }
}
```

- [ ] **Step 4: Add to the Xcode project and run tests**

Run: `xcodebuild test ... -only-testing:WythinTests/ExerciseSuppressionTests | xcpretty`
Expected: PASS, all 9 cases.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Metrics/ExerciseSuppression.swift ios/WythinTests/ExerciseSuppressionTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(metrics): ExerciseSuppression — VSI as a slope, severe domain excluded"
```

---

### Task 6: ExerciseResponse — assemble Load and the three axes

**Files:**
- Create: `ios/Wythin/Metrics/ExerciseResponse.swift`
- Test: `ios/WythinTests/ExerciseResponseTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ExerciseIntensity` (Task 4), `ExerciseSuppression` (Task 5)
- Produces:
  - `enum AxisValue { case score(Int, word: String); case unavailable(reason: String) }`
  - `struct ExerciseResponse { let load: Int; let suppression: AxisValue; let recovery: AxisValue; let efficiency: AxisValue; let domainSplit: [IntensityDomain: TimeInterval] }`
  - `ExerciseResponse.percentileScore(value: Double, history: [Double], lowerIsBetter: Bool) -> Int?`
  - `ExerciseResponse.reactivationScore(dcAfter: Double?, dcPre: Double?) -> AxisValue`

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ExerciseResponseTests.swift`:

```swift
import XCTest
@testable import Wythin

final class ExerciseResponseTests: XCTestCase {

    // MARK: Percentile scoring

    func testCheapestSlopeInHistoryScoresHighest() {
        // lowerIsBetter: a less negative slope is cheaper. -0.10 beats all of these.
        let history = [-0.20, -0.25, -0.30, -0.35]
        let score = ExerciseResponse.percentileScore(value: -0.10, history: history,
                                                     lowerIsBetter: false)
        XCTAssertEqual(score, 100)
    }

    func testCostliestSlopeScoresLowest() {
        let history = [-0.20, -0.25, -0.30, -0.35]
        XCTAssertEqual(ExerciseResponse.percentileScore(value: -0.40, history: history,
                                                        lowerIsBetter: false), 0)
    }

    func testMedianValueScoresNearFifty() {
        let history = [-0.10, -0.20, -0.30, -0.40]
        let score = ExerciseResponse.percentileScore(value: -0.25, history: history,
                                                     lowerIsBetter: false)!
        XCTAssertEqual(Double(score), 50, accuracy: 15)
    }

    func testTooLittleHistoryYieldsNoScore() {
        XCTAssertNil(ExerciseResponse.percentileScore(value: -0.2, history: [-0.3, -0.25],
                                                      lowerIsBetter: false))
    }

    // MARK: Recovery, phase 1 — a single checkpoint

    func testReactivationScoresAndReadsProvisional() {
        // 41% of pre-session vagal tone back at the 10-minute mark.
        guard case let .score(value, word) =
                ExerciseResponse.reactivationScore(dcAfter: 4.1, dcPre: 10) else {
            return XCTFail("expected a score")
        }
        XCTAssertEqual(value, 41)
        XCTAssertEqual(word, "provisional · 1 of 7",
                       "phase 1 has one checkpoint and must say so")
    }

    func testReactivationIsUnavailableWithoutABaseline() {
        guard case let .unavailable(reason) =
                ExerciseResponse.reactivationScore(dcAfter: 4.1, dcPre: nil) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testReactivationAboveBaselineCapsAtOneHundred() {
        guard case let .score(value, _) =
                ExerciseResponse.reactivationScore(dcAfter: 14, dcPre: 10) else {
            return XCTFail("expected a score")
        }
        XCTAssertEqual(value, 100)
    }

    // MARK: Unavailability is stated, never guessed

    func testTwoKindsOfEmptinessReadDifferently() {
        let thin = ExerciseResponse.efficiency(slope: -0.2, history: [-0.3],
                                               hasExternalSignal: true)
        guard case let .unavailable(r1) = thin else { return XCTFail("expected unavailable") }
        XCTAssertTrue(r1.contains("of 3"), "thin history must show progress toward a baseline")

        let noSignal = ExerciseResponse.efficiency(slope: nil, history: [],
                                                   hasExternalSignal: false)
        guard case let .unavailable(r2) = noSignal else { return XCTFail("expected unavailable") }
        XCTAssertTrue(r2.lowercased().contains("signal"),
                      "a missing denominator is a different absence from a thin history")
        XCTAssertNotEqual(r1, r2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:WythinTests/ExerciseResponseTests | xcpretty`
Expected: FAIL — "cannot find 'ExerciseResponse' in scope".

- [ ] **Step 3: Implement**

Create `ios/Wythin/Metrics/ExerciseResponse.swift`:

```swift
import Foundation

/// One axis reading. An axis that cannot be computed says why rather than
/// showing a number it does not have.
enum AxisValue: Equatable {
    case score(Int, word: String)
    case unavailable(reason: String)
}

/// The exercise scoring model: one descriptive magnitude and three
/// directional axes that are never averaged together.
///
/// Load carries the size of the stimulus, which is what frees all three axes
/// to point the same way — higher is better on every one.
struct ExerciseResponse {
    let load:         Int
    let suppression:  AxisValue
    let recovery:     AxisValue
    let efficiency:   AxisValue
    let domainSplit:  [IntensityDomain: TimeInterval]

    /// Sessions of the same subtype needed before a comparison means anything.
    static let minimumHistory = 3

    /// Position of `value` within `history`, as 0…100 where higher is better.
    static func percentileScore(value: Double,
                                history: [Double],
                                lowerIsBetter: Bool) -> Int? {
        guard history.count >= minimumHistory else { return nil }
        let better = history.filter { lowerIsBetter ? value < $0 : value > $0 }.count
        let equal  = history.filter { $0 == value }.count
        let pct = (Double(better) + 0.5 * Double(equal)) / Double(history.count) * 100
        return Int(min(max(pct, 0), 100).rounded())
    }

    /// Phase 1 Recovery: vagal reactivation from the existing 10-minute
    /// after-window, as a percentage of pre-session DC. One checkpoint of the
    /// seven the full cascade will carry, so it always reads provisional.
    static func reactivationScore(dcAfter: Double?, dcPre: Double?) -> AxisValue {
        guard let after = dcAfter, let pre = dcPre, pre > 0 else {
            return .unavailable(reason: "no baseline")
        }
        let pct = min(max(after / pre * 100, 0), 100)
        return .score(Int(pct.rounded()), word: "provisional · 1 of 7")
    }

    /// Efficiency: cost per unit of external mechanical work. Two distinct
    /// absences — no denominator at all, versus not enough history to compare
    /// against — and they must read differently.
    static func efficiency(slope: Double?,
                           history: [Double],
                           hasExternalSignal: Bool) -> AxisValue {
        guard hasExternalSignal, let slope else {
            return .unavailable(reason: "no ext. signal")
        }
        guard let score = percentileScore(value: slope, history: history,
                                          lowerIsBetter: false) else {
            return .unavailable(reason: "\(history.count + 1) of \(minimumHistory)")
        }
        return .score(score, word: word(for: score))
    }

    /// Suppression: cost per unit of internal (heart-rate) work.
    static func suppression(slope: Double?, history: [Double]) -> AxisValue {
        guard let slope else { return .unavailable(reason: "no fit") }
        guard let score = percentileScore(value: slope, history: history,
                                          lowerIsBetter: false) else {
            return .unavailable(reason: "\(history.count + 1) of \(minimumHistory)")
        }
        return .score(score, word: word(for: score))
    }

    /// Plain-language read. Never "poor" — see the spec's copy rules.
    static func word(for score: Int) -> String {
        switch score {
        case 80...:   return "cheap"
        case 60..<80: return "better than usual"
        case 40..<60: return "typical"
        case 20..<40: return "costlier than usual"
        default:      return "costly"
        }
    }
}
```

- [ ] **Step 4: Add to the Xcode project and run tests**

Run: `xcodebuild test ... -only-testing:WythinTests/ExerciseResponseTests | xcpretty`
Expected: PASS, all 8 cases.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Metrics/ExerciseResponse.swift ios/WythinTests/ExerciseResponseTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(metrics): ExerciseResponse — Load plus three independent axes"
```

---

### Task 7: Persist the response on ActivityLog

**Files:**
- Modify: `ios/Wythin/Models/ActivityLog.swift` (new stored properties; `computeHRVWindows`; `backfillMissingWindows`)
- Test: `ios/WythinTests/ExerciseResponsePersistenceTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ExerciseIntensity`, `ExerciseSuppression`, `ExerciseResponse` (Tasks 4–6)
- Produces: on `ActivityLog` — `var exerciseLoad: Double?`, `var vsiSlopePer10: Double?`, `var efficiencySlope: Double?`, `var hasExternalWorkSignal: Bool`, `var domainModerateSec: Double?`, `var domainHeavySec: Double?`, `var domainSevereSec: Double?`; and `func computeExerciseResponse(context: ModelContext)`

**Why stored:** the list row has no sample series in hand — only the window averages already on the model. The VSI slope needs the full series, so it is computed once at session end and written, exactly as `computeHRVWindows` already does for the window averages.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ExerciseResponsePersistenceTests.swift`. Use an in-memory SwiftData container, following the pattern already used in `ImpactDeltaTests.swift` — open that file first and mirror its container setup.

```swift
import XCTest
import SwiftData
@testable import Wythin

final class ExerciseResponsePersistenceTests: XCTestCase {

    func testFinishedExerciseGetsALoadAndASlope() throws {
        // Build a container with ActivityLog + HRVSample, insert an exercise
        // entry with a synthetic sample series spanning before/during/after,
        // call computeExerciseResponse, and assert the stored fields.
        //
        // The series must include: rising HR through the during-window, DC
        // falling as HR rises, and DFA a1 above 0.5 so nothing is excluded.
        //
        // Assert: exerciseLoad > 0, vsiSlopePer10 < 0, domain seconds sum to
        // roughly the during-window duration.
    }

    func testRestorativeEntryGetsNoExerciseFields() throws {
        // A meditation entry must come back with exerciseLoad == nil after
        // computeExerciseResponse — the guard on ActivityClass must hold.
    }

    func testBackfillIsIdempotent() throws {
        // Run backfillMissingWindows twice; the second run must not change
        // any stored value.
    }
}
```

Fill each body in using `ImpactDeltaTests.swift`'s container helper. Do not leave the bodies as comments — they are described here rather than written out because the container boilerplate must match whatever that file currently does, and copying a stale version of it would break the build.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:WythinTests/ExerciseResponsePersistenceTests | xcpretty`
Expected: FAIL — `computeExerciseResponse` does not exist.

- [ ] **Step 3: Implement**

Add the stored properties to `ActivityLog` beside the existing window fields, all optional so SwiftData migrates without a version bump:

```swift
    // Exercise response (activating class only; nil for restorative entries)
    var exerciseLoad:          Double?
    var vsiSlopePer10:         Double?
    var efficiencySlope:       Double?
    var hasExternalWorkSignal: Bool = false
    var domainModerateSec:     Double?
    var domainHeavySec:        Double?
    var domainSevereSec:       Double?
```

Add `computeExerciseResponse(context:)`, modelled directly on `computeHRVWindows`: same predicate, same `MetricsQualityFilter` gate, same `[startedAt, end)` during-window partition. Guard on `activityTypeEnum.activityClass == .activating` and return immediately otherwise.

Inside it: derive `restingHR` and `ceiling` (fetch 180 days of `HRVSample.meanBPM` for the ceiling; use `AnchorBaseline.restingHR.mean` when available, else the 5th percentile of the same history), build the three tuple arrays, and call into Tasks 4–6.

Set `hasExternalWorkSignal` from the subtype: `true` for the motion-bearing subtypes (`Easy Run`, `Tempo Run`, `Intervals`, `Long Run`, `Trail Run`, `HIIT`, `Boxing`, `Rowing`, `Nature Walk`, `City Walk`, `Hiking`, `Treadmill`), `false` otherwise. Put this list in `ExerciseIntensity` as `static let motionBearingSubtypes: Set<String>` so it is testable and has one home.

Call `computeExerciseResponse` everywhere `computeHRVWindows` is already called — `ActivityLogging.end`, `ActivityLogging.logPast`, the edit-sheet callback in `ActivitiesView.sheetContent`, and `backfillMissingWindows`. Bump the backfill version constant from 2 to 3.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:WythinTests/ExerciseResponsePersistenceTests | xcpretty`
Then the full activity suite: `-only-testing:WythinTests/ActivityTypeTests -only-testing:WythinTests/ImpactDeltaTests -only-testing:WythinTests/ActivityMetricStatsTests`
Expected: PASS. `ImpactDeltaTests` must still pass untouched — restorative scoring is unchanged.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Models/ActivityLog.swift ios/Wythin/Metrics/ExerciseIntensity.swift ios/WythinTests/ExerciseResponsePersistenceTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): compute and store the exercise response at session end"
```

---

### Task 8: ExerciseLogRow

**Files:**
- Create: `ios/Wythin/UI/Activities/ExerciseLogRow.swift`
- Modify: `ios/Wythin/UI/Activities/ActivitiesView.swift` (extract the existing `ActivityLogRow`, then branch)
- Modify: `ios/Wythin/UI/Design/Theme.swift` (add `domainHeavy`, `domainSevere`)
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ActivityClass` (Task 2), stored fields (Task 7), `AxisValue` (Task 6)
- Produces: `struct ExerciseLogRow: View { let entry: ActivityLog }`

**Reference:** section 02 of the mockup.

- [ ] **Step 1: Extract the existing row, unchanged**

`ActivitiesView.swift` is 502 lines. Move `ActivityLogRow` and `LogMetricCell` verbatim into a new `ios/Wythin/UI/Activities/ActivityLogRow.swift`, changing only `private struct` to `struct` so it stays reachable. No behaviour change.

Build and run `-only-testing:WythinTests/ActivityTypeTests` to confirm the project still compiles.

Commit: `refactor(activities): extract ActivityLogRow from ActivitiesView`

- [ ] **Step 2: Add the two domain colours to Theme**

In `Theme`, beside the existing accents:

```swift
    static let domainHeavy  = Color(hex: "#FDBA2D")   // DFA a1 0.50–0.75
    static let domainSevere = Color(hex: "#F43F5E")   // DFA a1 < 0.50
```

These are not `Theme.rsa` and `Theme.warn`: that pair sits at ΔE 10.9 in normal vision and is genuinely hard to tell apart in a stacked bar. These values were validated against the card surface at ΔE 22.3 normal, 11.8 protan.

- [ ] **Step 3: Build ExerciseLogRow**

Create `ios/Wythin/UI/Activities/ExerciseLogRow.swift`. Layout, matching section 02 of the mockup:

- Header identical to `ActivityLogRow` — icon circle, `displayName`, `timeStr · durationString`.
- Trailing badge: `exerciseLoad` rounded to an integer over a `LOAD` caption in `Theme.monoLabel`/`Theme.dim`. Renders nothing when nil.
- A 34pt-tall sparkline of the during-window HR series. Phase 1 has no stored series, so read it from `entry.duringHR` only if a series is unavailable — if there is no series, omit the sparkline entirely rather than drawing a flat line.
- Three chips in a `LazyVGrid` of 3 columns, spacing 6, mirroring `LogMetricCell`'s styling: caption in 8.5pt `Theme.dim`, value in 17pt semibold, word in 8.5pt `Theme.dim`. Colours: Suppression `Theme.hrv`, Recovery `Theme.accent`, Efficiency `Theme.breathe`.
- `AxisValue.unavailable(reason:)` renders `—` in `Theme.dim` with the reason as the word. Never a zero.

- [ ] **Step 4: Branch in ActivitiesView**

In the `ForEach(group.entries)` body:

```swift
                    ForEach(group.entries) { entry in
                        Group {
                            switch entry.activityTypeEnum.activityClass {
                            case .activating:  ExerciseLogRow(entry: entry)
                            case .restorative: ActivityLogRow(entry: entry)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { activeSheet = .detail(entry) }
                        // ...existing swipe actions and row styling unchanged
                    }
```

- [ ] **Step 5: Verify visually, then commit**

Launch the app on the iPhone 17 Pro simulator. Confirm: an exercise entry shows Load and three chips; a meditation entry shows the nine-cell grid exactly as before; a legacy `"Walk"` entry appears with its subtype label and the exercise treatment.

```bash
git add ios/Wythin/UI/Activities/ExerciseLogRow.swift ios/Wythin/UI/Activities/ActivityLogRow.swift ios/Wythin/UI/Activities/ActivitiesView.swift ios/Wythin/UI/Design/Theme.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): exercise list row — Load badge and three axis chips"
```

---

### Task 9: ExerciseDetailView with timeline and domain bar

**Files:**
- Create: `ios/Wythin/UI/Activities/Charts/SessionTimelineChart.swift`
- Create: `ios/Wythin/UI/Activities/Charts/IntensityDomainBar.swift`
- Create: `ios/Wythin/UI/Activities/ExerciseDetailView.swift`
- Modify: `ios/Wythin/UI/Activities/ActivitiesView.swift` (`sheetContent`)
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: everything above
- Produces: `struct ExerciseDetailView: View { @Bindable var entry: ActivityLog }`

**Reference:** section 04 of the mockup.

- [ ] **Step 1: IntensityDomainBar**

A stacked horizontal bar, 16pt tall, corner radius 4, from `[IntensityDomain: TimeInterval]`. Segments in order moderate → heavy → severe, coloured `Theme.accent` / `Theme.domainHeavy` / `Theme.domainSevere`, with a **2pt gap between segments** — adjacent fills need a surface-coloured separator or the boundary reads as a third colour. Zero-duration domains are omitted, not drawn as slivers. Caption underneath: `22 min moderate · 28 heavy · 12 severe`, each in its own colour.

- [ ] **Step 2: SessionTimelineChart**

Two `LineMark` series on **one** normalised 0–100 y-axis — %HRR in `Theme.rsa`, % vagal withdrawn in `Theme.hrv` — with an `AreaMark` filling between them at `Theme.hrv.opacity(0.16)`. Never a second y-axis: the whole point is that the two are directly comparable and the gap is the reading.

`% vagal withdrawn` per sample is `(1 - dc / dcPre) * 100`, clamped 0…100, using the entry's `beforeDC` as `dcPre`. Where `dcPre` is nil or zero, render the HR series alone and omit the fill.

A legend is required (two series): direct labels at the series ends, plus a caption row. Include a `.chartOverlay` crosshair with a tooltip reporting time, both values, and the gap — the mockup's hover behaviour.

- [ ] **Step 3: ExerciseDetailView**

Copy `ActivityDetailView`'s scaffolding — the same `NavigationStack`, `loadChartPoints`, `Done` toolbar item, `onChange` reload on `startedAt`/`endedAt`. Then the card stack, in order:

1. Header — icon, name, date, duration, Load badge
2. `SESSION` card — `SessionTimelineChart` then `IntensityDomainBar`
3. `SUPPRESSION · VSI` card — score, word, and a readout row: `VSI <slope> lnDC / 10 %HRR`, `depth <word>`, `τ_on` omitted in phase 1
4. `RECOVERY` card — score and `provisional · 1 of 7`
5. `EFFICIENCY` card — score, or `—` with its reason
6. `COACH` card — reuse `ActivityDetailView`'s `coachInsight` and `entry.insightText` verbatim
7. `▸ Raw metrics (9)` — a `DisclosureGroup` containing the existing `ForEach(metrics)` of `MetricProgressRow`, unchanged

Compute the `metrics` array exactly as `ActivityDetailView` does so the raw rows behave identically.

- [ ] **Step 4: Route the sheet**

In `ActivitiesView.sheetContent`:

```swift
        case .detail(let entry):
            switch entry.activityTypeEnum.activityClass {
            case .activating:  ExerciseDetailView(entry: entry)
            case .restorative: ActivityDetailView(entry: entry)
            }
```

- [ ] **Step 5: Verify and commit**

Run the full test suite: `xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO | xcpretty`

Expected: everything passes except the known pre-existing `BLETests` ECG-parse failure. If anything else is red, it is yours.

Launch on the simulator. Open an exercise session: the timeline renders, the domain bar splits, three cards show scores, and `▸ Raw metrics (9)` expands to the nine familiar rows. Open a meditation session: it is the old screen, unchanged.

```bash
git add ios/Wythin/UI/Activities/Charts/ ios/Wythin/UI/Activities/ExerciseDetailView.swift ios/Wythin/UI/Activities/ActivitiesView.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): exercise detail — session timeline and intensity domains"
```

---

## Self-Review

**Spec coverage for phase 1.** §2.1 ActivityClass → Task 2. §2.2 Walk merge → Task 1. §3 signal roster → Tasks 4–5 consume exactly those. §4 Load → Task 4. §5.1 Suppression as a slope with severe exclusion → Task 5. §5.2 Recovery, phase-1 subset → Task 6 `reactivationScore`. §5.3 Efficiency with two distinct absences → Task 6. §8.1 list row → Task 8. §8.3 detail view items 1, 2, 3, 4, 5, 7, 8 → Task 9. §8.7 copy rules → Task 6 `word(for:)` and Task 8's unavailable rendering.

**Deliberately deferred, and covered by later phases:** §5.1 τ_on and Stability, §5.2 the six other checkpoints, §6 segmentation and break quality, §7.1 DC detrending, §7.3 breathing, §8.2 live banner, §8.4 session map, §8.5 records, §8.6 trends, §9 recommendation engine, §10 readiness.

**Type consistency.** `AxisValue` is produced in Task 6 and consumed in Tasks 8 and 9. `VSIFit.slopePer10` is produced in Task 5, stored as `vsiSlopePer10` in Task 7, displayed in Task 9. `IntensityDomain` is defined in Task 4 and consumed in Tasks 6, 7 and 9. `ExerciseIntensity.motionBearingSubtypes` is introduced in Task 7 and lives in the Task 4 file — Task 7's commit includes that file for exactly that reason.

**Known gap, stated rather than hidden.** Task 8 step 3 wants a during-window HR sparkline, but phase 1 stores only window averages, not a series. The row therefore omits the sparkline unless a series is available. Storing a downsampled series is a phase-2 decision, not a silent phase-1 addition.

---

## Execution Handoff

Plan complete. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, reviewed between tasks
2. **Inline Execution** — tasks executed in this session with checkpoints
