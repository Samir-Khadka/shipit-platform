"use strict";
/* ShipIt demo worker — polls the API's /health on an interval and logs the
   result as JSON. Demonstrates inter-service communication; zero npm
   dependencies (uses the global fetch available in Node 18+). */
const API_URL = process.env.API_URL || "http://localhost:8000";
const INTERVAL_MS = Number.parseInt(process.env.POLL_INTERVAL_MS || "5000", 10);

async function checkOnce() {
  const started = Date.now();
  try {
    const res = await fetch(`${API_URL}/health`);
    const body = await res.json();
    console.log(
      JSON.stringify({
        ts: new Date().toISOString(),
        ok: res.ok,
        status: res.status,
        latencyMs: Date.now() - started,
        version: body.version || null,
      }),
    );
  } catch (err) {
    console.error(
      JSON.stringify({
        ts: new Date().toISOString(),
        ok: false,
        error: String((err && err.message) || err),
      }),
    );
  }
}

checkOnce();
setInterval(checkOnce, INTERVAL_MS);
