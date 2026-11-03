# Sleep night sync — the dashboard shows what the app shows

**Date:** 2026-09-06
**Status:** agreed in chat, building

## Problem

A night is an `ActivityLog` row typed `Sleep`. The app stores the score, the
five section scores, the four-stage minutes, the regularity index and the
stage summary on that row, and draws the hypnogram, the position bands, the
wake bouts and the heart-rate nadir by re-reading the raw ticks every time the
night is opened. The upload (`ActivityUploadPayload`) carries none of it: a
night reaches the server as a start, an end and 36 window averages. The tick
stream on the server has no motion and no body position, so nothing can be
rebuilt there. The dashboard therefore shows a night as an ordinary activity
with an empty Impact tile.

## Design

One nested `sleep` object on the activity upload, one JSONB column on the
server, one panel on the dashboard. The vocabulary is the insight payload's
(`SleepNightPayload`), which is already the reviewed wire shape for a night.

### iOS

- `ActivityLog.sleepDetailJSON: String?` — written by `SleepRecorder.record`
  from the night's own points, once, at record time. Holds what the row does
  not already store and the dashboard needs to draw the night:
  `stage_runs` (run-length hypnogram, five stages), `position_bands`,
  `positions` (minutes per pose), `position_recorded`, `wake_bouts`,
  `longest_wake_min`, `lowest_hr`, `lowest_hr_at`. Wake bouts and longest wake
  are the ones the Continuity section was scored on, not a view-time
  recomputation, so the upload is auditable against the printed arithmetic.
- `SleepThresholds.algorithmVersion` → 14 (main had already taken 13 for the per-minute baselines, and build 120 shipped it without the detail), so every recorded night is
  purged and rebuilt with the detail. A rebuilt night has a new id and an old
  `endedAt`, which the uploader's watermark would skip, so the recorder
  rewinds the watermark to the earliest night it rewrote. Re-uploads are
  upserts and harmless.
- `ActivityUploadPayload.sleep: SleepUploadPayload?` — nil for anything but a
  night. Fields: `score, arithmetic, stage_summary, asleep_min, in_bed_min,
  regularity, algorithm_version, read_text, sections{timing,duration,
  continuity,autonomic,breathing}, stages{wake,rem,n1,n2,n3}` plus the detail
  above. Absent sections stay absent, never 0.
- `ActivityRestore` puts the sleep fields back on a restored row, including
  the algorithm version, so a restored phone shows its nights instead of
  purging them and failing to rebuild from a tick stream that has no motion.

### Server

- `activities.sleep JSONB`, additive migration.
- `ActivitySchema.sleep: Optional[dict]`; stored as-is.
- One night per window: when a Sleep row is upserted, other Sleep rows of the
  same user whose window overlaps it are deleted. A rebuilt or corrected
  night replaces its predecessor instead of sitting beside it.
- The activity detail and the user's activity list return `sleep`.

### Dashboard

For a Sleep activity:

- The Impact tile becomes **Night score** — `score/100`, with the arithmetic.
- A **The night** panel mirroring the app's night screen: time asleep with
  time in bed and efficiency beneath it, asleep → woke clocks; "how this
  number was made" with the arithmetic and a bar per section of weight ×
  score; the five sections with their detail line and verdict, absent ones
  as "not measured"; stages with minutes and share of sleep; positions with
  minutes and share of known time, or which of the two silences it is.
- A **montage** on one shared clock: the hypnogram as a lane ribbon (depth is
  vertical position, wake a neutral lane), the position bands, heart rate
  with its nadir marked, HRV and breathing from the server's tick stream,
  wake bands shaded behind every trace. No movement lane — motion is not
  synced.
- The before / during / after cards stay below, unchanged.

## Out of scope

Motion sync, per-epoch upload, sleep on the MCP server, deleting purged
nights from the app side (the overlap rule on the server covers it).
