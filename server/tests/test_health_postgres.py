"""Real PostgreSQL transactions, ownership, replay and deletion contracts."""
from contextlib import asynccontextmanager
from copy import deepcopy
from hashlib import sha256
import asyncio
import json
from uuid import uuid4

import pytest
from httpx import AsyncClient, ASGITransport

from server.tests.test_health import envelope, change, workout


@asynccontextmanager
async def client():
    from server.main import app
    from server.db import init_pool,create_schema,close_pool
    await init_pool()
    await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app,client=('health-test-'+str(uuid4()),50000)),base_url='http://test') as c:
            yield c
    finally:
        await close_pool()


async def enrolled(c):
    r = await c.post('/v1/health/installations',json={})
    assert r.status_code == 201, r.text
    identity = r.json()
    headers = {'Authorization':'Bearer '+identity['credential']}
    r = await c.post('/v1/health/apple-health/connections',headers=headers,json={'stream_id':str(uuid4()),'cloud_consent':True,'consent_version':'1'})
    assert r.status_code == 200,r.text
    return headers,r.json()


async def send(c,h,body,status=200):
    r = await c.post('/v1/health/apple-health/batches',headers=h,json=body)
    assert r.status_code == status,r.text
    return r.json()


def sample(wid, parent=None):
    return {'metric':'heart_rate','value':120,'unit':'count/min','started_at':'2026-11-15T16:00:00Z','ended_at':'2026-11-15T16:00:00Z','source':workout()['source'],'representation':'series' if parent else 'point','parent_id':parent,'workout_ids':[wid]}


@pytest.mark.asyncio
async def test_retry_concurrency_is_atomic_and_changed_payload_conflicts():
    async with client() as c:
        h,conn = await enrolled(c)
        body=envelope(conn)
        a,b=await asyncio.gather(send(c,h,body),send(c,h,body))
        assert a == b
        assert a['sequence']==1 and a['expected_sequence']==2
        modified=deepcopy(body); modified['changes'][0]['workout']['activity_code']=1
        await send(c,h,modified,409)
        await send(c,h,envelope(conn,3),409)
        page=(await c.get('/v1/health/activities',headers=h)).json()
        assert len(page['items'])==1


@pytest.mark.asyncio
async def test_bad_dependency_rolls_back_whole_batch_and_operation_ledger():
    async with client() as c:
        h,conn=await enrolled(c)
        first=change(workout=workout())
        body=envelope(conn,changes=[first,change('upsert_sample',sample=sample(str(uuid4())))])
        await send(c,h,body,409)
        assert (await c.get('/v1/health/activities',headers=h)).json()['items']==[]
        body['changes']=[first]
        await send(c,h,body)


@pytest.mark.asyncio
async def test_owner_isolation_cursor_tombstones_and_terminal_delete():
    async with client() as c:
        h,conn=await enrolled(c); other,oc=await enrolled(c)
        a=change(workout=workout()); wid=a['external_id']
        ack=await send(c,h,envelope(conn,changes=[a]))
        aid=ack['workout_mappings'][0]['activity_id']
        await send(c,other,envelope(conn,2,[change('delete_workout',wid)]),404)
        assert (await c.get('/v1/health/activities/'+aid,headers=other)).status_code==404
        assert (await c.get('/v1/health/activities/'+wid,headers=h)).status_code==200
        page=(await c.get('/v1/health/activities?limit=1',headers=h)).json()
        cursor=page['next_cursor']
        assert (await c.get('/v1/health/activities',params={'cursor':cursor},headers=other)).status_code==400
        await send(c,h,envelope(conn,2,[change('delete_workout',wid)]))
        deleted=(await c.get('/v1/health/activities',params={'cursor':cursor},headers=h)).json()['items']
        assert len(deleted)==1 and deleted[0]['deleted'] is True and deleted[0]['workout'] is None
        replay=await send(c,h,envelope(conn,3,[change(external_id=wid,workout=workout())]))
        assert replay['results'][0]['status']=='ignored_deleted'
        assert (await c.get('/v1/health/activities/'+aid,headers=h)).json()['deleted'] is True


@pytest.mark.asyncio
async def test_operation_ids_cannot_be_reused_for_new_content():
    async with client() as c:
        h,conn=await enrolled(c); op=change(workout=workout())
        await send(c,h,envelope(conn,changes=[op]))
        ack=await send(c,h,envelope(conn,2,[op]))
        assert ack['results'][0]['status']=='replayed'
        op['workout']['activity_code']=2
        await send(c,h,envelope(conn,3,[op]),409)


@pytest.mark.asyncio
async def test_series_is_hidden_until_commit_and_parent_delete_is_terminal():
    async with client() as c:
        h,conn=await enrolled(c); wid=str(uuid4()); parent=str(uuid4()); child=str(uuid4()); gen=str(uuid4())
        await send(c,h,envelope(conn,changes=[change(external_id=wid,workout=workout())]))
        begin=change('begin_series',parent,series={'generation':gen,'expected_parts':1,'digest':sha256(child.encode()).hexdigest()})
        part=change('series_part',parent,series={'generation':gen,'part_index':0,'samples':[{'external_id':child,**sample(wid,parent)}]})
        await send(c,h,envelope(conn,2,[begin,part]))
        detail=await c.get('/v1/health/activities/'+wid,headers=h)
        assert detail.json()['samples']==[]
        await send(c,h,envelope(conn,3,[change('commit_series',parent,series={'generation':gen})]))
        assert len((await c.get('/v1/health/activities/'+wid,headers=h)).json()['samples'])==1
        await send(c,h,envelope(conn,4,[change('delete_sample',parent)]))
        assert (await c.get('/v1/health/activities/'+wid,headers=h)).json()['samples']==[]
        late=await send(c,h,envelope(conn,5,[change('series_part',parent,series=part['series']),change('upsert_sample',child,sample=sample(wid,parent))]))
        assert all(r['status']=='ignored_deleted' for r in late['results'])


@pytest.mark.asyncio
async def test_purge_invalidates_old_epoch_cursor_and_requires_new_consent():
    async with client() as c:
        h,conn=await enrolled(c); body=envelope(conn)
        await send(c,h,body)
        cursor=(await c.get('/v1/health/activities',headers=h)).json()['next_cursor']
        path='/v1/health/apple-health/data?connection_epoch=1'
        p=await c.delete(path,headers=h)
        assert p.status_code==200 and p.json()['connection_epoch']==2
        assert (await c.delete(path,headers=h)).json()==p.json()
        await send(c,h,body,409)
        assert (await c.get('/v1/health/activities',params={'cursor':cursor},headers=h)).status_code==409
        assert (await c.get('/v1/health/activities',headers=h)).json()['items']==[]
        status=(await c.get('/v1/health/apple-health/status',headers=h)).json()
        assert status['cloud_consent'] is False


@pytest.mark.asyncio
async def test_annotation_survives_workout_refresh_and_samples_stale_analysis():
    async with client() as c:
        h,conn=await enrolled(c); wid=str(uuid4())
        analysis={'algorithm_version':1,'input_revision':1,'computed_at':'2026-11-15T20:00:00Z','status':'available','statistics':[]}
        await send(c,h,envelope(conn,changes=[change(external_id=wid,workout=workout()),change('update_annotation',wid,annotation={'notes':'keep me'}),change('upsert_analysis',wid,analysis=analysis)]))
        await send(c,h,envelope(conn,2,[change(external_id=wid,workout=workout())]))
        detail=(await c.get('/v1/health/activities/'+wid,headers=h)).json()
        assert detail['annotation']['notes']=='keep me'
        await send(c,h,envelope(conn,3,[change('upsert_analysis',wid,analysis=analysis),change('upsert_sample',sample=sample(wid))]))
        detail=(await c.get('/v1/health/activities/'+wid,headers=h)).json()
        assert detail['analysis']['stale'] is True


@pytest.mark.asyncio
async def test_pause_blocks_new_ingestion_but_preserves_ack_and_reads():
    async with client() as c:
        h,conn=await enrolled(c); body=envelope(conn)
        ack=await send(c,h,body)
        path='/v1/health/apple-health/connections/'+conn['connection_id']
        assert (await c.patch(path,headers=h,json={'cloud_consent':False})).status_code==200
        assert await send(c,h,body)==ack
        await send(c,h,envelope(conn,2),403)
        assert len((await c.get('/v1/health/activities',headers=h)).json()['items'])==1
        assert (await c.patch(path,headers=h,json={'cloud_consent':True})).status_code==422
        assert (await c.patch(path,headers=h,json={'cloud_consent':True,'consent_version':'1'})).status_code==200
        await send(c,h,envelope(conn,2))


@pytest.mark.asyncio
async def test_pagination_captures_updates_and_deletes_after_old_workouts():
    async with client() as c:
        h,conn=await enrolled(c)
        first=change(workout=workout()); second=change(workout=workout())
        await send(c,h,envelope(conn,changes=[first,second]))
        page=(await c.get('/v1/health/activities?limit=1',headers=h)).json()
        assert page['has_more'] is True
        follow=(await c.get('/v1/health/activities',params={'limit':1,'cursor':page['next_cursor']},headers=h)).json()
        assert follow['items'][0]['external_id']==second['external_id'] and follow['has_more'] is False
        await send(c,h,envelope(conn,2,[change('delete_workout',first['external_id'])]))
        after=(await c.get('/v1/health/activities',params={'cursor':follow['next_cursor']},headers=h)).json()
        assert after['items'][0]['deleted'] is True


@pytest.mark.asyncio
async def test_delete_during_staging_cannot_publish_on_late_commit():
    async with client() as c:
        h,conn=await enrolled(c); wid=str(uuid4()); parent=str(uuid4()); child=str(uuid4()); gen=str(uuid4())
        await send(c,h,envelope(conn,changes=[change(external_id=wid,workout=workout())]))
        await send(c,h,envelope(conn,2,[change('begin_series',parent,series={'generation':gen,'expected_parts':1,'digest':sha256(child.encode()).hexdigest()}),change('series_part',parent,series={'generation':gen,'part_index':0,'samples':[{'external_id':child,**sample(wid,parent)}]})]))
        await send(c,h,envelope(conn,3,[change('delete_sample',parent)]))
        reply=await send(c,h,envelope(conn,4,[change('commit_series',parent,series={'generation':gen})]))
        assert reply['results'][0]['status']=='ignored_deleted'
        assert (await c.get('/v1/health/activities/'+wid,headers=h)).json()['samples']==[]


@pytest.mark.asyncio
async def test_bad_series_digest_is_atomic_and_children_require_staging():
    async with client() as c:
        h,conn=await enrolled(c); wid=str(uuid4()); parent=str(uuid4()); child=str(uuid4()); gen=str(uuid4())
        await send(c,h,envelope(conn,changes=[change(external_id=wid,workout=workout())]))
        await send(c,h,envelope(conn,2,[change('upsert_sample',child,sample=sample(wid,parent))]),409)
        begin=change('begin_series',parent,series={'generation':gen,'expected_parts':1,'digest':'0'*64})
        part=change('series_part',parent,series={'generation':gen,'part_index':0,'samples':[{'external_id':child,**sample(wid,parent)}]})
        commit=change('commit_series',parent,series={'generation':gen})
        await send(c,h,envelope(conn,2,[begin,part,commit]),409)
        assert (await c.get('/v1/health/activities/'+wid,headers=h)).json()['samples']==[]
        begin['series']['digest']=sha256(child.encode()).hexdigest()
        await send(c,h,envelope(conn,2,[begin,part,commit]))


@pytest.mark.asyncio
async def test_enrollment_forbids_existing_identity_and_keeps_only_secret_hash():
    from server.db import get_pool
    async with client() as c:
        bad=await c.post('/v1/health/installations',json={'installation_id':str(uuid4())})
        assert bad.status_code==422
        r=await c.post('/v1/health/installations',json={});identity=r.json()
        row=await get_pool().fetchrow('SELECT * FROM health_installations WHERE id=$1',__import__('uuid').UUID(identity['installation_id']))
        assert identity['credential'].startswith('whi_') and len(identity['credential'])==47
        assert identity['credential'] not in str(dict(row))
        assert row['credential_hash']==sha256(identity['credential'].encode()).hexdigest()


@pytest.mark.asyncio
async def test_detail_samples_paginate_without_duplicates_and_bind_cursor_to_workout_revision():
    async with client() as c:
        h,conn=await enrolled(c);wid=str(uuid4());other=str(uuid4())
        ids=[str(uuid4()) for _ in range(5)]
        await send(c,h,envelope(conn,changes=[change(external_id=wid,workout=workout()),change(external_id=other,workout=workout())]+[change('upsert_sample',sid,sample=sample(wid)) for sid in ids]))
        path='/v1/health/activities/'+wid
        first=(await c.get(path,headers=h,params={'sample_limit':2})).json()
        assert len(first['samples'])==2
        seen=[s['external_id'] for s in first['samples']]
        cursor=first['next_samples_cursor']
        assert cursor
        assert (await c.get('/v1/health/activities/'+other,headers=h,params={'samples_cursor':cursor})).status_code==400
        while cursor:
            page=(await c.get(path,headers=h,params={'sample_limit':2,'samples_cursor':cursor})).json()
            seen += [s['external_id'] for s in page['samples']]
            cursor=page['next_samples_cursor']
        assert len(seen)==5 and set(seen)==set(ids)
        await send(c,h,envelope(conn,2,[change('upsert_sample',sample=sample(wid))]))
        changed=await c.get(path,headers=h,params={'samples_cursor':first['next_samples_cursor']})
        assert changed.status_code==409


@pytest.mark.asyncio
async def test_single_snapshot_cannot_exceed_restore_budget():
    async with client() as c:
        h,conn=await enrolled(c)
        body=workout()
        body['events']=[{'kind':'🎯'*200,'started_at':body['started_at'],'ended_at':body['started_at']}]*2000
        await send(c,h,envelope(conn,changes=[change(workout=body)]),422)
        assert (await c.get('/v1/health/activities',headers=h)).json()['items']==[]


@pytest.mark.asyncio
async def test_restore_pages_are_bounded_by_bytes_as_well_as_count():
    async with client() as c:
        h,conn=await enrolled(c)
        workouts=[change(workout={**workout(),'activity_name':'x'*200}) for _ in range(200)]
        await send(c,h,envelope(conn,changes=workouts))
        first=(await c.get('/v1/health/activities?limit=200',headers=h)).json()
        await send(c,h,envelope(conn,2,[change('update_annotation',w['external_id'],annotation={'notes':'n'*10000}) for w in workouts]))
        response=await c.get('/v1/health/activities',headers=h,params={'limit':200,'cursor':first['next_cursor']})
        assert response.status_code==200
        assert len(response.content)<2*1024*1024
        page=response.json()
        assert page['has_more'] is True
        follow=(await c.get('/v1/health/activities',headers=h,params={'limit':200,'cursor':page['next_cursor']})).json()
        all_ids=[i['external_id'] for i in page['items']+follow['items']]
        assert len(all_ids)==200 and set(all_ids)=={w['external_id'] for w in workouts}


@pytest.mark.asyncio
async def test_multipart_series_commit_orders_manifest_and_rejects_duplicate_children():
    async with client() as c:
        h,conn=await enrolled(c);wid=str(uuid4());parent=str(uuid4());gen=str(uuid4())
        children=[str(uuid4()) for _ in range(3)]
        await send(c,h,envelope(conn,changes=[change(external_id=wid,workout=workout())]))
        begin=change('begin_series',parent,series={'generation':gen,'expected_parts':3,'digest':sha256('\n'.join(children).encode()).hexdigest()})
        await send(c,h,envelope(conn,2,[begin]+[change('series_part',parent,series={'generation':gen,'part_index':i,'samples':[{'external_id':children[i],**sample(wid,parent)}]}) for i in (2,0,1)]))
        await send(c,h,envelope(conn,3,[change('commit_series',parent,series={'generation':gen})]))
        assert {s['external_id'] for s in (await c.get('/v1/health/activities/'+wid,headers=h)).json()['samples']}==set(children)
        gen=str(uuid4())
        begin=change('begin_series',parent,series={'generation':gen,'expected_parts':2,'digest':sha256((children[0]+'\n'+children[0]).encode()).hexdigest()})
        parts=[change('series_part',parent,series={'generation':gen,'part_index':i,'samples':[{'external_id':children[0],**sample(wid,parent)}]}) for i in range(2)]
        await send(c,h,envelope(conn,4,[begin]+parts+[change('commit_series',parent,series={'generation':gen})]),409)
        # A failed replacement leaves the complete previous generation available.
        detail=(await c.get('/v1/health/activities/'+wid,headers=h)).json()
        assert {s['external_id'] for s in detail['samples']}==set(children)
        assert not any(s['stale'] for s in detail['samples'])


@pytest.mark.asyncio
@pytest.mark.parametrize('epoch',[1,7])
async def test_purge_before_first_connection_is_idempotent_and_allows_fresh_consent(epoch):
    async with client() as c:
        identity=(await c.post('/v1/health/installations',json={})).json()
        h={'Authorization':'Bearer '+identity['credential']}
        path=f'/v1/health/apple-health/data?connection_epoch={epoch}'
        first=await c.delete(path,headers=h)
        assert first.status_code==200,first.text
        assert first.json()['connection_epoch']==epoch+1 and first.json()['cloud_consent'] is False
        assert (await c.delete(path,headers=h)).json()==first.json()
        connected=await c.post('/v1/health/apple-health/connections',headers=h,json={'stream_id':str(uuid4()),'cloud_consent':True,'consent_version':'1'})
        assert connected.status_code==200
        conn=connected.json()
        assert conn['connection_epoch']==epoch+1 and conn['expected_sequence']==1
        old=envelope(conn);old['connection_epoch']=epoch
        await send(c,h,old,409)
        await send(c,h,envelope(conn))


# Verbatim XCTAttachment exported from the successful Swift
# HealthRepositoryTests.testSeriesBatchWireFixtureAndAck() on 2026-11-16.
# Retain Swift's UUID casing, fractional dates, omitted optionals and slash escapes.
SWIFT_WIRE_JSON = r'''{"batch_id":"d178a0d7-7099-40c3-a066-df6eb3ffc617","changes":[{"external_id":"6c4f648a-7fa6-4688-b7ce-e51c57701a6c","operation":"upsert_workout","operation_id":"7e4c2126-b5f1-47ef-86e2-dabeb75b9683","workout":{"active_duration_seconds":600,"activity_code":37,"activity_name":"Running","ended_at":"1970-01-01T02:56:40.000Z","events":[],"segments":[],"source":{"bundle_identifier":"test","name":"Watch"},"started_at":"1970-01-01T02:46:40.000Z","user_entered":false}},{"external_id":"a6c018c4-5ec2-45c9-9a61-0d37fe1c8fdd","operation":"begin_series","operation_id":"b4a6e6af-0228-4a75-a820-b4b1f6d7c67e","series":{"digest":"92b706c2ce1fdd74a4b812aeb7fac9c2affc736aaaf58587357f4b78f0a6f909","expected_parts":1,"generation":"4eefd162-9c2a-4247-bc3c-e671118582e1"}},{"external_id":"a6c018c4-5ec2-45c9-9a61-0d37fe1c8fdd","operation":"series_part","operation_id":"43a6748e-2c1a-4326-ac80-22fed4b1388b","series":{"generation":"4eefd162-9c2a-4247-bc3c-e671118582e1","part_index":0,"samples":[{"ended_at":"1970-01-01T02:46:40.000Z","external_id":"b15f5837-cef0-5b65-a34c-5670d1d531ef","metric":"heart_rate","parent_id":"A6C018C4-5EC2-45C9-9A61-0D37FE1C8FDD","representation":"series","source":{"bundle_identifier":"test","name":"Watch"},"started_at":"1970-01-01T02:46:40.000Z","unit":"count\/min","value":100,"workout_ids":["6C4F648A-7FA6-4688-B7CE-E51C57701A6C"]},{"ended_at":"1970-01-01T02:46:41.000Z","external_id":"dc783d98-0a79-5291-a349-49a00b686f8f","metric":"heart_rate","parent_id":"A6C018C4-5EC2-45C9-9A61-0D37FE1C8FDD","representation":"series","source":{"bundle_identifier":"test","name":"Watch"},"started_at":"1970-01-01T02:46:41.000Z","unit":"count\/min","value":101,"workout_ids":["6C4F648A-7FA6-4688-B7CE-E51C57701A6C"]},{"ended_at":"1970-01-01T02:46:42.000Z","external_id":"1021b4a2-acca-5d86-a574-29c9d1c03dee","metric":"heart_rate","parent_id":"A6C018C4-5EC2-45C9-9A61-0D37FE1C8FDD","representation":"series","source":{"bundle_identifier":"test","name":"Watch"},"started_at":"1970-01-01T02:46:42.000Z","unit":"count\/min","value":102,"workout_ids":["6C4F648A-7FA6-4688-B7CE-E51C57701A6C"]}]}},{"external_id":"a6c018c4-5ec2-45c9-9a61-0d37fe1c8fdd","operation":"commit_series","operation_id":"68b72026-f1a1-47f4-bf97-d6043547402b","series":{"generation":"4eefd162-9c2a-4247-bc3c-e671118582e1"}},{"analysis":{"algorithm_version":1,"computed_at":"2026-11-16T06:16:50.253Z","input_revision":3,"statistics":[{"boundary_samples_omitted":0,"count":3,"first_at":"1970-01-01T02:46:40.000Z","last_at":"1970-01-01T02:46:42.000Z","maximum":102,"mean":101,"method":"mean_of_observations","metric":"heart_rate","minimum":100,"observed_seconds":0,"source":{"bundle_identifier":"test","name":"Watch"},"window":"during"}],"status":"partial"},"external_id":"6c4f648a-7fa6-4688-b7ce-e51c57701a6c","operation":"upsert_analysis","operation_id":"6446f9ab-7e9a-46f9-bda4-5ff4fec6ea12"},{"annotation":{"notes":"Synthetic only","title":"Fixture"},"external_id":"6c4f648a-7fa6-4688-b7ce-e51c57701a6c","operation":"update_annotation","operation_id":"36d92c11-7195-4d6a-8bf8-5ab4dd3c2eae"}],"connection_epoch":1,"connection_id":"41eeb16c-79d5-4480-8fa7-0bc49c7a09b9","schema_version":1,"sequence":1,"stream_id":"069dfeac-5626-4c74-b813-0194b4f892fa"}'''


@pytest.mark.asyncio
async def test_real_swift_repository_fixture_validates_ingests_and_restores():
    from server.health.models import Batch
    # Validate the actual Swift envelope before substituting live server IDs.
    Batch.model_validate_json(SWIFT_WIRE_JSON)
    body=json.loads(SWIFT_WIRE_JSON)
    async with client() as c:
        h,conn=await enrolled(c)
        for key in ('connection_id','connection_epoch','stream_id'):
            body[key]=conn[key]
        ack=await send(c,h,body)
        assert [r['status'] for r in ack['results']]==['applied']*6
        assert await send(c,h,body)==ack
        wid='6c4f648a-7fa6-4688-b7ce-e51c57701a6c'
        restored=(await c.get('/v1/health/activities/'+wid,headers=h)).json()
        assert restored['workout']['activity_code']==37
        assert restored['workout']['active_duration_seconds']==600
        assert restored['workout']['source']['name']=='Watch'
        assert [s['value'] for s in restored['samples']]==[100,101,102]
        assert all(s['parent_id']=='a6c018c4-5ec2-45c9-9a61-0d37fe1c8fdd' for s in restored['samples'])
        statistic=restored['analysis']['statistics'][0]
        assert (statistic['window'],statistic['count'],statistic['mean'])==('during',3,101)
        assert restored['analysis']['stale'] is False
        assert restored['annotation']=={'title':'Fixture','notes':'Synthetic only'}
