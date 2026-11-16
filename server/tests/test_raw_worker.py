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
    async with client() as c:
        from server.tests.test_raw_consent import grant
        owner = f'worker-{uuid.uuid4()}'
        await grant(c,owner)
        user = await db.get_or_create_user(owner)
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


@pytest.mark.asyncio
async def test_bad_metadata_isolated_from_following_chunk(tmp_path,monkeypatch):
    monkeypatch.setenv('RAW_ARCHIVE_ROOT',str(tmp_path))
    monkeypatch.setenv('RAW_ARCHIVE_REQUIRE_MOUNT','0')
    async with client() as c:
        from server.tests.test_raw_consent import grant
        owner=f'poison-{uuid.uuid4()}'
        await grant(c,owner)
        user=await db.get_or_create_user(owner)
        bad=json.loads(packet('hr',b'\x10\x3c\x00\x04')); bad['id']=1
        outcomes=[]
        for payload in [(json.dumps(bad)+'\n').encode(),packet('hr',b'\x10\x3c\x00\x04').encode()]:
            chunk=uuid.uuid4(); digest=hashlib.sha256(payload).hexdigest()
            archive_store.get_archive().put(user,chunk,digest,payload)
            async with db.get_pool().acquire() as conn:
                await conn.execute('INSERT INTO raw_chunks (user_id,chunk_id,sha256,byte_count) VALUES ($1,$2,$3,$4)',user,chunk,digest,len(payload))
            outcomes.append(await process_chunk(user,chunk))
        assert outcomes == ['failed','processed']


@pytest.mark.asyncio
async def test_revocation_stops_processing_previously_uploaded_chunks(tmp_path,monkeypatch):
    monkeypatch.setenv('RAW_ARCHIVE_ROOT',str(tmp_path))
    monkeypatch.setenv('RAW_ARCHIVE_REQUIRE_MOUNT','0')
    async with client() as c:
        from server.tests.test_raw_consent import grant
        owner=f'paused-worker-{uuid.uuid4()}'
        await grant(c,owner)
        user=await db.get_or_create_user(owner)
        payload=packet('hr',b'\x10\x3c\x00\x04').encode()
        chunk=uuid.uuid4(); digest=hashlib.sha256(payload).hexdigest()
        archive_store.get_archive().put(user,chunk,digest,payload)
        async with db.get_pool().acquire() as conn:
            await conn.execute('INSERT INTO raw_chunks (user_id,chunk_id,sha256,byte_count) VALUES ($1,$2,$3,$4)',user,chunk,digest,len(payload))
        response=await c.put('/v1/raw/consent',headers={'X-User-ID':owner},json={
            'enabled':False,'expected_revision':1,'consent_version':'raw-v1-2026-11-15'})
        assert response.status_code == 200
        assert await process_chunk(user,chunk) == 'not_consented'
        async with db.get_pool().acquire() as conn:
            assert await conn.fetchval('SELECT count(*) FROM raw_analysis WHERE user_id=$1',user) == 0
