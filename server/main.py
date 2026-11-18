"""
JustBreathe Sync Server
=======================
Run:   uvicorn server.main:app --host 0.0.0.0 --port 8000 --reload
Prod:  uvicorn server.main:app --host 0.0.0.0 --port 8000 --workers 4
"""
from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager, suppress
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .db import init_pool, close_pool, create_schema, purge_expired_recording_diagnostics
from .auth import key_ok
from .auth_user import resolve_bearer, AuthError
from .mcp_server import mcp
from .health.router import router as health_router
from .routers import sessions, stream, admin, insights, tokens, me, activities, metrics, profile, usage, raw, felt_state, recording_diagnostics


async def _maintain_recording_diagnostics() -> None:
    while True:
        await asyncio.sleep(3600)
        try:
            await purge_expired_recording_diagnostics()
        except Exception:
            logging.getLogger(__name__).exception("Recording diagnostics retention cleanup failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool()
    try:
        await create_schema()
        await purge_expired_recording_diagnostics()
        maintenance = asyncio.create_task(_maintain_recording_diagnostics())
        try:
            async with mcp.session_manager.run():
                yield
        finally:
            maintenance.cancel()
            with suppress(asyncio.CancelledError):
                await maintenance
    finally:
        await close_pool()


app = FastAPI(
    title="JustBreathe Sync API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Paths reachable without the API key. /health is for uptime checks; the
# dashboard is a data-free HTML shell that then fetches /admin/stats WITH the
# key, so serving the shell openly leaks nothing.
_OPEN_PATHS = {"/health", "/admin/dashboard"}
# Per-user routes and the independent Health installation namespace authenticate
# inside their routers. Health never accepts the legacy PAT. Enrollment alone
# creates a new empty namespace. (/v1/tokens stays gated — app-only.)
_BEARER_PREFIXES = ("/v1/me", "/v1/health")


def _bearer_exempt(path: str) -> bool:
    """True if path equals a Bearer prefix exactly, or is nested under one
    (prefix + "/"). Prevents accidental exemption of unrelated paths that
    merely share a string prefix, e.g. "/v1/messages" vs "/v1/me"."""
    return any(path == p or path.startswith(p + "/") for p in _BEARER_PREFIXES)


def _mcp_path(path: str) -> bool:
    """The MCP endpoint is mounted at /mcp (streamable-HTTP under /mcp/)."""
    return path == "/mcp" or path.startswith("/mcp/")


@app.middleware("http")
async def api_key_gate(request: Request, call_next):
    path = request.url.path
    if path in _OPEN_PATHS:
        return await call_next(request)
    # MCP authenticates per request with a personal Bearer token. Enforce it at
    # the transport — not just inside each tool — so anonymous callers can't read
    # initialize/tools/list, and a bad token returns a real 401 (which lets an
    # MCP client re-issue credentials) rather than an in-band tool error.
    if _mcp_path(path):
        try:
            await resolve_bearer(request.headers.get("authorization"))
        except AuthError as e:
            return JSONResponse({"detail": e.detail}, status_code=e.status)
        return await call_next(request)
    # /v1/me and /v1/health enforce their distinct credentials in the route.
    if _bearer_exempt(path):
        return await call_next(request)
    # Everything else needs the shared key (only enforced when API_KEY is
    # configured — see server/auth.py).
    if not key_ok(request.headers.get("x-api-key")):
        return JSONResponse({"detail": "unauthorized"}, status_code=401)
    response = await call_next(request)
    # Every admin response says which dashboard the server is serving, so an
    # open tab — which only ever fetches data, never the page — notices a
    # deploy and reloads itself instead of drawing old columns from new data.
    if path.startswith("/admin"):
        response.headers["X-Dashboard-Version"] = admin.DASHBOARD_VERSION
    return response


app.include_router(sessions.router)
app.include_router(stream.router)
app.include_router(admin.router)
app.include_router(insights.router)
app.include_router(tokens.router)
app.include_router(me.router)
app.include_router(activities.router)
app.include_router(metrics.router)
app.include_router(profile.router)
app.include_router(usage.router)
app.include_router(raw.router)
app.include_router(felt_state.router)
app.include_router(health_router)
app.include_router(recording_diagnostics.router)

app.mount("/mcp", mcp.streamable_http_app())


@app.get("/health")
async def health():
    return {"status": "ok"}
