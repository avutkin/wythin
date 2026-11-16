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
