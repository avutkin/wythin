# Recording timezones across travel

> **For agentic workers:** Use superpowers:executing-plans or superpowers:subagent-driven-development; keep phone and server changes isolated until their shared payload contract is verified.

**Goal:** Preserve the phone's timezone at measurement time so flights and delayed uploads do not rewrite historical local time.

**Architecture:** UTC timestamps remain unchanged. Optional IANA `timezone` metadata travels with each metric sample and activity through persistence, upload, restore, and display. The profile is only the current phone zone. The OS supplies the zone; no new location permission is introduced. Legacy recordings without evidence remain unknown. Derived nights use their recorded samples' zones.

**Tech stack:** Swift/SwiftData, Foundation calendars, FastAPI, PostgreSQL, existing dashboard JavaScript.

**Spec:** User request in this conversation: Alexey Molchanov was in Dubai on November 11, though the dashboard used Moscow; correctly follow the phone when traveling. This document records the implementation decisions.

## Global constraints

- Work only in isolated worktrees. Preserve other sessions' work.
- Never change UTC instants or durations to repair a timezone label.
- All new payload fields are optional, compatible with build 146 and existing stores.
- Snapshot `TimeZone.autoupdatingCurrent.identifier` at live capture, never at retry/upload.
- Restore paths preserve nil and recorded zones. Backfilled sleep obtains a zone from its measurements.
- Profile and check-in calendars refresh on foreground/timezone change.
- Use tools/ship.sh for any iOS release; full WythinTests must pass before merging.

## Review focus

1. Dubai capture followed by a Moscow upload preserves the Dubai zone and UTC instant.
2. Cloud restore does not stamp the device's current zone onto unknown historical records.
3. Rebuilt sleep and corrections retain historical civil-day identity after travel.
4. Mixed-zone history and DST retain correct dates and clock labels.
5. Legacy uploads neither erase known sample zones nor become evidence of historical location.

## Task 1: iOS capture, persistence, restore, historical display

**Files:** `ios/Wythin/Models/{ActivityLog,HRVSample,MetricsHistoryPoint}.swift`, `Sync/{APIClient,ActivityUploader,ActivityRestore,CloudRestoreService}.swift`, live activity creation, sleep detector/recorder, activity/sleep display, check-in coordinator and AppEnvironment; related existing tests.

**Interface:** Optional `timezone: String?` on metric samples/history points and activities, serialized as `timezone`. Live construction captures the current identifier. Restore and legacy construction can explicitly preserve nil. Activity display uses its reference zone at start; sample points preserve zone changes within an activity.

- [x] Add failing regressions for capture → timezone change → upload, both restore paths, legacy nil, and delayed sleep reconstruction.
- [x] Implement the payload contract and calendar usage; preserve stable UTC durations and historical day/correction association.
- [x] Run focused Swift tests, then full WythinTests after integration.

## Task 2: Server storage and historical dashboards

**Files:** `server/{db,models,zones}.py`, `routers/{metrics,admin}.py`, `templates/dashboard.html`, server tests.

**Interface:** Accept validated optional sample `timezone`; export it; keep it outside numeric aggregation fields. Existing known zones win over duplicate uploads. Admin raw/aggregated series retain zone metadata without averaging across zones. Daily history uses each recorded zone, with explicitly identified profile fallback only for legacy data.

- [x] Add failing API tests for valid/invalid zones, duplicate legacy upload, export, mixed-zone charts and local dates.
- [x] Add schema and handlers; update chart clocks/tooltips and historical day bucketing.
- [x] Run server suite against an isolated local test database and JavaScript syntax checks.

## Task 3: Review, repair verified history, integration

- [x] Review the combined diff and exercise travel/DST cases; resolve important findings.
- [x] Verify production November 11 measurement coverage. Apply a bounded, auditable Asia/Dubai correction only to the user-confirmed Dubai day (2026-11-10 20:00Z ≤ t < 2026-11-11 20:00Z), preserving UTC data and current profile. Do not guess other trip dates.
- [x] Recheck build 146 in the public-link external group; report access eligibility without claiming a named anonymous tester's installation.
- [x] Integrate tested changes safely and report exactly what is deployed versus pending.

## Execution evidence

- Server commit `287fbc3` passed all 176 server tests on a clean, isolated PostgreSQL database. Independent review verified corrected duplicate-upload protection, per-zone query performance, and explicit unknown-zone fallback labels. Dashboard clock helpers passed Dubai/Moscow, historical DST, and UTC-override checks in Node.
- Server changes are on main and deployed to the existing production `prod` branch via a merge, preserving its configuration. A restrictive file creation mask briefly prevented API startup; source read permissions were restored and `/health` plus authenticated chart endpoints verified healthy.
- The user-confirmed Dubai civil day was corrected for 17,220 metric rows. UTC timestamps were compared before/after and unchanged. A private, mode-0600 backup of original timezone metadata is stored on the server. No other trip dates or the current profile were rewritten. The exact interval's chart API now reports only Asia/Dubai; neighbouring legacy readings still show an explicit unknown-zone fallback.
- Build 146 is VALID, IN_BETA_TESTING externally, and assigned to the enabled public-link External Testers group. The user confirmed Alexey joined by that public link; his individual installation is anonymous.
- Initial integrated iOS capture/restore/sleep changes passed all 1,713 tests. Review found and fixed migration of applied legacy sleep corrections before enrichment/purging; 131 focused tests passed, including rebuilds. A pending pre-upgrade correction without a saved day or matching UTC boundary cannot safely be associated by guessing its original zone.
- Review also required the Live history screen to use stable civil dates, a bounded 52-hour UTC candidate query, recorded-zone membership, explicit chart bounds/reference clock, and correct cache invalidation. Tests cover Dubai midnight under a Moscow viewer, mixed-zone/date-line days, DST, and repaired metadata versus stale memory. This patch passed 49 focused tests and independent review. The combined iOS tree passed the final full suite before release; details are in `/tmp/wythin-travel-final-full.log`.
- The final combined suite and the mandatory `tools/ship.sh testflight` release suite each passed all 1,729 tests. Build **147**, commit `eaf84db`, was uploaded successfully, became VALID, passed Beta App Review, and is IN_BETA_TESTING for the public-link External Testers group. English and Russian release notes were saved. Build 146 remains available in that same group. Production server health and the corrected interval's chart API were verified after deployment.
