# ShipIt — a self-driving delivery platform

A portfolio project demonstrating platform engineering: you merge code, the
platform does everything else — build, scan, sign, deploy, canary, observe,
and heal. Nobody touches the cluster by hand.

## Vision

```
  ┌──────────┐  push   ┌───────────────────────────────────────────────┐
  │  GitHub  │ ──────► │ CI: test → Trivy scan → cosign sign → GHCR     │
  └──────────┘         └──────────────────────┬────────────────────────┘
                                              │ image tag bump in Git
                                              ▼
                        ┌───────────────────────────────────────────────┐
                        │ ArgoCD (app-of-apps): Git is the source of     │
                        │ truth — syncs the k3s cluster automatically    │
                        └──────────────────────┬────────────────────────┘
                                               ▼
                        ┌───────────────────────────────────────────────┐
                        │ Flagger + Linkerd: canary 10% → 50% → 100%,    │
                        │ automatic rollback on error-budget burn        │
                        └──────────────────────┬────────────────────────┘
                                               ▼
                        ┌───────────────────────────────────────────────┐
                        │ Prometheus + Grafana + Loki + Tempo: metrics,  │
                        │ logs, traces, SLO burn-rate alerts             │
                        └──────────────────────┬────────────────────────┘
                                               ▼
                        ┌───────────────────────────────────────────────┐
                        │ Chaos Mesh: scheduled pod-kills prove the      │
                        │ platform heals itself                          │
                        └───────────────────────────────────────────────┘
```

The demo app is a tiny polyglot microservice (`apps/`): a Python FastAPI
service, a Node.js worker that polls it, and a static frontend that shows
which API version served the page — the version display is what the Phase 3
canary demo flips between releases.

## Phase roadmap

| Phase | Goal | Status |
|-------|------|--------|
| 0 | Scaffold: demo microservice, Dockerfiles, CI → GHCR | ✅ done |
| 1 | k3s cluster + ArgoCD app-of-apps GitOps | planned |
| 2 | Supply-chain gates: Trivy blocking, cosign, Kyverno policies | planned |
| 3 | Flagger + Linkerd canaries with auto-rollback | planned |
| 4 | Observability: Loki, Tempo, SLO dashboards, Alertmanager | planned |
| 5 | Chaos experiments, architecture diagram, runbook, demo video | planned |

## Free-tier notes

Everything here runs free: k3d on a laptop today, Oracle Cloud Ampere
(4 OCPU / 24 GB) later — same manifests either way. GHCR hosts the images,
all tooling is open source. No cloud bill, no secrets in the repo.

## Quickstart (Phase 0)

```bash
# API
cd apps/api && pip install -r requirements.txt && uvicorn main:app --port 8000

# worker (needs the API up)
cd apps/worker && API_URL=http://localhost:8000 node worker.js

# web: serve apps/web statically (e.g. python3 -m http.server) and open index.html
```

## Layout

```
apps/api/        FastAPI service (/health, /version, /echo, /count)
apps/worker/     Node.js health-poller (zero deps)
apps/web/        static frontend showing the serving API version
docker/          container conventions
k8s/             manifests land here from Phase 1 (README for now)
.github/         CI: test → build → push images to GHCR
```
