# Activity log: end time + top-nine subtypes

**Date:** 2026-07-30
**Scope:** iOS activity-logging sheets (`ios/Wythin/UI/Activities/ActivityFormSheets.swift`, `ios/Wythin/Models/ActivityLog.swift`)

## Problem

Two friction points in the activity-log sheets:

1. **No end time.** `LogPastSheet` and `EditActivitySheet` take a start time and a duration; the end is implied (`start + duration`) and never shown. When you know an activity ran "2:15 to 3:00", you have to do the subtraction yourself. `StartActivitySheet` has only an optional target duration with no sense of when that lands.
2. **Subtype grid overflows.** `SubtypePicker` renders every built-in subtype plus up to six remembered custom ones. Exercise alone has 17 built-ins, so the grid runs to six-plus rows and pushes the sheet into a long scroll. The `+ Custom` chip sits at the end of that run, far from the top.

## Design

### 1. Shared time section with three synced controls

Extract the start-time/duration card — currently duplicated verbatim in `LogPastSheet` and `EditActivitySheet` — into a single `ActivityTimeSection` view. It shows three controls, all visible at once, with no mode toggle:

```
START TIME      [ Jul 30, 2:15 PM ]
END TIME        [ 3:00 PM ]

DURATION                    45 min
[ 5 ][ 10 ][ 15 ][ 20 ][ 30 ]
 ──────●──────────────────────────
```

- **START TIME** — `DatePicker` with `[.date, .hourAndMinute]`, unchanged from today.
- **END TIME** — new `DatePicker` with `[.hourAndMinute]` only. Its selectable range is `start + 1 minute ... min(start + 180 min, end of start's calendar day)`, which enforces the same-day constraint and keeps the end inside the duration slider's domain.
- **DURATION** — the existing `DurationPresetRow` chips plus the 1…180 slider, unchanged.

**Sync invariant:** `end == start + duration` always holds. Concretely:

- Editing **duration** (chip or slider) moves the end time, start fixed.
- Editing **end time** recomputes the duration, start fixed.
- Editing **start time** keeps the duration and shifts the end. If the new start pushes the end past midnight, the duration is clamped so the end lands at 23:59 of the start's day.

The sheets keep `startDate` and `durationMins` as their source of truth (as today), so the save path is untouched. The end-time picker binds through a computed `Binding<Date>` whose setter writes back a duration. The clamping arithmetic lives in a pure helper — `ActivityTimeMath` — so it is unit-testable without a view:

```swift
enum ActivityTimeMath {
    /// Latest end permitted for a start: same calendar day, ≤180 min out.
    static func maxEnd(start: Date, calendar: Calendar) -> Date

    /// Duration implied by an end time, clamped to 1...180 and same-day.
    static func duration(start: Date, end: Date, calendar: Calendar) -> Double

    /// Duration clamped so start + duration stays within the same day.
    static func clampedDuration(start: Date, minutes: Double, calendar: Calendar) -> Double
}
```

`Calendar` is injected rather than read from `.current` inside the helper so tests can pin a timezone.

### 2. Start Now: planned end

`StartActivitySheet`'s `TARGET (OPTIONAL)` row gains an **END BY** time picker beside it, synced against "now" by the same rule: choosing an end sets the target minutes to the difference; choosing a preset chip updates the shown end time. The sheet re-reads "now" when it appears, not on every render, so the end time does not drift while the sheet is open.

This stays a *target*: it seeds the same optional `targetMinutes` that `onStart` already passes today. Nothing auto-stops the activity — it still ends when the user stops it. The row's existing `clear` action clears both the target and the end-by display, returning to "no target".

A `DatePicker` always renders some value, so "no target" cannot be shown as an empty picker. Instead the END BY row is only present once a target exists: with no target, a dimmed `SET END TIME` button sits in its place, and tapping it seeds the default 15-minute target and reveals the picker. `clear` returns to the button.

### 3. Subtype picker: top eight + Custom

Add a ranking function alongside the existing `SubtypeMemory`:

```swift
enum SubtypeRanking {
    /// Built-ins and remembered customs for `type`, ranked by how often they
    /// appear in `entries`; built-in list order breaks ties and covers
    /// never-used subtypes. `pinned` is forced into the result if present.
    static func top(_ count: Int,
                    type: ActivityType,
                    entries: [ActivityLog],
                    pinned: String? = nil) -> [String]
}
```

Rules:

- Candidates are `type.subtypes` (built-ins) unioned with `SubtypeMemory.remembered(type:entries:)` (custom subtypes the user has actually logged).
- Rank by descending use count over `entries` filtered to that activity type. Ties break by built-in list order first, then remembered-recency order, so an untouched type shows its built-ins in the order they are declared today.
- Return at most `count` entries.

`SubtypePicker` renders `SubtypeRanking.top(8, …)` followed by the `+ Custom` chip — exactly nine chips, one clean 3×3 grid, with Custom always in the last cell.

**Pinned-selection guard.** When `EditActivitySheet` opens an entry whose subtype falls outside the top eight, that subtype would be selected but invisible. The picker passes its current `selected` value as `pinned`; the ranking forces it into the list (displacing the eighth-ranked entry), so the grid stays nine chips and the selection is always on screen. The same guard covers `LogPastSheet` opened from a Practice prefill.

The custom text-field behaviour below the grid is unchanged.

## Non-goals

- No schema change. `ActivityLog.endedAt` already exists and is already written by both save paths.
- No server or sync change.
- No change to how activities are stopped, or to the active-session banner.
- No cross-midnight activities. End is same-day by construction; a session that genuinely spans midnight is out of scope for this pass.

## Testing

New unit tests, following the existing `SubtypeMemoryTests` style (pure functions, no view instantiation):

- `ActivityTimeMathTests` — end-to-duration and duration-to-end round-trips; clamping at the 180-minute ceiling; clamping at end-of-day (a 23:40 start cannot produce a 00:10 end); start moved later carries the duration; a pinned timezone so the day boundary is deterministic.
- `SubtypeRankingTests` — most-used first; built-in order preserved with no history; remembered customs can outrank unused built-ins; result capped at the requested count; `pinned` forced in and total count preserved; pinned already in the top eight does not duplicate.

Existing `SubtypeMemoryTests` continue to pass unchanged — `SubtypeMemory.remembered` keeps its current contract and is consumed by the new ranking rather than replaced.

Manual check on device: log a past activity by end time, confirm the saved row's duration matches; edit an entry with an unusual subtype and confirm the chip is visible and selected.

## Notes

Baseline: `WythinTests` has one known pre-existing failure (BLETests ECG parse) unrelated to this work.
