"use strict";
/* ShipIt demo frontend logic — no framework. Calls the API's /version and
   functional endpoints and renders which backend version served the page. */
const API = window.SHIPIT_API_URL || "http://localhost:8000";

async function api(path, opts) {
  const res = await fetch(`${API}${path}`, opts);
  if (!res.ok) throw new Error(`HTTP ${res.status} on ${path}`);
  return res.json();
}

async function refreshVersion() {
  try {
    const v = await api("/version");
    document.getElementById("version").textContent = v.version;
  } catch (e) {
    document.getElementById("version").textContent = `unreachable (${e.message})`;
  }
}

async function refreshCount() {
  const c = await api("/count");
  document.getElementById("countOut").textContent = JSON.stringify(c, null, 2);
}

document.getElementById("echoBtn").addEventListener("click", async () => {
  const message = document.getElementById("echoInput").value;
  const out = await api("/echo", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message }),
  });
  document.getElementById("echoOut").textContent = JSON.stringify(out, null, 2);
});

document.getElementById("incrBtn").addEventListener("click", async () => {
  await api("/count/incr", { method: "POST" });
  await refreshCount();
});

refreshVersion();
refreshCount();
