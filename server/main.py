"""
JustBreathe Sync Server
=======================
Run:   uvicorn server.main:app --host 0.0.0.0 --port 8000 --reload
Prod:  uvicorn server.main:app --host 0.0.0.0 --port 8000 --workers 4
"""
from __future__ import annotations

from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .db import init_pool, close_pool, create_schema
from .auth import key_ok
from .routers import sessions, stream, admin, insights, tokens, me


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool()
    await create_schema()
    yield
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
# Per-user routes authenticate via Bearer token inside the route, so they
# bypass the shared X-API-Key gate. (/v1/tokens stays gated — app-only.)
_BEARER_PREFIXES = ("/v1/me", "/mcp")


@app.middleware("http")
async def api_key_gate(request: Request, call_next):
    # Everything outside _OPEN_PATHS/_BEARER_PREFIXES needs the key (only
    # enforced when API_KEY is configured — see server/auth.py).
    path = request.url.path
    if path in _OPEN_PATHS or path.startswith(_BEARER_PREFIXES):
        return await call_next(request)
    if not key_ok(request.headers.get("x-api-key")):
        return JSONResponse({"detail": "unauthorized"}, status_code=401)
    return await call_next(request)


app.include_router(sessions.router)
app.include_router(stream.router)
app.include_router(admin.router)
app.include_router(insights.router)
app.include_router(tokens.router)
app.include_router(me.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
