"""Bounded, idempotent archive of exact Polar notification bytes."""
from __future__ import annotations
import hashlib
import json
import uuid
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import Response
from starlette.concurrency import run_in_threadpool
from ..auth_user import current_user_id
from ..db import get_or_create_user, get_pool
from .. import archive_store

router = APIRouter(tags=["raw"])
MAX_CHUNK_BYTES = archive_store.MAX_BYTES
_root = archive_store.archive_root  # legacy filesystem integration


async def lock_archive_user(conn, user_id):
    # Shared by ingest, processing, consent and deletion. Transaction-scoped,
    # so a crash cannot leave an advisory lock behind.
    await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", str(user_id))


def _ack(chunk_id, digest, size):
    return Response(json.dumps({"chunk_id": str(chunk_id), "sha256": digest, "byte_count": size}),
                    media_type="application/json",
                    headers={"X-Chunk-SHA256": digest, "X-Chunk-Bytes": str(size)})


@router.post("/v1/raw/chunks/{chunk_id}")
async def upload_chunk(chunk_id: uuid.UUID, request: Request,
                       x_user_id: str = Header(..., alias="X-User-ID"),
                       x_chunk_sha256: str = Header(..., alias="X-Chunk-SHA256")):
    archive = archive_store.get_archive()
    payload_buffer = bytearray()
    async for part in request.stream():
        payload_buffer.extend(part)
        if len(payload_buffer) > MAX_CHUNK_BYTES:
            raise HTTPException(413, "raw chunk too large")
    payload = bytes(payload_buffer)
    if not payload:
        raise HTTPException(413, "raw chunk must be 1–1,500,000 bytes")
    digest = hashlib.sha256(payload).hexdigest()
    if digest != x_chunk_sha256.lower():
        raise HTTPException(422, "raw chunk hash mismatch")
    user_id = await get_or_create_user(x_user_id)
    async with get_pool().acquire() as conn, conn.transaction():
        await lock_archive_user(conn, user_id)
        existing = await conn.fetchrow(
            "SELECT sha256, byte_count, storage_backend FROM raw_chunks WHERE user_id=$1 AND chunk_id=$2",
            user_id, chunk_id)
        if existing:
            if existing["sha256"] != digest or existing["byte_count"] != len(payload):
                raise HTTPException(409, "chunk id already has different bytes")
            archive = archive_store.get_archive(existing["storage_backend"])
            await run_in_threadpool(archive.get, user_id, chunk_id, digest)
        else:
            await run_in_threadpool(archive.put, user_id, chunk_id, digest, payload)
            await conn.execute(
                "INSERT INTO raw_chunks (user_id,chunk_id,sha256,byte_count,storage_backend) "
                "VALUES ($1,$2,$3,$4,$5)", user_id, chunk_id, digest, len(payload), archive.backend)
    return _ack(chunk_id, digest, len(payload))


@router.get("/v1/me/raw/chunks")
async def list_chunks(user_id: str = Depends(current_user_id), limit: int = 1000,
                      cursor: uuid.UUID | None = None):
    limit = min(max(limit, 1), 1000)
    async with get_pool().acquire() as conn:
        rows = await conn.fetch(
            "SELECT chunk_id, sha256, byte_count, created_at FROM raw_chunks "
            "WHERE user_id = $1 AND ($2::uuid IS NULL OR chunk_id > $2) "
            "ORDER BY chunk_id LIMIT $3", user_id, cursor, limit)
    return {"chunks": [{"chunk_id": str(r["chunk_id"]), "sha256": r["sha256"],
                         "byte_count": r["byte_count"], "created_at": r["created_at"].isoformat()}
                        for r in rows],
            "next_cursor": str(rows[-1]["chunk_id"]) if len(rows) == limit else None}


@router.get("/v1/me/raw/chunks/{chunk_id}")
async def download_chunk(chunk_id: uuid.UUID, user_id: str = Depends(current_user_id)):
    async with get_pool().acquire() as conn, conn.transaction():
        await lock_archive_user(conn, user_id)
        row = await conn.fetchrow(
            "SELECT sha256, storage_backend FROM raw_chunks WHERE user_id=$1 AND chunk_id=$2",
            user_id, chunk_id)
        if row is None:
            raise HTTPException(404, "chunk not found")
        archive = archive_store.get_archive(row["storage_backend"])
        data = await run_in_threadpool(archive.get, user_id, chunk_id, row["sha256"])
    return Response(data, media_type="application/x-ndjson")
