"""Transactional ordered ingestion and immutable, owner-bound restore feed."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from uuid import UUID, uuid4

from fastapi import HTTPException

from ..db import get_pool
from .models import Batch, Change

LIMITS = {'max_changes':200,'max_body_bytes':2*1024*1024}
MAX_SNAPSHOT_BYTES = 1024*1024
PAGE_BYTES = 1887436  # 1.8 MiB, below the mobile transport's 2 MiB response cap.
PAGE_METADATA_BYTES = 4096


def dumps(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)


def decoded(value):
    return json.loads(value) if isinstance(value,str) else value


def digest(value):
    return hashlib.sha256(dumps(value).encode()).hexdigest()


def conflict(code, **metadata):
    raise HTTPException(409, {'code':code,**metadata})


def connection_info(row):
    return {'connection_id':str(row['id']),'connection_epoch':row['epoch'],'stream_id':str(row['stream_id']),
            'expected_sequence':row['sequence']+1,'server_revision':row['revision'],
            'cloud_consent':row['cloud_consent'],'consent_version':row['consent_version'],
            'state':'active' if row['cloud_consent'] else 'paused','limits':LIMITS}


async def enroll(ip):
    token = 'whi_'+secrets.token_urlsafe(32)
    owner = uuid4()
    async with get_pool().acquire() as db, db.transaction():
        bucket = hashlib.sha256(ip.encode()).hexdigest()
        count = await db.fetchval('''INSERT INTO health_enrollment_limits(bucket) VALUES($1)
            ON CONFLICT(bucket) DO UPDATE SET
            attempts=CASE WHEN health_enrollment_limits.started_at < now()-interval '1 hour' THEN 1 ELSE health_enrollment_limits.attempts+1 END,
            started_at=CASE WHEN health_enrollment_limits.started_at < now()-interval '1 hour' THEN now() ELSE health_enrollment_limits.started_at END
            RETURNING attempts''', bucket)
        if count > 120:
            raise HTTPException(429,'enrollment rate limit',headers={'Retry-After':'3600'})
        await db.execute("DELETE FROM health_installations i WHERE created_at < now()-interval '24 hours' AND NOT EXISTS(SELECT 1 FROM health_connections c WHERE c.installation_id=i.id)")
        await db.execute('INSERT INTO health_installations(id,credential_hash,cursor_secret) VALUES($1,$2,$3)',owner,hashlib.sha256(token.encode()).hexdigest(),secrets.token_hex(32))
    return {'installation_id':str(owner),'credential':token}


async def connect(owner, body):
    if not body.cloud_consent:
        raise HTTPException(403,'explicit cloud consent required')
    async with get_pool().acquire() as db, db.transaction():
        if not await db.fetchval('SELECT id FROM health_installations WHERE id=$1 FOR UPDATE',owner['id']):
            raise HTTPException(401,'health installation expired')
        row=await db.fetchrow('SELECT * FROM health_connections WHERE installation_id=$1 FOR UPDATE',owner['id'])
        if row is None:
            row=await db.fetchrow('''INSERT INTO health_connections(id,installation_id,stream_id,cloud_consent,consent_version)
                VALUES($1,$2,$3,true,$4) RETURNING *''',uuid4(),owner['id'],body.stream_id,body.consent_version)
        else:
            if row['stream_id'] != body.stream_id and not (row['sequence']==0 and row['last_purged_epoch'] is not None):
                conflict('stream_mismatch',connection_epoch=row['epoch'],expected_sequence=row['sequence']+1)
            row=await db.fetchrow('''UPDATE health_connections SET cloud_consent=true,consent_version=$2,
                consented_at=now(),stream_id=$3 WHERE id=$1 RETURNING *''',row['id'],body.consent_version,body.stream_id)
        return connection_info(row)


async def get_connection(db,owner,lock=False):
    row=await db.fetchrow('SELECT * FROM health_connections WHERE installation_id=$1'+(' FOR UPDATE' if lock else ''),owner['id'])
    if row is None:
        raise HTTPException(404,'health connection not found')
    return row


async def status(owner):
    async with get_pool().acquire() as db:
        row=await get_connection(db,owner)
        result=connection_info(row)
        result['last_ack_at']=row['last_ack_at'].isoformat() if row['last_ack_at'] else None
        return result


async def patch_connection(owner,connection_id,body):
    async with get_pool().acquire() as db,db.transaction():
        row=await get_connection(db,owner,True)
        if row['id']!=connection_id:
            raise HTTPException(404,'health connection not found')
        if body.cloud_consent and not body.consent_version:
            raise HTTPException(422,'consent_version required to resume')
        row=await db.fetchrow('''UPDATE health_connections SET cloud_consent=$2,consent_version=COALESCE($3,consent_version),
            consented_at=CASE WHEN $2 THEN now() ELSE consented_at END WHERE id=$1 RETURNING *''',row['id'],body.cloud_consent,body.consent_version)
        return connection_info(row)


def item(row):
    return {'external_id':str(row['external_id']),'activity_id':str(row['activity_id']),
            'workout':decoded(row['workout']),'analysis':decoded(row['analysis']),
            'annotation':decoded(row['annotation']),'deleted':row['deleted'],'server_revision':row['server_revision']}


async def emit(db,cid,epoch,ids,revision,stale=False):
    for external_id in sorted(set(ids),key=str):
        row=await db.fetchrow('''UPDATE health_workouts SET server_revision=$3,
            analysis=CASE WHEN $4 AND analysis IS NOT NULL THEN analysis || '{"stale":true}'::jsonb ELSE analysis END
            WHERE connection_id=$1 AND external_id=$2 RETURNING *''',cid,external_id,revision,stale)
        if row:
            snapshot=dumps(item(row))
            if len(snapshot.encode())>MAX_SNAPSHOT_BYTES:
                raise HTTPException(422,'combined workout, analysis and annotation exceeds 1 MiB')
            await db.execute('INSERT INTO health_changes(connection_id,epoch,item) VALUES($1,$2,$3::jsonb)',cid,epoch,snapshot)


async def sample_affected(db,cid,ids):
    if not ids:
        return set()
    return set(await db.fetchval('SELECT COALESCE(array_agg(DISTINCT workout_id),ARRAY[]::uuid[]) FROM health_sample_links WHERE connection_id=$1 AND sample_id=ANY($2::uuid[])',cid,list(ids)))


async def series_affected(db,cid,parent_id):
    rows=await db.fetch('''SELECT DISTINCT l.workout_id FROM health_sample_links l JOIN health_samples s
        ON l.connection_id=s.connection_id AND l.sample_id=s.external_id
        WHERE s.connection_id=$1 AND s.parent_id=$2''',cid,parent_id)
    return {r['workout_id'] for r in rows}


async def save_sample(db,cid,external_id,sample):
    refs=[UUID(i) for i in sample.get('workout_ids',[])]
    valid=await db.fetch('SELECT external_id,deleted FROM health_workouts WHERE connection_id=$1 AND external_id=ANY($2::uuid[])',cid,refs)
    if len(valid)!=len(refs):
        conflict('unknown_workout')
    refs=[r['external_id'] for r in valid if not r['deleted']]
    # Windows, not client links alone, determine which analyses become stale.
    # asyncpg binds datetime objects rather than ISO strings for timestamptz.
    from datetime import datetime
    overlap=await db.fetch("""SELECT external_id FROM health_workouts WHERE connection_id=$1 AND NOT deleted
        AND (workout->>'started_at')::timestamptz - interval '5 minutes' <= $3::timestamptz
        AND (workout->>'ended_at')::timestamptz + interval '10 minutes' >= $2::timestamptz""",
        cid,datetime.fromisoformat(sample['started_at'].replace('Z','+00:00')),datetime.fromisoformat(sample['ended_at'].replace('Z','+00:00')))
    refs=list(set(refs)|{r['external_id'] for r in overlap})
    affected=await sample_affected(db,cid,[external_id])
    parent=UUID(sample['parent_id']) if sample.get('parent_id') else None
    await db.execute('''INSERT INTO health_samples(connection_id,external_id,parent_id,sample) VALUES($1,$2,$3,$4::jsonb)
        ON CONFLICT(connection_id,external_id) DO UPDATE SET parent_id=EXCLUDED.parent_id,sample=EXCLUDED.sample,stale=false''',cid,external_id,parent,dumps(sample))
    await db.execute('DELETE FROM health_sample_links WHERE connection_id=$1 AND sample_id=$2',cid,external_id)
    for ref in refs:
        await db.execute('INSERT INTO health_sample_links(connection_id,sample_id,workout_id) VALUES($1,$2,$3)',cid,external_id,ref)
    return affected|set(refs)


async def apply_change(db,cid,epoch,change,revision):
    external_id=change.external_id
    operation=change.operation
    is_workout=operation in ('upsert_workout','delete_workout','update_annotation','upsert_analysis')
    if is_workout:
        row=await db.fetchrow('SELECT * FROM health_workouts WHERE connection_id=$1 AND external_id=$2',cid,external_id)
        if row and row['deleted']:
            return 'ignored_deleted'
        if operation=='upsert_workout':
            await db.execute('''INSERT INTO health_workouts(connection_id,external_id,activity_id,workout,server_revision)
                VALUES($1,$2,$3,$4::jsonb,$5) ON CONFLICT(connection_id,external_id) DO UPDATE SET workout=EXCLUDED.workout''',cid,external_id,uuid4(),dumps(change.workout.model_dump(mode='json')),revision)
            await emit(db,cid,epoch,[external_id],revision,True)
        elif operation=='delete_workout':
            await db.execute('''INSERT INTO health_workouts(connection_id,external_id,activity_id,deleted,server_revision)
                VALUES($1,$2,$3,true,$4) ON CONFLICT(connection_id,external_id) DO UPDATE SET deleted=true,workout=NULL,analysis=NULL,annotation=NULL''',cid,external_id,uuid4(),revision)
            await db.execute('DELETE FROM health_sample_links WHERE connection_id=$1 AND workout_id=$2',cid,external_id)
            await db.execute('''DELETE FROM health_samples s WHERE connection_id=$1 AND NOT deleted AND NOT EXISTS
                (SELECT 1 FROM health_sample_links l WHERE l.connection_id=s.connection_id AND l.sample_id=s.external_id)''',cid)
            await emit(db,cid,epoch,[external_id],revision)
        else:
            if row is None:
                conflict('unknown_workout')
            if operation=='update_annotation':
                await db.execute('UPDATE health_workouts SET annotation=$3::jsonb WHERE connection_id=$1 AND external_id=$2',cid,external_id,dumps(change.annotation.model_dump(mode='json')))
            else:
                data=change.analysis.model_dump(mode='json');data['stale']=False;data['computed_by']='client'
                await db.execute('UPDATE health_workouts SET analysis=$3::jsonb WHERE connection_id=$1 AND external_id=$2',cid,external_id,dumps(data))
            await emit(db,cid,epoch,[external_id],revision)
        return 'applied'
    parent=change.sample.parent_id if change.sample else None
    tombstone=await db.fetchval('SELECT EXISTS(SELECT 1 FROM health_samples WHERE connection_id=$1 AND deleted AND (external_id=$2 OR external_id=$3))',cid,external_id,parent)
    if tombstone:
        return 'ignored_deleted'
    if operation=='delete_sample':
        ids=[r['external_id'] for r in await db.fetch('SELECT external_id FROM health_samples WHERE connection_id=$1 AND (external_id=$2 OR parent_id=$2)',cid,external_id)]
        affected=await sample_affected(db,cid,ids)
        await db.execute('''UPDATE health_samples SET sample=NULL,deleted=true,stale=false WHERE connection_id=$1 AND (external_id=$2 OR parent_id=$2)''',cid,external_id)
        await db.execute('''INSERT INTO health_samples(connection_id,external_id,deleted) VALUES($1,$2,true)
            ON CONFLICT(connection_id,external_id) DO NOTHING''',cid,external_id)
        await db.execute('DELETE FROM health_sample_links WHERE connection_id=$1 AND sample_id=ANY($2::uuid[])',cid,ids)
        await db.execute('DELETE FROM health_series WHERE connection_id=$1 AND parent_id=$2',cid,external_id)
        await emit(db,cid,epoch,affected,revision,True)
    elif operation=='upsert_sample':
        if change.sample.parent_id is not None:
            conflict('series_requires_staging')
        affected=await save_sample(db,cid,external_id,change.sample.model_dump(mode='json'))
        await emit(db,cid,epoch,affected,revision,True)
    elif operation=='begin_series':
        series=change.series
        existing=await db.fetchrow('SELECT * FROM health_series WHERE connection_id=$1 AND parent_id=$2',cid,external_id)
        if existing and existing['generation']==series.generation:
            if existing['expected_parts']!=series.expected_parts or existing['digest']!=series.digest:
                conflict('series_generation_conflict')
            return 'applied'
        await db.execute('DELETE FROM health_series WHERE connection_id=$1 AND parent_id=$2',cid,external_id)
        await db.execute('INSERT INTO health_series(connection_id,parent_id,generation,expected_parts,digest) VALUES($1,$2,$3,$4,$5)',cid,external_id,series.generation,series.expected_parts,series.digest)
        affected=await series_affected(db,cid,external_id)
        await db.execute('UPDATE health_samples SET stale=true WHERE connection_id=$1 AND parent_id=$2',cid,external_id)
        await emit(db,cid,epoch,affected,revision,True)
    elif operation in ('series_part','commit_series'):
        series=change.series
        staging=await db.fetchrow('SELECT * FROM health_series WHERE connection_id=$1 AND parent_id=$2',cid,external_id)
        if not staging or staging['generation']!=series.generation:
            conflict('unknown_series_generation')
        if operation=='series_part':
            if series.part_index>=staging['expected_parts']:
                conflict('series_part_out_of_range')
            data=[s.model_dump(mode='json') for s in series.samples]
            old=await db.fetchval('SELECT samples FROM health_series_parts WHERE connection_id=$1 AND parent_id=$2 AND part_index=$3',cid,external_id,series.part_index)
            if old is not None:
                if decoded(old)!=data:
                    conflict('series_part_conflict')
            elif staging['committed']:
                conflict('series_already_committed')
            else:
                await db.execute('INSERT INTO health_series_parts(connection_id,parent_id,part_index,samples) VALUES($1,$2,$3,$4::jsonb)',cid,external_id,series.part_index,dumps(data))
        elif not staging['committed']:
            part_count=await db.fetchval('SELECT count(*) FROM health_series_parts WHERE connection_id=$1 AND parent_id=$2',cid,external_id)
            if part_count!=staging['expected_parts']:
                conflict('series_incomplete')
            duplicates=await db.fetchval('''SELECT EXISTS(
                SELECT child->>'external_id' FROM health_series_parts p
                CROSS JOIN LATERAL jsonb_array_elements(p.samples) child
                WHERE p.connection_id=$1 AND p.parent_id=$2
                GROUP BY child->>'external_id' HAVING count(*)>1)''',cid,external_id)
            manifest=hashlib.sha256();first=True
            query='SELECT samples FROM health_series_parts WHERE connection_id=$1 AND parent_id=$2 ORDER BY part_index'
            # At most one bounded part is resident, even for a long container.
            # Duplicate detection stays in PostgreSQL instead of a Python set
            # whose size would grow with the full multi-part series.
            async for part in db.cursor(query,cid,external_id,prefetch=1):
                for child in decoded(part['samples']):
                    if not first:
                        manifest.update(b'\n')
                    manifest.update(child['external_id'].encode())
                    first=False
            if duplicates or manifest.hexdigest()!=staging['digest']:
                conflict('series_digest_mismatch')
            affected=await series_affected(db,cid,external_id)
            # Replacement generations replace, rather than append to, the published container.
            await db.execute('DELETE FROM health_samples WHERE connection_id=$1 AND parent_id=$2 AND NOT deleted',cid,external_id)
            async for part in db.cursor(query,cid,external_id,prefetch=1):
                for sample in decoded(part['samples']):
                    sid=UUID(sample.pop('external_id'))
                    dead=await db.fetchval('SELECT deleted FROM health_samples WHERE connection_id=$1 AND external_id=$2',cid,sid)
                    if not dead:
                        affected |= await save_sample(db,cid,sid,sample)
            await db.execute('UPDATE health_series SET committed=true WHERE connection_id=$1 AND parent_id=$2',cid,external_id)
            await emit(db,cid,epoch,affected,revision,True)
    return 'applied'


async def ingest(owner,batch:Batch):
    body_hash=digest(batch.model_dump(mode='json'))
    async with get_pool().acquire() as db,db.transaction():
        connection=await get_connection(db,owner,True)
        cid=connection['id'];epoch=connection['epoch']
        if batch.connection_id!=cid:
            raise HTTPException(404,'health connection not found')
        if batch.connection_epoch!=epoch:
            conflict('epoch_mismatch',connection_epoch=epoch,expected_sequence=connection['sequence']+1)
        if batch.stream_id!=connection['stream_id']:
            conflict('stream_mismatch',connection_epoch=epoch,expected_sequence=connection['sequence']+1)
        old=await db.fetchrow('SELECT * FROM health_batch_ledger WHERE connection_id=$1 AND epoch=$2 AND (batch_id=$3 OR sequence=$4)',cid,epoch,batch.batch_id,batch.sequence)
        if old:
            if old['payload_hash']!=body_hash or old['batch_id']!=batch.batch_id or old['sequence']!=batch.sequence:
                conflict('batch_conflict',expected_sequence=connection['sequence']+1)
            return decoded(old['response'])
        if not connection['cloud_consent']:
            raise HTTPException(403,'cloud consent is paused')
        if batch.sequence!=connection['sequence']+1:
            conflict('sequence_mismatch',expected_sequence=connection['sequence']+1)
        results=[];revision=connection['revision']
        for change in batch.changes:
            op_hash=digest(change.model_dump(mode='json'))
            prior=await db.fetchval('SELECT payload_hash FROM health_operation_ledger WHERE connection_id=$1 AND epoch=$2 AND operation_id=$3',cid,epoch,change.operation_id)
            if prior:
                if prior!=op_hash:
                    conflict('operation_conflict')
                result='replayed'
            else:
                revision+=1
                result=await apply_change(db,cid,epoch,change,revision)
                await db.execute('INSERT INTO health_operation_ledger(connection_id,epoch,operation_id,payload_hash) VALUES($1,$2,$3,$4)',cid,epoch,change.operation_id,op_hash)
            results.append({'operation_id':str(change.operation_id),'status':result})
        ids=[c.external_id for c in batch.changes if c.operation in ('upsert_workout','delete_workout','update_annotation','upsert_analysis')]
        rows=await db.fetch('SELECT external_id,activity_id FROM health_workouts WHERE connection_id=$1 AND external_id=ANY($2::uuid[]) ORDER BY external_id',cid,ids)
        reply={'batch_id':str(batch.batch_id),'sequence':batch.sequence,'server_revision':revision,'connection_epoch':epoch,
               'expected_sequence':batch.sequence+1,'workout_mappings':[{'external_id':str(r['external_id']),'activity_id':str(r['activity_id'])} for r in rows],'results':results}
        await db.execute('UPDATE health_connections SET sequence=$2,revision=$3,last_ack_at=now() WHERE id=$1',cid,batch.sequence,revision)
        await db.execute('INSERT INTO health_batch_ledger(connection_id,epoch,batch_id,sequence,payload_hash,response) VALUES($1,$2,$3,$4,$5,$6::jsonb)',cid,epoch,batch.batch_id,batch.sequence,body_hash,dumps(reply))
        return reply


def signed_cursor(owner,data):
    payload=base64.urlsafe_b64encode(dumps({'owner':str(owner['id']),**data}).encode()).decode().rstrip('=')
    signature=hmac.new(owner['cursor_secret'].encode(),payload.encode(),hashlib.sha256).hexdigest()
    return payload+'.'+signature


def read_cursor(owner,cursor):
    try:
        payload,signature=cursor.split('.')
        expected=hmac.new(owner['cursor_secret'].encode(),payload.encode(),hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature,expected):
            raise ValueError()
        data=json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
        if data['owner']!=str(owner['id']):
            raise ValueError()
    except (ValueError,KeyError,TypeError):
        raise HTTPException(400,'invalid health cursor')
    return data


def encode_cursor(owner,epoch,position):
    return signed_cursor(owner,{'kind':'activities','epoch':epoch,'position':position})


def decode_cursor(owner,cursor,epoch):
    data=read_cursor(owner,cursor)
    if data.get('kind')!='activities' or type(data.get('position')) is not int or data['position']<0:
        raise HTTPException(400,'invalid health cursor')
    if data.get('epoch')!=epoch:
        conflict('cursor_epoch_mismatch',connection_epoch=epoch)
    return data['position']


async def activities(owner,cursor,limit):
    async with get_pool().acquire() as db,db.transaction(isolation='repeatable_read',readonly=True):
        connection=await get_connection(db,owner)
        position=decode_cursor(owner,cursor,connection['epoch']) if cursor else 0
        # PostgreSQL applies the byte budget before returning JSON to the worker;
        # a large archive page must not first allocate hundreds of MiB in Python.
        rows=await db.fetch('''SELECT id,item FROM (
            SELECT id,item,sum(octet_length(item::text)) OVER(ORDER BY id) AS bytes,
                row_number() OVER(ORDER BY id) AS ordinal FROM (
                SELECT id,item FROM health_changes WHERE connection_id=$1 AND epoch=$2 AND id>$3 ORDER BY id LIMIT $4
            ) limited
        ) budgeted WHERE bytes<=$5 OR ordinal=1 ORDER BY id''',connection['id'],connection['epoch'],position,limit+1,PAGE_BYTES-PAGE_METADATA_BYTES)
        page=rows[:limit]
        items=[decoded(r['item']) for r in page]
        if len(dumps(items).encode())>PAGE_BYTES-PAGE_METADATA_BYTES:
            raise HTTPException(413,'stored snapshot exceeds restore page size')
        position=page[-1]['id'] if page else position
        more=await db.fetchval('SELECT EXISTS(SELECT 1 FROM health_changes WHERE connection_id=$1 AND epoch=$2 AND id>$3)',connection['id'],connection['epoch'],position)
        return {'items':items,'next_cursor':encode_cursor(owner,connection['epoch'],position),'has_more':more,'connection_epoch':connection['epoch']}


async def detail(owner,activity_id,sample_limit=500,samples_cursor=None):
    async with get_pool().acquire() as db,db.transaction(isolation='repeatable_read',readonly=True):
        connection=await get_connection(db,owner)
        row=await db.fetchrow('SELECT * FROM health_workouts WHERE connection_id=$1 AND (activity_id=$2 OR external_id=$2)',connection['id'],activity_id)
        if not row:
            raise HTTPException(404,'health activity not found')
        offset=0
        if samples_cursor:
            data=read_cursor(owner,samples_cursor)
            if data.get('kind')!='samples' or data.get('workout')!=str(row['external_id']) or type(data.get('offset')) is not int or data['offset']<0:
                raise HTTPException(400,'invalid health sample cursor')
            if data.get('epoch')!=connection['epoch']:
                conflict('cursor_epoch_mismatch',connection_epoch=connection['epoch'])
            if data.get('revision')!=row['server_revision']:
                conflict('samples_revision_mismatch',server_revision=row['server_revision'])
            offset=data['offset']
        result=item(row)
        samples=await db.fetch('''SELECT s.external_id,s.sample,s.stale FROM health_samples s JOIN health_sample_links l
            ON s.connection_id=l.connection_id AND s.external_id=l.sample_id WHERE s.connection_id=$1 AND l.workout_id=$2 AND NOT s.deleted
            ORDER BY (s.sample->>'started_at')::timestamptz,s.external_id LIMIT $3 OFFSET $4''',connection['id'],row['external_id'],sample_limit+1,offset)
        remaining=PAGE_BYTES-PAGE_METADATA_BYTES-len(dumps(result).encode())
        selected=[]
        for sample in samples[:sample_limit]:
            value={'external_id':str(sample['external_id']),**decoded(sample['sample']),'stale':sample['stale']}
            size=len(dumps(value).encode())+1
            if size>remaining:
                break
            selected.append(value)
            remaining-=size
        if samples and not selected:
            raise HTTPException(413,'stored snapshot exceeds restore page size')
        result['samples']=selected
        result['next_samples_cursor']=signed_cursor(owner,{'kind':'samples','epoch':connection['epoch'],'workout':str(row['external_id']),
            'revision':row['server_revision'],'offset':offset+len(selected)}) if len(samples)>len(selected) else None
        result['connection_epoch']=connection['epoch']
        return result


async def purge(owner,epoch):
    async with get_pool().acquire() as db,db.transaction():
        # Share enrollment's owner lock with connect: if the first connect failed,
        # deletion still has a durable receipt and cannot race a new connection.
        if not await db.fetchval('SELECT id FROM health_installations WHERE id=$1 FOR UPDATE',owner['id']):
            raise HTTPException(401,'health installation expired')
        row=await db.fetchrow('SELECT * FROM health_connections WHERE installation_id=$1 FOR UPDATE',owner['id'])
        if row is None:
            cid=uuid4()
            await db.execute('''INSERT INTO health_connections
                (id,installation_id,stream_id,epoch,revision,cloud_consent,consent_version,consented_at,last_purged_epoch)
                VALUES($1,$2,$3,$4,1,false,'',NULL,$5)''',cid,owner['id'],uuid4(),epoch+1,epoch)
            return {'connection_id':str(cid),'connection_epoch':epoch+1,'expected_sequence':1,'cloud_consent':False}
        if epoch!=row['epoch']:
            if row['last_purged_epoch']==epoch:
                return {'connection_id':str(row['id']),'connection_epoch':epoch+1,'expected_sequence':1,'cloud_consent':False}
            conflict('epoch_mismatch',connection_epoch=row['epoch'])
        cid=row['id']
        for table in ('health_workouts','health_samples','health_series','health_changes','health_batch_ledger','health_operation_ledger'):
            await db.execute('DELETE FROM '+table+' WHERE connection_id=$1',cid)
        await db.execute('UPDATE health_connections SET epoch=epoch+1,sequence=0,revision=revision+1,cloud_consent=false,last_purged_epoch=$2,last_ack_at=NULL WHERE id=$1',cid,epoch)
        return {'connection_id':str(cid),'connection_epoch':epoch+1,'expected_sequence':1,'cloud_consent':False}
