"""Bounded, missing-only repair of historical Stress Balance snapshots."""

async def backfill_stress_balance(pool, batch_size: int = 10000) -> int:
    batch_size = max(1, min(int(batch_size), 50000))
    total = 0
    for table in ('metric_samples', 'hrv_samples'):
        while True:
            # Each statement commits one bounded batch. No receipt timestamps,
            # original measurements or already captured snapshots are changed.
            count = await pool.fetchval(f"""
                WITH candidates AS (
                    SELECT ctid, wythin_stress_balance(rmssd, lf_hf, breath_bpm) AS value
                    FROM {table}
                    WHERE stress_balance IS NULL
                      AND wythin_stress_balance(rmssd, lf_hf, breath_bpm) IS NOT NULL
                    LIMIT $1 FOR UPDATE
                ), updated AS (
                    UPDATE {table} AS target SET stress_balance = candidates.value
                    FROM candidates WHERE target.ctid = candidates.ctid
                    RETURNING 1
                ) SELECT count(*) FROM updated
            """, batch_size)
            total += count
            if count < batch_size:
                break
    return total
