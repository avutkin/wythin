"""Raw Polar packet archive: exact bytes, idempotent retries, user scope."""
from __future__ import annotations

import hashlib
import uuid
from contextlib import asynccontextmanager

import pytest
from httpx import ASGITransport, AsyncClient

from server.main import app


@asynccontextmanager
async def client():
    from server.db import close_pool, create_schema, init_pool
    await init_pool()
    await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            yield c
    finally:
        await close_pool()


@pytest.mark.asyncio
async def test_raw_chunk_round_trip_retry_and_user_scope(tmp_path, monkeypatch):
    monkeypatch.setenv("RAW_ARCHIVE_ROOT", str(tmp_path))
    monkeypatch.setenv("RAW_ARCHIVE_REQUIRE_MOUNT", "0")
    owner = f"raw-{uuid.uuid4()}"
    stranger = f"raw-{uuid.uuid4()}"
    chunk_id = uuid.uuid4()
    payload = b'{"stream":"ecg","payload":"AP+BSg=="}\n'
    headers = {"X-User-ID": owner, "X-Chunk-SHA256": hashlib.sha256(payload).hexdigest()}
    async with client() as c:
        first = await c.post(f"/v1/raw/chunks/{chunk_id}", content=payload, headers=headers)
        assert first.status_code == 200, first.text
        assert first.headers["X-Chunk-SHA256"] == headers["X-Chunk-SHA256"]
        assert first.headers["X-Chunk-Bytes"] == str(len(payload))
        again = await c.post(f"/v1/raw/chunks/{chunk_id}", content=payload, headers=headers)
        assert again.status_code == 200, again.text
        assert again.json() == first.json()

        owner_token = (await c.post("/v1/tokens", json={"name": "raw-owner"},
                                    headers={"X-User-ID": owner})).json()["token"]
        other_token = (await c.post("/v1/tokens", json={"name": "raw-other"},
                                    headers={"X-User-ID": stranger})).json()["token"]
        own = await c.get(f"/v1/me/raw/chunks/{chunk_id}",
                          headers={"Authorization": f"Bearer {owner_token}"})
        other = await c.get(f"/v1/me/raw/chunks/{chunk_id}",
                            headers={"Authorization": f"Bearer {other_token}"})
        assert own.status_code == 200 and own.content == payload
        assert other.status_code == 404
        assert len(list(tmp_path.rglob("*.jsonl.gz"))) == 1
        listing = await c.get("/v1/me/raw/chunks", headers={"Authorization": f"Bearer {owner_token}"})
        assert [row["chunk_id"] for row in listing.json()["chunks"]] == [str(chunk_id)]
        assert listing.json()["next_cursor"] is None

        changed = await c.post(f"/v1/raw/chunks/{chunk_id}", content=b"different\n",
                               headers={"X-User-ID": owner,
                                        "X-Chunk-SHA256": hashlib.sha256(b"different\n").hexdigest()})
        assert changed.status_code == 409
        still_original = await c.get(f"/v1/me/raw/chunks/{chunk_id}",
                                     headers={"Authorization": f"Bearer {owner_token}"})
        assert still_original.content == payload

        erased = await c.delete("/v1/me/data", headers={"Authorization": f"Bearer {owner_token}"})
        assert erased.status_code == 200 and erased.json()["raw_chunks"] == 1
        assert not list(tmp_path.rglob("*.jsonl.gz"))


@pytest.mark.asyncio
async def test_raw_chunk_rejects_wrong_hash(tmp_path, monkeypatch):
    monkeypatch.setenv("RAW_ARCHIVE_ROOT", str(tmp_path))
    monkeypatch.setenv("RAW_ARCHIVE_REQUIRE_MOUNT", "0")
    async with client() as c:
        r = await c.post(f"/v1/raw/chunks/{uuid.uuid4()}", content=b"raw",
                         headers={"X-User-ID": f"raw-{uuid.uuid4()}",
                                  "X-Chunk-SHA256": "0" * 64})
        assert r.status_code == 422


@pytest.mark.asyncio
async def test_raw_upload_refuses_unmounted_directory(tmp_path, monkeypatch):
    monkeypatch.setenv("RAW_ARCHIVE_ROOT", str(tmp_path))
    monkeypatch.delenv("RAW_ARCHIVE_REQUIRE_MOUNT", raising=False)
    async with client() as c:
        r = await c.post(f"/v1/raw/chunks/{uuid.uuid4()}", content=b"raw\n",
                         headers={"X-User-ID": f"raw-{uuid.uuid4()}",
                                  "X-Chunk-SHA256": hashlib.sha256(b"raw\n").hexdigest()})
        assert r.status_code == 503


@pytest.mark.asyncio
async def test_raw_export_detects_archive_corruption(tmp_path, monkeypatch):
    monkeypatch.setenv("RAW_ARCHIVE_ROOT", str(tmp_path))
    monkeypatch.setenv("RAW_ARCHIVE_REQUIRE_MOUNT", "0")
    owner = f"raw-{uuid.uuid4()}"
    chunk_id = uuid.uuid4()
    payload = b"exact notification bytes\n"
    async with client() as c:
        uploaded = await c.post(f"/v1/raw/chunks/{chunk_id}", content=payload,
                                headers={"X-User-ID": owner,
                                         "X-Chunk-SHA256": hashlib.sha256(payload).hexdigest()})
        assert uploaded.status_code == 200
        token = (await c.post("/v1/tokens", json={"name": "raw-owner"},
                              headers={"X-User-ID": owner})).json()["token"]
        archived = next(tmp_path.rglob("*.jsonl.gz"))
        archived.write_bytes(b"broken")
        restored = await c.get(f"/v1/me/raw/chunks/{chunk_id}",
                               headers={"Authorization": f"Bearer {token}"})
        assert restored.status_code == 503
