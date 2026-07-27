# Wythin Admin Analytics Dashboard — Design Outline

**Date:** 2026-07-26
**Status:** Design outline (brainstormed); MVP pending implementation plan
**Scope:** A detailed server-hosted admin dashboard to track critical metrics **per user** — engagement, consistency, practice volume, live HRV charts, and activity before/during/after drill-down — extending the existing `/admin` dashboard.

## Goal

Give the app owner one place to see, across all users and per individual user: who is active, how much and how consistently they use the app, and — on drilling into a user — the exact same live metric charts and activity before/during/after views that the user sees in the app.

## Context (what already exists)

- **Backend**: FastAPI, Postgres. Self-contained HTML dashboard at `GET /admin/dashboard` (`server/templates/dashboard.html`, ~400 lines) that fetches JSON from `/admin/*` and renders with vanilla JS + inline **SVG** charts. Auth: shared `X-API-Key` (`API_KEY` env).
- **Views today**: `#view-overview` (KPI tiles + a sessions/day bar chart + a users table), `#view-user` (user KPIs + sessions table + activities table), `#view-session` (per-metric charts from `/admin/sessions/{id}/samples`).
- **Data today**:
  - `users` (id, device_id, display_name, created_at)
  - `sessions` (started_at, ended_at, avg_coherence, avg_rsa_ms, best_resonance_bpm)
  - `hrv_samples` (per-tick within a session)
  - `metric_samples` — **per-user continuous metric stream** (mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms, coherence, cbi, breath_bpm, ts) — the live-view data source
  - `activities` — full ActivityLog mirror: type/subtype, `impact_score`, and **before/during/after** for all 9 metrics
  - `api_tokens`
- **Existing `/admin` endpoints**: `/stats`, `/users`, `/users/{id}` (returns sessions + activities), `/sessions/{id}/samples`, `/sessions/{id}/export`.

## Decisions (from brainstorming)

| Question | Decision |
|----------|----------|
| App-usage metrics (opens/day, in-app minutes/day) | **Add real telemetry** — iOS sends app-open/foreground events; backend stores them. (Sub-project 1.) |
| "Best practices" adherence | **Consistency / streak** only — days-active/week, current streak, practiced-today. |
| First slice (MVP) | **Dashboard core on existing data (sub-projects 2 + 3 + 4)** — active-users list, per-user KPIs, live charts, activity drill-down. |
| Charting | Reuse the existing dashboard's **inline-SVG** approach (self-contained, no external deps). |
| Auth | Keep the shared `X-API-Key` gate (single admin). |

## Critical per-user metric model (the outline)

Everything the dashboard tracks, per user:

| Category | Metrics | Source |
|---|---|---|
| **Engagement** | app opens/day, in-app minutes/day, days-active, last-seen, first-seen | `usage_events` (NEW, sub-project 1) |
| **Consistency (best practice)** | current streak (consecutive days with ≥1 session/activity), days-active in last 7/30, practiced-today | `sessions` + `activities` (+ `usage_events`) |
| **Practice volume** | sessions/day, recording minutes/day, activities/day, total sessions/minutes | `sessions`, `activities` |
| **HRV / physiology (live charts)** | the 9 metrics over time: HR, RSA, SDNN, coherence, DC, DFA α1, PIP, RCMSE, stress balance | `metric_samples` |
| **Activities** | each logged activity + before/during/after for all 9 metrics + impact score | `activities` |

## Architecture

Extend the existing self-contained dashboard (one HTML file + `/admin/*` JSON endpoints). Add a per-user "live charts" view and an "activity detail" (before/during/after) view; enrich overview + user KPIs.

```
Browser ──X-API-Key──> FastAPI /admin/*  ──> Postgres
   │
   ├── /admin/dashboard         HTML shell (existing, extended)
   ├── /admin/stats             overview KPIs + sessions/day + per-user rollup (extend: streak, engagement)
   ├── /admin/users             active-users list + KPI columns (extend)
   ├── /admin/users/{id}        user KPIs + sessions + activities (exists)
   ├── /admin/users/{id}/metrics?window=…   NEW — per-user metric_samples series (9 live charts)
   ├── /admin/activities/{id}   NEW — one activity's before/during/after for all 9 metrics
   └── /admin/usage?...         NEW (sub-project 1) — engagement from usage_events
```

Dashboard view flow: **Overview** → click user → **User detail** (KPIs + 9 live charts + activity list) → click activity → **Activity detail** (before/during/after, mirroring the app).

## Sub-project breakdown

Each is its own spec → plan → build. MVP = 2 + 3 + 4.

### 1. Usage telemetry (iOS + backend) — deferred after MVP
- **iOS**: emit lightweight events — `app_opened` (cold launch), `foreground`/`background` (to derive in-app seconds) — batched, sent to the backend with the app token.
- **Backend**: `usage_events` table (`user_id`, `event_type`, `ts`, optional `duration_ms`); ingest endpoint; `/admin/usage` aggregates to opens/day + in-app minutes/day.
- **Dashboard**: fill the Engagement columns with real data (until then they show "—" or the session-based proxy).

### 2. Dashboard overview (MVP)
- KPI tiles: total users, active 7d/30d, total sessions, total minutes, median streak.
- **Active-users table**: one row per user — display name/device, last-seen, streak, days-active/7d, sessions/day (7d), recording min/day (7d), activities count. Sortable columns; click a row → user detail.
- "Active" = has a session or activity in the selected window (default 30 days).

### 3. Per-user drill-down: live charts (MVP)
- On the user detail view, render the **same 9 metrics** as the app's Live view as time-series line charts from `metric_samples`, with a window selector (24h / 7d / 30d).
- `GET /admin/users/{id}/metrics?window=…` returns bucketed series per metric (mirrors the app's bucketing so charts read the same).
- Reuse the inline-SVG line chart; one card per metric, same colors/labels as the app (consumer names).

### 4. Per-user drill-down: activities (MVP)
- User detail lists the user's activities (type/subtype, time, duration, impact score) — make each **clickable**.
- Click → **Activity detail** view: for all 9 metrics, show **before / during / after** values and the benefit-signed change, laid out like the app's activity detail (grouped, colored by benefit), plus the impact score.
- `GET /admin/activities/{id}` returns the activity's before/during/after for all 9 metrics (data already stored on the `activities` row).

### 5. Deploy to a server — deferred after MVP
- Host the backend + dashboard on a real server (the Hetzner path) so it's reachable beyond localhost (phone, anywhere), behind the `X-API-Key` and TLS. Reuses the earlier deployment design.

## Consistency / streak definition

- **Practice day** = a calendar day (user's local day; store/compare in UTC for the MVP, refine later) with ≥1 session OR ≥1 activity.
- **Current streak** = count of consecutive practice days ending today (or yesterday, to not break overnight).
- **Days-active/7d, /30d** = distinct practice days in the trailing window.
- **Practiced-today** = boolean.
- Computed in SQL over `sessions` + `activities` timestamps.

## Dashboard views (detail)

- **Overview**: KPI tiles row; sessions/day bar chart (exists); active-users table with the columns above; window selector.
- **User detail**: KPI header (engagement, streak, volume); **9 live-metric charts** (window selector); **activities list** (clickable); sessions list (exists).
- **Activity detail**: header (type/subtype, time, duration, impact score); a 9-row before/during/after table or small grouped cards, each metric colored by whether the change was a benefit — same semantics as the app.

## Success criteria (MVP)

- Overview lists all active users with correct streak, days-active, sessions/day, minutes/day (recording), activity count; sortable.
- Clicking a user shows the 9 live-metric charts (from `metric_samples`) over the selected window, reading the same as the app.
- The user's activities are listed and clickable; the activity detail shows before/during/after for all 9 metrics + impact score, matching the app's numbers.
- All new endpoints require the `X-API-Key`; the HTML shell stays open.

## Out of scope (MVP)

- Real app-open/in-app-minute telemetry (sub-project 1) — engagement columns show the session-based proxy until then.
- Deployment to a server (sub-project 5) — MVP runs against the local/existing backend.
- Multi-admin accounts / per-admin auth (single shared key).
- Editing user data from the dashboard (read-only).

## Open items to confirm before/with the plan

- Exact bucketing windows for the per-user live charts (match the app's 30m/2h/24h, or dashboard-specific 24h/7d/30d?).
- Whether the activity detail should also render the before/during/after **sample charts** (like the app's per-activity charts) or just the stored aggregate values (MVP: aggregates).
