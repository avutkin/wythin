# Self check-in — two prompts, stored on phone + server, shown on the dashboard

**Date:** 2026-09-13
**Status:** agreed in chat, building

## Problem

Wythin computes state from physiology but has no ground truth for how the
person actually felt. Two self-reports start collecting it so the metrics can
later be correlated with them:

1. **Moment check-in** — once a day, after the strap has been worn 10–15
   minutes, a popup asks how the person feels *right now*.
2. **Previous-day review** — on the first open of the day, a popup asks how
   *yesterday* was on average.

Both are unlabelled sliders (anchor words only, no numbers), disappear once
answered, and land on the server and the admin dashboard.

This feature was half-built before. On 2026-08-03 `a8aa086` added a "How do
you feel right now?" drop-down to the Live widget (see
`2026-08-02-current-state-accuracy-design.md` §6); `fc3c518` removed the UI the
same day. `FeltStateLog`, `FeltStateLogUploader` and
`APIClient.uploadFeltStateLog` survive; the server never got its route or
table. This design finishes the server half, resurrects and extends the
control, adds the two triggers, and puts a panel on the dashboard.

Decisions taken with Alex:

| Question | Decision |
|---|---|
| Delivery of the moment check-in | Local notification if backgrounded, popup directly if in foreground |
| "Randomly during the day" | Random moment 10–15 min after the strap goes on, first qualifying wear of the day |
| Morning review gate | Only when yesterday has strap data |
| Scales | Moment: mood, focus, energy, anxiety, stress. Previous day: focus, energy, anxiety, stress, sleep |

## Design

### Data

`FeltStateLog` gains optional fields (additive; SwiftData lightweight
migration, nothing new is non-optional or unique):

| field | meaning |
|---|---|
| `kind: String?` | `"moment"` or `"previous_day"`; nil reads as moment |
| `anxiety`, `sleep: Double?` | the two new scales, 0–100, nil = untouched |
| `dayKey: String?` | local `yyyy-MM-dd` the answer refers to (yesterday for previous_day) |
| `timezone: String?` | phone zone identifier at save time |
| `wornMinutes: Double?` | minutes the strap had been on when asked (moment only) |

`timestamp` is always the save instant (the uploader's watermark keys on it);
a previous-day row is never back-dated — that is what `dayKey` is for.
`stateKey` stays nil for now: `LiveStateStore` is view-owned and unreachable
from `AppEnvironment`.

`FeltStateUploadPayload` carries the same keys in snake_case
(`kind, anxiety, sleep, day_key, timezone, worn_minutes`). Untouched stays
`nil` end to end — never 50.

Server table `felt_state_logs`: `id BIGSERIAL, user_id UUID FK (cascade),
client_id TEXT UNIQUE, kind TEXT NOT NULL DEFAULT 'moment', ts TIMESTAMPTZ
NOT NULL, day_key TEXT, timezone TEXT, focus/energy/stress/mood/anxiety/sleep
REAL, state_key TEXT, worn_minutes REAL, created_at`, index `(user_id, ts
DESC)`. Upsert on `client_id`; every field except `id`/`timestamp` optional
so the shipped client's five-key body still validates.

### Scales and copy

Moment — "How do you feel right now?": mood *low → great*, focus *scattered →
sharp*, energy *depleted → charged*, anxiety *calm → on edge*, stress *easy →
under load*.

Previous day — "Yesterday, on average": focus, energy, anxiety, stress as
above, then **"Last night's sleep"** *broken → deep* (the night that ended
this morning, worded so it is not read as the night before yesterday).

Anchor words follow `OnboardingStateSlider` so the onboarding baseline and
the check-ins share a vocabulary.

### Moment trigger

The 5 s loops in `AppEnvironment` only run while `bluetooth-central` keeps
the process alive on strap traffic, so the ask is **pre-scheduled with the
OS**, not fired by a timer.

- Worn = `ble.state == .connected` (off-body already drops to `.standby`).
  `startUsageTracking()` already tracks `recordingStart`; that is
  `wornSince`. The coordinator is called from that same loop.
- `eligibleAt = max(wornSince + 10 min, today 08:00)`, `fireAt = eligibleAt +
  U(0, 5 min)`, require `fireAt < 21:00`. Evaluated on every poll, so a 23:00
  connect asks at 08:00–08:05 next morning, and a wear that crosses midnight
  still asks once for the new day.
- When `fireAt` is computed and not asked today: schedule a
  `UNTimeIntervalNotificationTrigger` at `fireAt` with the fixed identifier
  `wythin.checkin.moment` (re-add replaces), persist the ledger
  (`askedDayKey`, `fireAt`) in `UserDefaults`. If the strap goes to
  standby/disconnected before `fireAt`: cancel the request and clear the
  ledger so the day can ask again on the next wear.
- If the app is foreground when `fireAt` passes, the poll presents the sheet
  directly (`willPresent` returns `[]`, so a notification would show nothing
  in the foreground anyway).
- Notification permission is only ever requested from the nudge toggle in
  Settings today. If not authorized, no notification is scheduled; the poll
  still presents in-foreground when `fireAt` passes. The first time any
  check-in sheet is shown, its footer offers "Remind me when the app is
  closed", which requests authorization.
- Stale: on foreground or on a late tap, if `now − fireAt > 60 min`, drop the
  pending ask and clear delivered notifications. `askedDayKey` stays set.
- Tap routing: `WythinAppDelegate.userNotificationCenter(didReceive:)`
  currently guards on the nudge key and drops everything else. A check-in
  branch goes before it (userInfo `checkin = moment`). The tap only needs to
  open the app; `appDidBecomeActive` reads the ledger and presents.

### Previous-day trigger

- Evaluated in `checkIns.appDidBecomeActive(now:)`, idempotent per day,
  called from both `ContentView.task` and the foreground branch of
  `isInForeground.didSet` (that flag starts `true`, so launch needs its own
  call).
- Show when: today's key ≠ `previousDayShownDayKey`, onboarding complete, the
  cloud-sync notice is not up, and yesterday has strap data (a
  `fetchCount` of `HRVSample` over yesterday's local range).
- Mark shown-today when actually presented, whether answered or skipped —
  never at evaluation, so onboarding or the cloud notice cannot eat the day.
- Queue order: previous-day first, then moment.

Day keys use `CheckInDayKey.string(for:calendar:)` producing `yyyy-MM-dd`;
`NudgeBudget.dayKey` is not zero-padded and is not sent.

### Popup (`CheckInSheet`)

One `.sheet(item:)` on `mainApp` bound to `env.checkIns.presented`. A second
sheet on the same node would silently fail, so `canPresent =
hasCompletedOnboarding && !showCloudNotice`, re-attempted in the cloud-notice
closures. Large detent; swipe-down = skip. Title, one-line helper, the scale
rows (resurrected `FeltStateScaleRow`: custom drag track, 28 pt knob,
untouched = grey centred knob with no fill), **Done** (enabled once any scale
is touched) and **Skip**. Done writes the row, saves, and flushes the uploader
immediately.

### Server

- `server/db.py` — `CREATE TABLE IF NOT EXISTS felt_state_logs` + index in
  the additive block of `SCHEMA_SQL`.
- `server/models.py` — `FeltStateLogUpload`, timezone through the same
  validator `ProfileUpload` uses.
- `server/routers/felt_state.py` — `POST /felt-state-logs`, single object,
  `X-User-ID` → `get_or_create_user`, `INSERT … ON CONFLICT (client_id) DO
  UPDATE` with `COALESCE(EXCLUDED.x, felt_state_logs.x)` per scale,
  `RETURNING id`, `kind = body.kind or "moment"`.
- `server/routers/me.py::delete_my_data` — add `felt_state_logs` (and
  `usage_events`, a pre-existing gap).
- `server/routers/admin.py::user_detail` — add `check_ins` (newest first).

### Dashboard

`#view-user` gains a **Check-ins** panel after Activities: When (phone
clock), Kind, Mood, Focus, Energy, Anxiety, Stress, Sleep as whole numbers or
"—", Worn (min).

### Web prototype

`docs/checkin-prototype.html` — single file, no deps, phone-width. Two
buttons simulate each prompt; the popup slides up over a mock Live screen,
shows the unlabelled sliders, and appends the exact wire JSON to a log below.
Not on any deploy path.

## Out of scope

Correlating check-ins with metrics, an MCP tool for check-ins, in-app history
or editing of check-ins, stamping `stateKey`.
