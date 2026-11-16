"""Daily incremental signal audit. Run with python -m server.raw_worker.

Each chunk is bounded and independently committed. Failures retry the next day;
no raw source is deleted. No external AI calls occur in this worker.
"""
from __future__ import annotations
import asyncio
import json
import logging
import time
from collections import Counter
from fastapi import HTTPException
from starlette.concurrency import run_in_threadpool
from . import archive_store, db
from .raw_analysis import VERSION, analyze_chunk
from .routers.raw import lock_archive_user

log = logging.getLogger(__name__)


async def process_chunk(user, chunk):
    async with db.get_pool().acquire() as conn, conn.transaction():
        await lock_archive_user(conn, user)
        consent = await conn.fetchval('SELECT enabled FROM raw_consents WHERE user_id=$1',user)
        if consent is not True:
            return 'not_consented'
        source = await conn.fetchrow('SELECT sha256,storage_backend FROM raw_chunks WHERE user_id=$1 AND chunk_id=$2',user,chunk)
        if source is None:
            return 'deleted'
        existing = await conn.fetchrow('SELECT source_sha256,result FROM raw_analysis WHERE user_id=$1 AND chunk_id=$2 AND algorithm_version=$3',user,chunk,VERSION)
        if existing and existing['result'] is not None and existing['source_sha256'] == source['sha256']:
            return 'already_processed'
        result = error = None
        try:
            store = archive_store.get_archive(source['storage_backend'])
            payload = await run_in_threadpool(store.get,user,chunk,source['sha256'])
            result = await run_in_threadpool(analyze_chunk,payload)
        except HTTPException:
            error = 'source_unavailable'
        except ValueError:
            error = 'invalid_journal'
        await conn.execute('''INSERT INTO raw_analysis
            (user_id,chunk_id,algorithm_version,source_sha256,result,error_code,retry_after)
            VALUES ($1,$2,$3,$4,$5::jsonb,$6,CASE WHEN $6::text IS NULL THEN NULL ELSE NOW()+INTERVAL '1 day' END)
            ON CONFLICT (user_id,chunk_id,algorithm_version) DO UPDATE SET
            source_sha256=EXCLUDED.source_sha256,result=EXCLUDED.result,error_code=EXCLUDED.error_code,
            retry_after=EXCLUDED.retry_after,processed_at=NOW()''',user,chunk,VERSION,source['sha256'],json.dumps(result) if result else None,error)
        return 'failed' if error else 'processed'


async def run_daily(max_seconds=21600):
    counts = Counter()
    started = time.monotonic()
    while time.monotonic() - started < max_seconds:
        async with db.get_pool().acquire() as conn:
            rows = await conn.fetch('''SELECT c.user_id,c.chunk_id FROM raw_chunks c
                JOIN raw_consents consent ON consent.user_id=c.user_id AND consent.enabled
                LEFT JOIN raw_analysis a ON a.user_id=c.user_id AND a.chunk_id=c.chunk_id AND a.algorithm_version=$1
                WHERE a.chunk_id IS NULL OR a.source_sha256<>c.sha256
                   OR (a.result IS NULL AND a.retry_after<=NOW())
                ORDER BY c.created_at,c.chunk_id LIMIT 200''',VERSION)
        if not rows:
            return counts
        for row in rows:
            counts[await process_chunk(row['user_id'],row['chunk_id'])] += 1
            if time.monotonic() - started >= max_seconds:
                counts['time_budget_reached'] += 1
                return counts
    counts['time_budget_reached'] += 1
    return counts


async def main():
    await db.init_pool()
    try:
        counts = await run_daily()
        # Aggregate operational counts only; no identities or signal in logs.
        log.info('raw daily analysis version=%s counts=%s',VERSION,dict(counts))
        return 1 if counts['failed'] or counts['time_budget_reached'] else 0
    finally:
        await db.close_pool()


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    raise SystemExit(asyncio.run(main()))
