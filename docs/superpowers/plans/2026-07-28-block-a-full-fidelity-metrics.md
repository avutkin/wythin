# Block A — Full-Fidelity Metric Samples Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry all 26 of `HRVSample`'s metric fields from the device to `metric_samples` and make every one of them queryable through the MCP server, including a one-time backfill that enriches already-uploaded rows.

**Architecture:** Widen the server table and the Pydantic model by 12 columns, flip `/v1/metrics` from a discarding upsert to an enriching one, extend the MCP metric allowlist, then widen the iOS payload and add a backfill drain mode that re-walks local history at a usable rate.

**Tech Stack:** FastAPI + asyncpg + PostgreSQL (server), pytest + httpx `ASGITransport` (server tests), SwiftUI + SwiftData (app), XCTest (app tests).

**Spec:** `docs/superpowers/specs/2026-07-28-complete-data-capture-design.md`, Block A.

## Release requirement — server must deploy BEFORE the app ships

**The server migration (widened `metric_samples` schema + enriching upsert) must be deployed and restarted before the app build containing the widened 26-field payload and backfill drain ships.**

Why this ordering is load-bearing, not just nice-to-have: `server/models.py`'s `MetricSample` has no `extra='forbid'`. A device running the new app against an unmigrated server does not get an error — it gets `200 {"stored": N}`, with the 12 new fields silently dropped by Pydantic before they ever reach the INSERT. The backfill drain has no way to detect this: from its point of view the upload succeeded, so it keeps draining, eventually completes, and stamps `metricsSyncSchemaVersion = MetricSyncService.currentSchemaVersion`. That stamp is permanent — the backfill is one-time by design. The device's history is now silently and permanently missing the 12 new columns, and it will never re-walk its local store to fix that.

**Escape hatch if the ordering is ever violated:** bump `MetricSyncService.currentSchemaVersion` (in `ios/Wythin/Sync/APIClient.swift`) in a follow-up app release. `needsBackfill(storedVersion:)` compares the device's stamped version against this constant, so incrementing it forces every device — including ones that already "completed" a backfill against the unmigrated server — to re-walk local history and re-upload once the server is actually caught up.

## Global Constraints

- **Work happens in the worktree `/Users/alexutkin/.claude/worktrees/block-a-metrics` on branch `feat/block-a-full-fidelity-metrics`.** Run every command from that directory. The main checkout at `/Users/alexutkin` has unrelated uncommitted work in these same files — do not touch it.
- Server tests run with: `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka /Users/alexutkin/.venv313/bin/python -m pytest <path> -v`. This database is dedicated to this worktree and already exists; baseline is 40 passed, 0 failed.
- Do NOT use the `wythin_test` database. It is shared with the main checkout, accumulates rows between runs, and currently fails `test_mcp.py::test_tool_helpers_scope_to_user` for that reason.
- Never use `/Users/alexutkin/.venv` — it is Python 3.9 and lacks the deps. Use `.venv313`.
- `metric_samples` already exists in production. New columns MUST be added via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` in `SCHEMA_SQL`, not only by editing the `CREATE TABLE` (which is `IF NOT EXISTS` and therefore a no-op on existing databases).
- The 12 new columns, in this exact order and spelling, used identically in `db.py`, `models.py`, `routers/metrics.py`, `mcp_server.py`, and the Swift payload: `rsa_idx`, `ie_ratio`, `ials`, `motion`, `signal_quality`, `rr_invalid_rate`, `rr_corrected_rate`, `ecg_quality_tier`, `ulf_power`, `vlf_power`, `lf_power`, `hf_power`.
- All are `REAL` except `ecg_quality_tier`, which is `INT` (Swift `Int?`, Pydantic `Optional[int]`).
- Every MCP tool resolves `user_id` from the Bearer token via `_auth(ctx)` and accepts no `user_id` argument. Do not add one.
- iOS builds verify with: `xcodebuild -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` and tests with the same command using `test` instead of `build`. There is no `iPhone 16` simulator on this machine — use `iPhone 17 Pro`.
- **The iOS baseline is RED before this plan starts: 167 tests, 3 assertion failures across 2 test methods** — `BLETests.testECGFrameParsing` (ECG frame parsing) and `MetricsTests.testBreathingRateInBand` (breathing-rate FFT, 2 assertions). Both are pre-existing on this branch and touch code no task here modifies. Do NOT fix them; they are out of scope. Success for an iOS task means: your new tests pass, and the full-suite failure count is still exactly those same 3 assertions in those same 2 methods. Any new failure elsewhere is yours.

---

### Task 1: Server schema — 12 new columns

**Files:**
- Modify: `server/db.py:102-110` (the `metric_samples` block in `SCHEMA_SQL`)
- Modify: `server/models.py:62-77` (`MetricSample`)
- Test: `server/tests/test_metrics.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `metric_samples` columns `rsa_idx, ie_ratio, ials, motion, signal_quality, rr_invalid_rate, rr_corrected_rate, ecg_quality_tier, ulf_power, vlf_power, lf_power, hf_power`; `MetricSample` Pydantic fields of the same names. Task 2 writes them, Task 3 reads them.

- [ ] **Step 1: Write the failing test**

Add to `server/tests/test_metrics.py`:

```python
_NEW_COLS = ["rsa_idx", "ie_ratio", "ials", "motion", "signal_quality",
             "rr_invalid_rate", "rr_corrected_rate", "ecg_quality_tier",
             "ulf_power", "vlf_power", "lf_power", "hf_power"]


@pytest.mark.asyncio
async def test_new_metric_columns_exist_and_round_trip():
    from server.db import get_pool
    async with _client() as c:
        body = {"samples": [{
            "ts": "2026-07-28T09:00:00Z",
            "mean_bpm": 61.0,
            "rsa_idx": 0.42, "ie_ratio": 1.6, "ials": 0.21, "motion": 12.5,
            "signal_quality": 0.93, "rr_invalid_rate": 0.01,
            "rr_corrected_rate": 0.02, "ecg_quality_tier": 2,
            "ulf_power": 100.0, "vlf_power": 200.0,
            "lf_power": 300.0, "hf_power": 400.0,
        }]}
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-wide"})
        assert r.status_code == 200, r.text

        async with get_pool().acquire() as conn:
            row = await conn.fetchrow(
                "SELECT " + ", ".join(_NEW_COLS) + " FROM metric_samples ms "
                "JOIN users u ON u.id = ms.user_id "
                "WHERE u.device_id = 'ms-wide' AND ms.ts = '2026-07-28T09:00:00Z'")
        assert row is not None, "sample row was not stored"
        assert row["motion"] == pytest.approx(12.5)
        assert row["ecg_quality_tier"] == 2
        assert row["hf_power"] == pytest.approx(400.0)
        assert row["signal_quality"] == pytest.approx(0.93)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka /Users/alexutkin/.venv313/bin/python -m pytest server/tests/test_metrics.py::test_new_metric_columns_exist_and_round_trip -v`

Expected: FAIL — `asyncpg.exceptions.UndefinedColumnError: column "rsa_idx" does not exist`.

- [ ] **Step 3: Add the columns to the schema**

In `server/db.py`, replace the `metric_samples` block with:

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

-- Block A: the 12 fields HRVSample carries that the original 14-column payload
-- dropped. ALTER (not just the CREATE above) because the table already exists
-- in production, where CREATE TABLE IF NOT EXISTS is a no-op.
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS rsa_idx           REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS ie_ratio          REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS ials              REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS motion            REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS signal_quality    REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS rr_invalid_rate   REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS rr_corrected_rate REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS ecg_quality_tier  INT;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS ulf_power         REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS vlf_power         REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS lf_power          REAL;
ALTER TABLE metric_samples ADD COLUMN IF NOT EXISTS hf_power          REAL;
```

- [ ] **Step 4: Add the fields to the Pydantic model**

In `server/models.py`, append to `class MetricSample` (after `vti`):

```python
    rsa_idx: Optional[float] = None
    ie_ratio: Optional[float] = None
    ials: Optional[float] = None
    motion: Optional[float] = None
    signal_quality: Optional[float] = None
    rr_invalid_rate: Optional[float] = None
    rr_corrected_rate: Optional[float] = None
    ecg_quality_tier: Optional[int] = None
    ulf_power: Optional[float] = None
    vlf_power: Optional[float] = None
    lf_power: Optional[float] = None
    hf_power: Optional[float] = None
```

- [ ] **Step 5: Extend the insert column list**

In `server/routers/metrics.py:14-15`, replace `_COLS` with:

```python
_COLS = ["mean_bpm","rmssd","sdnn","pnn50","lf_hf","rsa_ms","coherence","cbi",
         "breath_bpm","dfa1","rcmse","pip","dc","vti",
         "rsa_idx","ie_ratio","ials","motion","signal_quality",
         "rr_invalid_rate","rr_corrected_rate","ecg_quality_tier",
         "ulf_power","vlf_power","lf_power","hf_power"]
```

No other change to that file in this task — the `placeholders` expression already derives its width from `len(_COLS)`.

- [ ] **Step 6: Run the test to verify it passes**

Run: `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka /Users/alexutkin/.venv313/bin/python -m pytest server/tests/test_metrics.py -v`

Expected: PASS, all tests in the file (the two pre-existing ones must still pass).

- [ ] **Step 7: Commit**

```bash
git add server/db.py server/models.py server/routers/metrics.py server/tests/test_metrics.py
git commit -m "feat(metrics): widen metric_samples to all 26 HRVSample fields"
```

---

### Task 2: Enriching upsert

Re-uploading an existing `(user_id, ts)` currently hits `ON CONFLICT DO NOTHING` and is silently discarded. The Task 5 backfill re-sends rows that are already stored, so without this change the backfill is a no-op. Use `COALESCE(EXCLUDED.col, metric_samples.col)` rather than a bare `EXCLUDED.col`: a later upload that omits a field must not erase a value an earlier upload provided.

**Files:**
- Modify: `server/routers/metrics.py:33-37`
- Test: `server/tests/test_metrics.py`

**Interfaces:**
- Consumes: `_COLS` from Task 1.
- Produces: `POST /v1/metrics` enriches existing rows in place. Task 5's backfill depends on this.

- [ ] **Step 1: Write the failing test**

Add to `server/tests/test_metrics.py`:

```python
@pytest.mark.asyncio
async def test_reupload_enriches_without_erasing():
    from server.db import get_pool
    ts = "2026-07-28T09:30:00Z"
    async with _client() as c:
        # First upload: the old 14-field shape (no motion, no quality).
        await c.post("/v1/metrics", headers={"X-User-ID": "ms-enrich"},
                     json={"samples": [{"ts": ts, "mean_bpm": 60.0, "rmssd": 41.0}]})
        # Second upload: same ts, adds the new fields, omits rmssd entirely.
        await c.post("/v1/metrics", headers={"X-User-ID": "ms-enrich"},
                     json={"samples": [{"ts": ts, "mean_bpm": 60.0,
                                        "motion": 8.25, "ecg_quality_tier": 1}]})

        async with get_pool().acquire() as conn:
            row = await conn.fetchrow(
                "SELECT rmssd, motion, ecg_quality_tier FROM metric_samples ms "
                "JOIN users u ON u.id = ms.user_id "
                "WHERE u.device_id = 'ms-enrich' AND ms.ts = $1",
                __import__("datetime").datetime.fromisoformat(ts.replace("Z", "+00:00")))
        assert row["motion"] == pytest.approx(8.25), "new field was not written on conflict"
        assert row["ecg_quality_tier"] == 1
        assert row["rmssd"] == pytest.approx(41.0), "omitted field was erased by the re-upload"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka /Users/alexutkin/.venv313/bin/python -m pytest server/tests/test_metrics.py::test_reupload_enriches_without_erasing -v`

Expected: FAIL — `assert None == approx(8.25)`, because `DO NOTHING` discarded the second upload.

- [ ] **Step 3: Switch to an enriching upsert**

In `server/routers/metrics.py`, replace the `sql` assignment (currently lines 33-37) with:

```python
    placeholders = ", ".join(f"${i}" for i in range(1, len(_COLS) + 3))
    # COALESCE, not a bare EXCLUDED: a re-upload that omits a column must leave
    # the stored value alone. Bare EXCLUDED would null it out.
    updates = ", ".join(
        f"{c} = COALESCE(EXCLUDED.{c}, metric_samples.{c})" for c in _COLS
    )
    sql = (
        f"INSERT INTO metric_samples (user_id, ts, {', '.join(_COLS)}) "
        f"VALUES ({placeholders}) "
        f"ON CONFLICT (user_id, ts) DO UPDATE SET {updates}"
    )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka /Users/alexutkin/.venv313/bin/python -m pytest server/tests/test_metrics.py -v`

Expected: PASS — 4 tests. `test_upload_is_idempotent_and_scoped` must still pass (an unchanged re-upload is still a no-op in effect).

- [ ] **Step 5: Commit**

```bash
git add server/routers/metrics.py server/tests/test_metrics.py
git commit -m "feat(metrics): enriching upsert so re-uploads fill new columns"
```

---

### Task 3: MCP exposure of the new metrics

**Files:**
- Modify: `server/mcp_server.py:165-171` (`_METRIC_COLS`, `_METRIC_ALIASES`)
- Test: `server/tests/test_mcp.py`

**Interfaces:**
- Consumes: the columns from Task 1.
- Produces: `_resolve_metric(name)` accepts all 26 column names plus the aliases `stillness`, `quality`, `breathing_ratio`, `fragmentation`. `get_day_summary` / `get_metric_trend` / `get_metric_stats` cover all 26.

- [ ] **Step 1: Write the failing test**

Add to `server/tests/test_mcp.py`:

```python
@pytest.mark.asyncio
async def test_new_metrics_resolve_and_aggregate():
    from server.db import get_or_create_user
    from server.mcp_server import _resolve_metric, _metric_stats, _day_summary
    async with _client() as c:
        # Column names resolve directly.
        assert _resolve_metric("motion") == "motion"
        assert _resolve_metric("hf_power") == "hf_power"
        assert _resolve_metric("ecg_quality_tier") == "ecg_quality_tier"
        # Friendly aliases resolve to columns.
        assert _resolve_metric("stillness") == "motion"
        assert _resolve_metric("quality") == "signal_quality"
        assert _resolve_metric("breathing_ratio") == "ie_ratio"
        assert _resolve_metric("fragmentation") == "ials"
        # Unknown names are still rejected (no SQL-column injection).
        with pytest.raises(ValueError):
            _resolve_metric("motion; DROP TABLE users")

        await c.post("/v1/metrics", headers={"X-User-ID": "mcp-wide"}, json={"samples": [
            {"ts": "2026-07-28T12:00:00Z", "motion": 10.0, "signal_quality": 0.9},
            {"ts": "2026-07-28T12:00:02Z", "motion": 20.0, "signal_quality": 0.8},
        ]})
        uid = await get_or_create_user("mcp-wide")

        stats = await _metric_stats(uid, "stillness",
                                    "2026-07-28T00:00:00Z", "2026-07-29T00:00:00Z")
        assert stats["metric"] == "motion"
        assert stats["n"] == 2
        assert stats["avg"] == pytest.approx(15.0)

        summary = await _day_summary(uid, "2026-07-28")
        assert "motion" in summary, "day summary must cover the new columns"
        assert summary["signal_quality"]["n"] == 2
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka /Users/alexutkin/.venv313/bin/python -m pytest server/tests/test_mcp.py::test_new_metrics_resolve_and_aggregate -v`

Expected: FAIL — `ValueError: unknown metric 'motion'`.

- [ ] **Step 3: Extend the allowlist and aliases**

In `server/mcp_server.py`, replace `_METRIC_COLS` and `_METRIC_ALIASES` with:

```python
_METRIC_COLS = {"mean_bpm", "rmssd", "sdnn", "pnn50", "lf_hf", "rsa_ms", "coherence",
                "cbi", "breath_bpm", "dfa1", "rcmse", "pip", "dc", "vti",
                "rsa_idx", "ie_ratio", "ials", "motion", "signal_quality",
                "rr_invalid_rate", "rr_corrected_rate", "ecg_quality_tier",
                "ulf_power", "vlf_power", "lf_power", "hf_power"}
_METRIC_ALIASES = {
    "hr": "mean_bpm", "heart_rate": "mean_bpm", "pulse": "mean_bpm",
    "inner_noise": "pip", "harmony": "dfa1", "vagal_tone": "dc",
    "calm_power": "vti", "hrv": "rmssd", "stress_balance": "lf_hf",
    "stillness": "motion", "quality": "signal_quality",
    "breathing_ratio": "ie_ratio", "fragmentation": "ials",
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka /Users/alexutkin/.venv313/bin/python -m pytest server/tests/test_mcp.py -v`

Expected: PASS — all tests in the file.

- [ ] **Step 5: Run the whole server suite**

Run: `DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka /Users/alexutkin/.venv313/bin/python -m pytest server/tests -v`

Expected: PASS, except `server/tests/test_usage.py`, which is a pre-existing red suite for Block E (no `/v1/usage` router exists yet). Do not fix it here.

- [ ] **Step 6: Commit**

```bash
git add server/mcp_server.py server/tests/test_mcp.py
git commit -m "feat(mcp): expose all 26 metric columns with friendly aliases"
```

---

### Task 4: iOS payload carries all 26 fields

`MetricSamplePayload` is built inline inside `MetricSyncService.syncIfEnabled` today, which makes the mapping untestable. Move it to an `init(from:)` extension, matching the existing `SamplePayload.init(from:)` pattern at `APIClient.swift:414`.

**Files:**
- Modify: `ios/Wythin/Models/HRVSample.swift` (add a field-wise initializer)
- Modify: `ios/Wythin/Sync/APIClient.swift:170-174` (`MetricSamplePayload`), `:365-370` (the inline mapping)
- Test: `ios/WythinTests/PayloadBuilderTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks (the server accepts these fields after Task 1).
- Produces: `HRVSample.init(timestamp: Date)` and `MetricSamplePayload.init(from s: HRVSample, iso: ISO8601DateFormatter)`. Task 5 calls the latter.

- [ ] **Step 1: Add a field-wise initializer to HRVSample**

`HRVSample` currently has only `init(from tick: MetricsTick)`, and `MetricsTick` has ~30 non-defaulted `let` fields — so a test cannot construct a sample without an unreadable 30-argument literal. Add a second designated initializer inside the class body of `ios/Wythin/Models/HRVSample.swift`, directly above `init(from tick:)`:

```swift
    /// Timestamp-only initializer. Every metric property is an optional `var`
    /// and therefore defaults to nil, so callers set only the fields they care
    /// about. Used by tests and by any construction path that isn't a tick.
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
```

- [ ] **Step 2: Write the failing test**

Add to `ios/WythinTests/PayloadBuilderTests.swift`:

```swift
    func testMetricSamplePayloadCarriesAll26Fields() {
        let sample = HRVSample(timestamp: Date())
        sample.meanBPM = 62; sample.rmssd = 41; sample.sdnn = 55; sample.pnn50 = 12
        sample.lfHF = 1.4; sample.rsaMs = 30; sample.rsaIdx = 0.42; sample.coherence = 0.7
        sample.cbi = 0.5; sample.breathBPM = 6; sample.ieRatio = 1.6; sample.dfa1 = 1.0
        sample.rcmse = 2.1; sample.pip = 33; sample.ials = 0.21; sample.dc = 7.5
        sample.vti = 3.9; sample.motion = 12.5; sample.signalQuality = 0.93
        sample.rrInvalidRate = 0.01; sample.rrCorrectedRate = 0.02; sample.ecgQualityTier = 2
        sample.ulfPower = 100; sample.vlfPower = 200; sample.lfPower = 300; sample.hfPower = 400

        let payload = MetricSamplePayload(from: sample, iso: ISO8601DateFormatter())

        XCTAssertEqual(payload.rsa_idx, 0.42)
        XCTAssertEqual(payload.ie_ratio, 1.6)
        XCTAssertEqual(payload.ials, 0.21)
        XCTAssertEqual(payload.motion, 12.5)
        XCTAssertEqual(payload.signal_quality, 0.93)
        XCTAssertEqual(payload.rr_invalid_rate, 0.01)
        XCTAssertEqual(payload.rr_corrected_rate, 0.02)
        XCTAssertEqual(payload.ecg_quality_tier, 2)
        XCTAssertEqual(payload.ulf_power, 100)
        XCTAssertEqual(payload.vlf_power, 200)
        XCTAssertEqual(payload.lf_power, 300)
        XCTAssertEqual(payload.hf_power, 400)
        // The original 14 must survive the refactor.
        XCTAssertEqual(payload.mean_bpm, 62)
        XCTAssertEqual(payload.vti, 3.9)
    }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:WythinTests/PayloadBuilderTests 2>&1 | tail -20`

Expected: FAIL to compile — `value of type 'MetricSamplePayload' has no member 'motion'`.

- [ ] **Step 4: Widen the payload struct**

In `ios/Wythin/Sync/APIClient.swift`, replace the `MetricSamplePayload` declaration with:

```swift
struct MetricSamplePayload: Codable {
    let ts: String
    let mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms: Float?
    let coherence, cbi, breath_bpm, dfa1, rcmse, pip, dc, vti: Float?
    // Block A: the fields the original 14-field payload dropped — the four
    // spectral bands, motion, and the four signal-quality fields. Without the
    // quality fields a reader cannot tell a real reading from a strap-off artifact.
    let rsa_idx, ie_ratio, ials, motion: Float?
    let signal_quality, rr_invalid_rate, rr_corrected_rate: Float?
    let ecg_quality_tier: Int?
    let ulf_power, vlf_power, lf_power, hf_power: Float?
}
```

- [ ] **Step 5: Add the testable mapping**

In `ios/Wythin/Sync/APIClient.swift`, directly below the `extension SamplePayload { ... }` block, add:

```swift
extension MetricSamplePayload {
    init(from s: HRVSample, iso: ISO8601DateFormatter) {
        self.ts = iso.string(from: s.timestamp)
        self.mean_bpm = s.meanBPM; self.rmssd = s.rmssd; self.sdnn = s.sdnn
        self.pnn50 = s.pnn50; self.lf_hf = s.lfHF; self.rsa_ms = s.rsaMs
        self.coherence = s.coherence; self.cbi = s.cbi; self.breath_bpm = s.breathBPM
        self.dfa1 = s.dfa1; self.rcmse = s.rcmse; self.pip = s.pip
        self.dc = s.dc; self.vti = s.vti
        self.rsa_idx = s.rsaIdx; self.ie_ratio = s.ieRatio
        self.ials = s.ials; self.motion = s.motion
        self.signal_quality = s.signalQuality
        self.rr_invalid_rate = s.rrInvalidRate
        self.rr_corrected_rate = s.rrCorrectedRate
        self.ecg_quality_tier = s.ecgQualityTier
        self.ulf_power = s.ulfPower; self.vlf_power = s.vlfPower
        self.lf_power = s.lfPower; self.hf_power = s.hfPower
    }
}
```

- [ ] **Step 6: Use it in the uploader**

In `ios/Wythin/Sync/APIClient.swift`, inside `MetricSyncService.syncIfEnabled`, replace the `let payload = MetricsUploadPayload(samples: samples.map { s in ... })` block with:

```swift
        let payload = MetricsUploadPayload(
            samples: samples.map { MetricSamplePayload(from: $0, iso: iso) })
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `xcodebuild -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:WythinTests/PayloadBuilderTests 2>&1 | tail -20`

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add ios/Wythin/Models/HRVSample.swift ios/Wythin/Sync/APIClient.swift ios/WythinTests/PayloadBuilderTests.swift
git commit -m "feat(sync): upload all 26 metric fields via a testable payload builder"
```

---

### Task 5: Backfill drain mode

The normal uploader sends 2,000 rows per tick-driven pass, throttled to one pass per 120 s (`AppEnvironment.swift:404`). At 43,200 ticks/day that is roughly 21 hours of foreground time per month of history — unusable for a backfill. Backfill therefore runs as a distinct mode: batches of 5,000 (the server's `_MAX_BATCH`) loop back-to-back with no throttle until the store is drained.

**Files:**
- Modify: `ios/Wythin/Sync/APIClient.swift:324-376` (`MetricSyncService`)
- Test: `ios/WythinTests/MetricSyncBackfillTests.swift` (create)

**Interfaces:**
- Consumes: `MetricSamplePayload.init(from:iso:)` from Task 4; the enriching upsert from Task 2.
- Produces: `MetricSyncService.currentSchemaVersion` (`static let`, value `1`) and `MetricSyncService.needsBackfill(storedVersion:)` — a pure static function the test drives without network or SwiftData.

- [ ] **Step 1: Write the failing test**

Create `ios/WythinTests/MetricSyncBackfillTests.swift`:

```swift
import XCTest
@testable import Wythin

final class MetricSyncBackfillTests: XCTestCase {

    func testBackfillTriggersBelowCurrentSchemaVersion() {
        XCTAssertTrue(MetricSyncService.needsBackfill(storedVersion: 0),
                      "a device that never ran the widened payload must backfill")
        XCTAssertFalse(MetricSyncService.needsBackfill(storedVersion: MetricSyncService.currentSchemaVersion),
                       "an up-to-date device must not backfill again")
        XCTAssertFalse(MetricSyncService.needsBackfill(storedVersion: MetricSyncService.currentSchemaVersion + 1),
                       "a newer stored version must not trigger a downgrade backfill")
    }

    func testBackfillBatchIsLargerThanNormalBatch() {
        XCTAssertGreaterThan(MetricSyncService.backfillBatchSize, MetricSyncService.normalBatchSize)
        XCTAssertLessThanOrEqual(MetricSyncService.backfillBatchSize, 5000,
                                 "server rejects batches over its 5000-sample cap with 413")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:WythinTests/MetricSyncBackfillTests 2>&1 | tail -20`

Expected: FAIL to compile — `type 'MetricSyncService' has no member 'needsBackfill'`.

- [ ] **Step 3: Add the version constants and predicate**

In `ios/Wythin/Sync/APIClient.swift`, inside `final class MetricSyncService`, delete the line `private let batch = 2000` and add in its place:

```swift
    /// Bumped whenever the uploaded payload gains fields. A device whose stored
    /// version is lower re-walks its local history once so already-uploaded rows
    /// gain the new columns (the server upsert enriches in place).
    static let currentSchemaVersion = 1
    static let normalBatchSize = 2000
    /// The server rejects more than 5000 samples per request with 413.
    static let backfillBatchSize = 5000

    static func needsBackfill(storedVersion: Int) -> Bool {
        storedVersion < currentSchemaVersion
    }

    @AppStorage("metricsSyncSchemaVersion") private var storedSchemaVersion = 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:WythinTests/MetricSyncBackfillTests 2>&1 | tail -20`

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Implement the drain loop**

In `ios/Wythin/Sync/APIClient.swift`, replace the body of `syncIfEnabled` from `let after = iso.date(...)` to the end of the method with:

```swift
        // A device that has never uploaded the widened payload re-walks its
        // whole local history once. Reset the watermark, then drain.
        let backfilling = Self.needsBackfill(storedVersion: storedSchemaVersion)
        if backfilling { lastSyncedISO = "" }

        let batchSize = backfilling ? Self.backfillBatchSize : Self.normalBatchSize
        var drained = false

        // Normal passes send one batch and wait for the next tick-driven call.
        // Backfill loops until the store is drained — at one batch per 120 s a
        // month of 2 s ticks would take ~21 h of foreground time.
        repeat {
            let after = iso.date(from: lastSyncedISO) ?? Date.distantPast
            let ctx = ModelContext(container)
            var desc = FetchDescriptor<HRVSample>(
                predicate: #Predicate { $0.timestamp > after },
                sortBy: [SortDescriptor(\.timestamp)])
            desc.fetchLimit = batchSize
            guard let samples = try? ctx.fetch(desc), !samples.isEmpty else {
                drained = true
                break
            }
            let payload = MetricsUploadPayload(
                samples: samples.map { MetricSamplePayload(from: $0, iso: iso) })
            guard (try? await client.uploadMetrics(payload, userID: userID)) != nil,
                  let last = samples.last else {
                // Leave the watermark where it is; the next pass retries.
                break
            }
            lastSyncedISO = iso.string(from: last.timestamp)
            if samples.count < batchSize { drained = true }
            await Task.yield()   // don't monopolise the main actor
        } while backfilling && !drained

        // Only stamp the version once the history is fully drained, so an
        // interrupted backfill resumes on the next pass instead of being lost.
        if backfilling && drained {
            storedSchemaVersion = Self.currentSchemaVersion
        }
```

- [ ] **Step 6: Verify the app builds and the full test suite passes**

Run: `xcodebuild -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | tail -20`

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add ios/Wythin/Sync/APIClient.swift ios/WythinTests/MetricSyncBackfillTests.swift
git commit -m "feat(sync): one-time backfill drain so stored rows gain the new fields"
```

---

### Task 6: End-to-end verification

**Files:**
- Test: manual, against the local server.

- [ ] **Step 1: Start the local server**

```bash
cd /Users/alexutkin/.claude/worktrees/block-a-metrics && DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka \
  /Users/alexutkin/.venv313/bin/python -m uvicorn server.main:app --port 8000
```

- [ ] **Step 2: Post a 26-field sample and read it back through the MCP helper**

```bash
curl -s -X POST localhost:8000/v1/metrics \
  -H 'Content-Type: application/json' \
  -H 'X-User-ID: e2e-block-a' \
  -H "X-API-Key: $(grep -o 'apiKey = "[^"]*"' ios/Wythin/Sync/APIClient.swift | cut -d'"' -f2)" \
  -d '{"samples":[{"ts":"2026-07-28T15:00:00Z","mean_bpm":61,"motion":9.5,"signal_quality":0.88,"hf_power":410,"ecg_quality_tier":2}]}'
```

Expected: `{"stored":1}`.

- [ ] **Step 3: Confirm the new columns are queryable**

```bash
DATABASE_URL=postgresql://postgres@localhost:5432/wythin_test_blocka /Users/alexutkin/.venv313/bin/python -c "
import asyncio
from server.db import init_pool, get_or_create_user
from server.mcp_server import _day_summary
async def main():
    await init_pool()
    uid = await get_or_create_user('e2e-block-a')
    print(await _day_summary(uid, '2026-07-28'))
asyncio.run(main())"
```

Expected: a dict containing `motion`, `signal_quality`, `hf_power`, and `ecg_quality_tier` entries.

- [ ] **Step 4: Confirm the working tree is clean**

```bash
git status --short
```

Expected: clean (all work already committed in Tasks 1-5).

---

## Notes for the implementer

- **Do not touch `server/tests/test_usage.py`.** It is an untracked, pre-written red suite for Block E; `/v1/usage` does not exist yet. It will fail on every full-suite run during this plan. That is expected.
- **`server/models.py` and `server/db.py` have uncommitted changes** from earlier work on this branch. Stage only the hunks this plan describes; do not `git add -A`.
- **Why `COALESCE` in Task 2 matters:** the backfill re-sends historical rows from `HRVSample`. If a field was never computed for an old tick it arrives as `null`, and a bare `EXCLUDED.col` would overwrite a good stored value with `null`.
- **Why the version stamp lands last (Task 5, Step 5):** stamping before the drain completes would strand a partially-backfilled device — it would never retry, and its older rows would keep NULLs permanently.
