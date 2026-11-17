"""Health contract validation (no database required)."""
from copy import deepcopy
from uuid import uuid4

import pytest
from pydantic import ValidationError

from server.health.models import Batch, Enrollment


def workout():
    return {'activity_code':37,'started_at':'2026-11-15T15:30:00Z','ended_at':'2026-11-15T19:40:00Z','active_duration_seconds':15000,'source':{'bundle_identifier':'example.synthetic','name':'Synthetic'}}


def change(operation='upsert_workout', external_id=None, **payload):
    return {'operation_id':str(uuid4()),'operation':operation,'external_id':external_id or str(uuid4()),**payload}


def envelope(connection=None, sequence=1, changes=None):
    connection = connection or {'connection_id':str(uuid4()),'connection_epoch':1,'stream_id':str(uuid4())}
    return {'schema_version':1,'connection_id':connection['connection_id'],'connection_epoch':connection['connection_epoch'],'batch_id':str(uuid4()),'stream_id':connection['stream_id'],'sequence':sequence,'changes':changes or [change(workout=workout())]}


def test_enrollment_rejects_caller_selected_owner():
    with pytest.raises(ValidationError):
        Enrollment.model_validate({'owner_id':str(uuid4())})


@pytest.mark.parametrize('edit',[
    lambda b: b['changes'][0]['workout'].update(started_at='2026-11-15T15:30:00'),
    lambda b: b['changes'][0]['workout'].update(ended_at='2026-11-15T14:30:00Z'),
    lambda b: b['changes'][0]['workout'].update(active_duration_seconds=99999),
    lambda b: b['changes'][0]['workout'].update(active_duration_seconds=float('nan')),
    lambda b: b.update(changes=b['changes']*201),
    lambda b: b.update(owner_id=str(uuid4())),
    lambda b: b.update(sequence=10**100),
    lambda b: b['changes'][0].update(annotation={'notes':'unexpected'}),
])
def test_invalid_batches_rejected(edit):
    body = envelope()
    edit(body)
    with pytest.raises(ValidationError):
        Batch.model_validate(body)


def test_long_workouts_are_not_capped_to_manual_form_limit():
    assert Batch.model_validate(envelope()).changes[0].workout.active_duration_seconds == 15000


def test_sample_units_and_finite_values_are_enforced():
    s = {'metric':'heart_rate','value':120,'unit':'ms','started_at':'2026-11-15T16:00:00Z','ended_at':'2026-11-15T16:00:00Z','source':workout()['source']}
    with pytest.raises(ValidationError):
        Batch.model_validate(envelope(changes=[change('upsert_sample',sample=s)]))


@pytest.mark.asyncio
async def test_health_auth_cannot_be_bypassed_by_legacy_headers():
    from httpx import AsyncClient, ASGITransport
    from server.main import app
    async with AsyncClient(transport=ASGITransport(app=app),base_url='http://test') as client:
        for headers in ({},{'X-User-ID':'victim'},{'Authorization':'Bearer wyb_old_pat','X-API-Key':'anything'}):
            response = await client.get('/v1/health/activities',headers=headers)
            assert response.status_code == 401


@pytest.mark.asyncio
async def test_request_limit_applies_before_parsing_chunked_json():
    from httpx import AsyncClient, ASGITransport
    from server.main import app
    async def body():
        yield b'{"padding":"'
        for _ in range(33):
            yield b'x'*65536
        yield b'"}'
    async with AsyncClient(transport=ASGITransport(app=app),base_url='http://test') as client:
        r=await client.post('/v1/health/installations',content=body(),headers={'Content-Type':'application/json'})
        assert r.status_code==413


@pytest.mark.asyncio
async def test_nonfinite_raw_json_returns_validation_error_without_echoing_payload():
    from httpx import AsyncClient, ASGITransport
    from server.main import app
    async with AsyncClient(transport=ASGITransport(app=app),base_url='http://test') as client:
        response=await client.post('/v1/health/installations',content='{"owner_id":NaN}',headers={'Content-Type':'application/json'})
        assert response.status_code==422
        assert 'NaN' not in response.text
