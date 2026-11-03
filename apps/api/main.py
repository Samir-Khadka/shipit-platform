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

from fastapi import FastAPI
from pydantic import BaseModel

SERVICE = "shipit-api"
app = FastAPI(title=SERVICE)

_counter = {"value": 0}


def app_version() -> str:
    return os.environ.get("APP_VERSION", "v1.0.0")


class EchoIn(BaseModel):
    message: str


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "service": SERVICE, "version": app_version()}


@app.get("/version")
def version() -> dict:
    return {"service": SERVICE, "version": app_version()}


@app.post("/echo")
def echo(payload: EchoIn) -> dict:
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
