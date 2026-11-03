"""Bounded, idempotent archive of exact Polar notification bytes.

RAW_ARCHIVE_ROOT must be an existing directory on separate durable storage.
The API refuses uploads when it is unset, to avoid silently filling the system disk.
"""
from __future__ import annotations

import hashlib
import gzip
import json
import os
import shutil
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import Response

from ..auth_user import current_user_id
from ..db import get_or_create_user, get_pool

router = APIRouter(tags=["raw"])
MAX_CHUNK_BYTES = 1_500_000


def _root() -> Path:
    configured = os.getenv("RAW_ARCHIVE_ROOT")
    if not configured:
        raise HTTPException(status_code=503, detail="raw archive is not configured")
    root = Path(configured)
    if not root.is_dir():
        raise HTTPException(status_code=503, detail="raw archive is unavailable")
    if os.getenv("RAW_ARCHIVE_REQUIRE_MOUNT", "1") != "0" and not os.path.ismount(root):
        raise HTTPException(status_code=503, detail="raw archive volume is not mounted")
    return root


def _path(root: Path, user_id: str, chunk_id: uuid.UUID) -> Path:
    return root / user_id / f"{chunk_id}.jsonl.gz"


def _read_payload(path: Path) -> bytes:
    try:
        return gzip.decompress(path.read_bytes())
    except (OSError, EOFError) as exc:
        raise HTTPException(status_code=503, detail="archived chunk is corrupt") from exc


def _ack(chunk_id: uuid.UUID, digest: str, size: int) -> Response:
    body = json.dumps({"chunk_id": str(chunk_id), "sha256": digest, "byte_count": size})
    return Response(body, media_type="application/json",
                    headers={"X-Chunk-SHA256": digest, "X-Chunk-Bytes": str(size)})


@router.post("/v1/raw/chunks/{chunk_id}")
async def upload_chunk(chunk_id: uuid.UUID, request: Request,
                       x_user_id: str = Header(..., alias="X-User-ID"),
                       x_chunk_sha256: str = Header(..., alias="X-Chunk-SHA256")):
    root = _root()
    payload_buffer = bytearray()
    async for part in request.stream():
        payload_buffer.extend(part)
        if len(payload_buffer) > MAX_CHUNK_BYTES:
            raise HTTPException(status_code=413, detail="raw chunk too large")
    payload = bytes(payload_buffer)
    if not payload or len(payload) > MAX_CHUNK_BYTES:
        raise HTTPException(status_code=413, detail="raw chunk must be 1–1,500,000 bytes")
    digest = hashlib.sha256(payload).hexdigest()
    if digest != x_chunk_sha256.lower():
        raise HTTPException(status_code=422, detail="raw chunk hash mismatch")
    user_id = await get_or_create_user(x_user_id)
    path = _path(root, user_id, chunk_id)
    async with get_pool().acquire() as conn:
        existing = await conn.fetchrow(
            "SELECT sha256, byte_count FROM raw_chunks WHERE user_id = $1 AND chunk_id = $2",
            user_id, chunk_id)
        if existing:
            if existing["sha256"] != digest or existing["byte_count"] != len(payload):
                raise HTTPException(status_code=409, detail="chunk id already has different bytes")
            if not path.is_file() or hashlib.sha256(_read_payload(path)).hexdigest() != digest:
                raise HTTPException(status_code=503, detail="archived chunk is unavailable")
            return _ack(chunk_id, digest, len(payload))
        if shutil.disk_usage(root).free < len(payload) + 1_000_000_000:
            raise HTTPException(status_code=507, detail="raw archive volume is nearly full")
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{chunk_id}.{uuid.uuid4()}.tmp")
        try:
            with temporary.open("xb") as output:
                output.write(gzip.compress(payload, compresslevel=6, mtime=0))
                output.flush()
                os.fsync(output.fileno())
            try:
                os.link(temporary, path)
            except FileExistsError:
                if hashlib.sha256(_read_payload(path)).hexdigest() != digest:
                    raise HTTPException(status_code=409, detail="chunk id already has different bytes")
            dir_fd = os.open(path.parent, os.O_DIRECTORY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
            inserted = await conn.fetchrow(
                "INSERT INTO raw_chunks (user_id, chunk_id, sha256, byte_count) "
                "VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING RETURNING sha256",
                user_id, chunk_id, digest, len(payload))
            if inserted is None:
                winner = await conn.fetchrow(
                    "SELECT sha256 FROM raw_chunks WHERE user_id = $1 AND chunk_id = $2",
                    user_id, chunk_id)
                if winner is None or winner["sha256"] != digest:
                    raise HTTPException(status_code=409, detail="chunk id already has different bytes")
        finally:
            temporary.unlink(missing_ok=True)
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
    root = _root()
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT sha256 FROM raw_chunks WHERE user_id = $1 AND chunk_id = $2",
            user_id, chunk_id)
    if row is None:
        raise HTTPException(status_code=404, detail="chunk not found")
    path = _path(root, user_id, chunk_id)
    if not path.is_file():
        raise HTTPException(status_code=503, detail="archived chunk is unavailable")
    data = _read_payload(path)
    if hashlib.sha256(data).hexdigest() != row["sha256"]:
        raise HTTPException(status_code=503, detail="archived chunk is corrupt")
    return Response(data, media_type="application/x-ndjson")
