import hashlib
import json
import uuid
import pytest
from server.tests.test_raw import client
from server.tests.test_raw_analysis import packet
from server import db, archive_store
from server.raw_worker import process_chunk


@pytest.mark.asyncio
async def test_worker_replay_and_corrupt_source_never_marks_success(tmp_path, monkeypatch):
    monkeypatch.setenv('RAW_ARCHIVE_ROOT', str(tmp_path))
    monkeypatch.setenv('RAW_ARCHIVE_REQUIRE_MOUNT', '0')
    async with client():
        user = await db.get_or_create_user(f'worker-{uuid.uuid4()}')
        chunk = uuid.uuid4()
        payload = packet('hr', b'\x10\x3c\x00\x04').encode()
        digest = hashlib.sha256(payload).hexdigest()
        store = archive_store.get_archive()
        store.put(user, chunk, digest, payload)
        async with db.get_pool().acquire() as conn:
            await conn.execute('INSERT INTO raw_chunks (user_id,chunk_id,sha256,byte_count) VALUES ($1,$2,$3,$4)',user,chunk,digest,len(payload))
        assert await process_chunk(user, chunk) == 'processed'
        assert await process_chunk(user, chunk) == 'already_processed'
        async with db.get_pool().acquire() as conn:
            rows = await conn.fetch('SELECT result FROM raw_analysis WHERE user_id=$1',user)
        assert len(rows) == 1
        assert json.loads(rows[0]['result'])['rr']['ticks'] == [1024]
        # A different chunk whose source is corrupt must remain retryable.
        bad = uuid.uuid4()
        store.path(user,bad).write_bytes(b'corrupt')
        async with db.get_pool().acquire() as conn:
            await conn.execute('INSERT INTO raw_chunks (user_id,chunk_id,sha256,byte_count) VALUES ($1,$2,$3,$4)',user,bad,digest,len(payload))
        assert await process_chunk(user,bad) == 'failed'
        async with db.get_pool().acquire() as conn:
            row = await conn.fetchrow('SELECT result,error_code FROM raw_analysis WHERE user_id=$1 AND chunk_id=$2',user,bad)
        assert row['result'] is None and row['error_code'] == 'source_unavailable'
