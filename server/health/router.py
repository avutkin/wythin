"""Health API; the mandatory credential dependency never uses legacy auth."""
from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.routing import APIRoute
from fastapi.exceptions import RequestValidationError

from .auth import installation
from .models import Enrollment, ConnectionRequest, ConnectionPatch, Batch
from . import store


class BoundedRoute(APIRoute):
    def get_route_handler(self):
        original = super().get_route_handler()
        async def bounded(request:Request):
            # Check actual bytes, including chunked requests, before JSON parsing.
            chunks=bytearray()
            async for chunk in request.stream():
                if len(chunks)+len(chunk)>store.LIMITS['max_body_bytes']:
                    raise HTTPException(413,'health request exceeds 2 MiB')
                chunks.extend(chunk)
            request._body=bytes(chunks)
            try:
                return await original(request)
            except RequestValidationError:
                # Do not echo health values, or ask the JSON error serializer
                # to encode a rejected non-finite value such as NaN.
                raise HTTPException(422,'invalid health payload') from None
        return bounded


router=APIRouter(prefix='/v1/health',tags=['health'],route_class=BoundedRoute,responses={
    401:{'description':'Missing or invalid installation credential'},
    403:{'description':'Cloud consent required or paused'},
    409:{'description':'Epoch, stream, sequence, immutable operation or dependency conflict'},
    413:{'description':'JSON body exceeds 2 MiB'},
    422:{'description':'Invalid or unbounded health payload'},
    429:{'description':'Enrollment rate limit'},
})


@router.post('/installations',status_code=201)
async def enroll(body:Enrollment,request:Request):
    return await store.enroll(request.client.host if request.client else 'unknown')


@router.post('/apple-health/connections')
async def connect(body:ConnectionRequest,owner=Depends(installation)):
    return await store.connect(owner,body)


@router.patch('/apple-health/connections/{connection_id}')
async def patch(connection_id:UUID,body:ConnectionPatch,owner=Depends(installation)):
    return await store.patch_connection(owner,connection_id,body)


@router.get('/apple-health/status')
async def status(owner=Depends(installation)):
    return await store.status(owner)


@router.post('/apple-health/batches')
async def batch(body:Batch,owner=Depends(installation)):
    return await store.ingest(owner,body)


@router.get('/activities')
async def activities(cursor:str|None=Query(default=None,max_length=1000),limit:int=Query(default=100,ge=1,le=200),owner=Depends(installation)):
    return await store.activities(owner,cursor,limit)


@router.get('/activities/{activity_id}')
async def detail(activity_id:UUID,include:str='series,analysis',
                 sample_limit:int=Query(default=500,ge=1,le=1000),
                 samples_cursor:str|None=Query(default=None,max_length=1500),owner=Depends(installation)):
    if set(include.split(',')) - {'series','analysis',''}:
        raise HTTPException(422,'unknown include field')
    return await store.detail(owner,activity_id,sample_limit,samples_cursor)


@router.delete('/apple-health/data')
async def purge(connection_epoch:int=Query(ge=1,le=9223372036854775806),owner=Depends(installation)):
    return await store.purge(owner,connection_epoch)
