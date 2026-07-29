# Activity Capture & Insights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify activity capture to two actions with duration presets, optional live targets and free-text subtypes; and make the activity detail's headline number reconcile with the per-metric numbers below it while replacing the bottom COACH card with structured LLM Session Insights plus a note under every chart.

**Architecture:** All UI work is in `ios/Wythin/UI/Activities/`, split out of the 1279-line `ActivitiesView.swift` into three focused files. The impact number changes from a cached 0–100 score to a computed mean benefit-signed delta, deleting the cache entirely. The insight pipeline keeps its existing shape (`InsightGenerator` → `POST /insights` → OpenAI, retried on foreground) but the activity payload becomes metric-keyed with during-window buckets, and the response becomes structured JSON carrying bullets plus a per-metric note.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / Swift Charts / XCTest (iOS); FastAPI / Pydantic v2 / pytest / OpenAI `gpt-4o-mini` (server).

## Global Constraints

- **Spec:** `ios/Wythin/docs/superpowers/specs/2026-07-28-activity-capture-and-insights-design.md`. Read it before starting.
- **New Swift files must be registered in `ios/Wythin.xcodeproj/project.pbxproj` manually.** This project does **not** use `PBXFileSystemSynchronizedRootGroup`, so a file dropped on disk will not compile. Each task creating a Swift file includes this step. Back up first: `cp ios/Wythin.xcodeproj/project.pbxproj ios/Wythin.xcodeproj/project.pbxproj.bak`.
- **iOS test command:** `xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/<TestClass>`
- **iOS build check:** `xcodebuild build -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'`
- **Server test command:** `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/<file> -v`
- **Metric keys are `ActivityMetricDef.techLabel` verbatim**, including the non-ASCII α: `"DC"`, `"RCMSE"`, `"PIP"`, `"DFA α1"`, `"LF/HF"`, `"RSA"`, `"VTI"`, `"HRV"`, `"HR"`. Never key by `label`.
- **Copy is fixed by the spec.** Buttons read exactly `START NOW`, `LOG PAST ACTIVITY`, `START ACTIVITY`, `SAVE`. Card title reads exactly `SESSION INSIGHTS`. The word "coach" must not appear in user-facing text.
- **Never auto-stop an activity.** No timer may call `ActivityLogging.end`.
- `.custom` must remain the **last** case of `ActivityType`.
- Existing style: `Theme.mono*` fonts, `.cardStyle()`, `Theme.accent` / `.warn` / `.dim` / `.text` / `.card` / `.surface` / `.border`.

---

## File Structure

| File | Responsibility |
|---|---|
| `ios/Wythin/UI/Activities/ActivitiesView.swift` (modify) | Tab root: list, active banner, history rows, sheet routing |
| `ios/Wythin/UI/Activities/ActivityFormSheets.swift` (create) | Start / LogPast / Edit sheets and the pickers they share |
| `ios/Wythin/UI/Activities/ActivityDetailView.swift` (create) | Detail screen + `SessionInsightsCard` |
| `ios/Wythin/UI/Activities/PracticeImpactMeter.swift` (rename) | Diverging −20…+20 delta meter |
| `ios/Wythin/UI/Activities/MetricProgressRow.swift` (modify) | Per-metric row; renders the LLM chart note |
| `ios/Wythin/Models/ActivityLog.swift` (modify) | Model: new types, `targetMinutes`, `insightJSON`, `impactDeltaPct` |
| `ios/Wythin/Models/SessionInsight.swift` (create) | Decodes the structured insight; dimension → SF Symbol map |
| `ios/Wythin/Metrics/ActivityImpact.swift` (modify) | Delta-scale captions + trend line |
| `ios/Wythin/Sync/ActivityInsightPayloadBuilder.swift` (create) | Builds the metric-keyed payload with during-window buckets |
| `ios/Wythin/Sync/InsightGenerator.swift` (modify) | Writes `insightJSON`; pending predicate |
| `server/routers/insights.py` (modify) | Metric-keyed formatting, JSON mode, structured response |

---

## Task 1: Strip the suggestions block

**Files:**
- Modify: `ios/Wythin/UI/Activities/ActivitiesView.swift:66-68,105-167,236-269,294-316,1270-1279`
- Modify: `ios/Wythin/Models/ActivityLog.swift:94-108`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Pure deletion plus two label changes.

This is deletion-only, so there is no test to write first. The gate is that the app still builds and `pendingTabRequest` has no remaining assignment.

- [ ] **Step 1: Delete the suggestions UI**

In `ActivitiesView.swift`, delete the `suggested` computed property (lines 66-68) and replace the whole `VStack(spacing: 10)` inside the `if activeEntry == nil` section with just the button row:

```swift
            // ── Action buttons (hidden while recording) ──
            if activeEntry == nil {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            activeSheet = .start
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("START NOW")
                            }
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.bg)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        Button {
                            activeSheet = .logPast
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("LOG PAST ACTIVITY")
                            }
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(Theme.accent.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5))
                        }
                    }
                    .cardStyle()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 4, trailing: 16))
                }
            }
```

- [ ] **Step 2: Delete the now-orphaned helpers**

Delete from `ActivitiesView.swift`:
- `hourLabel()` and `suggestedActivities()` (the whole `// MARK: - Helpers` section body, lines 236-269).
- `SuggestionChip` (the whole `// MARK: - SuggestionChip` block, lines 294-316).
- `DeltaChip` (the whole `// MARK: - DeltaChip` block) — pre-existing dead code with no references.
- The trailing `// MARK: - Collection helpers` block: `private extension Array { asArray / ifEmpty }` and `private extension ArraySlice { asArray }`.

Keep the `// MARK: - Helpers` marker if `impactCaption` or other helpers remain under it; otherwise delete the marker too.

- [ ] **Step 3: Delete `defaultHours`**

In `ActivityLog.swift`, delete the entire `var defaultHours: [Int]` computed property and its `// Hour ranges…` comment (lines 94-108). It was read only by `suggestedActivities()`.

- [ ] **Step 4: Verify nothing switches tabs and nothing references the deleted code**

Run:
```bash
grep -rn "pendingTabRequest = \|SuggestionChip\|suggestedActivities\|hourLabel\|defaultHours\|DeltaChip\|ifEmpty(fallback" ios/Wythin
```
Expected: **no output**. `pendingTabRequest` itself still exists in `AppEnvironment.swift` and `WythinApp.swift` (declaration and observer) — that is fine; only assignments are gone.

- [ ] **Step 5: Build**

Run:
```bash
xcodebuild build -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/UI/Activities/ActivitiesView.swift ios/Wythin/Models/ActivityLog.swift
git commit -m "feat(activities): drop suggestions block, relabel to START NOW / LOG PAST ACTIVITY

The suggestion chips held the only assignment to pendingTabRequest, so
removing them also stops the Activities tab jumping to Practices."
```

---

## Task 2: Add Coffee and Work activity types

**Files:**
- Modify: `ios/Wythin/Models/ActivityLog.swift:7-92`
- Test: `ios/WythinTests/ActivityTypeTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `ActivityType.coffee` (rawValue `"Coffee"`), `ActivityType.work` (rawValue `"Work"`). `.custom` stays last.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ActivityTypeTests.swift`:

```swift
import XCTest
@testable import Wythin

final class ActivityTypeTests: XCTestCase {

    func testCoffeeAndWorkExist() {
        XCTAssertEqual(ActivityType(rawValue: "Coffee"), .coffee)
        XCTAssertEqual(ActivityType(rawValue: "Work"), .work)
    }

    func testCustomRemainsLastCase() {
        // ActivityTypeCell and the showCustom flow assume Custom is the last
        // tile in the grid.
        XCTAssertEqual(ActivityType.allCases.last, .custom)
    }

    func testNewTypesHaveSubtypesAndIcons() {
        XCTAssertTrue(ActivityType.coffee.subtypes.contains("Espresso"))
        XCTAssertTrue(ActivityType.work.subtypes.contains("Deep Work"))
        XCTAssertFalse(ActivityType.coffee.icon.isEmpty)
        XCTAssertFalse(ActivityType.work.icon.isEmpty)
    }

    func testUnknownRawValueFallsBackToCustom() {
        let entry = ActivityLog(activityType: "Nonsense")
        XCTAssertEqual(entry.activityTypeEnum, .custom)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/ActivityTypeTests
```
Expected: compile failure — `type 'ActivityType' has no member 'coffee'`.

(If the new test file isn't picked up, add it to the `WythinTests` target in `project.pbxproj` per the Global Constraints, then re-run.)

- [ ] **Step 3: Add the cases**

In `ActivityLog.swift`, add to the enum immediately **before** `case custom`:

```swift
    case coffee       = "Coffee"
    case work         = "Work"
```

Add to `icon`:
```swift
        case .coffee:       return "cup.and.saucer.fill"
        case .work:         return "laptopcomputer"
```

Add to `color`:
```swift
        case .coffee:            return Color(hex: "#C89F6B")
        case .work:              return Theme.ulf
```

Add to `subtypes`:
```swift
        case .coffee:
            return ["Espresso", "Filter", "Latte", "Cold Brew", "Decaf"]
        case .work:
            return ["Deep Work", "Meetings", "Email", "Creative", "Reading"]
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/ActivityTypeTests
```
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Models/ActivityLog.swift ios/WythinTests/ActivityTypeTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): add Coffee and Work activity types"
```

---

## Task 3: Split ActivitiesView into three files

**Files:**
- Modify: `ios/Wythin/UI/Activities/ActivitiesView.swift`
- Create: `ios/Wythin/UI/Activities/ActivityFormSheets.swift`
- Create: `ios/Wythin/UI/Activities/ActivityDetailView.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing.
- Produces: `ActivityPickerSection(selected:selectedSubtype:customName:showCustom:)` — a `View` used by all three sheets, taking four `Binding`s. `StartActivitySheet`, `LogPastSheet`, `EditActivitySheet`, `SubtypePicker`, `ActivityTypeCell` keep their current public signatures and move to `ActivityFormSheets.swift`. `ActivityDetailView(entry:)` keeps its signature and moves to `ActivityDetailView.swift`.

This is a pure move with one extraction. Behaviour must not change; the gate is that the build succeeds and the existing test suite still passes.

- [ ] **Step 1: Move the detail view**

Create `ios/Wythin/UI/Activities/ActivityDetailView.swift` containing `import SwiftUI`, `import SwiftData`, `import Charts` and the entire `struct ActivityDetailView` block cut verbatim from `ActivitiesView.swift` (starting at `// MARK: - ActivityDetailView`, ending before `// MARK: - StartActivitySheet`).

Note: the source has a brace-nesting quirk — `ActivityDetailView`'s closing braces run to just before `// MARK: - StartActivitySheet`. Copy the whole region and let the compiler confirm balance.

- [ ] **Step 2: Move the sheets**

Create `ios/Wythin/UI/Activities/ActivityFormSheets.swift` with `import SwiftUI`, `import SwiftData` and, cut verbatim from `ActivitiesView.swift`: `StartActivitySheet`, `LogPastSheet`, `SubtypePicker`, `ActivityTypeCell`, `EditActivitySheet`.

`EditActivitySheet` is currently `private struct` inside `ActivitiesView.swift`. It is used from `ActivitiesView.sheetContent`, so on moving it must become internal — drop the `private` keyword.

- [ ] **Step 3: Extract the shared picker section**

All three sheets open with an identical type-grid + subtype + custom-name region. Add to `ActivityFormSheets.swift` and replace those three copies with a single call:

```swift
/// The type grid + subtype picker + custom-name field shared by the Start,
/// Log Past and Edit sheets. Owns no state — the host sheet holds it, because
/// each sheet seeds it differently.
struct ActivityPickerSection: View {
    @Binding var selected:        ActivityType
    @Binding var selectedSubtype: String?
    @Binding var customName:      String
    @Binding var showCustom:      Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 16) {
            Text("SELECT ACTIVITY")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ActivityType.allCases, id: \.self) { type in
                    ActivityTypeCell(type: type, isSelected: selected == type) {
                        selected = type
                        selectedSubtype = nil
                        showCustom = (type == .custom)
                    }
                }
            }
            .padding(.horizontal)

            SubtypePicker(type: selected, selected: $selectedSubtype)
                .padding(.horizontal)

            if showCustom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CUSTOM NAME")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    TextField("e.g. Ice bath", text: $customName)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text)
                        .padding(10)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.border, lineWidth: 0.5))
                }
                .padding(.horizontal)
            }
        }
    }
}
```

Note the deliberate change: the old code wrapped `SubtypePicker` in `if !selected.subtypes.isEmpty`. That guard is dropped, because Task 6 gives every type a `+ Custom` chip, so the picker is never empty.

In each of the three sheets, replace the copied region with:

```swift
                    ActivityPickerSection(selected: $selected,
                                          selectedSubtype: $selectedSubtype,
                                          customName: $customName,
                                          showCustom: $showCustom)
```

`StartActivitySheet` has no `customName` binding problem — it already declares `@State private var customName: String = ""`. `LogPastSheet` and `EditActivitySheet` likewise.

- [ ] **Step 4: Register both new files in the Xcode project**

```bash
cp ios/Wythin.xcodeproj/project.pbxproj ios/Wythin.xcodeproj/project.pbxproj.bak
```
Then add `ActivityFormSheets.swift` and `ActivityDetailView.swift` to the `Wythin` target: a `PBXFileReference`, a `PBXBuildFile`, membership in the `Activities` `PBXGroup`, and an entry in the `Sources` `PBXSourcesBuildPhase`. Mirror the four existing entries for `MetricProgressRow.swift` exactly, substituting fresh 24-hex-character UUIDs.

- [ ] **Step 5: Build and run the full suite**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED` and all pre-existing tests pass. No behaviour changed, so any failure is a bad move.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/UI/Activities/ ios/Wythin.xcodeproj/project.pbxproj
git commit -m "refactor(activities): split ActivitiesView, extract ActivityPickerSection

Pure move plus one extraction: the three sheets shared an identical
type-grid + subtype + custom-name region."
```

---

## Task 4: Duration presets

**Files:**
- Modify: `ios/Wythin/UI/Activities/ActivityFormSheets.swift`
- Test: `ios/WythinTests/DurationPresetTests.swift` (create)

**Interfaces:**
- Consumes: `ActivityFormSheets.swift` from Task 3.
- Produces: `DurationPresetRow(minutes: Binding<Double?>, title: String)` and `DurationPresetRow.presets: [Int]` (`[5, 10, 15, 20, 30]`), plus `DurationPresetRow.isSelected(_ preset: Int, minutes: Double?) -> Bool` as a static so it can be unit-tested without a view host.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/DurationPresetTests.swift`:

```swift
import XCTest
@testable import Wythin

final class DurationPresetTests: XCTestCase {

    func testPresetsAreTheSpecifiedFive() {
        XCTAssertEqual(DurationPresetRow.presets, [5, 10, 15, 20, 30])
    }

    func testExactValueSelectsThatPreset() {
        XCTAssertTrue(DurationPresetRow.isSelected(15, minutes: 15))
        XCTAssertFalse(DurationPresetRow.isSelected(20, minutes: 15))
    }

    func testNonPresetValueSelectsNothing() {
        // Dragging the slider off a preset must clear the highlight without
        // any extra state to track.
        for p in DurationPresetRow.presets {
            XCTAssertFalse(DurationPresetRow.isSelected(p, minutes: 17))
        }
    }

    func testNilValueSelectsNothing() {
        for p in DurationPresetRow.presets {
            XCTAssertFalse(DurationPresetRow.isSelected(p, minutes: nil))
        }
    }

    func testFractionalValueDoesNotSelect() {
        XCTAssertFalse(DurationPresetRow.isSelected(15, minutes: 15.4))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/DurationPresetTests
```
Expected: compile failure — `cannot find 'DurationPresetRow' in scope`.

- [ ] **Step 3: Implement `DurationPresetRow`**

Add to `ActivityFormSheets.swift`:

```swift
// MARK: - DurationPresetRow

/// Quick-pick minute chips. A shortcut over whatever control sits beside it,
/// never a mode: selection is derived purely from the bound value, so dragging
/// a slider to a non-preset number clears the highlight with no extra state.
struct DurationPresetRow: View {
    static let presets = [5, 10, 15, 20, 30]

    @Binding var minutes: Double?
    var title: String = "DURATION"
    /// Trailing text shown at the row's right edge (e.g. "15 min"). Empty hides it.
    var valueLabel: String = ""

    static func isSelected(_ preset: Int, minutes: Double?) -> Bool {
        guard let m = minutes else { return false }
        return m == Double(preset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                if !valueLabel.isEmpty {
                    Text(valueLabel)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.accent)
                } else if minutes != nil {
                    Button("clear") { minutes = nil }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.5))
                }
            }

            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.self) { p in
                    let on = Self.isSelected(p, minutes: minutes)
                    Button {
                        minutes = Double(p)
                    } label: {
                        Text("\(p)")
                            .font(Theme.monoLabel)
                            .foregroundStyle(on ? Theme.bg : Theme.accent)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(on ? Theme.accent : Theme.accent.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(on ? .clear : Theme.accent.opacity(0.25), lineWidth: 0.5))
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/DurationPresetTests
```
Expected: PASS, 5 tests.

- [ ] **Step 5: Wire into Log Past and Edit**

Both sheets currently hold `@State private var durationMins: Double`. Add a bridging binding to each, because `DurationPresetRow` binds `Double?` while the slider binds `Double`:

```swift
    /// Bridges the non-optional slider value to the preset row's optional
    /// binding. Writing nil is a no-op — the duration always has a value here.
    private var presetBinding: Binding<Double?> {
        Binding(get: { durationMins },
                set: { if let v = $0 { durationMins = v } })
    }
```

Then in each sheet's duration card, replace the `VStack(alignment: .leading, spacing: 4) { HStack { Text("DURATION") … } Slider(…) }` block with:

```swift
                        VStack(alignment: .leading, spacing: 8) {
                            DurationPresetRow(minutes: presetBinding,
                                              valueLabel: "\(Int(durationMins)) min")
                            Slider(value: $durationMins, in: 1...180, step: 1)
                                .tint(Theme.accent)
                        }
```

- [ ] **Step 6: Build**

Run:
```bash
xcodebuild build -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add ios/Wythin/UI/Activities/ActivityFormSheets.swift ios/WythinTests/DurationPresetTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): 5/10/15/20/30 duration presets on Log Past and Edit"
```

---

## Task 5: Optional live target on Start Now

**Files:**
- Modify: `ios/Wythin/Models/ActivityLog.swift`
- Modify: `ios/Wythin/UI/Activities/ActivityLogging.swift:22-37`
- Modify: `ios/Wythin/UI/Activities/ActivityFormSheets.swift` (`StartActivitySheet`)
- Modify: `ios/Wythin/UI/Activities/ActivitiesView.swift` (`ActiveActivityBanner`, `beginActivity`)
- Test: `ios/WythinTests/ActivityTargetTests.swift` (create)

**Interfaces:**
- Consumes: `DurationPresetRow` (Task 4).
- Produces: `ActivityLog.targetMinutes: Int?`; `ActivityLogging.begin(type:subtype:customName:targetMinutes:context:) -> ActivityLog`; `StartActivitySheet.onStart: (ActivityType, String?, String?, Int?) -> Void` — the fourth parameter is the target.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ActivityTargetTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Wythin

final class ActivityTargetTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let schema = Schema([ActivityLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func testBeginStoresTarget() {
        let ctx = makeContext()
        let entry = ActivityLogging.begin(type: .meditation, subtype: "Vipassana",
                                          customName: nil, targetMinutes: 15, context: ctx)
        XCTAssertEqual(entry.targetMinutes, 15)
        XCTAssertTrue(entry.isActive)
    }

    func testBeginWithoutTargetLeavesItNil() {
        let ctx = makeContext()
        let entry = ActivityLogging.begin(type: .walk, subtype: nil,
                                          customName: nil, targetMinutes: nil, context: ctx)
        XCTAssertNil(entry.targetMinutes)
    }

    func testLogPastNeverSetsATarget() {
        // A retrospective entry has a real duration; a target is meaningless.
        let ctx = makeContext()
        let start = Date()
        ActivityLogging.logPast(type: .meal, subtype: "Lunch", customName: nil,
                                start: start, end: start.addingTimeInterval(1800),
                                context: ctx, client: NoopInsightClient())
        let all = try! ctx.fetch(FetchDescriptor<ActivityLog>())
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all[0].targetMinutes)
    }
}

/// Insight client that never returns — logPast fires generation in a detached
/// Task we don't await, so this just has to not make a network call.
/// InsightAPIClient (APIClient.swift:406) declares exactly these two methods.
private struct NoopInsightClient: InsightAPIClient {
    struct Stop: Error {}
    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse { throw Stop() }
    func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse { throw Stop() }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/ActivityTargetTests
```
Expected: compile failure — `extra argument 'targetMinutes' in call`.

- [ ] **Step 3: Add the model field**

In `ActivityLog.swift`, add next to `isManual`:

```swift
    /// Optional intended duration for a live activity, in minutes. Drives the
    /// banner's progress display only — nothing ever stops an activity on a
    /// timer. Always nil for retrospective entries.
    var targetMinutes: Int?
```

Add `targetMinutes: Int? = nil` to `init` and assign `self.targetMinutes = targetMinutes`.

- [ ] **Step 4: Thread it through `ActivityLogging.begin`**

```swift
    @discardableResult
    static func begin(type: ActivityType, subtype: String?, customName: String?,
                      targetMinutes: Int?, context: ModelContext) -> ActivityLog {
        let entry = ActivityLog(
            activityType:    type.rawValue,
            activitySubtype: subtype,
            customName:      customName,
            startedAt:       .now,
            isManual:        false,
            targetMinutes:   targetMinutes
        )
        context.insert(entry)
        try? context.save()
        return entry
    }
```

Leave `logPast` untouched — it must never set a target.

- [ ] **Step 5: Run test to verify it passes**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/ActivityTargetTests
```
Expected: PASS, 3 tests.

- [ ] **Step 6: Add the target picker to `StartActivitySheet`**

Change the callback type and add state:

```swift
    let onStart: (ActivityType, String?, String?, Int?) -> Void
    @State private var targetMinutes: Double? = nil
```

Insert between `ActivityPickerSection` and the CTA:

```swift
                    DurationPresetRow(minutes: $targetMinutes, title: "TARGET (OPTIONAL)")
                        .padding(.horizontal)
```

Replace the CTA with the fixed label — delete the `startLabel` computed property:

```swift
                    Button {
                        let name = selected == .custom && !customName.isEmpty ? customName : nil
                        onStart(selected, selectedSubtype, name, targetMinutes.map { Int($0) })
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("START ACTIVITY")
                        }
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.bg)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal)
                    .disabled(selected == .custom && customName.isEmpty)
```

Update the call site in `ActivitiesView.sheetContent`:

```swift
        case .start:
            StartActivitySheet(preselected: nil) { type, subtype, name, target in
                ActivityLogging.begin(type: type, subtype: subtype, customName: name,
                                      targetMinutes: target, context: ctx)
            }
```

and delete the now-unused `beginActivity` helper.

- [ ] **Step 7: Show progress in the banner**

In `ActiveActivityBanner`, add:

```swift
    private var targetSeconds: TimeInterval? {
        entry.targetMinutes.map { TimeInterval($0) * 60 }
    }
    private var progress: Double? {
        guard let t = targetSeconds, t > 0 else { return nil }
        return min(elapsed / t, 1.0)
    }
    private var reachedTarget: Bool {
        guard let t = targetSeconds else { return false }
        return elapsed >= t
    }
    private var timerColor: Color { reachedTarget ? Theme.accent : Theme.warn }

    private func mmss(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
```

Change `elapsedString` to `mmss(elapsed)`, apply `timerColor` to the elapsed `Text`, and render the target after it:

```swift
                Text(elapsedString)
                    .font(Theme.mono(18))
                    .foregroundStyle(timerColor)
                    .monospacedDigit()
                if let t = targetSeconds {
                    Text("/ " + mmss(t))
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .monospacedDigit()
                }
```

Directly under that `HStack`, add the progress capsule:

```swift
            if let p = progress {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surface)
                            Capsule().fill(timerColor)
                                .frame(width: geo.size.width * CGFloat(p))
                        }
                    }
                    .frame(height: 4)
                    if reachedTarget {
                        Text("TARGET REACHED")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
```

The existing `.onReceive(timer)` already updates `elapsed` every second, which drives all of the above. **Add no timer-driven call to `onStop` or `ActivityLogging.end`** — passing the target changes colour only.

- [ ] **Step 8: Build and run the target tests**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/ActivityTargetTests
```
Expected: PASS.

Then confirm nothing auto-stops:
```bash
grep -n "ActivityLogging.end\|onStop" ios/Wythin/UI/Activities/ActivitiesView.swift
```
Expected: `onStop` only in the STOP `Button(action:)` and its declaration; `ActivityLogging.end` only inside `endActivity`.

- [ ] **Step 9: Commit**

```bash
git add ios/Wythin/Models/ActivityLog.swift ios/Wythin/UI/Activities/ ios/WythinTests/ActivityTargetTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): optional target duration with live progress

Start Now gains an optional 5/10/15/20/30 target. The banner shows
elapsed/target and turns accent on reaching it, but never stops the
activity itself."
```

---

## Task 6: Custom subtypes remembered from history

**Files:**
- Modify: `ios/Wythin/UI/Activities/ActivityFormSheets.swift` (`SubtypePicker`)
- Test: `ios/WythinTests/SubtypeMemoryTests.swift` (create)

**Interfaces:**
- Consumes: `ActivityPickerSection` (Task 3).
- Produces: `SubtypeMemory.remembered(type:entries:limit:) -> [String]` — a pure static so the derivation is unit-testable without a SwiftData view host. `SubtypePicker` keeps its `(type:selected:)` signature.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/SubtypeMemoryTests.swift`:

```swift
import XCTest
@testable import Wythin

final class SubtypeMemoryTests: XCTestCase {

    /// Entries newest-first, matching the @Query sort the picker consumes.
    private func entries(_ pairs: [(ActivityType, String?)]) -> [ActivityLog] {
        pairs.map { ActivityLog(activityType: $0.0.rawValue, activitySubtype: $0.1) }
    }

    func testExcludesBuiltInSubtypes() {
        let e = entries([(.exercise, "Yoga"), (.exercise, "Kettlebells")])
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r, ["Kettlebells"])
    }

    func testExcludesOtherActivityTypes() {
        let e = entries([(.walk, "Beach Walk"), (.exercise, "Kettlebells")])
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r, ["Kettlebells"])
    }

    func testDedupesKeepingMostRecentFirst() {
        let e = entries([(.exercise, "Kettlebells"),
                         (.exercise, "Sandbag"),
                         (.exercise, "Kettlebells")])
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r, ["Kettlebells", "Sandbag"])
    }

    func testCapsAtLimit() {
        let e = entries((1...10).map { (.exercise, "Custom \($0)") })
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r.count, 6)
        XCTAssertEqual(r.first, "Custom 1")
    }

    func testIgnoresNilAndBlankSubtypes() {
        let e = entries([(.exercise, nil), (.exercise, "   "), (.exercise, "Sandbag")])
        let r = SubtypeMemory.remembered(type: .exercise, entries: e, limit: 6)
        XCTAssertEqual(r, ["Sandbag"])
    }

    func testEmptyWhenNoHistory() {
        XCTAssertTrue(SubtypeMemory.remembered(type: .coffee, entries: [], limit: 6).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/SubtypeMemoryTests
```
Expected: compile failure — `cannot find 'SubtypeMemory' in scope`.

- [ ] **Step 3: Implement the derivation**

Add to `ActivityFormSheets.swift`:

```swift
// MARK: - SubtypeMemory

/// Remembered custom subtypes, derived from logged history rather than stored
/// separately. Every ActivityLog already persists its subtype, so there is
/// nothing extra to write, migrate or clean up — deleting the last entry that
/// used a subtype stops it being offered.
enum SubtypeMemory {
    static func remembered(type: ActivityType, entries: [ActivityLog], limit: Int = 6) -> [String] {
        let builtIn = Set(type.subtypes)
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries where entry.activityType == type.rawValue {
            guard let raw = entry.activitySubtype else { continue }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !builtIn.contains(name), !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
            if out.count == limit { break }
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/SubtypeMemoryTests
```
Expected: PASS, 6 tests.

- [ ] **Step 5: Add the `+ Custom` chip to `SubtypePicker`**

Replace `SubtypePicker` with:

```swift
struct SubtypePicker: View {
    let type: ActivityType
    @Binding var selected: String?

    @Query(sort: \ActivityLog.startedAt, order: .reverse)
    private var allEntries: [ActivityLog]

    @State private var showCustomField = false
    @State private var customSubtype   = ""
    @FocusState private var fieldFocused: Bool

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var remembered: [String] {
        SubtypeMemory.remembered(type: type, entries: allEntries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SUBTYPE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                if selected != nil {
                    Button("clear") {
                        selected = nil
                        showCustomField = false
                        customSubtype = ""
                    }
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim.opacity(0.5))
                }
            }

            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(type.subtypes + remembered, id: \.self) { sub in
                    chip(sub, label: sub, isOn: selected == sub) {
                        selected = selected == sub ? nil : sub
                        showCustomField = false
                    }
                }
                chip("__custom__", label: "+ Custom", isOn: showCustomField) {
                    showCustomField.toggle()
                    if showCustomField {
                        customSubtype = ""
                        fieldFocused = true
                    }
                }
            }

            if showCustomField {
                TextField("e.g. Kettlebells", text: $customSubtype)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .padding(10)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.border, lineWidth: 0.5))
                    .onChange(of: customSubtype) { _, new in
                        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                        selected = trimmed.isEmpty ? nil : trimmed
                    }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func chip(_ id: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(isOn ? Theme.bg : type.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(isOn ? type.color : type.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn ? .clear : type.color.opacity(0.25), lineWidth: 0.5))
        }
    }
}
```

Add `import SwiftData` to `ActivityFormSheets.swift` if Task 3 didn't already.

- [ ] **Step 6: Build**

Run:
```bash
xcodebuild build -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add ios/Wythin/UI/Activities/ActivityFormSheets.swift ios/WythinTests/SubtypeMemoryTests.swift ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): + Custom subtype chip, remembered from history

No new storage: subtypes are already persisted on every ActivityLog, so
remembered chips are derived by query and self-clean on entry deletion."
```

---

## Task 7: Replace the impact score with a reconcilable delta

**Files:**
- Modify: `ios/Wythin/Metrics/ActivityImpact.swift`
- Modify: `ios/Wythin/Models/ActivityLog.swift`
- Modify: `ios/WythinTests/ActivityImpactTests.swift`
- Test: `ios/WythinTests/ImpactDeltaTests.swift` (create)

**Interfaces:**
- Consumes: `ActivityMetricDef.benefitDelta(current:base:)` (existing).
- Produces: `ActivityLog.impactDeltaPct: Double?`; `ActivityImpact.caption(for delta: Double) -> String`; `ActivityImpact.trendLine(_ moves: [MetricMovement]) -> String?`. Removed: `ActivityLog.impactScore`, `ActivityLog.displayImpactScore`, `ActivityImpact.score`, `ActivityImpact.breakdown`, `ActivityImpact.recommendations`, `ActivityRecommendation`.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ImpactDeltaTests.swift`:

```swift
import XCTest
@testable import Wythin

final class ImpactDeltaTests: XCTestCase {

    func testDeltaIsTheMeanOfPerMetricBenefitDeltas() {
        let e = ActivityLog(activityType: "Meditation")
        // RSA higher-is-better: 40 → 44 is +10%.
        e.beforeRSA = 40; e.duringRSA = 44
        // HR lower-is-better: 60 → 54 is a 10% benefit.
        e.beforeHR = 60;  e.duringHR = 54
        let d = e.impactDeltaPct
        XCTAssertNotNil(d)
        XCTAssertEqual(d!, 10, accuracy: 0.001)
    }

    func testFallingPulseIsAPositiveDelta() {
        let e = ActivityLog(activityType: "Meditation")
        e.beforeHR = 60; e.duringHR = 54
        XCTAssertEqual(e.impactDeltaPct!, 10, accuracy: 0.001)
    }

    func testRisingPulseIsANegativeDelta() {
        let e = ActivityLog(activityType: "Run")
        e.beforeHR = 60; e.duringHR = 90
        XCTAssertEqual(e.impactDeltaPct!, -50, accuracy: 0.001)
    }

    func testMetricsMissingEitherWindowAreIgnored() {
        let e = ActivityLog(activityType: "Walk")
        e.beforeRSA = 40; e.duringRSA = 44   // counted
        e.beforeHR  = 60                      // no during — ignored
        e.duringVTI = 3.5                     // no before — ignored
        XCTAssertEqual(e.impactDeltaPct!, 10, accuracy: 0.001)
    }

    func testNilWhenNoMetricHasBothWindows() {
        XCTAssertNil(ActivityLog(activityType: "Walk").impactDeltaPct)
    }

    // MARK: captions

    func testCaptionBoundaries() {
        XCTAssertEqual(ActivityImpact.caption(for: 12),  "deeply restorative")
        XCTAssertEqual(ActivityImpact.caption(for: 11.9), "restorative")
        XCTAssertEqual(ActivityImpact.caption(for: 6),   "restorative")
        XCTAssertEqual(ActivityImpact.caption(for: 5.9), "settling")
        XCTAssertEqual(ActivityImpact.caption(for: 2),   "settling")
        XCTAssertEqual(ActivityImpact.caption(for: 1.9), "steady")
        XCTAssertEqual(ActivityImpact.caption(for: -2),  "steady")
        XCTAssertEqual(ActivityImpact.caption(for: -2.1), "activating")
        XCTAssertEqual(ActivityImpact.caption(for: -10), "activating")
        XCTAssertEqual(ActivityImpact.caption(for: -10.1), "strongly activating")
    }

    func testHardEffortIsNotCalledALightSession() {
        // A run legitimately posts a large negative delta. It must read as
        // effort, not as a poor session.
        XCTAssertEqual(ActivityImpact.caption(for: -35), "strongly activating")
    }

    // MARK: trend line

    func testTrendLineCountsMetricsBeatingBaseline() {
        let moves = [
            MetricMovement(name: "RSA", uplift: 12, vs2mo: 5),
            MetricMovement(name: "HRV", uplift: 15, vs2mo: 6),
            MetricMovement(name: "VTI", uplift: 1,  vs2mo: -1),
            MetricMovement(name: "HR",  uplift: 3,  vs2mo: nil),
        ]
        XCTAssertEqual(ActivityImpact.trendLine(moves),
                       "You beat your 2-month average on 2 of 3 metrics.")
    }

    func testTrendLineNilWithoutBaseline() {
        let moves = [MetricMovement(name: "RSA", uplift: 12, vs2mo: nil)]
        XCTAssertNil(ActivityImpact.trendLine(moves))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/ImpactDeltaTests
```
Expected: compile failure — `value of type 'ActivityLog' has no member 'impactDeltaPct'`.

- [ ] **Step 3: Rewrite `ActivityImpact.swift`**

Replace the file's contents with:

```swift
import Foundation

/// Overall practice impact and the one factual trend line the LLM can't
/// produce. Everything here is derived from each metric's benefit-signed
/// change (during vs before). Pure and unit-tested; views consume it.
enum ActivityImpact {

    /// Short caption for a session's mean benefit-signed delta.
    ///
    /// Describes DIRECTION, not quality. A hard run posts a large negative
    /// delta by design — heart rate up, variability down — and must read as
    /// effort rather than as a poor session.
    static func caption(for delta: Double) -> String {
        switch delta {
        case 12...:        return "deeply restorative"
        case 6..<12:       return "restorative"
        case 2..<6:        return "settling"
        case -2...2:       return "steady"
        case -10 ..< -2:   return "activating"
        default:           return "strongly activating"
        }
    }

    /// How many metrics beat the 2-month baseline. Kept as a deterministic
    /// line because the insight model is never sent that comparison.
    /// Nil when no metric has a baseline to compare against.
    static func trendLine(_ moves: [MetricMovement]) -> String? {
        let compared = moves.filter { $0.vs2mo != nil }.count
        guard compared > 0 else { return nil }
        let beat = moves.filter { ($0.vs2mo ?? 0) > 0 }.count
        return "You beat your 2-month average on \(beat) of \(compared) metrics."
    }
}

/// One metric's session movement.
struct MetricMovement {
    let name:   String   // consumer label, e.g. "Conscious Breathing"
    let uplift: Double?  // benefit-signed % during vs before
    let vs2mo:  Double?  // benefit-signed % during vs 2-month baseline
}
```

Note `case -2...2` precedes `case -10 ..< -2`, so exactly −2 lands in "steady" as the test asserts.

- [ ] **Step 4: Swap the model's score for the delta**

In `ActivityLog.swift`, delete `var impactScore: Int?` and the whole `displayImpactScore` property, and add:

```swift
    /// Mean benefit-signed change from the before-window to the during-window
    /// across the nine metrics — literally the average of the per-metric
    /// numbers shown on the rows below the meter, so the two cannot disagree.
    /// Computed, never cached: the stored window averages and the detail
    /// view's ActivityMetricStats both derive from the same quality-filtered
    /// samples, so there is nothing to keep in sync.
    var impactDeltaPct: Double? {
        let deltas = activityMetricDefs.compactMap { def in
            def.benefitDelta(current: self[keyPath: def.duringKey].map(Double.init),
                             base:    self[keyPath: def.beforeKey].map(Double.init))
        }
        guard !deltas.isEmpty else { return nil }
        return deltas.reduce(0, +) / Double(deltas.count)
    }
```

In `computeHRVWindows`, delete the trailing impact block — the comment, the `let points = …`, `let uplifts = …` and `impactScore = …` lines. In `backfillMissingWindows`, change the guard to:

```swift
            return entry.duringStress == nil
```

- [ ] **Step 5: Prune the old tests**

In `ActivityImpactTests.swift`, delete the `// MARK: score`, `// MARK: breakdown` and `// MARK: recommendations` sections in full — every test in the file. The replacements live in `ImpactDeltaTests`. Delete the now-empty file rather than leaving an empty class:

```bash
git rm ios/WythinTests/ActivityImpactTests.swift
```
and remove its entry from the `WythinTests` target in `project.pbxproj`.

- [ ] **Step 6: Fix the remaining call sites**

`ActivitiesView.swift` and `ActivityDetailView.swift` still reference `displayImpactScore`, `ActivityImpact.caption(for: score)` and `ActivityImpact.recommendations`. Task 8 rewrites those views. For now, make them compile by switching to the delta:

In `ActivityLogRow`, replace the badge block:
```swift
                if let delta = entry.impactDeltaPct {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "%+.0f%%", delta))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(deltaColor(delta))
                        Text(ActivityImpact.caption(for: delta))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
```
and replace the `impactColor(_ score: Int)` helper with:
```swift
    private func deltaColor(_ delta: Double) -> Color {
        if delta > 2  { return Theme.accent }
        if delta < -2 { return Theme.warn }
        return Theme.dim
    }
```

In `ActivityDetailView`, change `impactCaption` to take a `Double`, change the gauge guard to `if let delta = entry.impactDeltaPct`, pass `score: Int(delta.rounded())` to the existing gauge for now (Task 8 replaces the gauge), and replace the `recs` block with `ActivityImpact.trendLine(...)` rendering a single `Text` (Task 8 rewrites this card).

- [ ] **Step 7: Run the full suite**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`, all tests pass including the 9 new `ImpactDeltaTests`.

- [ ] **Step 8: Commit**

```bash
git add ios/Wythin ios/WythinTests ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): impact is now the before→during delta, not a 0-100 score

The cached score could never reconcile with the per-metric percentages
below it. impactDeltaPct is their mean, computed rather than cached.
Captions describe direction, so a hard run reads as activating rather
than as a light session."
```

---

## Task 8: Benefit-signed cells and the diverging meter

**Files:**
- Modify: `ios/Wythin/UI/Activities/ActivitiesView.swift` (`LogMetricCell`)
- Rename: `ios/Wythin/UI/Activities/PracticeImpactGauge.swift` → `PracticeImpactMeter.swift`
- Modify: `ios/Wythin/UI/Activities/ActivityDetailView.swift`
- Test: `ios/WythinTests/ImpactDeltaTests.swift` (extend)

**Interfaces:**
- Consumes: `ActivityLog.impactDeltaPct`, `ActivityImpact.caption(for:)` (Task 7).
- Produces: `PracticeImpactMeter(delta: Double, caption: String)`; `PracticeImpactMeter.fillFraction(_ delta: Double) -> Double` (0…1, 0.5 = zero) and `PracticeImpactMeter.isClamped(_ delta: Double) -> Bool`, both static for testing.

- [ ] **Step 1: Write the failing test**

Append to `ios/WythinTests/ImpactDeltaTests.swift`:

```swift
extension ImpactDeltaTests {

    func testMeterCentresOnZero() {
        XCTAssertEqual(PracticeImpactMeter.fillFraction(0), 0.5, accuracy: 0.0001)
    }

    func testMeterEndsAtTheDomainBounds() {
        XCTAssertEqual(PracticeImpactMeter.fillFraction(20), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PracticeImpactMeter.fillFraction(-20), 0.0, accuracy: 0.0001)
    }

    func testMeterIsLinearInBetween() {
        XCTAssertEqual(PracticeImpactMeter.fillFraction(10), 0.75, accuracy: 0.0001)
        XCTAssertEqual(PracticeImpactMeter.fillFraction(-10), 0.25, accuracy: 0.0001)
    }

    func testMeterClampsBeyondTheDomain() {
        XCTAssertEqual(PracticeImpactMeter.fillFraction(85), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PracticeImpactMeter.fillFraction(-85), 0.0, accuracy: 0.0001)
        XCTAssertTrue(PracticeImpactMeter.isClamped(85))
        XCTAssertTrue(PracticeImpactMeter.isClamped(-21))
        XCTAssertFalse(PracticeImpactMeter.isClamped(19))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/ImpactDeltaTests
```
Expected: compile failure — `cannot find 'PracticeImpactMeter' in scope`.

- [ ] **Step 3: Replace the gauge with the meter**

```bash
git mv ios/Wythin/UI/Activities/PracticeImpactGauge.swift ios/Wythin/UI/Activities/PracticeImpactMeter.swift
```
Update the file reference name and path in `project.pbxproj`, then replace the file's contents:

```swift
import SwiftUI

/// The overall practice impact meter: the session's mean benefit-signed change
/// from before to during, on a diverging −20…+20 % scale centred on zero.
///
/// This replaced a 0–100 arc gauge. The arc encoded "progress toward 100",
/// which no longer describes the value — a negative delta is a real, valid
/// reading (a hard workout), not a low score.
struct PracticeImpactMeter: View {
    let delta:   Double     // benefit-signed percent
    let caption: String

    private static let domain: Double = 20

    /// Position on the track, 0…1, with 0.5 as zero change.
    static func fillFraction(_ delta: Double) -> Double {
        let clamped = min(max(delta, -domain), domain)
        return (clamped + domain) / (2 * domain)
    }

    /// True when the value ran past the domain and the bar is pinned.
    static func isClamped(_ delta: Double) -> Bool { abs(delta) > domain }

    private var frac:      Double { Self.fillFraction(delta) }
    private var isPositive: Bool  { delta >= 0 }
    private var barColor:  Color  { isPositive ? Theme.accent : Theme.warn }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(String(format: "%+.0f%%", delta))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(barColor)
                    .monospacedDigit()
                Text(caption)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Text("avg change, before → during")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim.opacity(0.6))
            }

            GeometryReader { geo in
                let w = geo.size.width
                let mid = w / 2
                let x = CGFloat(frac) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                        .frame(height: 8)

                    // Fill grows from the centre toward the value.
                    Rectangle().fill(barColor)
                        .frame(width: abs(x - mid), height: 8)
                        .offset(x: min(x, mid))
                        // A pinned bar gets a square outer end so it can't be
                        // read as an exact value at the domain edge.
                        .clipShape(RoundedRectangle(cornerRadius: Self.isClamped(delta) ? 0 : 4))

                    // Zero tick.
                    Rectangle().fill(Theme.dim)
                        .frame(width: 1.5, height: 14)
                        .offset(x: mid - 0.75)
                }
                .frame(height: 14)
            }
            .frame(height: 14)

            HStack {
                Text("−20%").font(Theme.monoLabel).foregroundStyle(Theme.dim.opacity(0.6))
                Spacer()
                Text("0").font(Theme.monoLabel).foregroundStyle(Theme.dim.opacity(0.6))
                Spacer()
                Text("+20%").font(Theme.monoLabel).foregroundStyle(Theme.dim.opacity(0.6))
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/ImpactDeltaTests
```
Expected: PASS, 13 tests.

- [ ] **Step 5: Use the meter in the detail view**

In `ActivityDetailView.swift`, replace the impact card:

```swift
                        if let delta = entry.impactDeltaPct {
                            VStack(spacing: 14) {
                                Text("OVERALL PRACTICE IMPACT")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                PracticeImpactMeter(delta: delta,
                                                    caption: ActivityImpact.caption(for: delta))
                            }
                            .cardStyle()
                        }
```

Delete the `impactCaption` helper — `ActivityImpact.caption` is called directly.

- [ ] **Step 6: Make the list cells benefit-signed**

In `LogMetricCell`, replace `pctChange` and `deltaColor`:

```swift
    /// Benefit-signed change from the before-average to the during-average, so
    /// this cell's number is directly comparable to the row badge above it —
    /// the badge is the mean of these. A falling pulse reads +9%, which is why
    /// the absolute during-value stays printed underneath.
    private var pctChange: Double? {
        def.benefitDelta(current: during, base: before)
    }

    private var deltaColor: Color {
        guard let p = pctChange else { return Theme.dim.opacity(0.4) }
        if abs(p) < 0.05 { return Theme.dim }
        return p > 0 ? Theme.accent : Theme.warn
    }
```

`deltaText` is unchanged — it already renders the sign from `pctChange`.

- [ ] **Step 7: Verify the badge reconciles**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`, all pass.

Then confirm the old gauge is gone:
```bash
grep -rn "PracticeImpactGauge\|displayImpactScore\|impactScore" ios/Wythin/UI ios/Wythin/Metrics
```
Expected: **no output**. (`ActivityUploader.swift` still references `impactScore` — Task 9 handles it. If it appears here, that's expected only from `ios/Wythin/Sync/`.)

- [ ] **Step 8: Commit**

```bash
git add ios/Wythin ios/WythinTests ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): diverging impact meter, benefit-signed list cells

The row badge is now exactly the mean of the metric cells beneath it, so
the headline number reconciles with the detail."
```

---

## Task 9: Sync the delta to the server

**Files:**
- Modify: `ios/Wythin/Sync/ActivityUploader.swift:18,41,65`
- Modify: `server/db.py:85`
- Modify: `server/models.py:46`
- Modify: `server/routers/activities.py:38,44`
- Test: `server/tests/test_activities.py`

**Interfaces:**
- Consumes: `ActivityLog.impactDeltaPct` (Task 7).
- Produces: wire field `impact_delta_pct` (nullable float) on `POST /activities`.

- [ ] **Step 1: Write the failing test**

In `server/tests/test_activities.py`, add `"impact_delta_pct": 8.4,` to `_PAYLOAD` (alongside `"impact_score": 72,`) and append:

```python
@pytest.mark.asyncio
async def test_impact_delta_pct_round_trips():
    async with _client() as client:
        payload = dict(_PAYLOAD)
        payload["id"] = "00000000-0000-0000-0000-0000000000c4"
        payload["impact_delta_pct"] = -12.5
        up = await client.post("/activities", json=payload,
                               headers={"X-User-ID": "test-activity-user"})
        assert up.status_code == 200

        acts = await _user_activities(client, "test-activity-user")
        mine = next(a for a in acts if a["client_activity_id"] == payload["id"])
        assert mine["impact_delta_pct"] == -12.5


@pytest.mark.asyncio
async def test_impact_delta_pct_is_optional():
    # Builds shipped before this field must keep uploading successfully.
    async with _client() as client:
        payload = dict(_PAYLOAD)
        payload["id"] = "00000000-0000-0000-0000-0000000000c5"
        payload.pop("impact_delta_pct", None)
        up = await client.post("/activities", json=payload,
                               headers={"X-User-ID": "test-activity-user"})
        assert up.status_code == 200
```

Note the shape this file already uses, which differs from most of the suite: `POST /activities` takes a **single object, not a list**; auth is the `X-User-ID` header; and reads go through the `_user_activities(client, device_id)` helper against `/admin`, not a `GET /activities`.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_activities.py -v
```
Expected: FAIL — the response has no `impact_delta_pct` key.

- [ ] **Step 3: Add the column**

In `server/db.py`, add below `impact_score       INT,` inside the `activities` table body:

```sql
    impact_delta_pct   REAL,
```

**That alone is not enough.** `create_schema()` executes `SCHEMA_SQL`, which is entirely `CREATE TABLE IF NOT EXISTS` — on the deployed database the `activities` table already exists, so a new column inside the `CREATE TABLE` body is silently ignored. Fresh test databases would pass while production quietly dropped the field.

There is no migration mechanism in this file yet, so add one. Append to the very end of `SCHEMA_SQL`:

```sql
-- Additive migrations. SCHEMA_SQL runs on every boot, and each statement here
-- is idempotent, so this block is safe to re-run and safe to grow. Columns
-- added to a CREATE TABLE body above only reach a database that does not yet
-- exist; existing deployments need them stated here as well.
ALTER TABLE activities ADD COLUMN IF NOT EXISTS impact_delta_pct REAL;
```

Keep the column in both places: the `CREATE TABLE` body documents the intended schema, and the `ALTER` is what actually reaches a live database.

- [ ] **Step 4: Add the model field and the insert column**

`server/models.py`, next to `impact_score`:
```python
    impact_delta_pct: Optional[float] = None
```

`server/routers/activities.py`, add `"impact_delta_pct"` to the column-name list and `activity.impact_delta_pct` to the values tuple, keeping both in the same position relative to `impact_score`.

- [ ] **Step 5: Run test to verify it passes**

Run:
```bash
DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_activities.py -v
```
Expected: PASS.

- [ ] **Step 6: Send it from the app**

In `ActivityUploader.swift`: rename the property `impactScore: Int?` → `impactDeltaPct: Float?`, its coding key `case impactScore = "impact_score"` → `case impactDeltaPct = "impact_delta_pct"`, and its assignment → `impactDeltaPct = e.impactDeltaPct.map(Float.init)`.

`impact_score` stays in the database schema holding historical values; the app simply stops writing it. Do not backfill.

- [ ] **Step 7: Build and run both suites**

Run:
```bash
xcodebuild build -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_activities.py server/tests/test_admin.py -v
```
Expected: `BUILD SUCCEEDED`; all server tests pass (`test_admin.py`'s existing `impact_score` assertions still hold — the column is untouched).

- [ ] **Step 8: Commit**

```bash
git add ios/Wythin/Sync/ActivityUploader.swift server/
git commit -m "feat(sync): upload impact_delta_pct alongside the legacy impact_score column

Writing a signed delta into the 0-100 impact_score column would mix two
scales in one place, so the delta gets its own nullable column and old
rows keep their historical score."
```

---

## Task 10: Structured, metric-keyed insights on the server

**Files:**
- Modify: `server/models.py:158-206`
- Modify: `server/routers/insights.py`
- Test: `server/tests/test_insights.py`

**Interfaces:**
- Consumes: nothing from earlier tasks (server-side only).
- Produces: request field `activity_metrics: dict[str, ActivityMetricWindow]`; response fields `headline: Optional[str]`, `bullets: list[InsightBullet]`, `next_step: Optional[str]`, `metric_notes: dict[str, str]`. `InsightBullet` has `dimension: str` and `text: str`. `text` remains required and non-empty in every mode.

- [ ] **Step 1: Write the failing test**

Add to `server/tests/test_insights.py`, reusing the file's existing `_Fake*` classes and `dependency_overrides` pattern:

```python
import json

_STRUCTURED = json.dumps({
    "headline": "Deep, settled session",
    "bullets": [
        {"dimension": "breathing", "text": "Breathing lengthened from minute 4."},
        {"dimension": "energy",    "text": "Pulse fell 9% and stayed down."},
        {"dimension": "calm",      "text": "Stress balance eased throughout."},
    ],
    "next_step": "Lengthen the exhale next time.",
    "metric_notes": {
        "RSA": "Climbed steadily once the pacer started.",
        "HR":  "Dropped early, then held flat.",
    },
})

_ACTIVITY_METRICS = {
    "RSA": {"label": "Conscious Breathing", "unit": "ms", "direction": "higher",
            "before": 38.0, "during": 52.0, "after": 44.0,
            "during_buckets": [40.0, 46.0, 51.0, 55.0, 54.0]},
    "HR": {"label": "Pulse", "unit": "bpm", "direction": "lower",
           "before": 64.0, "during": 58.0, "after": 60.0,
           "during_buckets": [63.0, 60.0, 58.0, 56.0, 56.0]},
}


@pytest.mark.asyncio
async def test_activity_mode_returns_structured_fields():
    app.dependency_overrides[get_openai_client] = lambda: _FakeClient(_STRUCTURED)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as ac:
            r = await ac.post("/insights", json={
                "mode": "activity",
                "activity_type": "Meditation",
                "activity_subtype": "Vipassana",
                "duration_min": 20,
                "activity_metrics": _ACTIVITY_METRICS,
            })
        assert r.status_code == 200
        body = r.json()
        assert body["headline"] == "Deep, settled session"
        assert len(body["bullets"]) == 3
        assert body["bullets"][0]["dimension"] == "breathing"
        assert body["metric_notes"]["RSA"].startswith("Climbed")
        # text is assembled from the structured fields, not generated twice.
        assert "Deep, settled session" in body["text"]
        assert "Lengthen the exhale" in body["text"]
    finally:
        app.dependency_overrides.clear()


@pytest.mark.asyncio
async def test_activity_metrics_reach_the_prompt():
    fake = _FakeClient(_STRUCTURED)
    app.dependency_overrides[get_openai_client] = lambda: fake
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as ac:
            await ac.post("/insights", json={
                "mode": "activity",
                "activity_type": "Meditation",
                "activity_metrics": _ACTIVITY_METRICS,
            })
        user_msg = fake.last_messages[-1]["content"]
        # Every metric is named by its techLabel key, with direction and shape.
        assert "RSA" in user_msg and "HR" in user_msg
        assert "Conscious Breathing" in user_msg
        assert "higher is better" in user_msg
        assert "lower is better" in user_msg
        assert "40" in user_msg   # a bucket value
    finally:
        app.dependency_overrides.clear()


@pytest.mark.asyncio
async def test_flat_fields_still_work_for_older_clients():
    app.dependency_overrides[get_openai_client] = lambda: _FakeClient(_STRUCTURED)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as ac:
            r = await ac.post("/insights", json={
                "mode": "activity",
                "activity_type": "Walk",
                "before_hr": 70.0, "during_hr": 88.0, "after_hr": 72.0,
            })
        assert r.status_code == 200
        assert r.json()["text"]
    finally:
        app.dependency_overrides.clear()


@pytest.mark.asyncio
async def test_malformed_json_retries_once_then_502():
    fake = _FakeClient("not json at all")
    app.dependency_overrides[get_openai_client] = lambda: fake
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as ac:
            r = await ac.post("/insights", json={
                "mode": "activity",
                "activity_type": "Walk",
                "activity_metrics": _ACTIVITY_METRICS,
            })
        assert r.status_code == 502
        assert fake.call_count == 2   # one retry, then give up
    finally:
        app.dependency_overrides.clear()


@pytest.mark.asyncio
async def test_other_modes_are_unaffected():
    app.dependency_overrides[get_openai_client] = lambda: _FakeClient(
        "engaged_performing | Locked In\n• a\n• b\n• c\n→ go"
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as ac:
            r = await ac.post("/insights", json={
                "mode": "live_state",
                "window_minutes": 10,
                "metrics": {"HR": {"now": 62.0}},
            })
        assert r.status_code == 200
        assert r.json()["bullets"] == []
        assert r.json()["metric_notes"] == {}
    finally:
        app.dependency_overrides.clear()
```

The existing `_FakeChatCompletions` needs to record calls for two of these. Extend it to keep `self.call_count` and `self.last_messages`, and expose them on the fake client — follow the shape already in the file.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_insights.py -v
```
Expected: FAIL — `KeyError: 'headline'`.

- [ ] **Step 3: Add the models**

In `server/models.py`, above `InsightRequest`:

```python
class ActivityMetricWindow(BaseModel):
    """One metric's before/during/after averages plus the shape of its during
    window. Keyed in the request by the app's techLabel ("RSA", "DC", "DFA α1"),
    which is also the key metric_notes comes back under."""
    label:     str
    unit:      str = ""
    direction: str = "higher"        # "higher" | "lower" | "target"
    before:    Optional[float] = None
    during:    Optional[float] = None
    after:     Optional[float] = None
    during_buckets: Optional[list[Optional[float]]] = None   # 5, oldest first


class InsightBullet(BaseModel):
    dimension: str                   # breathing|focus|energy|calm|recovery|effort
    text:      str
```

Add to `InsightRequest`, under the activity-mode fields:
```python
    activity_metrics: Optional[dict[str, ActivityMetricWindow]] = None
```

Replace `InsightResponse`:
```python
class InsightResponse(BaseModel):
    text: str                                     # flat form; every mode sets it
    headline:     Optional[str] = None
    bullets:      list[InsightBullet] = []
    next_step:    Optional[str] = None
    metric_notes: dict[str, str] = {}
```

- [ ] **Step 4: Format the metric-keyed payload**

In `server/routers/insights.py`, extend `_format_metrics` to prefer the new field:

```python
_DIRECTION_WORDS = {
    "higher": "higher is better",
    "lower":  "lower is better",
    "target": "closer to the target is better",
}


def _format_activity_metrics(req: InsightRequest) -> str:
    lines = [f"Activity: {req.activity_type}"]
    if req.activity_subtype:
        lines.append(f"Subtype: {req.activity_subtype}")
    if req.duration_min is not None:
        lines.append(f"Duration: {req.duration_min} min")
    lines.append("")
    lines.append("Metrics (key = the identifier to use in metric_notes):")

    for key, m in (req.activity_metrics or {}).items():
        direction = _DIRECTION_WORDS.get(m.direction, m.direction)
        parts = [
            f"{key} — {m.label} ({direction})",
            f"before={m.before}{m.unit}",
            f"during={m.during}{m.unit}",
            f"after={m.after}{m.unit}",
        ]
        if m.during_buckets:
            shape = ", ".join("?" if v is None else f"{v:.4g}" for v in m.during_buckets)
            parts.append(f"during in 5 equal slices (oldest first): [{shape}]")
        else:
            parts.append("no time detail available — describe magnitude only, "
                         "make no claims about when anything happened")
        lines.append("  " + " | ".join(parts))

    return "\n".join(lines)
```

In the handler's `else` branch:

```python
    else:
        if not req.activity_type:
            raise HTTPException(status_code=422, detail="activity_type is required for activity mode")
        if req.activity_metrics:
            system_prompt = _ACTIVITY_STRUCTURED_PROMPT
            user_content = _format_activity_metrics(req)
            max_tokens = 700          # nine notes plus the summary
            structured = True
        else:
            # Builds shipped before the metric-keyed payload.
            system_prompt = _SYSTEM_PROMPT
            user_content = _format_metrics(req)
            max_tokens = 150
            structured = False
```

Set `structured = False` in the other two mode branches.

- [ ] **Step 5: Add the structured prompt**

```python
_ACTIVITY_STRUCTURED_PROMPT = (
    "You are a sports coach and physiologist reviewing ONE logged session of a "
    "specific activity. You are given the activity type and subtype, and a set "
    "of heart-rate/HRV metrics with their before, during and after averages, "
    "each labeled with which direction is better, and most with the during "
    "window split into five equal time slices (oldest first) so you can see "
    "when things moved.\n"
    "\n"
    "The activity type is CENTRAL. A good session looks different per type:\n"
    "— Calming practices (meditation, breathwork, yoga, nap): heart rate down, "
    "RSA/HRV/vagal tone up, stress balance falling.\n"
    "— Hard effort (run, exercise, cold exposure): a strong sympathetic push "
    "DURING is the point — heart rate up and variability down is success, not "
    "failure — and what matters is how cleanly the AFTER window recovers.\n"
    "— Intake and load (meal, coffee, alcohol, work): read the size and "
    "duration of the disturbance and how fast it settles.\n"
    "Never call a hard session bad for showing effort.\n"
    "\n"
    "Reply with a single JSON object and nothing else:\n"
    "{\n"
    '  "headline": "<3-6 words: how this session went>",\n'
    '  "bullets": [ {"dimension": "<key>", "text": "<one sentence>"}, ... ],\n'
    '  "next_step": "<one specific, calibrated recommendation for the next '
    'similar session>",\n'
    '  "metric_notes": { "<metric key>": "<1-2 sentences>", ... }\n'
    "}\n"
    "\n"
    "BULLETS — EXACTLY 3. Each is one plain-language sentence connecting what "
    "the numbers did to what it MEANS for the person. Each must use a DIFFERENT "
    "'dimension', chosen from EXACTLY these keys: breathing, focus, energy, "
    "calm, recovery, effort. Use no other value — the app maps the key to an "
    "icon and an unknown key renders as a blank.\n"
    "\n"
    "METRIC_NOTES — one entry for EVERY metric key you were given, using that "
    "key verbatim (keys may contain spaces and non-ASCII, e.g. 'DFA α1'). Each "
    "note is 1-2 sentences saying WHAT MOVED, WHEN in the window it moved, and "
    "whether that fits this activity. Use the five slices for timing; if a "
    "metric has no slices, describe magnitude only. Do NOT restate what the "
    "metric means — the app already prints a definition underneath.\n"
    "\n"
    "Never use markdown. Never compare to an average, a norm, a 'usual' value "
    "or a previous session — you have not been given one and a separate part of "
    "the app owns that comparison. Speak directly to the person as their coach "
    "('you'). Base everything only on the numbers provided."
)
```

- [ ] **Step 6: Parse, retry once, assemble `text`**

Replace the handler's completion block:

```python
    async def _complete(force_json: bool) -> str:
        kwargs = {
            "model": "gpt-4o-mini",
            "max_tokens": max_tokens,
            "temperature": 0.6,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
        }
        if force_json:
            kwargs["response_format"] = {"type": "json_object"}
        response = await client.chat.completions.create(**kwargs)
        return (response.choices[0].message.content or "").strip()

    try:
        raw = await _complete(structured)
    except OpenAIError as e:
        raise HTTPException(status_code=502, detail=str(e))

    if not raw:
        raise HTTPException(status_code=502, detail="Empty response from OpenAI")

    if not structured:
        return InsightResponse(text=raw)

    parsed = _parse_structured(raw)
    if parsed is None:
        # One retry — JSON mode occasionally still returns prose.
        try:
            raw = await _complete(True)
        except OpenAIError as e:
            raise HTTPException(status_code=502, detail=str(e))
        parsed = _parse_structured(raw)
    if parsed is None:
        raise HTTPException(status_code=502, detail="Malformed JSON from OpenAI")

    return parsed
```

And the parser, near `_format_activity_metrics`:

```python
def _parse_structured(raw: str) -> Optional[InsightResponse]:
    """Decode the model's JSON into an InsightResponse, assembling the flat
    `text` form from the same fields so there is exactly one generation.
    Returns None when the payload isn't usable, which triggers one retry."""
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(data, dict):
        return None

    headline = (data.get("headline") or "").strip()
    next_step = (data.get("next_step") or "").strip()

    bullets: list[InsightBullet] = []
    for b in data.get("bullets") or []:
        if not isinstance(b, dict):
            continue
        text = (b.get("text") or "").strip()
        if text:
            bullets.append(InsightBullet(dimension=(b.get("dimension") or "").strip(), text=text))

    notes = {
        str(k): str(v).strip()
        for k, v in (data.get("metric_notes") or {}).items()
        if isinstance(v, str) and v.strip()
    }

    flat_parts = [headline] + [b.text for b in bullets]
    if next_step:
        flat_parts.append(f"Next session: {next_step}")
    text = "\n".join(p for p in flat_parts if p)
    if not text:
        return None

    return InsightResponse(text=text, headline=headline or None, bullets=bullets,
                           next_step=next_step or None, metric_notes=notes)
```

Add `import json` and `from typing import Optional` at the top of the module if not present, and import `InsightBullet` / `ActivityMetricWindow` from `..models`.

- [ ] **Step 7: Run test to verify it passes**

Run:
```bash
DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_insights.py -v
```
Expected: PASS, including the pre-existing tests for the other two modes.

- [ ] **Step 8: Commit**

```bash
git add server/
git commit -m "feat(insights): metric-keyed activity payload and structured response

The old payload carried four metrics, two of which the app doesn't even
display, and no timing — so per-chart notes were impossible. Activity
mode is now keyed by techLabel with during-window buckets, and returns
bullets plus a note per metric via JSON mode. Flat fields still work for
older clients; the other two modes are untouched."
```

---

## Task 11: Build and store the structured insight on iOS

**Files:**
- Modify: `ios/Wythin/Sync/APIClient.swift:42-60,135-137`
- Create: `ios/Wythin/Sync/ActivityInsightPayloadBuilder.swift`
- Create: `ios/Wythin/Models/SessionInsight.swift`
- Modify: `ios/Wythin/Models/ActivityLog.swift`
- Modify: `ios/Wythin/Sync/InsightGenerator.swift`
- Modify: `ios/WythinTests/InsightGeneratorTests.swift`
- Test: `ios/WythinTests/ActivityInsightPayloadTests.swift` (create)

**Interfaces:**
- Consumes: the server contract from Task 10.
- Produces: `ActivityLog.insightJSON: String?` and `ActivityLog.sessionInsight: SessionInsight?`; `SessionInsight` with `headline: String?`, `bullets: [SessionInsightBullet]`, `nextStep: String?`, `metricNotes: [String: String]`; `SessionInsightBullet.dimension: String`, `.text: String`, `.symbol: String`, `.color: Color`; `ActivityInsightPayloadBuilder.buckets(values:startedAt:endedAt:count:) -> [Double?]`.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/ActivityInsightPayloadTests.swift`:

```swift
import XCTest
@testable import Wythin

final class ActivityInsightPayloadTests: XCTestCase {

    private func timed(_ start: Date, _ offsets: [(Double, Double)]) -> [(date: Date, value: Double)] {
        offsets.map { (start.addingTimeInterval($0.0), $0.1) }
    }

    func testBucketsAveragePerSlice() {
        let start = Date(timeIntervalSince1970: 0)
        let end   = start.addingTimeInterval(500)   // 5 slices of 100s
        let values = timed(start, [(10, 1), (50, 3),      // slice 0 → 2
                                   (150, 10),             // slice 1 → 10
                                   (250, 20),             // slice 2 → 20
                                   (350, 30),             // slice 3 → 30
                                   (450, 40)])            // slice 4 → 40
        let b = ActivityInsightPayloadBuilder.buckets(values: values, startedAt: start, endedAt: end, count: 5)
        XCTAssertEqual(b.count, 5)
        XCTAssertEqual(b[0]!, 2,  accuracy: 0.0001)
        XCTAssertEqual(b[1]!, 10, accuracy: 0.0001)
        XCTAssertEqual(b[4]!, 40, accuracy: 0.0001)
    }

    func testEmptySlicesAreNil() {
        let start = Date(timeIntervalSince1970: 0)
        let end   = start.addingTimeInterval(500)
        let b = ActivityInsightPayloadBuilder.buckets(values: timed(start, [(10, 5)]),
                                                      startedAt: start, endedAt: end, count: 5)
        XCTAssertEqual(b[0]!, 5, accuracy: 0.0001)
        XCTAssertNil(b[1]); XCTAssertNil(b[4])
    }

    func testValuesOutsideTheDuringWindowAreExcluded() {
        let start = Date(timeIntervalSince1970: 1000)
        let end   = start.addingTimeInterval(500)
        let values: [(date: Date, value: Double)] = [
            (start.addingTimeInterval(-60), 999),   // before
            (start.addingTimeInterval(50),   7),
            (end.addingTimeInterval(60),    888),   // after
        ]
        let b = ActivityInsightPayloadBuilder.buckets(values: values, startedAt: start, endedAt: end, count: 5)
        XCTAssertEqual(b[0]!, 7, accuracy: 0.0001)
        XCTAssertNil(b[1])
    }

    func testAllNilWhenThereAreNoValues() {
        let start = Date(timeIntervalSince1970: 0)
        let b = ActivityInsightPayloadBuilder.buckets(values: [], startedAt: start,
                                                      endedAt: start.addingTimeInterval(300), count: 5)
        XCTAssertEqual(b.count, 5)
        XCTAssertTrue(b.allSatisfy { $0 == nil })
    }

    func testZeroLengthWindowYieldsAllNil() {
        let start = Date(timeIntervalSince1970: 0)
        let b = ActivityInsightPayloadBuilder.buckets(values: [(start, 5)], startedAt: start,
                                                      endedAt: start, count: 5)
        XCTAssertTrue(b.allSatisfy { $0 == nil })
    }

    // MARK: SessionInsight decoding

    func testDecodesStructuredResponse() throws {
        let json = """
        {"text":"x","headline":"Deep, settled session",
         "bullets":[{"dimension":"breathing","text":"Breathing lengthened."}],
         "next_step":"Lengthen the exhale.",
         "metric_notes":{"RSA":"Climbed steadily.","DFA α1":"Held near 1.0."}}
        """
        let insight = try XCTUnwrap(SessionInsight(json: json))
        XCTAssertEqual(insight.headline, "Deep, settled session")
        XCTAssertEqual(insight.bullets.count, 1)
        XCTAssertEqual(insight.bullets[0].dimension, "breathing")
        XCTAssertEqual(insight.nextStep, "Lengthen the exhale.")
        XCTAssertEqual(insight.metricNotes["DFA α1"], "Held near 1.0.")
    }

    func testUnknownDimensionFallsBackRatherThanRenderingBlank() {
        let b = SessionInsightBullet(dimension: "wobble", text: "x")
        XCTAssertEqual(b.symbol, "circle.fill")
    }

    func testKnownDimensionsMapToSymbols() {
        XCTAssertEqual(SessionInsightBullet(dimension: "breathing", text: "x").symbol, "lungs.fill")
        XCTAssertEqual(SessionInsightBullet(dimension: "effort", text: "x").symbol, "flame.fill")
    }

    func testMalformedJSONDecodesToNil() {
        XCTAssertNil(SessionInsight(json: "not json"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/ActivityInsightPayloadTests
```
Expected: compile failure — `cannot find 'ActivityInsightPayloadBuilder' in scope`.

- [ ] **Step 3: Create `SessionInsight.swift`**

```swift
import Foundation
import SwiftUI

/// One insight bullet. The model supplies a `dimension` key from a fixed set,
/// never an icon name — an SF Symbol it invented would render as blank space.
struct SessionInsightBullet: Codable, Identifiable {
    let dimension: String
    let text:      String

    var id: String { dimension + text }

    var symbol: String {
        switch dimension {
        case "breathing": return "lungs.fill"
        case "focus":     return "scope"
        case "energy":    return "bolt.fill"
        case "calm":      return "leaf.fill"
        case "recovery":  return "arrow.clockwise.heart.fill"
        case "effort":    return "flame.fill"
        default:          return "circle.fill"
        }
    }

    var color: Color {
        switch dimension {
        case "breathing": return Theme.breathe
        case "focus":     return Theme.hrv
        case "energy":    return Theme.accent
        case "calm":      return Theme.rsa
        case "recovery":  return Theme.ulf
        case "effort":    return Theme.warn
        default:          return Theme.dim
        }
    }
}

/// The structured insight for one activity, as returned by POST /insights and
/// stored verbatim on the entry.
struct SessionInsight: Codable {
    let headline:    String?
    let bullets:     [SessionInsightBullet]
    let nextStep:    String?
    /// Keyed by ActivityMetricDef.techLabel — "RSA", "DC", "DFA α1", …
    let metricNotes: [String: String]

    enum CodingKeys: String, CodingKey {
        case headline, bullets
        case nextStep    = "next_step"
        case metricNotes = "metric_notes"
    }

    init(headline: String?, bullets: [SessionInsightBullet],
         nextStep: String?, metricNotes: [String: String]) {
        self.headline = headline
        self.bullets = bullets
        self.nextStep = nextStep
        self.metricNotes = metricNotes
    }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SessionInsight.self, from: data)
        else { return nil }
        self = decoded
    }
}

extension SessionInsight {
    /// Tolerate a payload with any subset of fields missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline    = try c.decodeIfPresent(String.self, forKey: .headline)
        bullets     = try c.decodeIfPresent([SessionInsightBullet].self, forKey: .bullets) ?? []
        nextStep    = try c.decodeIfPresent(String.self, forKey: .nextStep)
        metricNotes = try c.decodeIfPresent([String: String].self, forKey: .metricNotes) ?? [:]
    }
}
```

- [ ] **Step 4: Create `ActivityInsightPayloadBuilder.swift`**

```swift
import Foundation
import SwiftData

/// Builds the metric-keyed insight request for one activity, including the
/// shape of its during window. Kept out of InsightGenerator so the generator
/// stays a thin network-and-persist step.
///
/// Note the isolation: only `payload(for:context:)` is @MainActor, because it
/// touches ModelContext. `buckets` is pure and stays nonisolated so tests can
/// call it directly without hopping to the main actor.
enum ActivityInsightPayloadBuilder {

    static let bucketCount = 5

    /// Mean value per equal-width slice of [startedAt, endedAt), oldest first.
    /// A slice with no samples is nil — the prompt is told to make no timing
    /// claim about it rather than to interpolate.
    static func buckets(values: [(date: Date, value: Double)],
                        startedAt: Date, endedAt: Date,
                        count: Int = bucketCount) -> [Double?] {
        let span = endedAt.timeIntervalSince(startedAt)
        guard span > 0, count > 0 else { return Array(repeating: nil, count: count) }
        let width = span / Double(count)

        var sums   = Array(repeating: 0.0, count: count)
        var counts = Array(repeating: 0,   count: count)
        for v in values {
            let offset = v.date.timeIntervalSince(startedAt)
            guard offset >= 0, offset < span else { continue }
            let idx = min(Int(offset / width), count - 1)
            sums[idx]   += v.value
            counts[idx] += 1
        }
        return (0..<count).map { counts[$0] == 0 ? nil : sums[$0] / Double(counts[$0]) }
    }

    /// The full request for one completed activity. Returns nil if the entry
    /// has no end — an active activity has no during window to describe.
    @MainActor
    static func payload(for entry: ActivityLog, context: ModelContext) -> InsightPayload? {
        guard let end = entry.endedAt else { return nil }

        let windowStart = entry.startedAt.addingTimeInterval(-300)
        let windowEnd   = end.addingTimeInterval(600)
        let predicate = #Predicate<HRVSample> {
            $0.timestamp >= windowStart && $0.timestamp <= windowEnd
        }
        var desc = FetchDescriptor<HRVSample>(predicate: predicate,
                                              sortBy: [SortDescriptor(\.timestamp)])
        desc.fetchLimit = 10_000
        let raw = (try? context.fetch(desc)) ?? []
        let points = MetricsQualityFilter.filter(raw.map { MetricsHistoryPoint(from: $0) })

        var metrics: [String: ActivityMetricWindowPayload] = [:]
        for def in activityMetricDefs {
            let timed = points.compactMap { pt -> (date: Date, value: Double)? in
                guard let v = def.extract(pt) else { return nil }
                return (pt.timestamp, v)
            }
            // Samples may have been pruned before a retry sweep reaches this
            // entry. The stored window averages survive, so the insight is
            // still generated — just without timing.
            let slices = timed.isEmpty
                ? nil
                : buckets(values: timed, startedAt: entry.startedAt, endedAt: end)
                    .map { $0.map(Float.init) }

            metrics[def.techLabel] = ActivityMetricWindowPayload(
                label:     def.label,
                unit:      def.unit,
                direction: def.directionKey,
                before:    entry[keyPath: def.beforeKey],
                during:    entry[keyPath: def.duringKey],
                after:     nil,
                duringBuckets: slices
            )
        }

        return InsightPayload(entry: entry, metrics: metrics)
    }
}
```

`def.directionKey` doesn't exist yet. Add to `ActivityMetricDef` in `ActivityMetricsGrid.swift`:

```swift
    /// Wire form of `direction` for the insight payload — the model can't
    /// otherwise know that falling Inner Noise is good and falling RSA is not.
    var directionKey: String {
        switch direction {
        case .higher: return "higher"
        case .lower:  return "lower"
        case .target: return "target"
        }
    }
```

`after` is left nil above because `ActivityMetricDef` carries no `afterKey`. Add one to the struct mirroring `beforeKey`/`duringKey`, populate it for all nine defs (`\.afterDC`, `\.afterRCMSE`, `\.afterPIP`, `\.afterDFA1`, `\.afterStress`, `\.afterRSA`, `\.afterVTI`, `\.afterRMSSD`, `\.afterHR`), and pass `entry[keyPath: def.afterKey]`.

- [ ] **Step 5: Update the wire types**

In `APIClient.swift`, add and extend:

```swift
struct ActivityMetricWindowPayload: Codable {
    let label:     String
    let unit:      String
    let direction: String
    let before:    Float?
    let during:    Float?
    let after:     Float?
    let duringBuckets: [Float?]?

    enum CodingKeys: String, CodingKey {
        case label, unit, direction, before, during, after
        case duringBuckets = "during_buckets"
    }
}
```

Extend `InsightPayload` with `let activityMetrics: [String: ActivityMetricWindowPayload]?`, coding key `case activityMetrics = "activity_metrics"`, and add the convenience initializer used above:

```swift
extension InsightPayload {
    init(entry: ActivityLog, metrics: [String: ActivityMetricWindowPayload]) {
        self.init(activityType:    entry.activityType,
                  activitySubtype: entry.activitySubtype,
                  durationMin:     entry.duration.map { Int(($0 / 60).rounded()) },
                  beforeHR: entry.beforeHR,     duringHR: entry.duringHR,     afterHR: entry.afterHR,
                  beforeRSA: entry.beforeRSA,   duringRSA: entry.duringRSA,   afterRSA: entry.afterRSA,
                  beforeSDNN: entry.beforeSDNN, duringSDNN: entry.duringSDNN, afterSDNN: entry.afterSDNN,
                  beforeLFHF: entry.beforeLFHF, duringLFHF: entry.duringLFHF, afterLFHF: entry.afterLFHF,
                  activityMetrics: metrics)
    }
}
```

Keep the flat fields populated — they cost nothing and keep the payload valid against an un-upgraded server.

Extend `InsightResponse`:

```swift
struct InsightResponse: Codable {
    let text:        String
    let headline:    String?
    let bullets:     [SessionInsightBullet]?
    let nextStep:    String?
    let metricNotes: [String: String]?

    enum CodingKeys: String, CodingKey {
        case text, headline, bullets
        case nextStep    = "next_step"
        case metricNotes = "metric_notes"
    }
}
```

This changes `InsightResponse`'s memberwise init, which `InsightGeneratorTests` uses. Add a convenience init so existing call sites keep working:

```swift
extension InsightResponse {
    init(text: String) {
        self.init(text: text, headline: nil, bullets: nil, nextStep: nil, metricNotes: nil)
    }
}
```

- [ ] **Step 6: Store the structured form**

In `ActivityLog.swift`, add beside `insightText`:

```swift
    /// The structured insight response, stored verbatim. `nil` means "not yet
    /// generated" — eligible for retry by `InsightGenerator.flushPending`.
    /// `insightText` is retained for entries logged before this field existed.
    var insightJSON: String?

    var sessionInsight: SessionInsight? {
        insightJSON.flatMap { SessionInsight(json: $0) }
    }
```

In `InsightGenerator.swift`:

```swift
    func generate(for entry: ActivityLog, context: ModelContext) async {
        guard let payload = ActivityInsightPayloadBuilder.payload(for: entry, context: context),
              let response = try? await client.generateInsight(payload) else { return }
        // A concurrent generate for the same entry (activity-end racing the
        // foreground retry sweep) may have landed while we awaited the network.
        guard entry.insightJSON == nil else { return }

        let insight = SessionInsight(headline: response.headline,
                                     bullets: response.bullets ?? [],
                                     nextStep: response.nextStep,
                                     metricNotes: response.metricNotes ?? [:])
        if let data = try? JSONEncoder().encode(insight),
           let json = String(data: data, encoding: .utf8) {
            entry.insightJSON = json
        }
        entry.insightText = response.text
        try? context.save()
    }
```

and change the pending predicate:

```swift
            predicate: #Predicate { $0.endedAt != nil && $0.insightJSON == nil },
```

- [ ] **Step 7: Update `InsightGeneratorTests`**

The two `insightText` assertions still hold — `generate` writes both fields. Add:

```swift
    @MainActor
    func testGenerateStoresStructuredInsight() async {
        let context = makeContext()
        let entry = ActivityLog(activityType: "Breathwork", startedAt: .now, endedAt: .now, isManual: true)
        context.insert(entry)

        let response = InsightResponse(
            text: "Deep, settled session",
            headline: "Deep, settled session",
            bullets: [SessionInsightBullet(dimension: "breathing", text: "Breathing lengthened.")],
            nextStep: "Lengthen the exhale.",
            metricNotes: ["RSA": "Climbed steadily."])
        let generator = InsightGenerator(client: FakeClient(result: .success(response)))
        await generator.generate(for: entry, context: context)

        XCTAssertEqual(entry.sessionInsight?.headline, "Deep, settled session")
        XCTAssertEqual(entry.sessionInsight?.metricNotes["RSA"], "Climbed steadily.")
    }

    @MainActor
    func testFlushPendingPicksUpLegacyEntriesWithTextButNoJSON() async {
        let context = makeContext()
        let legacy = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)
        legacy.insightText = "old flat insight"
        context.insert(legacy)

        let pending = InsightGenerator.pendingActivities(context: context)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, legacy.id)
    }
```

The schema in `makeContext()` is `Schema([ActivityLog.self])`; `payload(for:)` fetches `HRVSample`, which isn't in it. Add `HRVSample.self` to that schema so the fetch returns empty rather than trapping.

- [ ] **Step 8: Register the new files and run the tests**

Add `ActivityInsightPayloadBuilder.swift` and `SessionInsight.swift` to the `Wythin` target, and `ActivityInsightPayloadTests.swift` to `WythinTests`, per the Global Constraints.

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`, all pass.

- [ ] **Step 9: Commit**

```bash
git add ios/Wythin ios/WythinTests ios/Wythin.xcodeproj/project.pbxproj
git commit -m "feat(insights): metric-keyed payload with during-window buckets, structured storage

Sends all nine displayed metrics with direction and five time slices each,
and stores the structured response on the entry. insightText is retained
so entries logged before this still render."
```

---

## Task 12: Session Insights card and per-chart notes

**Files:**
- Modify: `ios/Wythin/UI/Activities/ActivityDetailView.swift`
- Modify: `ios/Wythin/UI/Activities/MetricProgressRow.swift`

**Interfaces:**
- Consumes: `ActivityLog.sessionInsight`, `SessionInsightBullet.symbol/.color` (Task 11); `ActivityImpact.trendLine` (Task 7); `PracticeImpactMeter` (Task 8).
- Produces: `SessionInsightsCard(entry:trendLine:)`. `MetricProgressRow` gains a `note: String?` parameter.

There is no new pure logic here — the units it composes are already covered by Tasks 7, 8 and 11. The gate is the build plus the manual checks in Step 5.

- [ ] **Step 1: Build the card**

Add to `ActivityDetailView.swift`:

```swift
// MARK: - SessionInsightsCard

/// The session's read: the model's headline and icon-tagged bullets, with one
/// deterministic trend line as a footer. Never called "coach" in the UI.
private struct SessionInsightsCard: View {
    let entry:     ActivityLog
    let trendLine: String?

    /// Legacy flat insight, for entries logged before the structured field
    /// existed. Rendered as headline-plus-body, the way it always was.
    @ViewBuilder
    private func legacy(_ text: String) -> some View {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 6) {
            Text(parts.first.map(String.init) ?? text)
                .font(Theme.monoBody.weight(.semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if parts.count > 1 {
                let rest = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    Text(rest)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    var body: some View {
        let insight = entry.sessionInsight
        let hasContent = insight != nil || entry.insightText != nil || trendLine != nil

        if hasContent {
            VStack(alignment: .leading, spacing: 12) {
                Text("SESSION INSIGHTS")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)

                if let insight {
                    if let headline = insight.headline, !headline.isEmpty {
                        Text(headline)
                            .font(Theme.monoBody.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(insight.bullets) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: bullet.symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(bullet.color)
                                .frame(width: 16)
                            Text(bullet.text)
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let next = insight.nextStep, !next.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text("→")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 16)
                            Text("Next session: \(next)")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if let text = entry.insightText {
                    legacy(text)
                }

                if let trendLine {
                    if insight != nil || entry.insightText != nil {
                        Divider().overlay(Theme.border)
                    }
                    Text(trendLine)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }
}
```

- [ ] **Step 2: Move it under the meter**

In `ActivityDetailView.body`, immediately after the impact card and **before** the `ForEach(metrics)`, insert:

```swift
                        SessionInsightsCard(
                            entry: entry,
                            trendLine: ActivityImpact.trendLine(metrics.map { m in
                                MetricMovement(name: m.def.label,
                                               uplift: m.stats.avgUpliftPct,
                                               vs2mo: m.def.benefitDelta(current: m.stats.duringMean,
                                                                         base: twoMonthAvg[m.def.id]))
                            }))
```

Delete the old bottom card entirely: the `let recs = …` block, the `if entry.insightText != nil || !recs.isEmpty { … }` card, and the now-unused `coachInsight`, `recIcon` and `recColor` helpers.

- [ ] **Step 3: Pass the note to each metric row**

In the same `ForEach`:

```swift
                        ForEach(metrics, id: \.def.id) { m in
                            MetricProgressRow(def: m.def,
                                              stats: m.stats,
                                              twoMonthValue: twoMonthAvg[m.def.id],
                                              color: entry.activityTypeEnum.color,
                                              points: chartPoints,
                                              startedAt: entry.startedAt,
                                              endedAt: windowEnd,
                                              note: entry.sessionInsight?.metricNotes[m.def.techLabel])
                        }
```

- [ ] **Step 4: Render it in `MetricProgressRow`**

Add the stored property after `endedAt`:

```swift
    /// Model-written note on what this metric did in this session. Nil when
    /// the insight hasn't arrived or didn't cover this metric — the row then
    /// shows only the static why-it-matters text, with no gap or placeholder.
    let note: String?
```

In the `if expanded` block, insert between the chart and the `why` text:

```swift
                    if let note, !note.isEmpty {
                        Text(note)
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(color.opacity(0.5)).frame(width: 2)
                            }
                    }
```

- [ ] **Step 5: Build and verify the card**

Run:
```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`, all pass.

Then confirm the copy and the ordering:
```bash
grep -rn "COACH\|coachInsight\|recIcon\|recColor" ios/Wythin
```
Expected: **no output**.

```bash
grep -n "SESSION INSIGHTS" ios/Wythin/UI/Activities/ActivityDetailView.swift
```
Expected: one match, positioned in the file after `PracticeImpactMeter` and before `ForEach(metrics`.

- [ ] **Step 6: Manual verification**

Launch the app in the simulator and confirm, in order:

1. Activities tab shows only `START NOW` and `LOG PAST ACTIVITY` — no suggestion chips.
2. `START NOW` opens a sheet titled `START ACTIVITY` with a `START ACTIVITY` button — the words "Log Past" and "Save" appear nowhere on it.
3. Picking a 15 target and starting shows `mm:ss / 15:00` with a progress bar; on reaching 15:00 it turns accent, shows `TARGET REACHED`, and **keeps running**.
4. Starting an activity leaves you on the Activities tab.
5. `LOG PAST ACTIVITY` opens a sheet with that title, preset chips, a slider and `SAVE`. Tapping 10 sets the slider; dragging to 17 clears the chip.
6. Typing a custom subtype and saving, then reopening the sheet, shows it as a chip for that type.
7. Opening an activity detail shows the diverging meter whose number equals the mean of the row percentages, then `SESSION INSIGHTS`, then the metric charts with a note above each `why` paragraph.

- [ ] **Step 7: Commit**

```bash
git add ios/Wythin/UI/Activities/
git commit -m "feat(activities): SESSION INSIGHTS card under the meter, notes under each chart

Replaces the bottom COACH card. Icon-tagged bullets come from the model;
the 2-month trend line stays deterministic because the model is never
sent that comparison."
```

---

## Verification

After Task 12, the whole feature should be exercised end-to-end:

```bash
xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16'
DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/ -v
```

Both must be green before the branch is considered done. The manual list in Task 12 Step 6 covers what tests can't: sheet copy, navigation, and that the headline number visibly reconciles with the rows.
