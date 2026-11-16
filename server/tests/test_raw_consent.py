import hashlib
import uuid
import pytest
from server.tests.test_raw import client


async def grant(c, owner):
    response = await c.put('/v1/raw/consent', headers={'X-User-ID':owner}, json={
        'enabled':True,'expected_revision':0,'consent_version':'raw-v1-2026-11-15'})
    assert response.status_code == 200, response.text
    return response.json()


@pytest.mark.asyncio
async def test_consent_absence_revoke_and_stale_acceptance(tmp_path,monkeypatch):
    monkeypatch.setenv('RAW_ARCHIVE_ROOT',str(tmp_path))
    monkeypatch.setenv('RAW_ARCHIVE_REQUIRE_MOUNT','0')
    owner=f'consent-{uuid.uuid4()}'
    chunk=uuid.uuid4(); payload=b'exact packet\n'
    headers={'X-User-ID':owner,'X-Chunk-SHA256':hashlib.sha256(payload).hexdigest()}
    async with client() as c:
        assert (await c.post(f'/v1/raw/chunks/{chunk}',content=payload,headers=headers)).status_code == 403
        consent=await grant(c,owner)
        headers['X-Archive-Consent-Token']=consent['token']
        assert (await c.post(f'/v1/raw/chunks/{chunk}',content=payload,headers=headers)).status_code == 200
        revoked=await c.put('/v1/raw/consent',headers={'X-User-ID':owner},json={
            'enabled':False,'expected_revision':1,'consent_version':'raw-v1-2026-11-15'})
        assert revoked.status_code == 200
        # A delayed enable request cannot overwrite a later decision.
        stale=await c.put('/v1/raw/consent',headers={'X-User-ID':owner},json={
            'enabled':True,'expected_revision':1,'consent_version':'raw-v1-2026-11-15'})
        assert stale.status_code == 409
        assert (await c.post(f'/v1/raw/chunks/{uuid.uuid4()}',content=payload,headers=headers)).status_code == 403
        again=await c.put('/v1/raw/consent',headers={'X-User-ID':owner},json={
            'enabled':True,'expected_revision':2,'consent_version':'raw-v1-2026-11-15'})
        assert again.status_code == 200
        assert again.json()['token'] != consent['token']
        # Old background-session tasks remain rejected even after re-enabling.
        assert (await c.post(f'/v1/raw/chunks/{uuid.uuid4()}',content=payload,headers=headers)).status_code == 403
        from server.db import get_pool, get_or_create_user
        user=await get_or_create_user(owner)
        async with get_pool().acquire() as conn:
            rows=await conn.fetch('SELECT enabled FROM raw_consent_events WHERE user_id=$1 ORDER BY revision',user)
        assert [r['enabled'] for r in rows] == [True,False,True]


@pytest.mark.asyncio
async def test_erasure_preserves_disabled_revision_barrier(tmp_path,monkeypatch):
    monkeypatch.setenv('RAW_ARCHIVE_ROOT',str(tmp_path))
    monkeypatch.setenv('RAW_ARCHIVE_REQUIRE_MOUNT','0')
    owner=f'erasure-{uuid.uuid4()}'
    async with client() as c:
        consent=await grant(c,owner)
        token=(await c.post('/v1/tokens',headers={'X-User-ID':owner},json={'name':'erase'})).json()['token']
        erased=await c.delete('/v1/me/data',headers={'Authorization':f'Bearer {token}'})
        assert erased.status_code == 200
        state=(await c.get('/v1/raw/consent',headers={'X-User-ID':owner})).json()
        assert state['enabled'] is False
        assert state['revision'] > consent['revision']
        stale=await c.put('/v1/raw/consent',headers={'X-User-ID':owner},json={
            'enabled':True,'expected_revision':0,'consent_version':'raw-v1-2026-11-15'})
        assert stale.status_code == 409


@pytest.mark.asyncio
async def test_timed_out_enable_cannot_outlive_acknowledged_refusal():
    import asyncio
    from server.db import get_pool,get_or_create_user
    from server.routers.raw import lock_archive_user
    owner=f'queued-{uuid.uuid4()}'
    headers={'X-User-ID':owner}
    async with client() as c:
        user=await get_or_create_user(owner)
        async with get_pool().acquire() as lock_conn:
            tx=lock_conn.transaction()
            await tx.start()
            await lock_archive_user(lock_conn,user)
            enabled=asyncio.create_task(c.put('/v1/raw/consent',headers=headers,json={
                'enabled':True,'expected_revision':0,'consent_version':'raw-v1-2026-11-15'}))
            try:
                # Client timeout need not cancel work already executing server-side.
                with pytest.raises(asyncio.TimeoutError):
                    await asyncio.wait_for(asyncio.shield(enabled),timeout=0.05)
                old=(await c.get('/v1/raw/consent',headers=headers)).json()
                assert old['enabled'] is False and old['revision'] == 0
                refusal=asyncio.create_task(c.put('/v1/raw/consent',headers=headers,json={
                    'enabled':False,'expected_revision':old['revision'],'consent_version':'raw-v1-2026-11-15'}))
                with pytest.raises(asyncio.TimeoutError):
                    await asyncio.wait_for(asyncio.shield(refusal),timeout=0.05)
            finally:
                await tx.commit()
            first, paused=await asyncio.gather(enabled,refusal)
            assert first.status_code == 200
            assert paused.status_code == 409
            latest=(await c.get('/v1/raw/consent',headers=headers)).json()
            acknowledged=await c.put('/v1/raw/consent',headers=headers,json={
                'enabled':False,'expected_revision':latest['revision'],'consent_version':'raw-v1-2026-11-15'})
            assert acknowledged.status_code == 200
            final=(await c.get('/v1/raw/consent',headers=headers)).json()
            assert final['enabled'] is False and final['revision'] == 2
