# SP5b — All-day continuous metric sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Continuously sync the app's stored HRV samples (14 metrics incl. Inner Noise/PIP) to the server when the user opts in, and expose aggregated views over them via MCP so Claude Code can answer "what happened to my Inner Noise today?".

**Architecture:** New `metric_samples` table (`(user_id, ts)` PK) + `POST /v1/metrics` batch-upsert (shared-key + `X-User-ID`, like `/sessions`) + `DELETE /v1/me/data` (Bearer). Three MCP tools return *aggregates* (never raw dumps). App gets an opt-in Settings toggle gating a `MetricSyncService` that incrementally uploads new `HRVSample`s.

**Tech Stack:** FastAPI, asyncpg, PostgreSQL, the MCP SDK, Swift/SwiftUI/SwiftData, XCTest.

## Global Constraints

- **Metric set = the 14 stored `HRVSample` fields:** `mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms, coherence, cbi, breath_bpm, dfa1, rcmse, pip, dc, vti`. (No "stress" column — it is derived, not stored.)
- **Server tests:** Python 3.13 venv `.venv313`, local Postgres `wythin_test`: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test .venv313/bin/pytest …`. Test fixtures init the DB pool directly (per SP3), never `LifespanManager`.
- **App:** build with `xcodebuild -project ios/Wythin.xcodeproj -scheme Wythin -destination 'generic/platform=iOS Simulator' -configuration Debug build`. No `.xcodeproj` change — new Swift lives in existing in-target files (`APIClient.swift`, and a new `MetricSyncService` appended to `APIClient.swift` or into `SyncService.swift` which is already in the target). SourceKit "cannot find … in scope" are false positives; only `xcodebuild` counts.
- **Isolation:** `/v1/metrics` scopes by `get_or_create_user(X-User-ID)`; MCP tools resolve `user_id` from the token, take no user_id arg, validate `metric` against an allowlist. `DELETE /v1/me/data` scopes by the Bearer token's user.
- **Opt-in:** the uploader runs only when `@AppStorage("cloudSyncEnabled")` is true (default false).
- Keep `from __future__ import annotations` in Python.

## File Structure

- Modify `server/db.py` — add `metric_samples` table.
- Modify `server/models.py` — `MetricSample`, `MetricsUpload`.
- Create `server/routers/metrics.py` — `POST /v1/metrics`.
- Modify `server/routers/me.py` — `DELETE /v1/me/data`.
- Modify `server/main.py` — include `metrics.router`.
- Modify `server/mcp_server.py` — `get_day_summary` / `get_metric_trend` / `get_metric_stats` (+ helpers, metric allowlist/aliases).
- Modify `server/tests/test_metrics.py` (new) and `server/tests/test_mcp.py`.
- Modify `ios/Wythin/Sync/APIClient.swift` — `uploadMetrics`, `MetricSyncService`.
- Modify `ios/Wythin/UI/Settings/SettingsView.swift` — opt-in toggle + "Delete my cloud data".
- Modify `ios/Wythin/App/AppEnvironment.swift` — drive `MetricSyncService` when enabled.

---

### Task 1: Server data layer — table, upload endpoint, erase

**Files:** Modify `server/db.py`, `server/models.py`, `server/routers/me.py`, `server/main.py`; Create `server/routers/metrics.py`, `server/tests/test_metrics.py`.

**Interfaces:**
- Produces: `POST /v1/metrics` `{samples:[…]}` → `{stored:int}`; `DELETE /v1/me/data` → `{metric_samples:int, sessions:int, activities:int}`; the `metric_samples` table.

- [ ] **Step 1: Add the table to `server/db.py` SCHEMA_SQL** (after the activities block)

```sql
CREATE TABLE IF NOT EXISTS metric_samples (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ts          TIMESTAMPTZ NOT NULL,
    mean_bpm REAL, rmssd REAL, sdnn REAL, pnn50 REAL, lf_hf REAL, rsa_ms REAL,
    coherence REAL, cbi REAL, breath_bpm REAL,
    dfa1 REAL, rcmse REAL, pip REAL, dc REAL, vti REAL,
    PRIMARY KEY (user_id, ts)
);
CREATE INDEX IF NOT EXISTS metric_samples_user_ts ON metric_samples(user_id, ts);
```

- [ ] **Step 2: Add models to `server/models.py`**

```python
class MetricSample(BaseModel):
    ts: str
    mean_bpm: Optional[float] = None
    rmssd: Optional[float] = None
    sdnn: Optional[float] = None
    pnn50: Optional[float] = None
    lf_hf: Optional[float] = None
    rsa_ms: Optional[float] = None
    coherence: Optional[float] = None
    cbi: Optional[float] = None
    breath_bpm: Optional[float] = None
    dfa1: Optional[float] = None
    rcmse: Optional[float] = None
    pip: Optional[float] = None
    dc: Optional[float] = None
    vti: Optional[float] = None

class MetricsUpload(BaseModel):
    samples: list[MetricSample]
```

- [ ] **Step 3: Write failing tests** — create `server/tests/test_metrics.py`

```python
from __future__ import annotations
from contextlib import asynccontextmanager
import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app

@asynccontextmanager
async def _client():
    from server.db import init_pool, close_pool, create_schema
    await init_pool(); await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            yield c
    finally:
        await close_pool()

def _sample(ts, pip):
    return {"ts": ts, "mean_bpm": 62.0, "rmssd": 40.0, "pip": pip, "dc": 7.5, "dfa1": 1.0, "vti": 3.9}

@pytest.mark.asyncio
async def test_upload_is_idempotent_and_scoped():
    async with _client() as c:
        body = {"samples": [_sample("2026-07-27T10:00:00Z", 30), _sample("2026-07-27T10:00:02Z", 31)]}
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-A"})
        assert r.status_code == 200 and r.json()["stored"] == 2
        # Re-post same ts → no duplicates (ON CONFLICT DO NOTHING)
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-A"})
        assert r.status_code == 200

@pytest.mark.asyncio
async def test_delete_my_data_scoped_to_token_user():
    async with _client() as c:
        await c.post("/v1/metrics", json={"samples": [_sample("2026-07-27T11:00:00Z", 30)]},
                     headers={"X-User-ID": "ms-del"})
        tok = (await c.post("/v1/tokens", json={"name": "t"}, headers={"X-User-ID": "ms-del"})).json()["token"]
        r = await c.delete("/v1/me/data", headers={"Authorization": f"Bearer {tok}"})
        assert r.status_code == 200
        assert r.json()["metric_samples"] >= 1
```

- [ ] **Step 4: Run — confirm fail**

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test .venv313/bin/pytest server/tests/test_metrics.py -v` → FAIL (404 / route missing).

- [ ] **Step 5: Create `server/routers/metrics.py`**

```python
"""POST /v1/metrics — batch upload of continuous HRV samples (opt-in cloud sync).
Shared-key gated; scoped to the caller's user via X-User-ID."""
from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException
from datetime import datetime

from ..db import get_pool, get_or_create_user
from ..models import MetricsUpload

router = APIRouter(prefix="/v1/metrics", tags=["metrics"])

_MAX_BATCH = 5000
_COLS = ["mean_bpm","rmssd","sdnn","pnn50","lf_hf","rsa_ms","coherence","cbi",
         "breath_bpm","dfa1","rcmse","pip","dc","vti"]


def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


@router.post("")
async def upload_metrics(body: MetricsUpload, x_user_id: str = Header(..., alias="X-User-ID")):
    if len(body.samples) > _MAX_BATCH:
        raise HTTPException(status_code=413, detail=f"max {_MAX_BATCH} samples per request")
    user_id = await get_or_create_user(x_user_id)
    rows = [
        tuple([user_id, _dt(s.ts)] + [getattr(s, c) for c in _COLS])
        for s in body.samples
    ]
    if not rows:
        return {"stored": 0}
    placeholders = ", ".join(f"${i}" for i in range(1, len(_COLS) + 3))
    sql = (
        f"INSERT INTO metric_samples (user_id, ts, {', '.join(_COLS)}) "
        f"VALUES ({placeholders}) ON CONFLICT (user_id, ts) DO NOTHING"
    )
    async with get_pool().acquire() as conn:
        await conn.executemany(sql, rows)
    return {"stored": len(rows)}
```

- [ ] **Step 6: Add `DELETE /v1/me/data` to `server/routers/me.py`**

```python
@router.delete("/data")
async def delete_my_data(user_id: str = Depends(current_user_id)):
    async with get_pool().acquire() as conn:
        async def _del(table: str) -> int:
            tag = await conn.execute(f"DELETE FROM {table} WHERE user_id = $1", user_id)
            return int(tag.split()[-1]) if tag.startswith("DELETE") else 0
        return {
            "metric_samples": await _del("metric_samples"),
            "sessions":       await _del("sessions"),
            "activities":     await _del("activities"),
        }
```

- [ ] **Step 7: Mount the router in `server/main.py`** — add `metrics` to the routers import and `app.include_router(metrics.router)`.

- [ ] **Step 8: Run tests + full suite — green**

Run: `DATABASE_URL=… .venv313/bin/pytest server/tests/ -v` → all pass.

- [ ] **Step 9: Commit**

```bash
git add server/db.py server/models.py server/routers/metrics.py server/routers/me.py server/main.py server/tests/test_metrics.py
git commit -m "feat(metrics): metric_samples table, POST /v1/metrics upsert, DELETE /v1/me/data"
```

---

### Task 2: MCP aggregate tools over metric_samples

**Files:** Modify `server/mcp_server.py`, `server/tests/test_mcp.py`.

**Interfaces:**
- Consumes: `metric_samples` (Task 1), `_auth`, `_parse_dt`, `get_pool`.
- Produces: tools `get_day_summary(date)`, `get_metric_trend(metric, since, until, buckets=60)`, `get_metric_stats(metric, since, until)`; helpers `_day_summary`, `_metric_trend`, `_metric_stats`; `_resolve_metric(name)`.

- [ ] **Step 1: Write failing tests** — append to `server/tests/test_mcp.py`

```python
@pytest.mark.asyncio
async def test_metric_tools_scope_and_aggregate():
    from server.db import get_or_create_user, get_pool
    from server.mcp_server import _day_summary, _metric_trend, _metric_stats
    import server.db as _  # ensure module import
    from server.db import init_pool, close_pool, create_schema
    await init_pool(); await create_schema()
    try:
        a = await get_or_create_user("mt-A"); b = await get_or_create_user("mt-B")
        async with get_pool().acquire() as conn:
            for i, pip in enumerate([40, 30, 20]):
                await conn.execute(
                    "INSERT INTO metric_samples (user_id, ts, pip, mean_bpm) VALUES ($1,$2,$3,$4) "
                    "ON CONFLICT DO NOTHING",
                    a, _parse_dt(f"2026-07-27T10:0{i}:00Z"), float(pip), 60.0)
        summ = await _day_summary(a, "2026-07-27")
        assert summ["pip"]["min"] == 20 and summ["pip"]["max"] == 40 and summ["pip"]["n"] == 3
        # user B sees nothing
        summ_b = await _day_summary(b, "2026-07-27")
        assert summ_b == {} or summ_b.get("pip", {}).get("n", 0) == 0
        stats = await _metric_stats(a, "inner_noise", "2026-07-27T00:00:00Z", "2026-07-28T00:00:00Z")
        assert stats["n"] == 3 and stats["min"] == 20
        trend = await _metric_trend(a, "pip", "2026-07-27T10:00:00Z", "2026-07-27T10:03:00Z", buckets=3)
        assert len(trend) >= 1
    finally:
        await close_pool()

def test_resolve_metric_alias_and_reject():
    from server.mcp_server import _resolve_metric
    assert _resolve_metric("inner_noise") == "pip"
    assert _resolve_metric("pip") == "pip"
    with pytest.raises(ValueError):
        _resolve_metric("; DROP TABLE")
```

(`_parse_dt` is already imported/available in `mcp_server`; import it in the test from `server.mcp_server`.)

- [ ] **Step 2: Run — confirm fail.** `… .venv313/bin/pytest server/tests/test_mcp.py -k metric -v` → FAIL.

- [ ] **Step 3: Add helpers + tools to `server/mcp_server.py`**

```python
_METRIC_COLS = {"mean_bpm","rmssd","sdnn","pnn50","lf_hf","rsa_ms","coherence",
                "cbi","breath_bpm","dfa1","rcmse","pip","dc","vti"}
_METRIC_ALIASES = {
    "hr": "mean_bpm", "heart_rate": "mean_bpm", "pulse": "mean_bpm",
    "inner_noise": "pip", "harmony": "dfa1", "vagal_tone": "dc",
    "calm_power": "vti", "hrv": "rmssd", "stress_balance": "lf_hf",
}

def _resolve_metric(name: str) -> str:
    key = (name or "").strip().lower()
    col = _METRIC_ALIASES.get(key, key)
    if col not in _METRIC_COLS:
        raise ValueError(f"unknown metric '{name}'; valid: {sorted(_METRIC_COLS | set(_METRIC_ALIASES))}")
    return col

def _day_bounds(date: str):
    start = datetime.fromisoformat(date).replace(tzinfo=timezone.utc)
    return start, start + timedelta(days=1)

async def _day_summary(user_id: str, date: str) -> dict:
    start, end = _day_bounds(date)
    aggs = ", ".join(f"avg({c}) a_{c}, min({c}) mn_{c}, max({c}) mx_{c}, count({c}) n_{c}" for c in sorted(_METRIC_COLS))
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            f"SELECT {aggs} FROM metric_samples WHERE user_id=$1 AND ts>=$2 AND ts<$3",
            user_id, start, end)
    out = {}
    for c in sorted(_METRIC_COLS):
        n = row[f"n_{c}"] or 0
        if n:
            out[c] = {"avg": round(row[f"a_{c}"], 3), "min": row[f"mn_{c}"], "max": row[f"mx_{c}"], "n": n}
    return out

async def _metric_stats(user_id: str, metric: str, since: str, until: str) -> dict:
    col = _resolve_metric(metric)
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            f"SELECT avg({col}) a, min({col}) mn, max({col}) mx, count({col}) n "
            f"FROM metric_samples WHERE user_id=$1 AND ts>=$2 AND ts<$3",
            user_id, _parse_dt(since), _parse_dt(until))
    return {"metric": col, "avg": round(row["a"], 3) if row["a"] is not None else None,
            "min": row["mn"], "max": row["mx"], "n": row["n"] or 0}

async def _metric_trend(user_id: str, metric: str, since: str, until: str, buckets: int = 60) -> list[dict]:
    col = _resolve_metric(metric)
    s, e = _parse_dt(since), _parse_dt(until)
    buckets = max(1, min(int(buckets), 500))
    span = max((e - s).total_seconds(), 1.0)
    width = span / buckets
    async with get_pool().acquire() as conn:
        rows = await conn.fetch(
            f"SELECT floor(extract(epoch from ts - $2) / $4)::int AS b, avg({col}) v "
            f"FROM metric_samples WHERE user_id=$1 AND ts>=$2 AND ts<$3 AND {col} IS NOT NULL "
            f"GROUP BY b ORDER BY b", user_id, s, e, width)
    return [{"t": (s + timedelta(seconds=r["b"] * width)).isoformat(), "value": round(r["v"], 3)} for r in rows]


@mcp.tool()
async def get_day_summary(ctx: Context, date: str) -> dict:
    """Per-metric avg/min/max/count for one UTC day (YYYY-MM-DD) of your data. Best for 'how was my X today'."""
    return await _day_summary(await _auth(ctx), date)

@mcp.tool()
async def get_metric_trend(ctx: Context, metric: str, since: str, until: str, buckets: int = 60) -> list[dict]:
    """Downsampled time series of one metric over [since, until) (ISO datetimes), ~`buckets` points. Metric accepts names/aliases like 'inner_noise', 'hr'."""
    return await _metric_trend(await _auth(ctx), metric, since, until, buckets)

@mcp.tool()
async def get_metric_stats(ctx: Context, metric: str, since: str, until: str) -> dict:
    """avg/min/max/count of one metric over [since, until). Good for comparisons across ranges."""
    return await _metric_stats(await _auth(ctx), metric, since, until)
```

Add imports at top of `mcp_server.py`: `from datetime import datetime, timedelta, timezone` (extend the existing datetime import). Update the registration test's expected tool set to include the three new names.

- [ ] **Step 4: Run tests + full suite — green.** `… .venv313/bin/pytest server/tests/ -v`.

- [ ] **Step 5: Commit**

```bash
git add server/mcp_server.py server/tests/test_mcp.py
git commit -m "feat(mcp): day-summary / metric-trend / metric-stats tools over metric_samples"
```

---

### Task 3: App — opt-in toggle + incremental uploader

**Files:** Modify `ios/Wythin/Sync/APIClient.swift`, `ios/Wythin/UI/Settings/SettingsView.swift`, `ios/Wythin/App/AppEnvironment.swift`.

**Interfaces:**
- Consumes: `APIConfig`, `request(...)`, `env.userID`, `HRVSample` (SwiftData), `env.sync.client`.
- Produces: `APIClient.uploadMetrics(_:userID:)`; `MetricSyncService`; Settings toggle + delete button.

- [ ] **Step 1: Add `uploadMetrics` + payload to `APIClient.swift`**

```swift
struct MetricSamplePayload: Codable {
    let ts: String
    let mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms: Float?
    let coherence, cbi, breath_bpm, dfa1, rcmse, pip, dc, vti: Float?
}
struct MetricsUploadPayload: Codable { let samples: [MetricSamplePayload] }
struct MetricsUploadResponse: Codable { let stored: Int }

extension APIClient {
    func uploadMetrics(_ payload: MetricsUploadPayload, userID: String) async throws -> MetricsUploadResponse {
        var req = request(path: "/v1/metrics", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(MetricsUploadResponse.self, from: data)
    }
    func deleteMyData(token: String) async throws {
        var req = request(path: "/v1/me/data", method: "DELETE")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: req)
    }
}
```

- [ ] **Step 2: Add `MetricSyncService`** (same file or a new section in APIClient.swift)

```swift
import SwiftData

@MainActor
final class MetricSyncService {
    private let client: APIClient
    private let userID: String
    private let container: ModelContainer
    @AppStorage("cloudSyncEnabled") private var enabled = false
    @AppStorage("metricsLastSyncedAt") private var lastSyncedISO = ""
    private let iso = ISO8601DateFormatter()
    private let batch = 2000

    init(client: APIClient, userID: String, container: ModelContainer) {
        self.client = client; self.userID = userID; self.container = container
    }

    func syncIfEnabled() async {
        guard enabled else { return }
        let after = iso.date(from: lastSyncedISO) ?? Date.distantPast
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp > after },
            sortBy: [SortDescriptor(\.timestamp)])
        desc.fetchLimit = batch
        guard let samples = try? ctx.fetch(desc), !samples.isEmpty else { return }
        let payload = MetricsUploadPayload(samples: samples.map { s in
            MetricSamplePayload(ts: iso.string(from: s.timestamp),
                mean_bpm: s.meanBPM, rmssd: s.rmssd, sdnn: s.sdnn, pnn50: s.pnn50,
                lf_hf: s.lfHF, rsa_ms: s.rsaMs, coherence: s.coherence, cbi: s.cbi,
                breath_bpm: s.breathBPM, dfa1: s.dfa1, rcmse: s.rcmse, pip: s.pip,
                dc: s.dc, vti: s.vti) })
        if (try? await client.uploadMetrics(payload, userID: userID)) != nil,
           let last = samples.last {
            lastSyncedISO = iso.string(from: last.timestamp)
        }
    }
}
```

- [ ] **Step 3: Drive it from `AppEnvironment`** — create a `MetricSyncService` alongside the other uploaders and call `await metricSync.syncIfEnabled()` on the existing periodic path (e.g., in the same place activity/session uploads are flushed, or a `Task` every ~120 s while active). Keep it best-effort (ignore failures).

- [ ] **Step 4: Settings — toggle + delete button** — in the CLAUDE CODE ACCESS section of `SettingsView.swift`:

```swift
Toggle(isOn: $cloudSyncEnabled) {
    VStack(alignment: .leading, spacing: 2) {
        Text("Sync my data to the cloud").font(Theme.monoBody).foregroundStyle(Theme.text)
        Text("Lets Claude Code read your continuous metrics. Off = data stays on this device.")
            .font(Theme.monoLabel).foregroundStyle(Theme.dim)
    }
}
.tint(Theme.accent)

if cloudSyncEnabled {
    Button(role: .destructive) { Task { await deleteCloudData() } } label: {
        Text("Delete my cloud data").font(Theme.monoBody).foregroundStyle(Theme.warn)
    }
}
```
with `@AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = false` and a `deleteCloudData()` that mints (or reuses) a token and calls `env.sync.client.deleteMyData(token:)`. (Simplest: create a short-lived token via `createToken`, call delete, then it can be revoked — or reuse the newest listed token. Implementer picks the clean path and notes it.)

- [ ] **Step 5: Build — `** BUILD SUCCEEDED **`.**

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Sync/APIClient.swift ios/Wythin/UI/Settings/SettingsView.swift ios/Wythin/App/AppEnvironment.swift
git commit -m "feat(sync): opt-in continuous metric upload + delete-my-cloud-data"
```

---

## Self-Review notes

- **Spec coverage:** raw 2s upsert table (T1), aggregate MCP tools incl. Inner Noise via `pip`/`inner_noise` alias (T2), opt-in toggle + uploader + erase (T3). Keep-forever = no prune. Rollup deferred.
- **Isolation:** `/v1/metrics` scoped by X-User-ID; MCP tools token-scoped, metric allowlisted (injection-safe); erase Bearer-scoped; cross-user tests in T1/T2.
- **Idempotency:** `ON CONFLICT (user_id, ts) DO NOTHING` + `lastSyncedAt` advance only on success.
- **Deploy note:** T1/T2 need a server deploy (create_schema adds the table); T3 ships with the next app build. Encryption-at-rest on Hetzner Postgres is a separate ops step.
