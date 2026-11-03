"""FAULT_RATE demo-knob tests — the fault injector behind the Phase 3 canary demo.

FAULT_RATE is strictly demo tooling: it makes /health and /echo fail with
HTTP 500 at the configured probability so a canary release can be made to
burn its error budget on demand. Default is 0.0 (off).
"""
from fastapi.testclient import TestClient

import main


def _client():
    return TestClient(main.app)


def test_fault_rate_off_by_default(monkeypatch):
    monkeypatch.delenv("FAULT_RATE", raising=False)
    c = _client()
    for _ in range(20):
        assert c.get("/health").status_code == 200
        assert c.post("/echo", json={"message": "x"}).status_code == 200


def test_fault_rate_full(monkeypatch):
    monkeypatch.setenv("FAULT_RATE", "1.0")
    c = _client()
    for _ in range(10):
        assert c.get("/health").status_code == 500
        assert c.post("/echo", json={"message": "x"}).status_code == 500
    # other endpoints are untouched by the injector
    assert c.get("/version").status_code == 200
    assert c.get("/count").status_code == 200


def test_fault_rate_invalid_value_is_safe(monkeypatch):
    monkeypatch.setenv("FAULT_RATE", "not-a-number")
    assert main.fault_rate() == 0.0
    assert _client().get("/health").status_code == 200


def test_fault_rate_clamped(monkeypatch):
    monkeypatch.setenv("FAULT_RATE", "99")
    assert main.fault_rate() == 1.0
    monkeypatch.setenv("FAULT_RATE", "-5")
    assert main.fault_rate() == 0.0
