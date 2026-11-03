"""API contract tests — run in CI on every push/PR."""
from fastapi.testclient import TestClient

import main


def _client():
    return TestClient(main.app)


def test_health_ok():
    r = _client().get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["service"] == "shipit-api"


def test_version_default(monkeypatch):
    monkeypatch.delenv("APP_VERSION", raising=False)
    r = _client().get("/version")
    assert r.status_code == 200
    assert r.json()["version"] == "v1.0.0"


def test_version_env_override(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v9.9.9")
    r = _client().get("/version")
    assert r.status_code == 200
    assert r.json()["version"] == "v9.9.9"


def test_echo_roundtrip():
    r = _client().post("/echo", json={"message": "hello shipit"})
    assert r.status_code == 200
    assert r.json()["echo"] == "hello shipit"


def test_counter_increments():
    c = _client()
    c.post("/count/reset")
    assert c.post("/count/incr").json()["count"] == 1
    assert c.post("/count/incr").json()["count"] == 2
    assert c.get("/count").json()["count"] == 2
