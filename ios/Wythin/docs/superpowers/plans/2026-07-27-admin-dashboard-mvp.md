# Admin Dashboard MVP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing `/admin` dashboard with per-user consistency/volume KPIs, per-user live-metric charts (from `metric_samples`), and a clickable activity before/during/after drill-down.

**Architecture:** Add three JSON endpoints to `server/routers/admin.py` and extend the existing self-contained `server/templates/dashboard.html` (vanilla JS + inline-SVG charts). No new tables. Reuses the current dashboard's `api()`, `miniChart()`, KPI/table patterns, and hash routing.

**Tech Stack:** FastAPI, asyncpg, Postgres 16, vanilla JS/SVG. Tests: pytest + httpx against a live Postgres.

## Global Constraints

- **Run the server & tests with Python 3.13** via `~/.venv-server/bin/python` (the backend imports `mcp`, which needs ≥3.10; `~/.venv` is 3.9 and cannot import the app).
- **Backend test command:** from `/Users/alexutkin`, `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_admin.py -v`. Tests self-create the schema; use the `wythin_test` DB (not `justbreathe`).
- Admin endpoints sit behind the `X-API-Key` gate (disabled when `API_KEY` is unset, as in the test `_client()`); the `/admin/dashboard` shell stays open.
- **Per-user live charts use only the signals stored in `metric_samples`**: `mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms, coherence, cbi, breath_bpm`. The 5 advanced metrics (DC, DFA α1, PIP, RCMSE, Stress) are NOT in `metric_samples` and are out of MVP scope for live charts (they remain fully available in the activity drill-down).
- Consistency definitions: a **practice day** = a UTC calendar day with ≥1 `sessions` row OR ≥1 `activities` row for the user. **current_streak** = length of the consecutive run of practice days ending today or yesterday. **days_active_7d** = distinct practice days in the last 7 days. **practiced_today** = a practice day equal to `CURRENT_DATE`.
- Keep asyncpg Record→JSON conversion consistent with the existing `_f`/`_activity_row` helpers.

**Repo note:** run `git` from `/Users/alexutkin`; commit paths use the `server/…` prefix. Current branch: `feat/sp4-api-access` (implement here unless told otherwise).

---

## Phase A — Backend (TDD)

### Task 1: Consistency + volume in `/admin/stats`

**Files:**
- Modify: `server/routers/admin.py` (the `usage_stats` handler — add a consistency CTE, extend per-user rows and KPIs)
- Modify: `server/tests/test_admin.py` (extend the `test_stats_shape` key assertions)

**Interfaces:**
- Produces: each `users[]` row in `/admin/stats` gains `current_streak: int`, `days_active_7d: int`, `practiced_today: bool`; `kpis` gains `median_streak: float`.

- [ ] **Step 1: Write the failing test**

In `server/tests/test_admin.py`, extend the existing per-user assertions in `test_stats_shape`. After the block that fetches `/admin/stats`, add:

```python
    u = next(x for x in data["users"] if x["session_count"] >= 1)
    assert "current_streak" in u
    assert "days_active_7d" in u
    assert "practiced_today" in u
    assert isinstance(u["current_streak"], int)
    assert "median_streak" in data["kpis"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alexutkin && DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_admin.py::test_stats_shape -v`
Expected: FAIL with `KeyError`/`assert "current_streak" in u`.

- [ ] **Step 3: Write minimal implementation**

In `server/routers/admin.py`, replace the `users = await conn.fetch(...)` query inside `usage_stats` with one that joins per-user consistency. Add above it a reusable SQL fragment and use it:

```python
        users = await conn.fetch(
            """
            WITH practice_days AS (
                SELECT DISTINCT user_id, (ts_day)::date AS d FROM (
                    SELECT user_id, date_trunc('day', started_at) AS ts_day FROM sessions
                    UNION ALL
                    SELECT user_id, date_trunc('day', started_at) AS ts_day FROM activities
                ) x
            ),
            islands AS (
                SELECT user_id, d,
                       d - (ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY d))::int AS grp
                FROM practice_days
            ),
            streaks AS (
                SELECT user_id, COUNT(*) AS len, MAX(d) AS last_day
                FROM islands GROUP BY user_id, grp
            ),
            consistency AS (
                SELECT
                    pd.user_id,
                    COALESCE(MAX(s.len) FILTER (WHERE s.last_day >= CURRENT_DATE - 1), 0) AS current_streak,
                    COUNT(DISTINCT pd.d) FILTER (WHERE pd.d > CURRENT_DATE - 7)          AS days_active_7d,
                    BOOL_OR(pd.d = CURRENT_DATE)                                          AS practiced_today
                FROM practice_days pd
                LEFT JOIN streaks s ON s.user_id = pd.user_id
                GROUP BY pd.user_id
            )
            SELECT
              u.id, u.device_id, u.display_name,
              u.created_at                       AS first_seen,
              MAX(s.started_at)                  AS last_seen,
              COUNT(s.id)                        AS session_count,
              COALESCE(SUM(EXTRACT(EPOCH FROM (s.ended_at - s.started_at)) / 60.0), 0) AS total_minutes,
              AVG(s.avg_coherence)               AS avg_coherence,
              AVG(s.avg_rsa_ms)                  AS avg_rsa,
              COALESCE(c.current_streak, 0)      AS current_streak,
              COALESCE(c.days_active_7d, 0)      AS days_active_7d,
              COALESCE(c.practiced_today, FALSE) AS practiced_today
            FROM users u
            LEFT JOIN sessions s    ON s.user_id = u.id
            LEFT JOIN consistency c ON c.user_id = u.id
            GROUP BY u.id, c.current_streak, c.days_active_7d, c.practiced_today
            ORDER BY last_seen DESC NULLS LAST
            """
        )
```

Add the three fields to each user dict in the return value's `"users"` list comprehension:

```python
                "current_streak":  r["current_streak"],
                "days_active_7d":  r["days_active_7d"],
                "practiced_today": r["practiced_today"],
```

Compute `median_streak` and add it to the `kpis` dict. After `def _f(v):`, before the `return`:

```python
    _streaks = sorted(r["current_streak"] for r in users)
    if _streaks:
        _mid = len(_streaks) // 2
        median_streak = float(_streaks[_mid] if len(_streaks) % 2 else (_streaks[_mid - 1] + _streaks[_mid]) / 2)
    else:
        median_streak = 0.0
```

and add `"median_streak": round(median_streak, 1),` to the `kpis` dict in the return.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/alexutkin && DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_admin.py -v`
Expected: PASS (all admin tests, including the extended `test_stats_shape`).

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin
git add server/routers/admin.py server/tests/test_admin.py
git commit -m "feat(admin): add per-user streak/days-active + median streak to /admin/stats"
```

---

### Task 2: `GET /admin/users/{id}/metrics` — per-user live series

**Files:**
- Modify: `server/routers/admin.py` (new route)
- Test: `server/tests/test_admin.py` (new `test_user_metrics_series`)

**Interfaces:**
- Produces: `GET /admin/users/{id}/metrics?window=24h|7d|30d` → `{"window": str, "samples": [{"ts": iso, "mean_bpm", "rmssd", "sdnn", "pnn50", "lf_hf", "rsa_ms", "coherence", "cbi", "breath_bpm"}]}`, bucketed with `date_bin` (24h→5min, 7d→1h, 30d→4h), newest window only, ordered by bucket.

- [ ] **Step 1: Write the failing test**

Append to `server/tests/test_admin.py`:

```python
@pytest.mark.asyncio
async def test_user_metrics_series():
    """Upload per-user metric_samples, then confirm the bucketed series endpoint
    returns them for that user. Requires a live database."""
    async with _client() as client:
        # /v1/metrics ingests into metric_samples for a device user
        up = await client.post("/v1/metrics", headers={"X-User-ID": "test-metrics-user"}, json={
            "samples": [
                {"ts": "2025-03-01T10:00:00Z", "mean_bpm": 61.0, "rmssd": 42.0, "coherence": 0.6},
                {"ts": "2025-03-01T10:00:02Z", "mean_bpm": 62.0, "rmssd": 44.0, "coherence": 0.62},
            ]
        })
        assert up.status_code in (200, 201), up.text

        # find the user id
        stats = await client.get("/admin/stats", params={"days": 3650})
        uid = next(u["id"] for u in stats.json()["users"] if u["device_id"] == "test-metrics-user")

        r = await client.get(f"/admin/users/{uid}/metrics", params={"window": "24h"})
    assert r.status_code == 200
    body = r.json()
    assert body["window"] == "24h"
    assert isinstance(body["samples"], list)
    assert {"ts", "mean_bpm", "rmssd", "coherence"} <= set(body["samples"][0])
```

(If the `/v1/metrics` request shape differs, read `server/routers/metrics.py` + `server/models.py::MetricsUpload` and match it — the point is to insert two `metric_samples` rows for one user.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alexutkin && DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_admin.py::test_user_metrics_series -v`
Expected: FAIL — 404 (route not defined).

- [ ] **Step 3: Write minimal implementation**

Add to `server/routers/admin.py` (after `user_detail`):

```python
_METRIC_WINDOWS = {
    "24h": ("24 hours", "5 minutes"),
    "7d":  ("7 days",   "1 hour"),
    "30d": ("30 days",  "4 hours"),
}


@router.get("/users/{user_id}/metrics")
async def user_metrics(user_id: str, window: str = "24h"):
    """Bucketed per-user metric_samples series for the live charts. `window` is
    one of 24h / 7d / 30d; buckets are averaged so the client charts read like
    the app's."""
    span, bucket = _METRIC_WINDOWS.get(window, _METRIC_WINDOWS["24h"])
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            f"""
            SELECT
              date_bin($2::interval, ts, TIMESTAMPTZ 'epoch') AS bucket,
              AVG(mean_bpm) AS mean_bpm, AVG(rmssd) AS rmssd, AVG(sdnn) AS sdnn,
              AVG(pnn50) AS pnn50, AVG(lf_hf) AS lf_hf, AVG(rsa_ms) AS rsa_ms,
              AVG(coherence) AS coherence, AVG(cbi) AS cbi, AVG(breath_bpm) AS breath_bpm
            FROM metric_samples
            WHERE user_id = $1::uuid AND ts > NOW() - $3::interval
            GROUP BY bucket
            ORDER BY bucket
            """,
            user_id, bucket, span,
        )
    def _f(v):
        return float(v) if v is not None else None
    return {
        "window": window if window in _METRIC_WINDOWS else "24h",
        "samples": [
            {
                "ts":         r["bucket"].isoformat(),
                "mean_bpm":   _f(r["mean_bpm"]),
                "rmssd":      _f(r["rmssd"]),
                "sdnn":       _f(r["sdnn"]),
                "pnn50":      _f(r["pnn50"]),
                "lf_hf":      _f(r["lf_hf"]),
                "rsa_ms":     _f(r["rsa_ms"]),
                "coherence":  _f(r["coherence"]),
                "cbi":        _f(r["cbi"]),
                "breath_bpm": _f(r["breath_bpm"]),
            }
            for r in rows
        ],
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/alexutkin && DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_admin.py::test_user_metrics_series -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin
git add server/routers/admin.py server/tests/test_admin.py
git commit -m "feat(admin): add /admin/users/{id}/metrics bucketed live series"
```

---

### Task 3: `GET /admin/activities/{id}` — one activity's before/during/after

**Files:**
- Modify: `server/routers/admin.py` (new route, reuses `_activity_row`)
- Test: `server/tests/test_admin.py` (new `test_activity_detail`)

**Interfaces:**
- Consumes: `_activity_row` (existing helper).
- Produces: `GET /admin/activities/{id}` → the activity as a JSON dict (all `activities` columns incl. every `before_*`/`during_*`/`after_*` and `impact_score`), or 404.

- [ ] **Step 1: Write the failing test**

Append to `server/tests/test_admin.py`:

```python
@pytest.mark.asyncio
async def test_activity_detail():
    """Upload an activity, then fetch its before/during/after detail."""
    act = {
        "id":              "00000000-0000-0000-0000-0000000000b1",
        "activity_type":   "Meditation",
        "activity_subtype":"Vipassana",
        "started_at":      "2025-04-01T08:00:00Z",
        "ended_at":        "2025-04-01T08:12:00Z",
        "impact_score":    62,
        "before_rsa": 20.0, "during_rsa": 30.0, "after_rsa": 26.0,
    }
    async with _client() as client:
        up = await client.post("/v1/activities", headers={"X-User-ID": "test-act-user"}, json=act)
        assert up.status_code in (200, 201), up.text
        r = await client.get(f"/admin/activities/{act['id']}")
    assert r.status_code == 200
    d = r.json()
    assert d["activity_subtype"] == "Vipassana"
    assert d["impact_score"] == 62
    assert d["during_rsa"] == 30.0 and d["before_rsa"] == 20.0
```

(Match the real upload shape from `server/routers/activities.py` + `server/models.py`; the goal is one persisted `activities` row whose id is known.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alexutkin && DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_admin.py::test_activity_detail -v`
Expected: FAIL — 404 (route not defined).

- [ ] **Step 3: Write minimal implementation**

Add to `server/routers/admin.py` (after `user_detail`):

```python
@router.get("/activities/{activity_id}")
async def activity_detail(activity_id: str):
    """One activity's full before/during/after metric grid + impact score."""
    pool = get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM activities WHERE id = $1::uuid", activity_id
        )
    if row is None:
        raise HTTPException(status_code=404, detail="activity not found")
    return _activity_row(row)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/alexutkin && DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test ~/.venv-server/bin/python -m pytest server/tests/test_admin.py -v`
Expected: PASS (whole admin suite).

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin
git add server/routers/admin.py server/tests/test_admin.py
git commit -m "feat(admin): add /admin/activities/{id} before/during/after detail"
```

---

## Phase B — Frontend (`server/templates/dashboard.html`)

No JS test harness. Verify each task by running the server and loading the dashboard in a browser. Start the server once (leave running across Phase B):

```bash
cd /Users/alexutkin && API_KEY=wythin-local-admin \
  DATABASE_URL=postgresql://postgres@localhost:5432/justbreathe \
  ~/.venv-server/bin/uvicorn server.main:app --host 127.0.0.1 --port 8000
```
Open `http://localhost:8000/admin/dashboard`, unlock with `wythin-local-admin`.

### Task 4: Overview table — streak & days-active columns

**Files:**
- Modify: `server/templates/dashboard.html` (the `UCOLS` array)

- [ ] **Step 1: Add two columns to `UCOLS`**

In the `UCOLS` array, insert after the `last_seen` entry:

```javascript
    { k: "current_streak", label: "Streak", cell: (u) => u.current_streak ? `${u.current_streak}d${u.practiced_today ? " •" : ""}` : "—" },
    { k: "days_active_7d", label: "Active 7d", cell: (u) => fmt(u.days_active_7d) },
```

- [ ] **Step 2: Verify**

Reload the dashboard overview. Expected: the users table shows **Streak** (e.g. `3d •` when practiced today) and **Active 7d** columns, and both sort when their headers are clicked (sorting is generic over `state.sortKey`, so no extra wiring needed).

- [ ] **Step 3: Commit**

```bash
cd /Users/alexutkin
git add server/templates/dashboard.html
git commit -m "feat(admin-ui): show streak and active-7d in the users table"
```

---

### Task 5: Per-user live-metric charts + window selector

**Files:**
- Modify: `server/templates/dashboard.html` (`#view-user` markup, a `LIVE_SIGNALS` list, `openUser`, a `loadUserMetrics` fn)

**Interfaces:**
- Consumes: `GET /admin/users/{id}/metrics?window=` (Task 2), `miniChart` (existing).

- [ ] **Step 1: Add the charts panel to the user view markup**

In `#view-user`, add above the Sessions panel:

```html
      <div class="panel">
        <h2>Live metrics
          <span class="sub">—
            <select id="user-window"><option value="24h">24h</option><option value="7d">7d</option><option value="30d">30d</option></select>
          </span>
        </h2>
        <div class="charts" id="user-charts"></div>
      </div>
```

- [ ] **Step 2: Add the signal list + loader**

Near `SIGNALS`, add the live-signal list (the metric_samples columns; consumer labels):

```javascript
  const LIVE_SIGNALS = [
    { k: "mean_bpm",   label: "Pulse",      unit: "bpm",    color: "var(--warn)",    d: 0 },
    { k: "rsa_ms",     label: "Conscious Breathing", unit: "ms", color: "var(--rsa)", d: 0 },
    { k: "rmssd",      label: "RMSSD",      unit: "ms",     color: "var(--hrv)",     d: 0 },
    { k: "sdnn",       label: "Energy Reserve", unit: "ms", color: "var(--hrv)",     d: 0 },
    { k: "coherence",  label: "Coherence",  unit: "",       color: "var(--coh)",     d: 2 },
    { k: "breath_bpm", label: "Breath",     unit: "br/min", color: "var(--breathe)", d: 1 },
    { k: "pnn50",      label: "pNN50",      unit: "%",      color: "var(--accent)",  d: 0 },
    { k: "lf_hf",      label: "LF/HF",      unit: "",       color: "var(--rsa)",     d: 2 },
    { k: "cbi",        label: "CBI",        unit: "",       color: "var(--breathe)", d: 2 },
  ];
  async function loadUserMetrics(id) {
    const d = await api(`users/${id}/metrics?window=${$("#user-window").value}`);
    const s = d.samples || [];
    $("#user-charts").innerHTML = s.length
      ? LIVE_SIGNALS.map(sig => miniChart(sig, s)).join("")
      : `<div class="empty">no live metrics in this window</div>`;
  }
```

- [ ] **Step 3: Call it from `openUser` and wire the selector**

In `openUser`, after `$("#user-kpis").innerHTML = ...`, add:

```javascript
    $("#user-window").onchange = () => loadUserMetrics(id).catch(() => {});
    loadUserMetrics(id).catch(() => {});
```

- [ ] **Step 4: Verify**

Reload, click a user with live data. Expected: a "Live metrics" panel shows up to 9 mini line charts; changing the window dropdown (24h/7d/30d) reloads them. Users without `metric_samples` show "no live metrics in this window".

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin
git add server/templates/dashboard.html
git commit -m "feat(admin-ui): per-user live-metric charts with window selector"
```

---

### Task 6: Activity drill-down (before/during/after)

**Files:**
- Modify: `server/templates/dashboard.html` (new `#view-activity` section, `drawActivities` rows clickable, `openActivity`, routing, `show()` list)

**Interfaces:**
- Consumes: `GET /admin/activities/{id}` (Task 3).

- [ ] **Step 1: Add the activity view section**

After `#view-session`, add:

```html
    <!-- Activity detail -->
    <section id="view-activity" style="display:none">
      <div class="kpis" id="activity-kpis"></div>
      <div class="panel">
        <h2>Before · During · After</h2>
        <div class="tablewrap"><table id="activity-metrics"></table></div>
      </div>
    </section>
```

- [ ] **Step 2: Register the view + make activity rows clickable**

In `show()`, add `"activity"` to the list: `["overview", "user", "session", "activity"].forEach(...)`.

In `drawActivities`, make each row clickable — change the `<tr>` to include a class/id and wire navigation. Replace the row template's opening tag with `<tr class="clickable" data-id="${a.id}">` and after `t.innerHTML = head + body;` add:

```javascript
    t.querySelectorAll("tr.clickable").forEach(tr => tr.onclick = () => { location.hash = "/activity/" + tr.dataset.id; });
```

- [ ] **Step 3: Add `openActivity` + the 9-metric before/during/after render**

Add near `openSession`:

```javascript
  const ACT_METRICS = [
    ["Pulse", "hr", 0, false], ["Conscious Breathing", "rsa", 0, true],
    ["RMSSD", "rmssd", 0, true], ["Energy Reserve", "sdnn", 0, true],
    ["Calm Power", "vti", 2, true], ["Stress Balance", "stress", 0, false],
    ["Adaptive Capacity", "rcmse", 2, true], ["Inner Noise", "pip", 0, false],
    ["Vagal Tone", "dc", 1, true],
  ];
  async function openActivity(id) {
    const a = await api(`activities/${id}`);
    show("activity");
    const name = a.activity_subtype || (a.activity_type === "Custom" ? (a.custom_name || "Custom") : a.activity_type);
    const back = state.userId ? `<a data-nav="/user/${state.userId}">user</a>` : `<a data-nav="/">Overview</a>`;
    $("#crumb").innerHTML = `<a data-nav="/">Overview</a> › ${back} › <strong>${name}</strong>`;
    const dur = (a.started_at && a.ended_at) ? (new Date(a.ended_at) - new Date(a.started_at)) / 60000 : null;
    $("#activity-kpis").innerHTML = [
      ["Activity", name], ["When", fmtTime(a.started_at)],
      ["Duration", dur == null ? "—" : fmt(dur, 0) + " <small>min</small>"],
      ["Impact", a.impact_score == null ? "—" : a.impact_score + "%"],
    ].map(([l, v]) => `<div class="kpi"><div class="label">${l}</div><div class="value">${v}</div></div>`).join("");
    const head = "<tr><th>Metric</th><th>Before</th><th>During</th><th>After</th><th>Δ</th></tr>";
    const body = ACT_METRICS.map(([label, key, dp, higherBetter]) => {
      const b = a[`before_${key}`], dv = a[`during_${key}`], af = a[`after_${key}`];
      let delta = "<span class='muted'>—</span>";
      if (b != null && dv != null) {
        const diff = dv - b, good = higherBetter ? diff >= 0 : diff <= 0;
        delta = `<span style="color:${good ? "var(--coh)" : "var(--warn)"}">${diff >= 0 ? "+" : "−"}${fmt(Math.abs(diff), dp)}</span>`;
      }
      const c = (v) => v == null ? "—" : fmt(v, dp);
      return `<tr><td>${label}</td><td>${c(b)}</td><td>${c(dv)}</td><td>${c(af)}</td><td>${delta}</td></tr>`;
    }).join("");
    $("#activity-metrics").innerHTML = head + body;
    wireCrumb();
    stamp();
  }
```

- [ ] **Step 4: Add the route**

In `route()`, add before the session branch:

```javascript
      if (parts[0] === "activity" && parts[1]) await openActivity(parts[1]);
      else if (parts[0] === "user" && parts[1]) await openUser(parts[1]);
```

- [ ] **Step 5: Verify**

Reload, open a user, click an activity row. Expected: an Activity view with KPI header (name, when, duration, impact) and a 9-row Before/During/After table with a benefit-colored Δ. Breadcrumb navigates back to the user and overview.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin
git add server/templates/dashboard.html
git commit -m "feat(admin-ui): activity before/during/after drill-down view"
```

---

## Self-Review — spec coverage

- Overview per-user KPIs (streak, days-active, volume) → Task 1 + Task 4. ✓
- Active-users list sortable → existing table + new columns (Task 4). ✓
- Per-user live charts (available signals, window selector) → Task 2 + Task 5. ✓
- Activity drill-down before/during/after for all 9 metrics + impact → Task 3 + Task 6. ✓
- `X-API-Key` gate on new endpoints (dashboard shell open) → inherited from the middleware; the new routes are under `/admin` and not in `_OPEN_PATHS`. ✓
- Live charts limited to `metric_samples` signals (advanced metrics via activity drill-down) → Global Constraints + Task 5 `LIVE_SIGNALS`. ✓

Names are consistent across tasks: endpoint paths (`/admin/users/{id}/metrics`, `/admin/activities/{id}`), response keys (`current_streak`, `days_active_7d`, `practiced_today`, `median_streak`), JS symbols (`LIVE_SIGNALS`, `loadUserMetrics`, `openActivity`, `ACT_METRICS`).

Deferred (not in this plan, per the outline): usage telemetry (sub-project 1), server deploy (sub-project 5), advanced live metrics in `metric_samples`.
