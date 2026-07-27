# Day Potential + Richer Live State — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a locally-scored, anchor-based Day Potential read (with streak) above the live state, and give the 10-minute Current State read a richer window while removing every day-average comparison from it.

**Architecture:** Seven new pure Swift types compute everything on-device (motion → anchor → baseline → score → streak; plus trend shape and two parsers). One new SwiftData model persists one frozen anchor per day. The backend gains a `day_potential` mode and a re-shaped `live_state` payload. The LLM supplies language only — never numbers.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData, XCTest; FastAPI + Pydantic + pytest; OpenAI `gpt-4o-mini` via the existing proxy.

**Spec:** `ios/Wythin/docs/superpowers/specs/2026-07-27-day-potential-live-state-design.md`

## Global Constraints

- **Swift test runner:** `cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:WythinTests/<TestClass>`
- **Swift build check:** `cd /Users/alexutkin/ios && xcodebuild -project Wythin.xcodeproj -scheme Wythin -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build`
- **Python test runner:** `cd /Users/alexutkin && .venv313/bin/pytest server/tests/test_insights.py -q`
- **Xcode project has NO file-system-synchronized groups.** Every new `.swift` file must be registered by hand in `ios/Wythin.xcodeproj/project.pbxproj` in four places: `PBXBuildFile`, `PBXFileReference`, the owning `PBXGroup` children list, and the target's `Sources` build phase. IDs are short hand-written tokens, not UUIDs: app files use `F<n>`/`A<n>`, test files `FT<n>`/`AT<n>`. Highest existing app id is `F208`; highest test id is `FT11`. Groups: `GAPP_MET` (Metrics), `GAPP_MOD` (Models), `GAPP_LIV` (UI/Live), `GTESTS` (WythinTests). App sources phase is `BSAPP` (line ~523), test sources phase is `BSTST` (line ~598).
- **No UI snapshot-testing infrastructure exists.** Pure-logic tasks get real XCTest TDD; UI wiring tasks are verified by `xcodebuild build` plus a manual simulator check, matching prior plans in this repo.
- **Plain-language copy rule** (carried from the live-state prompt): no technical metric terms in any user-visible string — no HRV, RMSSD, RSA, SDNN, DFA, LF/HF, "vagal tone", "coherence", "entropy", "deceleration". "Inner noise" is permitted; it is an app label.
- **The LLM never emits a number or a band.** Score, band, colour and label are computed on-device and passed to the prompt.

---

### Task 1: Motion magnitude through the tick pipeline

**Files:**
- Create: `ios/Wythin/Metrics/MotionCompute.swift`
- Create: `ios/WythinTests/MotionComputeTests.swift`
- Modify: `ios/Wythin/Metrics/MetricsEngine.swift`
- Modify: `ios/Wythin/Models/MetricsHistoryPoint.swift`
- Modify: `ios/Wythin/Models/HRVSample.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DataSnapshot.accXYZ: [SIMD3<Float>]` (already captured).
- Produces: `MotionCompute.magnitudeSD(accXYZ:) -> Float?`; `MetricsTick.motion`, `MetricsHistoryPoint.motion`, `HRVSample.motion`, all `Float?`.

- [ ] **Step 1: Write the failing test**

`ios/WythinTests/MotionComputeTests.swift`:

```swift
import XCTest
@testable import Wythin

final class MotionComputeTests: XCTestCase {

    private func constant(_ v: SIMD3<Float>, count: Int) -> [SIMD3<Float>] {
        Array(repeating: v, count: count)
    }

    func testReturnsNilBelowMinimumSamples() {
        XCTAssertNil(MotionCompute.magnitudeSD(accXYZ: constant(.init(0, 0, 1000), count: 50)))
    }

    func testPerfectlyStillIsZero() {
        let sd = MotionCompute.magnitudeSD(accXYZ: constant(.init(0, 0, 1000), count: 400))
        XCTAssertEqual(sd ?? -1, 0, accuracy: 0.001)
    }

    func testAlternatingMagnitudeGivesHalfThePeakToPeak() {
        // Magnitudes alternate 1000 / 1100 → mean 1050, SD 50.
        var samples: [SIMD3<Float>] = []
        for i in 0..<400 {
            samples.append(.init(0, 0, i.isMultiple(of: 2) ? 1000 : 1100))
        }
        let sd = MotionCompute.magnitudeSD(accXYZ: samples)
        XCTAssertEqual(sd ?? -1, 50, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:WythinTests/MotionComputeTests`
Expected: FAIL — `cannot find 'MotionCompute' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ios/Wythin/Metrics/MotionCompute.swift`:

```swift
import Foundation

/// Stillness detection input for the day's rested anchor: how much the
/// accelerometer vector magnitude varied over the window.
///
/// The H10 reports ACC in mg, so this SD is in mg too — a seated-still read
/// sits in the low single digits, typing and walking are an order of
/// magnitude above. Compared against `AnchorThresholds.stillnessSD`.
enum MotionCompute {

    /// Minimum samples before the SD means anything (200 Hz × ~1 s).
    static let minimumSamples = 200

    /// SD of the ACC vector magnitude over the window, in mg.
    /// Returns nil when there aren't enough samples.
    static func magnitudeSD(accXYZ: [SIMD3<Float>]) -> Float? {
        guard accXYZ.count >= minimumSamples else { return nil }

        var sum: Float = 0
        var magnitudes = [Float]()
        magnitudes.reserveCapacity(accXYZ.count)
        for v in accXYZ {
            let m = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
            magnitudes.append(m)
            sum += m
        }
        let mean = sum / Float(magnitudes.count)

        var variance: Float = 0
        for m in magnitudes { variance += (m - mean) * (m - mean) }
        variance /= Float(magnitudes.count)

        return variance.squareRoot()
    }
}
```

- [ ] **Step 4: Register the file in the Xcode project**

In `ios/Wythin.xcodeproj/project.pbxproj` add four lines:

```
		A209 /* MotionCompute.swift in Sources */ = {isa = PBXBuildFile; fileRef = F209 /* MotionCompute.swift */; };
		F209 /* MotionCompute.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MotionCompute.swift; sourceTree = "<group>"; };
```

plus `F209 /* MotionCompute.swift */,` in the `GAPP_MET` children list and `A209 /* MotionCompute.swift in Sources */,` in the `BSAPP` sources phase. Do the same for the test file with `AT12`/`FT12`, `GTESTS`, `BSTST`.

- [ ] **Step 5: Run test to verify it passes**

Run the Step 2 command. Expected: PASS, 3 tests.

- [ ] **Step 6: Wire `motion` through the tick pipeline**

In `MetricsTick` (`MetricsEngine.swift`), immediately after the `rrCorrectedRate` declaration:

```swift
    /// SD of ACC vector magnitude (mg) over the window — stillness input for
    /// the day's rested anchor. Defaulted so existing constructors compile.
    var motion: Float? = nil
```

In `MetricsEngine.compute`, add after the `rrCorrectedRate:` argument:

```swift
            motion:          MotionCompute.magnitudeSD(accXYZ: snapshot.accXYZ),
```

In `MetricsHistoryPoint`, add `let motion: Float?` after `rrCorrectedRate`, then `motion = tick.motion` in `init(from tick:)`, `motion = sample.motion` in `init(from sample:)`, and `self.motion = nil` in the convenience initializer.

In `HRVSample`, add `var motion: Float?` and `self.motion = tick.motion` in `init(from tick:)`. This is an additive optional — SwiftData migrates it lightweight, no migration plan needed.

- [ ] **Step 7: Verify the whole project still builds**

Run: `cd /Users/alexutkin/ios && xcodebuild -project Wythin.xcodeproj -scheme Wythin -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/MotionCompute.swift ios/WythinTests/MotionComputeTests.swift ios/Wythin/Metrics/MetricsEngine.swift ios/Wythin/Models/MetricsHistoryPoint.swift ios/Wythin/Models/HRVSample.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(anchor): compute and persist ACC motion magnitude per tick"
```

---

### Task 2: AnchorDetector — find the day's rested window

**Files:**
- Create: `ios/Wythin/Metrics/AnchorDetector.swift`
- Create: `ios/WythinTests/AnchorDetectorTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F210`/`A210`, `FT13`/`AT13`)

**Interfaces:**
- Consumes: `MetricsHistoryPoint` including `motion` from Task 1.
- Produces: `AnchorReading` (struct), `AnchorConfidence` (enum), `AnchorThresholds` (constants), `AnchorDetector.detect(_:now:) -> AnchorReading?`.

- [ ] **Step 1: Write the failing test**

`ios/WythinTests/AnchorDetectorTests.swift`:

```swift
import XCTest
@testable import Wythin

final class AnchorDetectorTests: XCTestCase {

    /// Builds `minutes` of still, clean 2s ticks starting at `hour` on a fixed day.
    private func stillPoints(minutes: Double,
                             hour: Int,
                             motion: Float? = 5,
                             hr: Float = 60,
                             vti: Float = 3.6) -> [MetricsHistoryPoint] {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20)
        comps.hour = hour
        let start = cal.date(from: comps)!
        let count = Int(minutes * 30)   // 30 ticks per minute at 2 s
        return (0..<count).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 2),
                                meanBPM: hr, vti: vti, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: motion,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
    }

    func testFindsCleanMorningWindow() {
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 7))
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.lnRMSSD ?? 0, 3.6, accuracy: 0.001)
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001)
        XCTAssertNotNil(a?.dc)
        XCTAssertFalse(a?.late ?? true)
        XCTAssertEqual(a?.confidence, .high)
    }

    func testRejectsWindowShorterThanMinimum() {
        XCTAssertNil(AnchorDetector.detect(stillPoints(minutes: 2, hour: 7)))
    }

    func testDropsDCOnShortWindow() {
        let a = AnchorDetector.detect(stillPoints(minutes: 4, hour: 7))
        XCTAssertNotNil(a)
        XCTAssertNil(a?.dc, "DC needs a 5-minute window")
        XCTAssertEqual(a?.confidence, .medium)
    }

    func testRejectsMotion() {
        XCTAssertNil(AnchorDetector.detect(stillPoints(minutes: 6, hour: 7, motion: 120)))
    }

    func testFallsBackToHRStabilityWhenMotionUnknown() {
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 7, motion: nil))
        XCTAssertNotNil(a)
        XCTAssertFalse(a?.motionKnown ?? true)
        XCTAssertEqual(a?.confidence, .low)
    }

    func testAfternoonOnlyWindowIsLate() {
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 15))
        XCTAssertNotNil(a)
        XCTAssertTrue(a?.late ?? false)
        XCTAssertEqual(a?.confidence, .medium)
    }

    func testPrefersMorningWindowOverLaterOne() {
        let points = stillPoints(minutes: 6, hour: 8) + stillPoints(minutes: 20, hour: 16)
        let a = AnchorDetector.detect(points)
        XCTAssertEqual(Calendar.current.component(.hour, from: a?.startedAt ?? .distantPast), 8)
    }

    func testRejectsImplausibleBreathingRate() {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let points = (0..<180).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 2),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 30, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        XCTAssertNil(AnchorDetector.detect(points))
    }
}
```

This test needs a construction path for the extra fields. Add a second convenience initializer to `MetricsHistoryPoint` (in the same file as the existing one), which the detector tests and later baseline tests both use:

```swift
    /// Convenience initializer covering the fields the anchor pipeline reads.
    init(
        anchorTestTimestamp: Date,
        meanBPM: Float? = nil,
        vti: Float? = nil,
        dc: Float? = nil,
        pip: Float? = nil,
        dfa1: Float? = nil,
        breathBPM: Float? = nil,
        motion: Float? = nil,
        signalQuality: Float? = nil,
        rrInvalidRate: Float? = nil,
        ecgQualityTier: Int? = nil
    ) {
        self.timestamp = anchorTestTimestamp
        self.ieRatio = nil; self.vti = vti; self.rmssd = vti.map { exp($0) }
        self.rsaMs = nil; self.sdnn = nil; self.pnn50 = nil
        self.ulfPower = nil; self.vlfPower = nil; self.lfPower = nil; self.hfPower = nil
        self.lfHF = nil; self.coherence = nil; self.cbi = nil
        self.breathBPM = breathBPM; self.meanBPM = meanBPM
        self.dfa1 = dfa1; self.signalQuality = signalQuality
        self.rrInvalidRate = rrInvalidRate; self.rrCorrectedRate = nil
        self.ecgQualityTier = ecgQualityTier
        self.rcmse = nil; self.pip = pip; self.ials = nil; self.dc = dc
        self.motion = motion
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:WythinTests/AnchorDetectorTests`
Expected: FAIL — `cannot find 'AnchorDetector' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ios/Wythin/Metrics/AnchorDetector.swift`:

```swift
import Foundation

// MARK: - Thresholds

/// Every gate the day's rested anchor must clear. One place, so the
/// stillness threshold can be calibrated against real captures.
enum AnchorThresholds {
    /// ACC magnitude SD (mg) below which the window counts as still.
    static let stillnessSD: Float = 20
    /// Fallback when `motion` is absent (backfilled history): SD of HR, bpm.
    static let hrStabilitySD: Float = 3
    static let minSignalQuality: Float = 0.9
    static let maxInvalidRate: Float = 0.05
    static let minECGTier: Int = 1
    static let breathRange: ClosedRange<Float> = 8...20
    /// Preferred window length — below this DC is dropped from the score.
    static let preferredMinSec: Double = 300
    /// Absolute minimum window length.
    static let minSec: Double = 180
    /// Windows starting before this hour are preferred over later ones.
    static let morningCutoffHour: Int = 12
    /// Largest gap between consecutive ticks still counted as continuous.
    static let maxGapSec: Double = 6
}

// MARK: - Reading

enum AnchorConfidence: String, Codable { case high, medium, low }

/// One day's rested-window reading. Frozen once captured.
struct AnchorReading: Equatable {
    let startedAt:   Date
    let durationSec: Double
    /// Fractional local hour of `startedAt` (7.5 = 07:30).
    let hour:        Double
    let lnRMSSD:     Float
    let dc:          Float?
    let restingHR:   Float
    let pip:         Float?
    let dfa1:        Float?
    let breathBPM:   Float?
    let late:        Bool
    let motionKnown: Bool
    let confidence:  AnchorConfidence

    var day: Date { Calendar.current.startOfDay(for: startedAt) }
}

// MARK: - Detector

/// Finds the first *rested* window of a day. Pure — no persistence, no clock
/// beyond what's passed in.
enum AnchorDetector {

    static func detect(_ points: [MetricsHistoryPoint], now: Date = .now) -> AnchorReading? {
        let usable = points
            .filter { passesPointGates($0) }
            .sorted { $0.timestamp < $1.timestamp }
        guard !usable.isEmpty else { return nil }

        let runs = continuousRuns(usable).filter { run in
            duration(run) >= AnchorThresholds.minSec && passesRunGates(run)
        }
        guard !runs.isEmpty else { return nil }

        let cal = Calendar.current
        let morning = runs.first { run in
            cal.component(.hour, from: run[0].timestamp) < AnchorThresholds.morningCutoffHour
        }
        guard let run = morning ?? runs.first else { return nil }

        return reading(from: run, late: morning == nil)
    }

    // MARK: Gates

    private static func passesPointGates(_ p: MetricsHistoryPoint) -> Bool {
        guard let q = p.signalQuality, q >= AnchorThresholds.minSignalQuality else { return false }
        guard let inv = p.rrInvalidRate, inv <= AnchorThresholds.maxInvalidRate else { return false }
        guard let tier = p.ecgQualityTier, tier >= AnchorThresholds.minECGTier else { return false }
        guard p.vti != nil, p.meanBPM != nil else { return false }
        if let m = p.motion, m > AnchorThresholds.stillnessSD { return false }
        if let b = p.breathBPM, !AnchorThresholds.breathRange.contains(b) { return false }
        return true
    }

    /// When motion is unknown for the whole run, fall back to HR stability.
    private static func passesRunGates(_ run: [MetricsHistoryPoint]) -> Bool {
        let motionKnown = run.contains { $0.motion != nil }
        guard !motionKnown else { return true }
        let hrs = run.compactMap { $0.meanBPM }
        guard hrs.count >= 2 else { return false }
        return sd(hrs) <= AnchorThresholds.hrStabilitySD
    }

    // MARK: Assembly

    private static func continuousRuns(_ points: [MetricsHistoryPoint]) -> [[MetricsHistoryPoint]] {
        var runs: [[MetricsHistoryPoint]] = []
        var current: [MetricsHistoryPoint] = []
        for p in points {
            if let last = current.last,
               p.timestamp.timeIntervalSince(last.timestamp) > AnchorThresholds.maxGapSec {
                runs.append(current)
                current = []
            }
            current.append(p)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func duration(_ run: [MetricsHistoryPoint]) -> Double {
        guard let first = run.first, let last = run.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }

    private static func reading(from run: [MetricsHistoryPoint], late: Bool) -> AnchorReading? {
        guard let lnRMSSD = median(run.compactMap { $0.vti }),
              let restingHR = median(run.compactMap { $0.meanBPM }),
              let start = run.first?.timestamp else { return nil }

        let dur = duration(run)
        let longEnoughForDC = dur >= AnchorThresholds.preferredMinSec
        let motionKnown = run.contains { $0.motion != nil }

        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: start))
                 + Double(cal.component(.minute, from: start)) / 60

        let confidence: AnchorConfidence
        if !motionKnown                                { confidence = .low }
        else if longEnoughForDC && !late               { confidence = .high }
        else                                           { confidence = .medium }

        return AnchorReading(
            startedAt:   start,
            durationSec: dur,
            hour:        hour,
            lnRMSSD:     lnRMSSD,
            dc:          longEnoughForDC ? median(run.compactMap { $0.dc }) : nil,
            restingHR:   restingHR,
            pip:         median(run.compactMap { $0.pip }),
            dfa1:        median(run.compactMap { $0.dfa1 }),
            breathBPM:   median(run.compactMap { $0.breathBPM }),
            late:        late,
            motionKnown: motionKnown,
            confidence:  confidence)
    }

    // MARK: Stats

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    static func sd(_ values: [Float]) -> Float {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let v = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        return v.squareRoot()
    }
}
```

- [ ] **Step 4: Register `F210`/`A210` and `FT13`/`AT13` in `project.pbxproj`** (same four places as Task 1).

- [ ] **Step 5: Run test to verify it passes**

Run the Step 2 command. Expected: PASS, 8 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/AnchorDetector.swift ios/WythinTests/AnchorDetectorTests.swift ios/Wythin/Models/MetricsHistoryPoint.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(anchor): detect the day's first rested window"
```

---

### Task 3: DailyAnchor persistence + backfill

**Files:**
- Create: `ios/Wythin/Models/DailyAnchor.swift`
- Modify: `ios/Wythin/App/WythinApp.swift:14`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F211`/`A211`)

**Interfaces:**
- Consumes: `AnchorReading` (Task 2).
- Produces: `DailyAnchor` (`@Model`), `DailyAnchor.init(from: AnchorReading)`, `DailyAnchor.reading -> AnchorReading`.

- [ ] **Step 1: Write the model**

`ios/Wythin/Models/DailyAnchor.swift`:

```swift
import Foundation
import SwiftData

/// One day's rested-window reading, written once and never recomputed —
/// the freeze is what keeps the day's potential score stable.
@Model
final class DailyAnchor {
    /// Start of the local day this anchor belongs to. Unique in practice.
    var day:         Date
    var startedAt:   Date
    var durationSec: Double
    var hour:        Double
    var lnRMSSD:     Float
    var dc:          Float?
    var restingHR:   Float
    var pip:         Float?
    var dfa1:        Float?
    var breathBPM:   Float?
    var late:        Bool
    var motionKnown: Bool
    /// `AnchorConfidence.rawValue`
    var confidenceRaw: String

    init(from r: AnchorReading) {
        self.day           = r.day
        self.startedAt     = r.startedAt
        self.durationSec   = r.durationSec
        self.hour          = r.hour
        self.lnRMSSD       = r.lnRMSSD
        self.dc            = r.dc
        self.restingHR     = r.restingHR
        self.pip           = r.pip
        self.dfa1          = r.dfa1
        self.breathBPM     = r.breathBPM
        self.late          = r.late
        self.motionKnown   = r.motionKnown
        self.confidenceRaw = r.confidence.rawValue
    }

    var reading: AnchorReading {
        AnchorReading(
            startedAt:   startedAt,
            durationSec: durationSec,
            hour:        hour,
            lnRMSSD:     lnRMSSD,
            dc:          dc,
            restingHR:   restingHR,
            pip:         pip,
            dfa1:        dfa1,
            breathBPM:   breathBPM,
            late:        late,
            motionKnown: motionKnown,
            confidence:  AnchorConfidence(rawValue: confidenceRaw) ?? .low)
    }
}
```

- [ ] **Step 2: Register the model in the SwiftData schema**

`ios/Wythin/App/WythinApp.swift:14` becomes:

```swift
        let schema = Schema([HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self, ActivityLog.self, DailyAnchor.self])
```

- [ ] **Step 3: Add the one-time backfill**

Everything the detector needs is already in `HRVSample`, so users with history do not start from an empty baseline. Add to `DailyAnchor.swift`:

```swift
/// One-time replay of stored history into anchors. Motion is unavailable for
/// past samples, so the HR-stability proxy applies and every anchor it
/// produces is marked low-confidence.
enum AnchorBackfill {

    static let flagKey = "anchorBackfillCompleted"

    @MainActor
    static func runIfNeeded(context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }
        defer { defaults.set(true, forKey: flagKey) }

        let existing = Set(((try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []).map { $0.day })
        let sessions = (try? context.fetch(FetchDescriptor<HRVSession>())) ?? []
        let points = sessions.flatMap { $0.samples }.map { MetricsHistoryPoint(from: $0) }

        let cal = Calendar.current
        let byDay = Dictionary(grouping: points) { cal.startOfDay(for: $0.timestamp) }
        for (day, dayPoints) in byDay where !existing.contains(day) {
            guard let reading = AnchorDetector.detect(MetricsQualityFilter.filter(dayPoints)) else { continue }
            context.insert(DailyAnchor(from: reading))
        }
        try? context.save()
    }
}
```

Call it once from `DayPotentialStore.refresh` (Task 12) before the first fetch.

- [ ] **Step 4: Register `F211`/`A211` in `project.pbxproj`** under `GAPP_MOD` and `BSAPP`.

- [ ] **Step 4: Verify the project builds**

Run the build-check command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Models/DailyAnchor.swift ios/Wythin/App/WythinApp.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(anchor): persist one frozen DailyAnchor per day"
```

---

### Task 4: AnchorBaseline — the personal 60-day norm

**Files:**
- Create: `ios/Wythin/Metrics/AnchorBaseline.swift`
- Create: `ios/WythinTests/AnchorBaselineTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F213`/`A213`, `FT14`/`AT14`)

**Interfaces:**
- Consumes: `[AnchorReading]`.
- Produces: `BaselineStat { mean, sd, n }`, `AnchorBaseline`, `AnchorBaseline.build(history:todayHour:now:) -> AnchorBaseline?`, `AnchorBaseline.minimumAnchors = 7`.

- [ ] **Step 1: Write the failing test**

`ios/WythinTests/AnchorBaselineTests.swift`:

```swift
import XCTest
@testable import Wythin

final class AnchorBaselineTests: XCTestCase {

    private func reading(daysAgo: Int, lnRMSSD: Float, hr: Float = 60, hour: Double = 7) -> AnchorReading {
        let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return AnchorReading(startedAt: start, durationSec: 300, hour: hour,
                             lnRMSSD: lnRMSSD, dc: 7.5, restingHR: hr, pip: 40, dfa1: 1.0,
                             breathBPM: 13, late: false, motionKnown: true, confidence: .high)
    }

    func testNilBelowMinimumAnchors() {
        let history = (1...6).map { reading(daysAgo: $0, lnRMSSD: 3.6) }
        XCTAssertNil(AnchorBaseline.build(history: history, todayHour: 7))
    }

    func testComputesMeanAndSD() {
        let values: [Float] = [3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 4.0]
        let history = values.enumerated().map { reading(daysAgo: $0.offset + 1, lnRMSSD: $0.element) }
        let b = AnchorBaseline.build(history: history, todayHour: 7)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 3.7, accuracy: 0.001)
        XCTAssertEqual(b?.lnRMSSD.n, 7)
        XCTAssertGreaterThan(b?.lnRMSSD.sd ?? 0, 0)
    }

    func testExcludesAnchorsOlderThanWindow() {
        var history = (1...7).map { reading(daysAgo: $0, lnRMSSD: 3.6) }
        history.append(reading(daysAgo: 90, lnRMSSD: 99))
        let b = AnchorBaseline.build(history: history, todayHour: 7)
        XCTAssertEqual(b?.lnRMSSD.n, 7)
    }

    func testPrefersAnchorsNearTodaysHour() {
        let morning = (1...7).map { reading(daysAgo: $0, lnRMSSD: 3.6, hour: 7) }
        let evening = (8...14).map { reading(daysAgo: $0, lnRMSSD: 9.0, hour: 21) }
        let b = AnchorBaseline.build(history: morning + evening, todayHour: 7)
        XCTAssertTrue(b?.hourMatched ?? false)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 3.6, accuracy: 0.001)
    }

    func testFallsBackToAllAnchorsWhenHourMatchTooSmall() {
        let evening = (1...8).map { reading(daysAgo: $0, lnRMSSD: 9.0, hour: 21) }
        let b = AnchorBaseline.build(history: evening, todayHour: 7)
        XCTAssertFalse(b?.hourMatched ?? true)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 9.0, accuracy: 0.001)
    }

    func testComputesRecentCV() {
        let values: [Float] = [3.0, 4.0, 3.0, 4.0, 3.0, 4.0, 3.0]
        let history = values.enumerated().map { reading(daysAgo: $0.offset + 1, lnRMSSD: $0.element) }
        let b = AnchorBaseline.build(history: history, todayHour: 7)
        XCTAssertGreaterThan(b?.cv7 ?? 0, 0.1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:WythinTests/AnchorBaselineTests`
Expected: FAIL — `cannot find 'AnchorBaseline' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ios/Wythin/Metrics/AnchorBaseline.swift`:

```swift
import Foundation

/// Mean/SD/n for one metric across the baseline window.
struct BaselineStat: Equatable {
    let mean: Float
    let sd:   Float
    let n:    Int

    /// z of `value`, or nil when the SD is degenerate.
    func z(_ value: Float) -> Float? {
        guard sd > 1e-6 else { return nil }
        return (value - mean) / sd
    }
}

/// The user's own norm, built from stored anchors. Nothing here is
/// population-referenced — every comparison is against the same person.
struct AnchorBaseline {
    let lnRMSSD:     BaselineStat
    let restingHR:   BaselineStat
    let dc:          BaselineStat?
    let pip:         BaselineStat?
    let dfa1Median:  Float?
    /// CV of the last 7 lnRMSSD anchors — the stability axis.
    let cv7:         Float?
    /// Distribution of historical rolling CV7s, for z-scoring `cv7`.
    let cv7Stat:     BaselineStat?
    let medianHour:  Double
    let anchorCount: Int
    let hourMatched: Bool

    /// Below this many anchors there is no SD, so no score (spec §7).
    static let minimumAnchors = 7
    static let windowDays     = 60
    /// Anchors within this many hours of today's count as like-for-like.
    static let hourTolerance: Double = 2

    static func build(history: [AnchorReading],
                      todayHour: Double,
                      now: Date = .now) -> AnchorBaseline? {

        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: now) ?? .distantPast
        let inWindow = history
            .filter { $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }       // newest first
        guard inWindow.count >= minimumAnchors else { return nil }

        let nearHour = inWindow.filter { abs($0.hour - todayHour) <= hourTolerance }
        let hourMatched = nearHour.count >= minimumAnchors
        let sample = hourMatched ? nearHour : inWindow

        guard let lnStat = stat(sample.map { $0.lnRMSSD }),
              let hrStat = stat(sample.map { $0.restingHR }) else { return nil }

        // CV7 over the most recent 7 anchors, and the distribution of the same
        // rolling statistic across the window, so it can be z-scored.
        let lnSeriesNewestFirst = sample.map { $0.lnRMSSD }
        let cv7 = coefficientOfVariation(Array(lnSeriesNewestFirst.prefix(7)))
        var rollingCVs: [Float] = []
        if lnSeriesNewestFirst.count >= 8 {
            for startIdx in 0...(lnSeriesNewestFirst.count - 7) {
                if let cv = coefficientOfVariation(Array(lnSeriesNewestFirst[startIdx..<(startIdx + 7)])) {
                    rollingCVs.append(cv)
                }
            }
        }

        return AnchorBaseline(
            lnRMSSD:     lnStat,
            restingHR:   hrStat,
            dc:          stat(sample.compactMap { $0.dc }),
            pip:         stat(sample.compactMap { $0.pip }),
            dfa1Median:  AnchorDetector.median(sample.compactMap { $0.dfa1 }),
            cv7:         cv7,
            cv7Stat:     rollingCVs.count >= 2 ? stat(rollingCVs) : nil,
            medianHour:  Double(AnchorDetector.median(sample.map { Float($0.hour) }) ?? Float(todayHour)),
            anchorCount: inWindow.count,
            hourMatched: hourMatched)
    }

    // MARK: Stats

    private static func stat(_ values: [Float]) -> BaselineStat? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count - 1)
        return BaselineStat(mean: mean, sd: variance.squareRoot(), n: values.count)
    }

    private static func coefficientOfVariation(_ values: [Float]) -> Float? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Float(values.count)
        guard abs(mean) > 1e-6 else { return nil }
        let variance = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count - 1)
        return variance.squareRoot() / abs(mean)
    }
}
```

- [ ] **Step 4: Register `F213`/`A213`, `FT14`/`AT14`.**

- [ ] **Step 5: Run test to verify it passes.** Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/AnchorBaseline.swift ios/WythinTests/AnchorBaselineTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(anchor): rolling 60-day personal baseline with hour matching"
```

---

### Task 5: PotentialScore — the 0–100 number

**Files:**
- Create: `ios/Wythin/Metrics/PotentialScore.swift`
- Create: `ios/WythinTests/PotentialScoreTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F214`/`A214`, `FT15`/`AT15`)

**Interfaces:**
- Consumes: `AnchorReading`, `AnchorBaseline`.
- Produces: `PotentialBand`, `PotentialComponents`, `PotentialPenalties`, `PotentialResult`, `PotentialScore.evaluate(anchor:baseline:) -> PotentialResult?`.

- [ ] **Step 1: Write the failing test**

`ios/WythinTests/PotentialScoreTests.swift`:

```swift
import XCTest
@testable import Wythin

final class PotentialScoreTests: XCTestCase {

    private func baseline(lnMean: Float = 3.6, lnSD: Float = 0.2,
                          hrMean: Float = 60, hrSD: Float = 4,
                          dcMean: Float? = 7.5, dcSD: Float = 1,
                          pipMean: Float? = 40, pipSD: Float = 5,
                          cv7: Float? = nil, cv7Mean: Float = 0.05, cv7SD: Float = 0.01,
                          dfa1Median: Float? = 1.0) -> AnchorBaseline {
        AnchorBaseline(
            lnRMSSD:   BaselineStat(mean: lnMean, sd: lnSD, n: 30),
            restingHR: BaselineStat(mean: hrMean, sd: hrSD, n: 30),
            dc:        dcMean.map { BaselineStat(mean: $0, sd: dcSD, n: 30) },
            pip:       pipMean.map { BaselineStat(mean: $0, sd: pipSD, n: 30) },
            dfa1Median: dfa1Median,
            cv7:       cv7,
            cv7Stat:   BaselineStat(mean: cv7Mean, sd: cv7SD, n: 30),
            medianHour: 7,
            anchorCount: 30,
            hourMatched: true)
    }

    private func anchor(ln: Float = 3.6, hr: Float = 60, dc: Float? = 7.5,
                        pip: Float? = 40, dfa1: Float? = 1.0, hour: Double = 7) -> AnchorReading {
        AnchorReading(startedAt: Date(), durationSec: 300, hour: hour,
                      lnRMSSD: ln, dc: dc, restingHR: hr, pip: pip, dfa1: dfa1,
                      breathBPM: 13, late: false, motionKnown: true, confidence: .high)
    }

    func testAtPersonalNormScoresFifty() {
        let r = PotentialScore.evaluate(anchor: anchor(), baseline: baseline())
        XCTAssertEqual(r?.score, 50)
        XCTAssertEqual(r?.band, .steady)
    }

    func testTwoSDAboveSaturatesAtHundred() {
        // +2 SD on every core component, no penalties.
        let r = PotentialScore.evaluate(
            anchor: anchor(ln: 4.0, hr: 52, dc: 9.5),
            baseline: baseline())
        XCTAssertEqual(r?.score, 75, "saturation guard caps a deeply-rested read")
        XCTAssertTrue(r?.saturated ?? false)
    }

    func testTwoSDBelowSaturatesAtZero() {
        let r = PotentialScore.evaluate(
            anchor: anchor(ln: 3.2, hr: 68, dc: 5.5),
            baseline: baseline())
        XCTAssertEqual(r?.score, 0)
        XCTAssertEqual(r?.band, .depleted)
    }

    func testFragmentationPenaltyCapsAtTen() {
        // +4 SD of PIP would be −20 uncapped.
        let r = PotentialScore.evaluate(
            anchor: anchor(pip: 60),
            baseline: baseline())
        XCTAssertEqual(r?.penalties.fragmentation ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(r?.score, 40)
    }

    func testStabilityPenaltyApplies() {
        let r = PotentialScore.evaluate(
            anchor: anchor(),
            baseline: baseline(cv7: 0.07))   // +2 SD of CV7 → −10
        XCTAssertEqual(r?.penalties.stability ?? 0, 10, accuracy: 0.001)
    }

    func testOrganizationPenaltyCapsAtFive() {
        let r = PotentialScore.evaluate(
            anchor: anchor(dfa1: 0.2),
            baseline: baseline())
        XCTAssertEqual(r?.penalties.organization ?? 0, 5, accuracy: 0.001)
    }

    func testMissingDCRedistributesWeight() {
        let r = PotentialScore.evaluate(anchor: anchor(dc: nil), baseline: baseline())
        XCTAssertNil(r?.components.dcZ)
        XCTAssertEqual(r?.score, 50, "at norm the redistribution is still 50")
    }

    func testRejectsAnchorFarFromUsualHour() {
        XCTAssertNil(PotentialScore.evaluate(anchor: anchor(hour: 15), baseline: baseline()))
    }

    func testBandBoundaries() {
        XCTAssertEqual(PotentialBand.forScore(85), .full)
        XCTAssertEqual(PotentialBand.forScore(79), .good)
        XCTAssertEqual(PotentialBand.forScore(59), .steady)
        XCTAssertEqual(PotentialBand.forScore(39), .light)
        XCTAssertEqual(PotentialBand.forScore(24), .depleted)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Expected: FAIL — `cannot find 'PotentialScore' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ios/Wythin/Metrics/PotentialScore.swift`:

```swift
import Foundation

// MARK: - Band

enum PotentialBand: String, Equatable {
    case full, good, steady, light, depleted

    static func forScore(_ s: Int) -> PotentialBand {
        switch s {
        case 80...:   return .full
        case 60..<80: return .good
        case 40..<60: return .steady
        case 25..<40: return .light
        default:      return .depleted
        }
    }

    /// User-visible label. Plain language only.
    var label: String {
        switch self {
        case .full:     return "full reserves"
        case .good:     return "good reserves"
        case .steady:   return "steady"
        case .light:    return "running light"
        case .depleted: return "depleted"
        }
    }
}

// MARK: - Explainability

struct PotentialComponents: Equatable {
    let lnRMSSDz:   Float
    let dcZ:        Float?
    let restingHRz: Float      // already benefit-signed (lower HR → positive)
}

struct PotentialPenalties: Equatable {
    let stability:     Float
    let fragmentation: Float
    let organization:  Float

    var total: Float { stability + fragmentation + organization }
}

struct PotentialResult: Equatable {
    let score:      Int
    let band:       PotentialBand
    let components: PotentialComponents
    let penalties:  PotentialPenalties
    let saturated:  Bool
}

// MARK: - Score

/// Capacity, scored against the user's own anchors.
///
/// Weighted rather than flat-averaged on purpose: every input is a lens on
/// the same vagal axis, so an equal-weight mean would over-weight whichever
/// axis has the most representatives. Fragmentation enters only as a penalty
/// — a fragmented rhythm inflates RMSSD while indicating worse function
/// (Costa, Davis & Goldberger 2017), so it must never read as good news.
///
/// No published work validates this specific composite as "readiness". The
/// weights are reasoned extension and live here so they can be calibrated.
/// If the composite ever disagrees with plain lnRMSSD inexplicably, trust
/// plain lnRMSSD.
enum PotentialScore {

    static let wLnRMSSD:   Float = 0.50
    static let wDC:        Float = 0.30
    static let wRestingHR: Float = 0.20

    /// Anchors this far (hours) from the personal median hour are not comparable.
    static let maxHourDeviation: Double = 4
    /// Saturation cap — a deeply rested read is flagged, not celebrated.
    static let saturationCap = 75

    static func evaluate(anchor: AnchorReading, baseline: AnchorBaseline) -> PotentialResult? {
        // Validity: circadian comparability.
        guard abs(anchor.hour - baseline.medianHour) <= maxHourDeviation else { return nil }

        guard let lnZ = baseline.lnRMSSD.z(anchor.lnRMSSD),
              let hrZraw = baseline.restingHR.z(anchor.restingHR) else { return nil }
        let hrZ = -hrZraw   // benefit-signed: lower resting HR is better

        let dcZ: Float? = {
            guard let dc = anchor.dc, let stat = baseline.dc else { return nil }
            return stat.z(dc)
        }()

        // Core, with DC's weight redistributed proportionally when absent.
        let capacityZ: Float
        if let dcZ {
            capacityZ = wLnRMSSD * lnZ + wDC * dcZ + wRestingHR * hrZ
        } else {
            let scale = 1 / (wLnRMSSD + wRestingHR)
            capacityZ = (wLnRMSSD * lnZ + wRestingHR * hrZ) * scale
        }

        let raw = min(max((50 + 25 * capacityZ).rounded(), 0), 100)

        // Penalties — capped, never bonuses.
        let stability: Float = {
            guard let cv7 = baseline.cv7, let stat = baseline.cv7Stat,
                  let z = stat.z(cv7) else { return 0 }
            return min(max(10 * z / 2, 0), 10)
        }()

        let fragmentation: Float = {
            guard let pip = anchor.pip, let stat = baseline.pip,
                  let z = stat.z(pip) else { return 0 }
            return min(max(10 * z / 2, 0), 10)
        }()

        let organization: Float = {
            guard let dfa1 = anchor.dfa1, let median = baseline.dfa1Median else { return 0 }
            // Scale deviation by a fixed 0.15 step — DFA α1 has no meaningful
            // per-person SD at this sample size.
            let z = abs(dfa1 - median) / 0.15
            return min(max(5 * z / 2, 0), 5)
        }()

        let penalties = PotentialPenalties(stability: stability,
                                           fragmentation: fragmentation,
                                           organization: organization)

        var score = Int(min(max(raw - penalties.total, 0), 100))

        // Saturation guard: high vagal index with an unusually low resting
        // rate is deep rest, not a peak. Cap rather than celebrate.
        let rmssdToday    = exp(anchor.lnRMSSD)
        let rmssdBaseline = exp(baseline.lnRMSSD.mean)
        let ratioToday    = rmssdToday / (60_000 / anchor.restingHR)
        let ratioBaseline = rmssdBaseline / (60_000 / baseline.restingHR.mean)
        let saturated = lnZ > 1 && hrZraw < -1 && ratioToday > ratioBaseline
        if saturated { score = min(score, saturationCap) }

        return PotentialResult(
            score:      score,
            band:       PotentialBand.forScore(score),
            components: PotentialComponents(lnRMSSDz: lnZ, dcZ: dcZ, restingHRz: hrZ),
            penalties:  penalties,
            saturated:  saturated)
    }
}
```

- [ ] **Step 4: Register `F214`/`A214`, `FT15`/`AT15`.**

- [ ] **Step 5: Run test to verify it passes.** Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/PotentialScore.swift ios/WythinTests/PotentialScoreTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(potential): weighted capacity score with capped penalties"
```

---

### Task 6: StreakCompute — consecutive mornings with one grace day

**Files:**
- Create: `ios/Wythin/Metrics/StreakCompute.swift`
- Create: `ios/WythinTests/StreakComputeTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F215`/`A215`, `FT16`/`AT16`)

**Interfaces:**
- Consumes: a set of `Date` (start-of-day) values with anchors.
- Produces: `StreakResult { current, best, graceUsed, totalAnchors }`, `StreakCompute.evaluate(days:today:) -> StreakResult`.

- [ ] **Step 1: Write the failing test**

`ios/WythinTests/StreakComputeTests.swift`:

```swift
import XCTest
@testable import Wythin

final class StreakComputeTests: XCTestCase {

    private let cal = Calendar.current
    private lazy var today = cal.startOfDay(for: Date())

    private func days(_ offsets: [Int]) -> Set<Date> {
        Set(offsets.map { cal.date(byAdding: .day, value: -$0, to: today)! })
    }

    func testUnbrokenRun() {
        let r = StreakCompute.evaluate(days: days([0, 1, 2, 3]), today: today)
        XCTAssertEqual(r.current, 4)
        XCTAssertFalse(r.graceUsed)
    }

    func testOneMissedDayDoesNotBreakTheRun() {
        // today, -1, (miss -2), -3, -4
        let r = StreakCompute.evaluate(days: days([0, 1, 3, 4]), today: today)
        XCTAssertEqual(r.current, 4)
        XCTAssertTrue(r.graceUsed)
    }

    func testTwoMissesWithinSevenDaysBreakTheRun() {
        // today, -1, (miss -2), -3, (miss -4), -5
        let r = StreakCompute.evaluate(days: days([0, 1, 3, 5]), today: today)
        XCTAssertEqual(r.current, 3)
    }

    func testSecondGraceAllowedOutsideTheSevenDayWindow() {
        // misses at -2 and -9 — more than 7 traversed days apart
        let r = StreakCompute.evaluate(days: days([0, 1, 3, 4, 5, 6, 7, 8, 10, 11]), today: today)
        XCTAssertEqual(r.current, 10)
    }

    func testTodayMissingStillCountsYesterdaysRun() {
        let r = StreakCompute.evaluate(days: days([1, 2, 3]), today: today)
        XCTAssertEqual(r.current, 3)
    }

    func testEmptyHistory() {
        let r = StreakCompute.evaluate(days: [], today: today)
        XCTAssertEqual(r.current, 0)
        XCTAssertEqual(r.best, 0)
        XCTAssertEqual(r.totalAnchors, 0)
    }

    func testBestIsTheLongestRunEver() {
        // a 5-run ending 20 days ago, and a 2-run now
        let old = days([20, 21, 22, 23, 24])
        let recent = days([0, 1])
        let r = StreakCompute.evaluate(days: old.union(recent), today: today)
        XCTAssertEqual(r.current, 2)
        XCTAssertEqual(r.best, 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Expected: FAIL — `cannot find 'StreakCompute' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ios/Wythin/Metrics/StreakCompute.swift`:

```swift
import Foundation

struct StreakResult: Equatable {
    let current:      Int
    let best:         Int
    let graceUsed:    Bool
    let totalAnchors: Int
}

/// Consecutive mornings with a valid anchor, forgiving one skipped day per
/// rolling 7. Strict streaks punish travel and illness — the days the data is
/// most informative — and a broken streak is a common quit trigger.
enum StreakCompute {

    /// A second miss within this many traversed days ends the run.
    static let graceWindow = 7

    static func evaluate(days: Set<Date>, today: Date, calendar: Calendar = .current) -> StreakResult {
        let start = calendar.startOfDay(for: today)
        guard !days.isEmpty else {
            return StreakResult(current: 0, best: 0, graceUsed: false, totalAnchors: 0)
        }

        // Today not yet logged is not a miss — start the walk at yesterday.
        let anchorDay = days.contains(start)
            ? start
            : (calendar.date(byAdding: .day, value: -1, to: start) ?? start)
        let (current, graceUsed) = run(endingAt: anchorDay, days: days, calendar: calendar)

        let best = days.map { run(endingAt: $0, days: days, calendar: calendar).length }.max() ?? 0

        return StreakResult(current: current,
                            best: max(best, current),
                            graceUsed: graceUsed,
                            totalAnchors: days.count)
    }

    /// Walks backwards from `day`, counting logged days and allowing at most
    /// one miss in any `graceWindow` of traversed days.
    private static func run(endingAt day: Date,
                            days: Set<Date>,
                            calendar: Calendar) -> (length: Int, graceUsed: Bool) {
        guard days.contains(day) else { return (0, false) }

        var length = 0
        var graceUsed = false
        var missOffsets: [Int] = []
        var offset = 0

        while true {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: day) else { break }
            if days.contains(d) {
                length += 1
            } else {
                // A second miss inside the rolling window ends the run.
                if missOffsets.contains(where: { offset - $0 < graceWindow }) { break }
                missOffsets.append(offset)
                graceUsed = true
            }
            offset += 1
            // Stop once nothing older remains.
            if !days.contains(where: { $0 < d }) { break }
        }

        return (length, graceUsed)
    }
}
```

- [ ] **Step 4: Register `F215`/`A215`, `FT16`/`AT16`.**

- [ ] **Step 5: Run test to verify it passes.** Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/StreakCompute.swift ios/WythinTests/StreakComputeTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(potential): grace-forgiving morning-read streak"
```

---

### Task 7: TrendShape + bucketed 10-minute window

**Files:**
- Create: `ios/Wythin/Metrics/TrendShapeCompute.swift`
- Create: `ios/WythinTests/TrendShapeComputeTests.swift`
- Modify: `ios/Wythin/Metrics/LiveStateTrendCompute.swift`
- Modify: `ios/WythinTests/LiveStateTrendComputeTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F216`/`A216`, `FT17`/`AT17`)

**Interfaces:**
- Produces: `TrendShape` (String-raw enum), `TrendShapeCompute.classify(_:) -> TrendShape`, `TrendShapeCompute.volatility(_:) -> String`; `MetricTrend` gains `buckets: [Float]?`, `slopePct: Float?`, `volatility: String?`, `shape: String?`. `MetricTrend.dayMean` is **retained** — the local day-load template needs it.

- [ ] **Step 1: Write the failing test**

`ios/WythinTests/TrendShapeComputeTests.swift`:

```swift
import XCTest
@testable import Wythin

final class TrendShapeComputeTests: XCTestCase {

    func testPlateau() {
        XCTAssertEqual(TrendShapeCompute.classify([70, 70.2, 69.9, 70.1, 70]), .plateau)
    }

    func testSteadyFall() {
        XCTAssertEqual(TrendShapeCompute.classify([74, 72.8, 70.2, 68.9, 68.4]), .steadyFall)
    }

    func testSteadyRise() {
        XCTAssertEqual(TrendShapeCompute.classify([60, 63, 66, 70, 74]), .steadyRise)
    }

    func testSpikeAndRecover() {
        XCTAssertEqual(TrendShapeCompute.classify([60, 70, 85, 68, 61]), .spikeAndRecover)
    }

    func testDipAndRecover() {
        XCTAssertEqual(TrendShapeCompute.classify([80, 70, 55, 72, 79]), .dipAndRecover)
    }

    func testOscillating() {
        XCTAssertEqual(TrendShapeCompute.classify([60, 75, 61, 76, 60]), .oscillating)
    }

    func testVolatilityBands() {
        XCTAssertEqual(TrendShapeCompute.volatility([70, 70.1, 70, 70.1, 70]), "low")
        XCTAssertEqual(TrendShapeCompute.volatility([60, 75, 61, 76, 60]), "high")
    }

    func testTooFewBucketsIsPlateau() {
        XCTAssertEqual(TrendShapeCompute.classify([70]), .plateau)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Expected: FAIL — `cannot find 'TrendShapeCompute' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ios/Wythin/Metrics/TrendShapeCompute.swift`:

```swift
import Foundation

/// The arc of a metric across the live window, as a label the model can read
/// directly. Small models misread a bare sequence of similar floats and
/// invent movement that isn't there — the label removes that guesswork.
enum TrendShape: String, Equatable {
    case steadyRise      = "steady-rise"
    case steadyFall      = "steady-fall"
    case plateau         = "plateau"
    case spikeAndRecover = "spike-and-recover"
    case dipAndRecover   = "dip-and-recover"
    case oscillating     = "oscillating"
}

enum TrendShapeCompute {

    /// Relative range below which the whole window counts as flat.
    static let plateauRelRange: Float = 0.03
    /// Relative step below which a bucket-to-bucket move is noise.
    static let significantStep: Float = 0.01

    static func classify(_ buckets: [Float]) -> TrendShape {
        guard buckets.count >= 3 else { return .plateau }

        let mean  = buckets.reduce(0, +) / Float(buckets.count)
        let scale = max(abs(mean), 1e-6)
        guard let maxV = buckets.max(), let minV = buckets.min() else { return .plateau }
        if (maxV - minV) / scale < plateauRelRange { return .plateau }

        // Significant steps only; noise-level moves are ignored.
        var signs: [Int] = []
        for i in 1..<buckets.count {
            let d = buckets[i] - buckets[i - 1]
            if abs(d) / scale > significantStep { signs.append(d > 0 ? 1 : -1) }
        }
        guard !signs.isEmpty else { return .plateau }

        var reversals = 0
        for i in 1..<max(signs.count, 1) where signs[i] != signs[i - 1] { reversals += 1 }

        let net = buckets[buckets.count - 1] - buckets[0]

        if reversals == 0 { return net > 0 ? .steadyRise : .steadyFall }

        if reversals == 1 {
            let maxIdx = buckets.firstIndex(of: maxV) ?? 0
            let minIdx = buckets.firstIndex(of: minV) ?? 0
            let interior = 1...(buckets.count - 2)
            let ends = max(buckets[0], buckets[buckets.count - 1])
            let endsLow = min(buckets[0], buckets[buckets.count - 1])
            if interior.contains(maxIdx), (maxV - ends) / scale > plateauRelRange {
                return .spikeAndRecover
            }
            if interior.contains(minIdx), (endsLow - minV) / scale > plateauRelRange {
                return .dipAndRecover
            }
            return net > 0 ? .steadyRise : .steadyFall
        }

        return .oscillating
    }

    /// "low" | "moderate" | "high" from the spread of the buckets.
    static func volatility(_ buckets: [Float]) -> String {
        guard buckets.count >= 2 else { return "low" }
        let mean  = buckets.reduce(0, +) / Float(buckets.count)
        let scale = max(abs(mean), 1e-6)
        let variance = buckets.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(buckets.count)
        let rel = variance.squareRoot() / scale
        if rel < 0.02 { return "low" }
        if rel < 0.05 { return "moderate" }
        return "high"
    }
}
```

- [ ] **Step 4: Extend `MetricTrend` and `summarize` in `LiveStateTrendCompute.swift`**

Add to `MetricTrend` (keeping every existing field so current call sites and tests still compile):

```swift
    let buckets:    [Float]?    // 5 × 2-min means, oldest first
    let slopePct:   Float?      // (last − first) / |first| × 100
    let volatility: String?
    let shape:      String?
```

with matching defaulted parameters in the initializer (`buckets: [Float]? = nil, slopePct: Float? = nil, volatility: String? = nil, shape: String? = nil`).

In `summarize`, replace the per-metric body so the window is also bucketed. The bucket edges come from timestamps, not counts, so a gap doesn't silently shift the arc:

```swift
        let bucketCount = 5
        let bucketSec   = Double(windowMinutes) * 60 / Double(bucketCount)
        let windowStart = cutoff

        for (key, path) in keyPaths {
            let values = window.compactMap(path)
            guard !values.isEmpty else { continue }
            let dayValues = history.compactMap(path)
            let dayMean = dayValues.isEmpty ? nil : dayValues.reduce(0, +) / Float(dayValues.count)

            // Bucket by timestamp; all five must be populated or the arc is dropped.
            var buckets: [Float] = []
            for i in 0..<bucketCount {
                let lo = windowStart.addingTimeInterval(Double(i) * bucketSec)
                let hi = windowStart.addingTimeInterval(Double(i + 1) * bucketSec)
                let inBucket = window
                    .filter { $0.timestamp >= lo && $0.timestamp < hi }
                    .compactMap(path)
                guard !inBucket.isEmpty else { buckets = []; break }
                buckets.append(inBucket.reduce(0, +) / Float(inBucket.count))
            }

            result[key] = trend(for: values,
                                dayMean: dayMean,
                                buckets: buckets.count == bucketCount ? buckets : nil)
        }
```

and in `trend(for:dayMean:buckets:)`:

```swift
        var slopePct: Float?
        var volatility: String?
        var shape: String?
        if let buckets, let first = buckets.first, let last = buckets.last, abs(first) > 1e-6 {
            slopePct   = (last - first) / abs(first) * 100
            volatility = TrendShapeCompute.volatility(buckets)
            shape      = TrendShapeCompute.classify(buckets).rawValue
        }
```

passing all four new values into the returned `MetricTrend`.

- [ ] **Step 5: Add a bucket test to `LiveStateTrendComputeTests.swift`**

```swift
    func testProducesFiveBucketsAndShape() {
        let values: [Float] = (0..<300).map { 74 - Float($0) * 0.02 }   // steady fall
        let now = Date()
        let history = (0..<300).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-Double(300 - i) * 2),
                                meanBPM: values[i])
        }
        let hr = LiveStateTrendCompute.summarize(history, windowMinutes: 10, now: now)?["hr"]
        XCTAssertEqual(hr?.buckets?.count, 5)
        XCTAssertEqual(hr?.shape, "steady-fall")
        XCTAssertNotNil(hr?.slopePct)
        XCTAssertEqual(hr?.volatility, "low")
    }
```

- [ ] **Step 6: Register `F216`/`A216`, `FT17`/`AT17`, then run both test classes.**

Run: `... -only-testing:WythinTests/TrendShapeComputeTests -only-testing:WythinTests/LiveStateTrendComputeTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/TrendShapeCompute.swift ios/WythinTests/TrendShapeComputeTests.swift ios/Wythin/Metrics/LiveStateTrendCompute.swift ios/WythinTests/LiveStateTrendComputeTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(live): bucket the 10-minute window and label its shape"
```

---

### Task 8: DayLoadSummary — the local, non-LLM day-load line

**Files:**
- Create: `ios/Wythin/Metrics/DayLoadSummary.swift`
- Create: `ios/WythinTests/DayLoadSummaryTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F218`/`A218`, `FT19`/`AT19`)

**Interfaces:**
- Consumes: anchor lnRMSSD, today's mean lnRMSSD, hours elapsed since the anchor.
- Produces: `DayLoadSummary.text(anchorLnRMSSD:dayMeanLnRMSSD:hoursElapsed:) -> String?`

- [ ] **Step 1: Write the failing test**

`ios/WythinTests/DayLoadSummaryTests.swift`:

```swift
import XCTest
@testable import Wythin

final class DayLoadSummaryTests: XCTestCase {

    func testNilWhenTooEarly() {
        XCTAssertNil(DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 3.5, hoursElapsed: 0.5))
    }

    func testNilWithoutDayMean() {
        XCTAssertNil(DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: nil, hoursElapsed: 5))
    }

    func testHoldingWhenDayMatchesAnchor() {
        let t = DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 3.58, hoursElapsed: 6)
        XCTAssertTrue(t?.contains("still there") ?? false)
    }

    func testSteadySpendInTheMiddleBand() {
        let t = DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 3.3, hoursElapsed: 6)
        XCTAssertTrue(t?.contains("steadily") ?? false)
    }

    func testHeavySpendWhenWellBelowAnchor() {
        let t = DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 2.6, hoursElapsed: 6)
        XCTAssertTrue(t?.contains("a lot of it") ?? false)
    }

    func testUsesNoTechnicalTerms() {
        let t = DayLoadSummary.text(anchorLnRMSSD: 3.6, dayMeanLnRMSSD: 3.3, hoursElapsed: 6) ?? ""
        for banned in ["HRV", "RMSSD", "RSA", "SDNN", "DFA", "vagal", "coherence", "entropy"] {
            XCTAssertFalse(t.localizedCaseInsensitiveContains(banned), "leaked \(banned)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Expected: FAIL — `cannot find 'DayLoadSummary' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ios/Wythin/Metrics/DayLoadSummary.swift`:

```swift
import Foundation

/// The "how the day has gone so far" line under Day Potential.
///
/// Deliberately NOT LLM-generated: it is the only part of the card that
/// changes through the day, and a template updates continuously for free and
/// never rewords itself. It is also the only place today's running average is
/// allowed to appear — the live-state read never compares to an average.
enum DayLoadSummary {

    /// Nothing meaningful to say before this much of the day has passed.
    static let minimumHours: Double = 2

    static func text(anchorLnRMSSD: Float,
                     dayMeanLnRMSSD: Float?,
                     hoursElapsed: Double) -> String? {
        guard hoursElapsed >= minimumHours,
              let dayMean = dayMeanLnRMSSD,
              anchorLnRMSSD > 1e-6 else { return nil }

        let hours = Int(hoursElapsed.rounded())
        let ratio = dayMean / anchorLnRMSSD

        let tail: String
        switch ratio {
        case 0.95...:    tail = "you've barely dipped below where you started — **most of the reserve is still there**."
        case 0.85..<0.95: tail = "you've been spending it **steadily** rather than in spikes."
        default:          tail = "you've already used **a lot of it** — what's left is worth protecting."
        }

        return "\(hours) hours in, \(tail)"
    }
}
```

- [ ] **Step 4: Register `F218`/`A218`, `FT19`/`AT19`.**

- [ ] **Step 5: Run test to verify it passes.** Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/DayLoadSummary.swift ios/WythinTests/DayLoadSummaryTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(potential): local day-load line, no LLM"
```

---

### Task 9: DayPotentialInsight — parse the day-potential reply

**Files:**
- Create: `ios/Wythin/Metrics/DayPotentialInsight.swift`
- Create: `ios/WythinTests/DayPotentialInsightTests.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F217`/`A217`, `FT18`/`AT18`)

**Interfaces:**
- Produces: `DayPotentialInsight(raw:)` with `title: String`, `bullets: [String]`, `recommendation: String?`.

- [ ] **Step 1: Write the failing test**

`ios/WythinTests/DayPotentialInsightTests.swift`:

```swift
import XCTest
@testable import Wythin

final class DayPotentialInsightTests: XCTestCase {

    func testParsesFullReply() {
        let raw = """
        Good Reserves
        • Your first still reading came in **at the top of your usual range**.
        • Your mornings are **settling into a steady rhythm**.
        → Room for one hard block and a full session.
        """
        let i = DayPotentialInsight(raw: raw)
        XCTAssertEqual(i.title, "Good Reserves")
        XCTAssertEqual(i.bullets.count, 2)
        XCTAssertTrue(i.bullets[0].hasPrefix("Your first still reading"))
        XCTAssertEqual(i.recommendation, "Room for one hard block and a full session.")
    }

    func testHandlesHyphenBullets() {
        let i = DayPotentialInsight(raw: "Steady\n- one\n- two\n-> go easy")
        XCTAssertEqual(i.bullets, ["one", "two"])
        XCTAssertEqual(i.recommendation, "go easy")
    }

    func testMissingRecommendation() {
        let i = DayPotentialInsight(raw: "Steady\n• only bullet")
        XCTAssertNil(i.recommendation)
        XCTAssertEqual(i.bullets.count, 1)
    }

    func testEmptyReply() {
        let i = DayPotentialInsight(raw: "   ")
        XCTAssertEqual(i.title, "")
        XCTAssertTrue(i.bullets.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Expected: FAIL — `cannot find 'DayPotentialInsight' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ios/Wythin/Metrics/DayPotentialInsight.swift`:

```swift
import Foundation

/// Parsed day-potential reply. Unlike `LiveStateInsight` there is no state
/// key — the band, colour and score are computed on-device, so the model has
/// nothing numeric to contradict.
struct DayPotentialInsight {
    let title:          String
    let bullets:        [String]
    let recommendation: String?

    init(raw: String) {
        let lines = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var title = ""
        var bullets: [String] = []
        var recommendation: String?

        for line in lines {
            if line.hasPrefix("→") || line.hasPrefix("->") {
                recommendation = line
                    .replacingOccurrences(of: "->", with: "")
                    .replacingOccurrences(of: "→", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("•") || line.hasPrefix("-") || line.hasPrefix("*") {
                bullets.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if title.isEmpty {
                title = line
            }
        }

        self.title = title
        self.bullets = bullets
        self.recommendation = recommendation
    }
}
```

Note the ordering: `->` is checked before `-` so a hyphen arrow is not mistaken for a bullet.

- [ ] **Step 4: Register `F217`/`A217`, `FT18`/`AT18`.**

- [ ] **Step 5: Run test to verify it passes.** Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Metrics/DayPotentialInsight.swift ios/WythinTests/DayPotentialInsightTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(potential): parse the day-potential reply"
```

---

### Task 10: API payloads — drop day_mean, add buckets, add day_potential

**Files:**
- Modify: `ios/Wythin/Sync/APIClient.swift:60-85`, `:204-209`, `:315-319`
- Modify: `ios/WythinTests/PayloadBuilderTests.swift`

**Interfaces:**
- Consumes: `MetricTrend` (Task 7), `PotentialResult`, `AnchorReading`, `AnchorBaseline`, `StreakResult`.
- Produces: revised `MetricTrendPayload`; new `DayPotentialPayload`; `APIClient.generateDayPotentialInsight(_:) -> InsightResponse`.

- [ ] **Step 1: Write the failing test**

Append to `ios/WythinTests/PayloadBuilderTests.swift`:

```swift
    func testLiveStatePayloadOmitsDayMean() throws {
        let trend = MetricTrend(start: 70, end: 68, min: 67, max: 74, mean: 70,
                                direction: "falling", dayMean: 71,
                                buckets: [74, 72, 70, 69, 68], slopePct: -8.1,
                                volatility: "low", shape: "steady-fall")
        let payload = LiveStateInsightPayload(windowMinutes: 10, trends: ["hr": trend])
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("day_mean"), "day_mean must not cross the network")
        XCTAssertTrue(json.contains("buckets"))
        XCTAssertTrue(json.contains("steady-fall"))
    }

    func testDayPotentialPayloadEncodesScoreAndStreak() throws {
        let payload = DayPotentialPayload(
            score: 72, band: "good",
            anchorHour: 7.2, anchorDurationMin: 5, late: false, confidence: "high",
            components: ["recovery_capacity": MetricComponentPayload(z: 0.8, level: "top of usual")],
            modifiers: ["fragmentation": 0],
            baselineAnchors: 41, baselineTarget: 60, baselineSufficient: true,
            recent: [64, 58, 61, 66, 69, 70, 72],
            streakCurrent: 4, streakBest: 6, graceUsed: false)
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"mode\":\"day_potential\""))
        XCTAssertTrue(json.contains("\"score\":72"))
        XCTAssertTrue(json.contains("streak"))
    }
```

- [ ] **Step 2: Run test to verify it fails.** Expected: FAIL — `cannot find 'DayPotentialPayload' in scope`.

- [ ] **Step 3: Rewrite `MetricTrendPayload` in `APIClient.swift`**

```swift
struct MetricTrendPayload: Codable {
    let now:        Float?
    let min:        Float?
    let max:        Float?
    let buckets:    [Float]?
    let slopePct:   Float?
    let volatility: String?
    let shape:      String?

    // NOTE: no day_mean. The live read must never compare to an average —
    // that is Day Potential's job, and withholding the field is the only
    // enforcement that doesn't leak.
    enum CodingKeys: String, CodingKey {
        case now, min, max, buckets, volatility, shape
        case slopePct = "slope_pct"
    }

    init(from t: MetricTrend) {
        now = t.end; min = t.min; max = t.max
        buckets = t.buckets; slopePct = t.slopePct
        volatility = t.volatility; shape = t.shape
    }
}
```

- [ ] **Step 4: Add the day-potential payload and client call**

```swift
struct MetricComponentPayload: Codable {
    let z: Float?
    let level: String?
}

struct DayPotentialPayload: Codable {
    let mode = "day_potential"
    let score: Int?
    let band: String?
    let anchorHour: Double
    let anchorDurationMin: Int
    let late: Bool
    let confidence: String
    let components: [String: MetricComponentPayload]
    let modifiers: [String: Float]
    let baselineAnchors: Int
    let baselineTarget: Int
    let baselineSufficient: Bool
    let recent: [Int]
    let streakCurrent: Int
    let streakBest: Int
    let graceUsed: Bool

    enum CodingKeys: String, CodingKey {
        case mode, score, band, components, modifiers, recent
        case anchorHour = "anchor_hour"
        case anchorDurationMin = "anchor_duration_min"
        case late, confidence
        case baselineAnchors = "baseline_anchors"
        case baselineTarget = "baseline_target"
        case baselineSufficient = "baseline_sufficient"
        case streakCurrent = "streak_current"
        case streakBest = "streak_best"
        case graceUsed = "grace_used"
    }
}
```

and alongside `generateLiveStateInsight`:

```swift
    func generateDayPotentialInsight(_ payload: DayPotentialPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(InsightResponse.self, from: data)
    }
```

- [ ] **Step 5: Run tests.**

Run: `... -only-testing:WythinTests/PayloadBuilderTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/Sync/APIClient.swift ios/WythinTests/PayloadBuilderTests.swift
git commit -m "feat(api): bucketed live-state payload without day_mean, plus day_potential"
```

---

### Task 11: Server — reshape live_state, add day_potential

**Files:**
- Modify: `server/models.py`
- Modify: `server/routers/insights.py`
- Modify: `server/tests/test_insights.py`

**Interfaces:**
- Consumes: the payloads from Task 10.
- Produces: `mode="day_potential"` handling; `_format_day_potential`; revised `_format_live_state`.

- [ ] **Step 1: Write the failing test**

Append to `server/tests/test_insights.py`:

```python
@pytest.mark.asyncio
async def test_day_potential_requires_score_when_baseline_sufficient():
    app.dependency_overrides[get_openai_client] = lambda: _FakeClient("x")
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        r = await ac.post("/insights", json={
            "mode": "day_potential",
            "anchor_hour": 7.2, "anchor_duration_min": 5,
            "late": False, "confidence": "high",
            "baseline_anchors": 41, "baseline_target": 60, "baseline_sufficient": True,
        }, headers={"X-API-Key": API_KEY})
    assert r.status_code == 422
    app.dependency_overrides.clear()


@pytest.mark.asyncio
async def test_day_potential_allows_recent_when_baseline_insufficient():
    app.dependency_overrides[get_openai_client] = lambda: _FakeClient("Learning\n• a\n• b\n→ c")
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        r = await ac.post("/insights", json={
            "mode": "day_potential",
            "anchor_hour": 7.2, "anchor_duration_min": 5,
            "late": False, "confidence": "high",
            "baseline_anchors": 3, "baseline_target": 60, "baseline_sufficient": False,
            "recent": [58, 61, 64],
        }, headers={"X-API-Key": API_KEY})
    assert r.status_code == 200
    app.dependency_overrides.clear()


def test_live_state_format_has_buckets_and_no_day_average():
    from server.models import InsightRequest, MetricTrend
    from server.routers.insights import _format_live_state
    req = InsightRequest(mode="live_state", window_minutes=10, metrics={
        "hr": MetricTrend(now=68.4, min=68.0, max=74.1,
                          buckets=[74.1, 72.8, 70.2, 68.9, 68.4],
                          slope_pct=-7.7, volatility="low", shape="steady-fall")
    })
    text = _format_live_state(req)
    assert "74.1 → 72.8" in text
    assert "steady-fall" in text
    assert "day_avg" not in text
```

Match the existing file's fixtures for `API_KEY` and `_FakeClient` — reuse whatever names are already defined there rather than redefining them.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/alexutkin && .venv313/bin/pytest server/tests/test_insights.py -q`
Expected: FAIL — unexpected keyword `buckets` / 200 where 422 expected.

- [ ] **Step 3: Update `server/models.py`**

```python
class MetricTrend(BaseModel):
    # legacy fields kept optional so an older client build still validates
    start: Optional[float] = None
    end:   Optional[float] = None
    mean:  Optional[float] = None
    direction: Optional[str] = None
    day_mean: Optional[float] = None

    now:        Optional[float] = None
    min:        Optional[float] = None
    max:        Optional[float] = None
    buckets:    Optional[list[float]] = None
    slope_pct:  Optional[float] = None
    volatility: Optional[str] = None
    shape:      Optional[str] = None


class MetricComponent(BaseModel):
    z: Optional[float] = None
    level: Optional[str] = None
```

and on `InsightRequest`:

```python
    # "day_potential" mode fields
    score:      Optional[int] = None
    band:       Optional[str] = None
    anchor_hour:         Optional[float] = None
    anchor_duration_min: Optional[int] = None
    late:       Optional[bool] = None
    confidence: Optional[str] = None
    components: Optional[dict[str, MetricComponent]] = None
    modifiers:  Optional[dict[str, float]] = None
    baseline_anchors:    Optional[int] = None
    baseline_target:     Optional[int] = None
    baseline_sufficient: Optional[bool] = None
    recent:     Optional[list[int]] = None
    streak_current: Optional[int] = None
    streak_best:    Optional[int] = None
    grace_used:     Optional[bool] = None
```

- [ ] **Step 4: Update `server/routers/insights.py`**

Replace `_format_live_state` with the bucketed renderer:

```python
def _format_live_state(req: InsightRequest) -> str:
    lines = [
        f"Window: last {req.window_minutes} minutes, split into five equal "
        f"buckets (oldest first). 'now' is the latest value, 'slope' is the "
        f"change across the window, 'shape' names the arc."
    ]
    for name, trend in (req.metrics or {}).items():
        label = _METRIC_NAMES.get(name, name)
        lines.append(f"{label}:")
        if trend.buckets:
            arc = " → ".join(f"{v:.1f}" for v in trend.buckets)
            lines.append(f"  buckets: {arc}")
        lines.append(
            f"  now={trend.now} | slope={trend.slope_pct}% | "
            f"volatility={trend.volatility} | shape={trend.shape} | "
            f"range={trend.min}-{trend.max}"
        )
    return "\n".join(lines)
```

Add the day-potential prompt and renderer:

```python
_DAY_POTENTIAL_SYSTEM_PROMPT = (
    "You are an expert physiologist writing the 'today's potential' read-out "
    "for a person wearing a chest strap. You are given a capacity score the "
    "app already computed from their FIRST RESTED READING of the day compared "
    "with their own personal baseline — you never compute, state, or "
    "contradict the number. Reply in EXACTLY this plain-text structure, no "
    "markdown headings, nothing before or after:\n"
    "\n"
    "<fresh 2-3 word title>\n"
    "• <how today's rested reading compares with their own usual range>\n"
    "• <what the pattern across recent mornings shows>\n"
    "→ <what today can realistically hold>\n"
    "\n"
    "Exactly 2 bullets. Wrap the single KEY IDEA of each bullet in **double "
    "asterisks**. Speak in plain everyday language about capacity, reserves, "
    "and what the body can carry today. NEVER use technical terms — no HRV, "
    "RMSSD, RSA, SDNN, DFA, LF/HF, 'vagal tone', 'coherence', 'entropy', "
    "'deceleration'. ('Inner noise' is fine — it is one of the app's own "
    "labels.) Never mention z-scores, weights, or the word 'baseline'; say "
    "'your usual range' instead.\n"
    "\n"
    "If the fragmentation modifier is above zero, do NOT describe recovery or "
    "reserves as high, however good the other numbers look — the rhythm is "
    "erratic and that inflates the underlying measure.\n"
    "If baseline_sufficient is false there is not yet enough history for a "
    "personal range: compare only with the immediately preceding mornings, "
    "claim no norms, and say the app is still learning what is normal for "
    "them.\n"
    "If confidence is 'low' or late is true, hedge accordingly.\n"
    "The title must vary — never simply echo the band name."
)


def _format_day_potential(req: InsightRequest) -> str:
    lines = []
    if req.score is not None:
        lines.append(f"Capacity score: {req.score}/100 (band: {req.band})")
    else:
        lines.append("Capacity score: not yet available — baseline still building.")
    lines.append(
        f"Rested reading: {req.anchor_hour:.1f}h, {req.anchor_duration_min} min, "
        f"late={req.late}, confidence={req.confidence}"
    )
    lines.append(
        f"History: {req.baseline_anchors} of {req.baseline_target} readings, "
        f"sufficient={req.baseline_sufficient}"
    )
    for name, comp in (req.components or {}).items():
        lines.append(f"{name}: z={comp.z} ({comp.level})")
    for name, value in (req.modifiers or {}).items():
        lines.append(f"modifier {name}: -{value}")
    if req.recent:
        lines.append("Recent morning scores (oldest first): " +
                     ", ".join(str(v) for v in req.recent))
    if req.streak_current is not None:
        lines.append(
            f"Streak: {req.streak_current} mornings (best {req.streak_best}, "
            f"grace_used={req.grace_used})"
        )
    return "\n".join(lines)
```

and in `generate_insight`, before the existing `live_state` branch:

```python
    if req.mode == "day_potential":
        if req.anchor_hour is None or req.baseline_sufficient is None:
            raise HTTPException(status_code=422, detail="anchor and baseline are required for day_potential mode")
        if req.baseline_sufficient and req.score is None:
            raise HTTPException(status_code=422, detail="score is required when the baseline is sufficient")
        if not req.baseline_sufficient and not req.recent:
            raise HTTPException(status_code=422, detail="recent is required when the baseline is insufficient")
        system_prompt = _DAY_POTENTIAL_SYSTEM_PROMPT
        user_content = _format_day_potential(req)
        max_tokens = 200
    elif req.mode == "live_state":
        ...
```

Also update the `live_state` prompt: replace every instruction to compare against `day_avg` with an instruction to describe the **arc** of the window — what moved, when in the window, and whether it held — and add: "NEVER compare to an average, a norm, or a typical value; you do not have one and must not invent one." Raise its `max_tokens` from 220 to 260.

- [ ] **Step 5: Run tests to verify they pass.**

Run: `cd /Users/alexutkin && .venv313/bin/pytest server/tests/test_insights.py -q`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin && git add server/models.py server/routers/insights.py server/tests/test_insights.py
git commit -m "feat(api): day_potential mode and arc-based live_state prompt"
```

---

### Task 12: DayPotentialStore — detection, scoring, once-daily narrative

**Files:**
- Create: `ios/Wythin/UI/Live/DayPotentialStore.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F219`/`A219`, group `GAPP_LIV`)

**Interfaces:**
- Consumes: everything from Tasks 2–10.
- Produces: `DayPotentialStore` with `anchor`, `result`, `streak`, `insight`, `loadLine`, `state`, and `refresh(env:force:)`.

- [ ] **Step 1: Write the store**

`ios/Wythin/UI/Live/DayPotentialStore.swift`:

```swift
import Foundation
import SwiftData

/// Owns the day's anchor, its score, the streak, and the once-daily
/// narrative. The score is computed on-device, so it renders even when the
/// network is down — only the prose depends on the API.
@MainActor
@Observable
final class DayPotentialStore {

    enum State: Equatable {
        case waitingForStillness      // no rested window yet today
        case baselineBuilding(Int)    // n anchors so far, < minimum
        case scored
    }

    private(set) var anchor:   AnchorReading?
    private(set) var result:   PotentialResult?
    private(set) var streak:   StreakResult?
    private(set) var recent:   [Int] = []
    private(set) var state:    State = .waitingForStillness
    var insight:  String?
    var loadLine: String?

    private var generatedForDay: Date?
    private var inFlight = false

    /// Finds/loads today's anchor, scores it, refreshes the streak and the
    /// local load line, and generates the narrative once per day.
    func refresh(env: AppEnvironment, force: Bool = false) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let context = env.modelContext
        let today   = Calendar.current.startOfDay(for: Date())

        // 1. Today's anchor — load if stored, otherwise try to detect one.
        var stored = (try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []
        var todayAnchor = stored.first { $0.day == today }?.reading

        if todayAnchor == nil {
            let todayPoints = env.tickHistory.filter { $0.timestamp >= today }
            if let detected = AnchorDetector.detect(todayPoints) {
                context.insert(DailyAnchor(from: detected))
                try? context.save()
                stored = (try? context.fetch(FetchDescriptor<DailyAnchor>())) ?? []
                todayAnchor = detected
            }
        }
        anchor = todayAnchor

        // 2. Streak + baseline from all stored anchors.
        let history = stored.map { $0.reading }
        streak = StreakCompute.evaluate(days: Set(history.map { $0.day }), today: today)

        guard let todayAnchor else {
            state = .waitingForStillness
            loadLine = nil
            return
        }

        let past = history.filter { $0.day < today }
        guard let baseline = AnchorBaseline.build(history: past, todayHour: todayAnchor.hour) else {
            state = .baselineBuilding(past.count + 1)
            result = nil
            await generate(env: env, baseline: nil, force: force)
            updateLoadLine(env: env, anchor: todayAnchor)
            return
        }

        result = PotentialScore.evaluate(anchor: todayAnchor, baseline: baseline)
        state  = result == nil ? .waitingForStillness : .scored

        // Recent scores for the sparkline — each past anchor scored against
        // the same baseline, so the bars are comparable.
        recent = past.suffix(7).compactMap {
            PotentialScore.evaluate(anchor: $0, baseline: baseline)?.score
        }

        updateLoadLine(env: env, anchor: todayAnchor)
        await generate(env: env, baseline: baseline, force: force)
    }

    // MARK: - Narrative (once per day)

    private func generate(env: AppEnvironment, baseline: AnchorBaseline?, force: Bool) async {
        let today = Calendar.current.startOfDay(for: Date())
        guard force || generatedForDay != today || insight == nil else { return }
        guard let anchor else { return }

        var components: [String: MetricComponentPayload] = [:]
        var modifiers:  [String: Float] = [:]
        if let r = result {
            components["recovery_capacity"] = MetricComponentPayload(
                z: r.components.lnRMSSDz, level: Self.level(r.components.lnRMSSDz))
            components["resting_pace"] = MetricComponentPayload(
                z: r.components.restingHRz, level: Self.level(r.components.restingHRz))
            if let dcZ = r.components.dcZ {
                components["settling_depth"] = MetricComponentPayload(z: dcZ, level: Self.level(dcZ))
            }
            modifiers["stability"]     = r.penalties.stability
            modifiers["fragmentation"] = r.penalties.fragmentation
            modifiers["organization"]  = r.penalties.organization
        }

        let payload = DayPotentialPayload(
            score: result?.score,
            band: result?.band.rawValue,
            anchorHour: anchor.hour,
            anchorDurationMin: Int((anchor.durationSec / 60).rounded()),
            late: anchor.late,
            confidence: anchor.confidence.rawValue,
            components: components,
            modifiers: modifiers,
            baselineAnchors: baseline?.anchorCount ?? recent.count,
            baselineTarget: AnchorBaseline.windowDays,
            baselineSufficient: baseline != nil,
            recent: recent,
            streakCurrent: streak?.current ?? 0,
            streakBest: streak?.best ?? 0,
            graceUsed: streak?.graceUsed ?? false)

        if let response = try? await env.sync.client.generateDayPotentialInsight(payload) {
            insight = response.text
            generatedForDay = today
        }
    }

    private func updateLoadLine(env: AppEnvironment, anchor: AnchorReading) {
        let today = Calendar.current.startOfDay(for: Date())
        let todayPoints = MetricsQualityFilter.filter(env.tickHistory.filter { $0.timestamp >= today })
        let vtis = todayPoints.compactMap { $0.vti }
        let dayMean = vtis.isEmpty ? nil : vtis.reduce(0, +) / Float(vtis.count)
        loadLine = DayLoadSummary.text(
            anchorLnRMSSD: anchor.lnRMSSD,
            dayMeanLnRMSSD: dayMean,
            hoursElapsed: Date().timeIntervalSince(anchor.startedAt) / 3600)
    }

    private static func level(_ z: Float) -> String {
        switch z {
        case 1.0...:      return "well above their usual"
        case 0.35..<1.0:  return "above their usual"
        case -0.35..<0.35: return "right around their usual"
        case -1.0.. < -0.35: return "below their usual"
        default:          return "well below their usual"
        }
    }
}
```

Note: `AppEnvironment` must expose `modelContext`. If it does not already, add a computed `var modelContext: ModelContext { modelContainer.mainContext }` to `AppEnvironment` (the container is already stored there at `AppEnvironment.swift:94`).

- [ ] **Step 2: Register `F219`/`A219` under `GAPP_LIV` and `BSAPP`.**

- [ ] **Step 3: Build**

Run the build-check command. Expected: `** BUILD SUCCEEDED **`.
Fix the `level(_:)` range syntax if the compiler objects — `case -1.0 ..< -0.35:` needs the spaces.

- [ ] **Step 4: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/UI/Live/DayPotentialStore.swift ios/Wythin/App/AppEnvironment.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(potential): store wiring anchor detection, scoring and narrative"
```

---

### Task 13: DayPotentialStrip UI

**Files:**
- Create: `ios/Wythin/UI/Live/DayPotentialStrip.swift`
- Modify: `ios/Wythin/UI/Live/LiveStateWidget.swift`
- Modify: `ios/Wythin/UI/Live/LiveView.swift:129-141`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj` (`F220`/`A220`)

**Interfaces:**
- Consumes: `DayPotentialStore`, `DayPotentialInsight`, `PotentialBand`.
- Produces: `DayPotentialStrip(store:)` view.

- [ ] **Step 1: Write the view**

`ios/Wythin/UI/Live/DayPotentialStrip.swift` — collapsed strip, day dots, baseline bar, and the expanded body. Colours come from `PotentialBand`, never from the model.

```swift
import SwiftUI

/// Today's capacity read: a collapsed one-line strip that expands to the
/// anchor provenance, the recent-mornings sparkline, the narrative, and the
/// local day-load line. The score is on-device, so this renders offline.
struct DayPotentialStrip: View {
    let store: DayPotentialStore
    @AppStorage("dayPotentialExpanded") private var expanded = false

    private var accent: Color {
        switch store.result?.band {
        case .full, .good: return Theme.accent
        case .steady:      return Theme.breathe
        case .light, .depleted: return Theme.warn
        case nil:          return Theme.dim
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            strip
            dots
            baselineBar
            if expanded { expandedBody }
            if store.anchor == nil, (store.streak?.current ?? 0) > 0 { nudge }
        }
    }

    // MARK: Collapsed

    private var strip: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(headline)
                        .font(Theme.monoLabel)
                        .foregroundStyle(accent)
                    ProgressView(value: Double(store.result?.score ?? 0), total: 100)
                        .tint(accent)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }
                Text(store.result.map { "\($0.score)" } ?? "—")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(store.result == nil ? Theme.dim : accent)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(accent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var headline: String {
        switch store.state {
        case .waitingForStillness: return "TODAY'S POTENTIAL · WAITING FOR A STILL MOMENT"
        case .baselineBuilding:    return "MORNING READ · LEARNING YOUR RANGE"
        case .scored:              return "TODAY'S POTENTIAL · \((store.result?.band.label ?? "").uppercased())"
        }
    }

    // MARK: Streak

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<7, id: \.self) { i in
                let day = Calendar.current.date(byAdding: .day, value: i - 6, to: Calendar.current.startOfDay(for: Date()))!
                let logged = store.loggedDays.contains(day)
                Circle()
                    .fill(logged ? accent : .clear)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(logged ? .clear : Theme.dim.opacity(0.35), lineWidth: 1.5))
            }
            Spacer()
            Text("\(store.streak?.current ?? 0) mornings in a row")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dim)
        }
    }

    private var baselineBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: Double(store.streak?.totalAnchors ?? 0), total: Double(AnchorBaseline.windowDays))
                .tint(Theme.breathe)
                .scaleEffect(x: 1, y: 0.5, anchor: .center)
            Text("\(store.streak?.totalAnchors ?? 0) of \(AnchorBaseline.windowDays) readings — your range sharpens as this fills")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dim)
        }
    }

    // MARK: Expanded

    @ViewBuilder
    private var expandedBody: some View {
        if let anchor = store.anchor {
            Text(anchorMeta(anchor))
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
        }
        if !store.recent.isEmpty {
            AnchorSparkline(scores: store.recent, accent: accent)
        }
        if let raw = store.insight {
            let parsed = DayPotentialInsight(raw: raw)
            ForEach(Array(parsed.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(accent.opacity(0.7)).frame(width: 5, height: 5).padding(.top, 6)
                    Text(styled(bullet))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let rec = parsed.recommendation {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "sun.max.fill").font(.system(size: 14)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WHAT TODAY CAN HOLD").font(Theme.monoLabel).foregroundStyle(accent)
                        Text(rec).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        if let load = store.loadLine {
            Divider().overlay(Theme.dim.opacity(0.2))
            Text("HOW THE DAY HAS GONE SO FAR").font(Theme.monoLabel).foregroundStyle(Theme.dim)
            Text(styled(load))
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nudge: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill").font(.system(size: 13)).foregroundStyle(Theme.warn)
            Text("Three quiet minutes with the strap on keeps it going.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Theme.warn.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func anchorMeta(_ a: AnchorReading) -> String {
        let mins = Int((a.durationSec / 60).rounded())
        let hh = Int(a.hour), mm = Int((a.hour - Double(hh)) * 60)
        return String(format: "%@ · %02d:%02d · %d MIN STILL", a.late ? "LATER READ" : "MORNING READ", hh, mm, mins)
    }

    private func styled(_ s: String) -> AttributedString {
        var attr = (try? AttributedString(markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in attr.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            attr[run.range].foregroundColor = Theme.text
        }
        return attr
    }
}

/// Seven recent morning scores as bars.
struct AnchorSparkline: View {
    let scores: [Int]
    let accent: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(scores.enumerated()), id: \.offset) { idx, score in
                RoundedRectangle(cornerRadius: 3)
                    .fill(idx == scores.count - 1 ? accent : Theme.dim.opacity(0.35))
                    .frame(height: max(6, CGFloat(score) * 0.42))
            }
        }
        .frame(height: 46)
    }
}
```

`DayPotentialStore` needs one more published property for the dots:

```swift
    private(set) var loggedDays: Set<Date> = []
```

set in `refresh` alongside `streak`.

- [ ] **Step 2: Mount it in `LiveStateWidget`**

Give `LiveStateWidget` a `potentialStore: DayPotentialStore` property and render `DayPotentialStrip(store: potentialStore)` as the first child of its `VStack`, above `header(...)`, with a `Divider().overlay(Theme.dim.opacity(0.2))` between the strip and the current-state header. In `LiveView`, create `@State private var potentialStore = DayPotentialStore()`, pass it to the widget, and add `await potentialStore.refresh(env: env, force: true)` to the pull-to-refresh closure at `LiveView.swift:129-132`.

Also start the day-potential refresh from the widget's existing loop — in `startLoop()`, call `await potentialStore.refresh(env: env)` right after `await store.refresh(env: env)`. Anchor detection needs to keep polling until a rested window appears; the store's own guards make repeat calls cheap once the anchor is frozen.

- [ ] **Step 3: Register `F220`/`A220`, build, and check in the simulator**

Run the build-check command, then run the app in the simulator and confirm: the strip renders in the waiting state with `—`, the chevron expands and collapses, and expansion survives a tab switch.

- [ ] **Step 4: Commit**

```bash
cd /Users/alexutkin && git add ios/Wythin/UI/Live/DayPotentialStrip.swift ios/Wythin/UI/Live/DayPotentialStore.swift ios/Wythin/UI/Live/LiveStateWidget.swift ios/Wythin/UI/Live/LiveView.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(potential): day-potential strip with streak and expansion"
```

---

### Task 14: Full suite + spec cross-check

- [ ] **Step 1: Run the whole Swift suite**

Run: `cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Run the whole server suite**

Run: `cd /Users/alexutkin && .venv313/bin/pytest server/tests -q`
Expected: all pass.

- [ ] **Step 3: Commit any fixes**

```bash
cd /Users/alexutkin && git commit -am "test: full suite green for day potential"
```
