# ShipIt demo video — 5-minute script

> **A note on honesty before you press record.** This script was written
> without a live cluster — the build environment can't run k3s — so every
> timestamp below is an estimate, not a promise. Do one dry run first and
> adjust the timings to what your machine actually does. If a step behaves
> differently on camera, say what you see; the platform's story survives
> honest narration, and nothing here asks you to fake a result.

**Setup (before recording):** cluster bootstrapped (`.\scripts\bootstrap.ps1`),
Grafana port-forwarded to `localhost:3000`, ArgoCD UI open in a second tab,
terminal with a large font. Have `scripts/demo-canary.md` open for the exact
canary commands.

---

## 0:00–0:30 — The problem (talking head or title card)

> "Every team says they do GitOps. Most teams still `kubectl apply` by hand,
> still get paged at 2am for a bad deploy, and still find out about an outage
> from a customer. ShipIt is a platform where you merge code — and the
> platform does everything else: build, scan, sign, deploy, canary, observe,
> and heal. Let me show you."

**Shot:** title card with the architecture diagram (`docs/architecture.md`).

## 0:30–1:15 — The loop (terminal)

> "Watch the loop. I change one line — the API version — and push."

**Shots / commands:**

```bash
# edit APP_VERSION in k8s/base/api.yaml, then:
git add -A && git commit -m "demo: bump api to v9.9.9" && git push
```

Cut to the GitHub Actions run: tests → build → **Trivy scan** → push to
GHCR → **cosign sign** → the `[ci]` tag-bump commit. Then the ArgoCD UI:
the `shipit-api` app syncs by itself.

> "No `kubectl apply`. Git is the only source of truth. And notice the scan
> and the signature — no unsigned or vulnerable image can reach the cluster.
> Kyverno enforces that at admission."

**Shot:** `kyverno test k8s/security/tests/require-signatures` passing
locally (proves the gate offline, no cluster needed).

## 1:15–2:30 — The money shot: canary auto-rollback (terminal + Grafana)

> "Now the part that pages people at 2am. I ship a bad build — this one
> fails 30% of requests — and I don't touch anything. Watch Flagger."

**Shots / commands** (from `scripts/demo-canary.md`):

```bash
kubectl -n shipit get canary shipit-api -w     # 10% → 50% → Halt
kubectl -n flagger logs -l app.kubernetes.io/name=flagger -f
# "...Halt ... success rate ~70% < 99%..."
```

> "The canary burned its error budget, Flagger halted the analysis, and
> traffic is back on the primary. The bad build never served real users.
> The 2am page just… didn't happen."

**Shot:** Grafana "ShipIt SLOs" dashboard — the burn-rate spike during the
halted canary.

## 2:30–3:30 — Observability: one dashboard tells the story (browser)

> "Everything the platform did is visible in one place."

**Shots:** Grafana `localhost:3000` — "ShipIt Golden Signals" (request
rate, error rate, p99 per service), then "ShipIt SLOs" (error budget
remaining, burn rates). Click into Tempo for a trace, Loki for the api's
logs during the canary.

> "Metrics, logs, traces — and the alerts are SLO burn-rate alerts, not
> threshold spam. Fast burn pages, slow burn warns."

## 3:30–4:15 — Chaos: prove it heals (terminal + Grafana)

> "A platform that can't prove it heals is a slide deck. Chaos Mesh is
> installed as code; the experiments are applied by hand — deliberately."

**Shots / commands:**

```bash
kubectl apply -f k8s/chaos/pod-kill-api.yaml
kubectl -n shipit get pods -w     # one api pod dies, a fresh one appears
```

> "One pod killed, the Deployment recreated it in seconds, ArgoCD stayed
> green — nothing in Git changed, so there was nothing to fight."

```bash
kubectl apply -f k8s/chaos/network-delay-api.yaml
# Grafana: p99 climbs past the 500ms line on the SLO dashboard
kubectl delete -f k8s/chaos/network-delay-api.yaml
```

## 4:15–5:00 — Closing (talking head)

> "Merge → tested → scanned → signed → deployed → canaried → observed →
> healed. Five phases, one command to bootstrap, zero cloud bill — k3d on
> a laptop today, Oracle Ampere later, same manifests. The repo is linked
> below; the architecture doc has the full diagram. If you run platform
> teams, you know which of these pieces is the hardest — it's the rollback.
> And that one's automatic."

**End card:** repo URL, `docs/architecture.md`, "star if you steal ideas".

---

### Shot checklist

- [ ] Title card + architecture diagram
- [ ] Terminal: version bump → push
- [ ] Browser: GitHub Actions run (scan + sign steps visible)
- [ ] Browser: ArgoCD UI syncing `shipit-api`
- [ ] Terminal: `kyverno test` green
- [ ] Terminal: `kubectl get canary -w` → Halt + Flagger logs
- [ ] Browser: Grafana SLO dashboard during the halt
- [ ] Browser: Golden Signals + one Tempo trace + Loki log tail
- [ ] Terminal: pod-kill → pod recreated
- [ ] Browser: p99 spike on network-delay, then recovery
- [ ] Talking head: problem (0:00) + closing (4:15)
