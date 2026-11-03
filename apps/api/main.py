"""ShipIt demo API — tiny but real.

Endpoints:
  GET  /health       liveness probe target (also polled by the worker)
  GET  /version      returns APP_VERSION — load-bearing for the Phase 3 canary demo
  POST /echo         echoes a JSON message back
  GET  /count        current counter value (in-memory)
  POST /count/incr   increments the counter
  POST /count/reset  resets the counter (used by tests)
"""
from __future__ import annotations

import os
import random

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel

SERVICE = "shipit-api"
app = FastAPI(title=SERVICE)

_counter = {"value": 0}


def app_version() -> str:
    return os.environ.get("APP_VERSION", "v1.0.0")


def fault_rate() -> float:
    """Demo-only fault injection knob.

    FAULT_RATE=0.0 (default) disables it. Set to 0.0–1.0 to make /health and
    /echo fail with HTTP 500 at that probability. Used by the Phase 3 canary
    demo: ship a release with FAULT_RATE=0.3 and watch Flagger's analysis fail
    and roll the release back automatically. NEVER set this outside a demo —
    it deliberately breaks the service.
    """
    try:
        return max(0.0, min(1.0, float(os.environ.get("FAULT_RATE", "0") or 0)))
    except (TypeError, ValueError):
        return 0.0


def _maybe_fault() -> JSONResponse | None:
    if random.random() < fault_rate():
        return JSONResponse(
            status_code=500,
            content={"error": "injected fault (FAULT_RATE demo knob — not a real failure)"},
        )
    return None


class EchoIn(BaseModel):
    message: str


@app.get("/health")
def health() -> dict:
    if (fault := _maybe_fault()) is not None:
        return fault  # type: ignore[return-value]
    return {"status": "ok", "service": SERVICE, "version": app_version()}


@app.get("/version")
def version() -> dict:
    return {"service": SERVICE, "version": app_version()}


@app.post("/echo")
def echo(payload: EchoIn) -> dict:
    if (fault := _maybe_fault()) is not None:
        return fault  # type: ignore[return-value]
    return {"echo": payload.message, "version": app_version()}


@app.get("/count")
def get_count() -> dict:
    return {"count": _counter["value"]}


@app.post("/count/incr")
def incr_count() -> dict:
    _counter["value"] += 1
    return {"count": _counter["value"]}


@app.post("/count/reset")
def reset_count() -> dict:
    _counter["value"] = 0
    return {"count": _counter["value"]}
