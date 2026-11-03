"""Phase 4 observability tests: /metrics exposition and the OTel opt-in.

The tracing knob must be safe in both positions — enabled against a dead
collector must not break requests, and disabled must be a clean no-op.
"""
import os

from fastapi.testclient import TestClient

import main


def _client():
    return TestClient(main.app)


def test_metrics_endpoint_exposes_prometheus_format():
    c = _client()
    r = c.get("/metrics")
    assert r.status_code == 200
    assert "http_request_duration_seconds" in r.text


def test_metrics_record_requests():
    c = _client()
    c.get("/version")
    c.post("/echo", json={"message": "hi"})
    body = c.get("/metrics").text
    # the instrumentator counts every request, labelled by handler/method/status
    assert 'handler="/version"' in body or "/version" in body


def test_tracing_noop_without_endpoint(monkeypatch):
    monkeypatch.delenv("OTEL_EXPORTER_OTLP_ENDPOINT", raising=False)
    # must not raise, must not install a provider
    assert main._maybe_init_tracing() is None


def test_tracing_init_with_unreachable_endpoint(monkeypatch):
    # A dead collector must not break the app — spans buffer and drop.
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
    assert main._maybe_init_tracing() is None
    c = _client()
    assert c.get("/health").status_code == 200
    assert c.get("/version").status_code == 200


def test_metrics_not_fault_injected(monkeypatch):
    # /metrics is infrastructure: FAULT_RATE must not corrupt it.
    monkeypatch.setenv("FAULT_RATE", "1.0")
    c = _client()
    assert c.get("/metrics").status_code == 200
