# Activity Capture & Insights Rework — Design Spec
Date: 2026-07-28

## Overview

Two related changes to the Activities tab:

1. **Capture** — simplify the top card down to two actions, and make both logging
   sheets fast to fill: duration presets, an optional live target, free-text
   subtypes on any activity type, and two new activity types.
2. **Interpretation** — make the headline number on an activity's detail
   reconcile with the per-metric numbers below it, and replace the bottom
   `COACH` card with a structured `SESSION INSIGHTS` card directly under the
   gauge, plus an LLM-written note under every metric chart.

Everything lives in `ios/Wythin/UI/Activities/` and `server/routers/insights.py`.

---

## 1. Activities list — top card

`ActivitiesView.logSection` currently renders a "SUGGESTED NOW" block above the
two action buttons. **Delete the whole block**: the label, the timestamp,
`SuggestionChip`, the `suggested` computed property, `hourLabel()`, and
`suggestedActivities()`.

That chip row's action (`env.pendingTabRequest = .train`) is the only assignment
to `pendingTabRequest` in the app, so removing it is also what fixes "starting an
activity shouldn't move me to the Practices tab." After the change the Activities
tab never programmatically switches tabs.

Two full-width buttons remain, relabelled:

| Was | Becomes |
|---|---|
| `▶ START` | `▶ START NOW` |
| `⟳ LOG PAST` | `⟳ LOG PAST ACTIVITY` |

### Cascading dead code to remove

- `ActivityType.defaultHours` — read only by `suggestedActivities()`.
- `private extension Array { asArray() / ifEmpty(fallback:) }` and
  `private extension ArraySlice { asArray() }` at the bottom of
  `ActivitiesView.swift` — used only by `suggestedActivities()`.
- `DeltaChip` — pre-existing dead code with no references anywhere in the app.
  Two earlier plans explicitly stepped around it to keep their diffs narrow;
  since this spec rewrites the file's structure anyway, delete it here.

### File split

`ActivitiesView.swift` is 1279 lines and every sheet inside it changes in this
spec. Split it three ways, with no behaviour change beyond what's specified here:

| File | Contents |
|---|---|
| `ActivitiesView.swift` | `ActivitySheet`, `ActivitiesView`, `ActiveActivityBanner`, `MetricPill`, `ActivityLogRow`, `LogMetricCell` |
| `ActivityFormSheets.swift` | `StartActivitySheet`, `LogPastSheet`, `EditActivitySheet`, `SubtypePicker`, `ActivityTypeCell`, `DurationPresetRow` |
| `ActivityDetailView.swift` | `ActivityDetailView`, `SessionInsightsCard` |

`StartActivitySheet`, `LogPastSheet` and `EditActivitySheet` share a near-identical
type-grid + subtype + custom-name section. Extract that shared region into one
`ActivityPickerSection` view used by all three, rather than keeping three copies.

---

## 2. Start Now sheet (`StartActivitySheet`)

Navigation title stays `START ACTIVITY`. There is no date picker and no Save
button — this sheet only ever starts a live activity.

### CTA

The CTA label becomes a constant `START ACTIVITY`, dropping the
`START \(startLabel)` interpolation and the `startLabel` property. The
interpolated form produced strings like `START VIPASSANA` that read as a
generic verb-plus-noun, which is what made the sheet feel like the Log Past
sheet. The selected type and subtype are already visible directly above the
button.

### Optional target duration

New section between the subtype picker and the CTA:

```
TARGET (optional)                       clear
   5     10    [15]    20     30
```

- Rendered by the shared `DurationPresetRow` (§3).
- No slider on this sheet — a live target is a rough intention, not a precise
  value.
- `clear` appears only when a preset is selected, and sets the target back to
  none.
- Default is none. Starting with no target selected is the common path and must
  stay one tap.

### Data model

`ActivityLog` gains:

```swift
var targetMinutes: Int?
```

`nil` = no target. Set from the sheet, threaded through
`ActivityLogging.begin(type:subtype:customName:targetMinutes:context:)`.

Log Past and Edit do not set it — a retrospective entry has a known real
duration, so a target is meaningless there.

### Live banner

`ActiveActivityBanner` renders a target when `entry.targetMinutes != nil`:

- Elapsed label becomes `07:22 / 15:00`.
- A progress capsule sits under the elapsed row, filling `elapsed / target`
  clamped to 1.0, tinted `Theme.warn` while under target.
- On reaching target: the capsule and elapsed text switch to `Theme.accent` and
  a `target reached` caption appears next to the timer.
- **The activity never stops itself.** No timer-driven `end()`, no notification.
  The user always presses STOP. Elapsed keeps counting past the target.

With `targetMinutes == nil` the banner renders exactly as it does today.

---

## 3. Log Past sheet (`LogPastSheet`)

Navigation title stays `LOG PAST ACTIVITY`. CTA stays `SAVE`. The start-time
`DatePicker` stays.

The duration slider gains a preset row directly above it:

```
DURATION                              15 min
   5     10    [15]    20     30
   [────────────●──────────────────]
```

### `DurationPresetRow`

New shared view in `ActivityFormSheets.swift`:

```swift
struct DurationPresetRow: View {
    static let presets = [5, 10, 15, 20, 30]
    @Binding var minutes: Double?   // nil = no preset selected
    let allowsDeselect: Bool
}
```

Behaviour:

- Tapping a preset sets the bound value to that number of minutes.
- A chip renders selected when the bound value equals its preset **exactly**.
- Dragging the slider to a non-preset value therefore deselects all chips
  naturally — no extra state, no mode flag. Dragging to exactly 15 re-highlights
  the 15 chip, which is correct and not a bug.
- Both controls stay enabled at all times. The chips are a shortcut, not a mode.

In `LogPastSheet` the binding writes into the existing `durationMins` state, so
the `endDate` computation is unchanged. In `StartActivitySheet` it writes into
`targetMinutes` and the slider is absent.

`EditActivitySheet` gets the same preset row above its slider — it has the
identical duration control and the same reason to want shortcuts.

### Prefill interaction

`LogPastSheet(prefill:)` (used by `PracticeDetailView`) seeds `durationMins` from
`prefill.durationMins`. If that value happens to be a preset it renders selected;
otherwise no chip is selected and the slider shows the prefilled value. No
special-casing needed.

---

## 4. Custom subtypes and new activity types

### `+ Custom` chip

`SubtypePicker` gains a trailing `+ Custom` chip for every activity type,
including types with an empty built-in list. Tapping it reveals a text field
below the grid; the entered text is written straight into `activitySubtype` as
free text.

The existing `customName` field and the `showCustom` flow stay as they are —
`customName` names a *Custom-type activity*, `activitySubtype` names a *subtype
of a known type*. They are different fields and both remain.

### Remembering — no new storage

Custom subtypes are already persisted: every `ActivityLog` stores its
`activitySubtype`. `SubtypePicker` therefore derives remembered subtypes by
query rather than by keeping a second list:

```swift
@Query private var allEntries: [ActivityLog]

private var remembered: [String] {
    let builtIn = Set(type.subtypes)
    let mine = allEntries
        .filter { $0.activityType == type.rawValue }
        .compactMap(\.activitySubtype)
        .filter { !builtIn.contains($0) }
    return Array(NSOrderedSet(array: mine)) as? [String] ?? []
}
```

Ordering: most-recently-used first. `allEntries` is already sorted by
`startedAt` descending at the query level, so first-occurrence order gives that
for free. Cap the rendered list at **6** remembered chips so the grid can't grow
unbounded; older ones remain reachable by retyping them into `+ Custom`.

Grid order: built-in chips, then remembered chips, then `+ Custom`.

This self-cleans: delete the last activity using a subtype and it stops being
offered. No migration, no settings screen, no orphaned vocabulary.

### New activity types

Two cases added to `ActivityType`:

| Case | `rawValue` | Icon | Color | Subtypes |
|---|---|---|---|---|
| `.coffee` | `"Coffee"` | `cup.and.saucer.fill` | `#C89F6B` | Espresso, Filter, Latte, Cold Brew, Decaf |
| `.work` | `"Work"` | `laptopcomputer` | `Theme.ulf` | Deep Work, Meetings, Email, Creative, Reading |

Inserted before `.custom` so Custom stays last in the grid. `.custom` must
remain the final case — `ActivityTypeCell` and the `showCustom` logic key off
it, and `activityTypeEnum` falls back to `.custom` for unknown raw values.

No `defaultHours` entries — that property is deleted in §1.

---

## 5. The headline number

### Problem

`ActivityLog.impactScore` is a 0–100 "goodness" score: each metric's
benefit-signed uplift is squashed to 0–1 around a 0.5 midpoint, then averaged.
A session where nothing changed scores 50. That number can never be reconciled
against the `+14%` / `−3%` figures on the metric rows below it, which is the
reported confusion.

### Change

Replace it with **`impactDeltaPct`**: the mean benefit-signed percentage change
from the before-window average to the during-window average, across the 9
metrics in `activityMetricDefs`.

```swift
/// Mean benefit-signed change, before-window → during-window, across the
/// nine metrics. Literally the average of the per-metric numbers shown on
/// the rows below the gauge — the two cannot disagree.
var impactDeltaPct: Double? {
    let deltas = activityMetricDefs.compactMap { def in
        def.benefitDelta(current: self[keyPath: def.duringKey].map(Double.init),
                         base:    self[keyPath: def.beforeKey].map(Double.init))
    }
    guard !deltas.isEmpty else { return nil }
    return deltas.reduce(0, +) / Double(deltas.count)
}
```

Computed live from the stored window averages — **no cached field**. The stored
averages and the detail view's `ActivityMetricStats` both derive from the same
`MetricsQualityFilter`-gated samples, so the two agree without a cache to keep
in sync.

### Removals

- `ActivityLog.impactScore` stored property.
- `ActivityLog.displayImpactScore`.
- `ActivityImpact.score(uplifts:fullMarks:)`.
- The `impactScore = ActivityImpact.score(...)` tail of `computeHRVWindows`,
  along with the now-unneeded `points` / `uplifts` computation there.
- The `entry.impactScore == nil` clause in `backfillMissingWindows`'s
  `needsFill` filter. The version-bump migration path stays.

`ActivityImpact.breakdown` has no consumer outside `ActivityImpactTests`; delete
it as well. `ios/WythinTests/ActivityImpactTests.swift` loses its `score` and
`breakdown` cases and gains the caption-boundary and `impactDeltaPct` cases
listed in §8.

### Server persistence of the score

`ActivityUploader` currently sends `impactScore` as `impact_score`, and the
server stores it in an `INT` column (`server/db.py:85`) surfaced by
`/activities`. Writing a signed delta into that column would mix two
incompatible scales in one place — rows written before this change are 0–100
"goodness", rows after would be roughly −20…+20.

Instead:

- Add a nullable `impact_delta_pct REAL` column alongside `impact_score`.
- `ActivityPayload` gains `impactDeltaPct` → `impact_delta_pct`; it stops
  populating `impact_score`, which stays in the schema holding historical values
  only.
- `server/models.py` `ActivityIn` gains `impact_delta_pct: Optional[float]`;
  `server/routers/activities.py` adds it to the insert column list.
- No backfill. Old rows keep their 0–100 score with a null delta; consumers that
  need a delta for an old row can compute it from the window averages, which are
  already uploaded.

### Benefit-signed metric cells

`LogMetricCell` (the 3×3 grid inside each activity row in the list) currently
shows **raw** percent change — Pulse dropping 9% renders `−9%` in green. The
detail rows show **benefit-signed** — the same drop renders `+9%`.

For the row badge to be the average of the cells it sits above, the cells switch
to benefit-signed:

```swift
private var pctChange: Double? {
    def.benefitDelta(current: during, base: before)
}
```

`deltaColor` then simplifies to keying off the sign of `pctChange` directly.
The absolute during-value already printed underneath each cell keeps the real
direction visible, so "Pulse +9%, 58 bpm" is unambiguous in context.

### Gauge

`PracticeImpactGauge` is replaced by a diverging meter centred on zero:

```
        −20        0        +20
         ├─────────┼───▓▓▓▓─┤
              +8%
          restorative
     avg change, before → during
```

- Domain −20%…+20%, value clamped to the ends. A clamped value renders with a
  flattened cap on that end so a pinned bar isn't mistaken for an exact reading.
- Fill grows from the centre: right in `Theme.accent`, left in `Theme.warn`.
- Centre tick at 0 in `Theme.dim`.
- The number keeps its explicit sign (`+8%`, `−12%`, `0%`).
- Third line, `Theme.monoLabel` / `Theme.dim`: `avg change, before → during`.
- Nothing renders when `impactDeltaPct` is nil.

The 240° arc, dashed fill and check-knob of the current gauge all encode
"progress toward 100", which no longer describes the value. The file is renamed
`PracticeImpactMeter.swift`.

### Captions

`ActivityImpact.caption(for:)` is rewritten against the delta scale and against
**direction rather than quality**. A hard run legitimately produces a large
negative delta — HR up, HRV down — and must not be labelled a "light session".

| Delta | Caption |
|---|---|
| `≥ +12` | deeply restorative |
| `+6 … +12` | restorative |
| `+2 … +6` | settling |
| `−2 … +2` | steady |
| `−10 … −2` | activating |
| `< −10` | strongly activating |

Signature changes from `caption(for score: Int)` to `caption(for delta: Double)`.

---

## 6. Session Insights and per-chart notes

### 6.1 Placement

The `COACH` card moves from the bottom of `ActivityDetailView` to **directly
under the gauge**, above the metric rows, and is retitled `SESSION INSIGHTS`.

```
┌────────────────────────────────────────┐
│ SESSION INSIGHTS                       │
│ Deep, settled session                  │
│                                        │
│ 🫁  Breathing lengthened from minute 4 │
│     and held — the pacing landed       │
│ ❤️  Pulse fell 9% and stayed down      │
│ ⚡  Stress balance eased throughout     │
│                                        │
│ → Next session: lengthen the exhale.   │
│ ─────────────────────────────────────  │
│ Beat your 2-month average on 6 of 9.   │
└────────────────────────────────────────┘
```

Per-chart notes render inside `MetricProgressRow`'s expanded region, between the
chart and the existing static `def.why` text, in `Theme.monoBody` with the same
left accent rule the `why` text uses:

```
  [ Conscious Breathing chart ]
  ▏Rose sharply once the pacer started, peaked
  ▏at minute 11, and only gave back a third of
  ▏that gain in the 10 minutes after.
  ▏
  ▏Conscious Breathing (RSA) is the swing of…   ← existing static text
```

### 6.2 The payload is missing most of the metrics, and all of the shape

Two gaps, not one:

**It carries the wrong four metrics.** `InsightPayload` sends before/during/after
for HR, RSA, SDNN and raw LF/HF only. The detail view renders **nine** —
DC, RCMSE, PIP, DFA α1, Stress Balance, RSA, VTI, RMSSD, HR. Two of the four
sent aren't even among them: SDNN isn't a displayed metric (RMSSD is, as "Energy
Reserve"), and the displayed stress figure is the breathing-robust 0–100 dial,
not the raw LF/HF ratio the payload sends. A note cannot be written for a chart
whose numbers were never transmitted.

**It carries no shape.** Averages support "fell 9%" but not "peaked at minute
11", which is what a per-chart note exists to say.

Both are fixed by restructuring the activity payload to be **metric-keyed**,
mirroring the `metrics: dict[str, MetricTrend]` pattern `live_state` mode
already uses in this same endpoint:

```
activity_metrics: dict[str, ActivityMetricWindow]   # key = techLabel
```

```python
class ActivityMetricWindow(BaseModel):
    label:     str                       # consumer name, e.g. "Conscious Breathing"
    unit:      str
    direction: str                       # "higher" | "lower" | "target"
    before:    Optional[float] = None
    during:    Optional[float] = None
    after:     Optional[float] = None
    during_buckets: Optional[list[Optional[float]]] = None   # 5, oldest first
```

Keys are `ActivityMetricDef.techLabel`: `"DC"`, `"RCMSE"`, `"PIP"`, `"DFA α1"`,
`"LF/HF"`, `"RSA"`, `"VTI"`, `"HRV"`, `"HR"` — the same keys `metric_notes`
comes back under, so request and response line up by construction.

`direction` is sent because the model cannot otherwise know that falling Inner
Noise is good and falling RSA is bad. It's derived from
`ActivityMetricDef.direction`.

Buckets are 5 equal-width means over the during window, from the same
`MetricsQualityFilter`-gated samples `computeHRVWindows` uses. Nine metrics × 5
= 45 numbers.

**Backwards compatibility:** the twelve flat `before_hr` / `during_rsa` / … fields
stay on `InsightRequest`, and `_format_metrics` prefers `activity_metrics` when
present, falling back to the flat fields otherwise. App builds shipped before
this change keep working against the updated server; they simply get no
`metric_notes`.

New `ActivityInsightPayloadBuilder` (in `ios/Wythin/Sync/`) owns this: given an
entry and a `ModelContext`, it fetches `HRVSample` for
`[startedAt − 300s, endedAt + 600s]`, filters through `MetricsQualityFilter`,
and produces the buckets alongside the existing averages. `InsightGenerator`
calls it instead of building the payload from entry fields directly, keeping the
generator thin.

**Pruned-sample fallback:** an old entry picked up by the retry sweep may have no
samples left in the store. Buckets are then omitted from the payload
(`during_buckets` absent), and the prompt instructs the model to describe
magnitude only and avoid timing claims. The stored window averages are always
present on the entry, so an insight is still produced.

### 6.3 The LLM never picks icons

Bullets carry a `dimension` key from a **fixed enum**, not an icon name:

| `dimension` | SF Symbol | Color |
|---|---|---|
| `breathing` | `lungs.fill` | `Theme.breathe` |
| `focus` | `scope` | `Theme.hrv` |
| `energy` | `bolt.fill` | `Theme.accent` |
| `calm` | `leaf.fill` | `Theme.rsa` |
| `recovery` | `arrow.clockwise.heart.fill` | `Theme.ulf` |
| `effort` | `flame.fill` | `Theme.warn` |

The app maps key → symbol. An unrecognised key falls back to
`circle.fill` / `Theme.dim` rather than rendering blank. Letting the model emit
SF Symbol names directly guarantees hallucinated names that render as empty
space.

### 6.4 Backend — `/insights` response

The response gains fields; `text` is retained unchanged so builds shipped before
this change keep working.

```python
class InsightBullet(BaseModel):
    dimension: str    # breathing|focus|energy|calm|recovery|effort
    text: str

class InsightResponse(BaseModel):
    text: str                            # legacy flat form, unchanged
    headline: Optional[str] = None
    bullets: list[InsightBullet] = []
    next_step: Optional[str] = None
    metric_notes: dict[str, str] = {}    # techLabel → one-to-two sentences
```

`metric_notes` is keyed by `ActivityMetricDef.techLabel`: `"DC"`, `"RCMSE"`,
`"PIP"`, `"DFA α1"`, `"LF/HF"`, `"RSA"`, `"VTI"`, `"HRV"`, `"HR"`. These are
stable identifiers already used as chart labels; `label` is consumer copy and
more likely to be reworded.

`text` is assembled server-side from the structured fields
(`headline + "\n" + bullets joined + "\n" + next_step`) so there is exactly one
generation, not two.

`InsightResponse` is shared by all three modes of this endpoint
(`activity` | `live_state` | `day_potential`). The new fields all carry
defaults, so the other two modes are unaffected and keep returning `text` alone.

Request additions to `InsightRequest`: `activity_metrics` as defined in §6.2.

The handler switches to OpenAI JSON mode (`response_format={"type":
"json_object"}`) with the schema described in the system prompt, `max_tokens`
raised to ~700 to fit nine notes. Model stays `gpt-4o-mini`.

On a malformed or non-JSON completion the handler retries **once**, then returns
502 — same failure contract as today, so the iOS retry sweep is unchanged.

### 6.5 Prompt

One system prompt covering both outputs, so the summary and the notes are
generated from the same reading and cannot contradict each other. It must state:

- The activity type and subtype are central. A good session differs by type: a
  run should show sympathetic push during and clean recovery after; meditation,
  breathwork and yoga should show heart rate down, RSA/SDNN up, stress balance
  falling.
- Exactly 3 bullets, each one sentence, plain language, each a *different*
  dimension.
- `next_step` is one specific, calibrated recommendation grounded in the numbers.
- Each `metric_notes` entry is 1–2 sentences on **what moved, when in the window,
  and why that fits (or doesn't fit) this activity**. Never restate the static
  definition — the app already prints that underneath.
- No markdown. No invented comparisons to norms, averages or "usual" values —
  the app owns that comparison separately (§6.7).

### 6.6 iOS storage

`ActivityLog` gains:

```swift
var insightJSON: String?
```

The full response body is stored verbatim; a computed `sessionInsight:
SessionInsight?` decodes it lazily for the views. `insightText` is **kept** and
still rendered for entries logged before this change (`insightJSON == nil &&
insightText != nil` → render today's headline-plus-body layout, no bullets, no
chart notes).

`InsightGenerator.generate` writes `insightJSON`; its no-clobber guard and
`flushPending`'s predicate both move from `insightText == nil` to
`insightJSON == nil`. Old entries with an `insightText` but no `insightJSON` are
therefore re-generated once into the new shape when the sweep reaches them —
intended, and bounded by the existing limit of 10.

### 6.7 Rule-based bullets

`ActivityImpact.recommendations` currently emits three kinds. After this change:

- `.keep` and `.watch` — **deleted**. The LLM bullets cover the same ground with
  better phrasing and full-session context.
- `.trend` — **kept**, rendered as the card's footer line below a divider. It
  states how many metrics beat the 2-month baseline, which the model has no way
  to know because that comparison isn't in the payload.

`ActivityRecommendation.Kind` collapses to the single `.trend` case; simplify to
a plain `String?` returned by a renamed `ActivityImpact.trendLine(_:)`.

---

## 7. Error handling

| Failure | Behaviour |
|---|---|
| OpenAI error / timeout | 502 from backend; `insightJSON` stays nil; no UI error; next foreground sweep retries |
| Malformed JSON from OpenAI | One server-side retry, then 502 |
| `metric_notes` missing a metric | That chart shows only its static `why` text — no placeholder, no gap |
| Unknown `dimension` key | Falls back to `circle.fill` / `Theme.dim` |
| Samples pruned before retry | Payload omits `during_buckets`; prompt avoids timing claims |
| Entry has `insightText` but no `insightJSON` | Renders legacy layout until the sweep regenerates it |
| `impactDeltaPct` nil (no paired windows) | Meter and caption omitted entirely, as the gauge is today |
| No custom subtypes yet | `SubtypePicker` shows built-ins + `+ Custom` only |

---

## 8. Testing

**Pure logic (unit):**
- `impactDeltaPct` equals the mean of `benefitDelta` across metrics; nil when no
  metric has both windows; ignores metrics missing one side.
- `ActivityImpact.caption(for:)` at each boundary (−10, −2, +2, +6, +12).
- `DurationPresetRow` selection: preset tap sets value; non-preset value selects
  nothing; exact-match value re-selects.
- `SubtypePicker.remembered`: excludes built-ins, dedupes, most-recent-first,
  caps at 6, empty when no history.
- `ActivityInsightPayloadBuilder`: 5 buckets over the during window, quality
  filter applied, buckets nil when no samples.

**Backend:**
- Handler returns the structured shape with a mocked OpenAI client.
- `text` is assembled from the structured fields and is non-empty.
- Malformed JSON → one retry → 502.
- `during_buckets` absent is accepted and produces a valid response.
- `/activities` accepts and round-trips `impact_delta_pct`, and still accepts a
  payload omitting it (`server/tests/test_activities.py`,
  `server/tests/test_admin.py` both currently assert on `impact_score` and need
  a delta case added — the existing `impact_score` assertions stay valid since
  the column is unchanged).

**iOS integration:**
- `flushPending` picks up entries with `insightJSON == nil` including those that
  already have a legacy `insightText`.
- Concurrent `generate` calls don't clobber (existing guard, new field).

**Manual:**
- Start with a 15-min target → banner shows `mm:ss / 15:00` and progress; passing
  the target changes colour and does **not** stop the activity.
- Log past with a preset, then drag the slider off it → chip deselects.
- Type a custom subtype, save, reopen the sheet → it appears as a chip.
- Open a detail view → the gauge number equals the mean of the row percentages.
- Confirm an entry logged before the change still renders its legacy insight.

---

## 9. Files changed / created

| Action | File |
|---|---|
| Modify | `ios/Wythin/UI/Activities/ActivitiesView.swift` — delete suggestions block, relabel buttons, benefit-signed `LogMetricCell`, split out sheets |
| Create | `ios/Wythin/UI/Activities/ActivityFormSheets.swift` — Start / LogPast / Edit / SubtypePicker / ActivityTypeCell / ActivityPickerSection / DurationPresetRow |
| Create | `ios/Wythin/UI/Activities/ActivityDetailView.swift` — detail + `SessionInsightsCard` |
| Rename | `PracticeImpactGauge.swift` → `PracticeImpactMeter.swift` — diverging meter |
| Modify | `ios/Wythin/UI/Activities/MetricProgressRow.swift` — per-chart LLM note above `def.why` |
| Modify | `ios/Wythin/Models/ActivityLog.swift` — `+.coffee`/`+.work`, drop `defaultHours`, `+targetMinutes`, `+insightJSON`, `+impactDeltaPct`, drop `impactScore`/`displayImpactScore` |
| Create | `ios/Wythin/Models/SessionInsight.swift` — `Codable` decode of the structured response + dimension→symbol map |
| Modify | `ios/Wythin/Metrics/ActivityImpact.swift` — drop `score`/`breakdown`, delta-scale `caption`, `recommendations` → `trendLine` |
| Modify | `ios/Wythin/UI/Activities/ActivityLogging.swift` — `begin` takes `targetMinutes` |
| Modify | `ios/Wythin/Sync/APIClient.swift` — payload/response fields |
| Create | `ios/Wythin/Sync/ActivityInsightPayloadBuilder.swift` — during-window buckets |
| Modify | `ios/Wythin/Sync/InsightGenerator.swift` — build via the builder, write `insightJSON`, predicate change |
| Modify | `ios/Wythin/Sync/ActivityUploader.swift` — send `impact_delta_pct`, stop sending `impact_score` |
| Modify | `ios/Wythin/UI/Train/PracticeDetailView.swift` — `LogPastSheet(prefill:)` call site if its signature moves |
| Modify | `ios/WythinTests/ActivityImpactTests.swift` — drop `score`/`breakdown` cases, add caption boundaries |
| Modify | `server/models.py` — `InsightBullet`, extended `InsightRequest`/`InsightResponse`, `ActivityIn.impact_delta_pct` |
| Modify | `server/routers/insights.py` — JSON mode, combined prompt, `text` assembly, one retry |
| Modify | `server/db.py` — `impact_delta_pct REAL` column |
| Modify | `server/routers/activities.py` — insert `impact_delta_pct` |
| Modify | `server/tests/test_activities.py` — `impact_delta_pct` round-trip case |

---

## 10. Out of scope

- Any change to `MetricsHistoryPoint`, `MetricsQualityFilter`, or how HRV window
  averages are computed. Only what's *displayed* on top of them changes.
- The Practices hub and `PracticeHubView` beyond the `LogPastSheet` call site.
- Cross-activity trend charts or a progress view over time.
- Caching, rate limiting or persistence of insights server-side — still fully
  stateless.
- A regenerate button, a settings toggle, or any user control over insights.
- Editing or deleting remembered custom subtypes from a settings screen — they
  are derived from history and managed by deleting entries.
- Notifications or auto-stop on reaching a target duration.
