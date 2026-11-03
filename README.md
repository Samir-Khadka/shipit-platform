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
| 1 | k3s cluster + ArgoCD app-of-apps GitOps | ✅ done |
| 2 | Supply-chain gates: Trivy blocking, cosign, Kyverno policies | ✅ done |
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

## Phase 1: GitOps core — how the loop works

```
merge to main
  → CI: pytest → build 3 images → push ghcr.io/samir-khadka/shipit-*:<sha>
  → CI commits "[ci] bump image tags to <sha>" (k8s/base/*.yaml)
  → ArgoCD (auto-sync, prune, selfHeal) rolls the new images into k3s
```

Nobody runs `kubectl apply` by hand after bootstrap. Git is the single source
of truth; the `[ci]` tag-bump commits skip the rebuild (loop guard in ci.yml).

**Bootstrap it yourself:**

```bash
# Linux (needs sudo): installs k3s + ArgoCD v3.5.7, applies the root app
sudo ./scripts/bootstrap.sh

# Windows (PowerShell, Docker Desktop running): k3d + ArgoCD v3.5.7
.\scripts\bootstrap.ps1
```

**Watch a sync:**

```bash
# ArgoCD UI (admin / <initial password>)
kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# cluster state
kubectl -n shipit get pods -w
kubectl -n argocd get applications
```

Try the loop: edit `APP_VERSION` in `k8s/base/api.yaml`, push to main, and
watch ArgoCD pick it up — no manual `kubectl` involved.

*Verified: the CI → GHCR → tag-bump loop runs live on GitHub Actions;
manifests pass kubeconform (Kubernetes 1.33) and yamllint; the cluster
bootstrap itself runs on your machine via `scripts/` (it needs a real
host with cgroups — a container sandbox can't run k3s).*

## Phase 2: supply-chain gates — the trust chain

No unsigned, vulnerable, or `:latest` image can reach the cluster:

```
CI:  build → Trivy scan (fail on HIGH/CRITICAL, fixable) → push → cosign sign (keyless OIDC)
Cluster: Kyverno admission policies (Enforce)
  1. require-image-signatures — every ghcr.io/samir-khadka/shipit-* image must
     carry a keyless Sigstore signature minted by main-branch CI
  2. disallow-latest-tag     — ':latest' is rejected; only immutable :<sha> tags
  3. require-requests-limits  — every container sets cpu/memory requests + limits
  4. require-pod-security     — no privileged containers, runAsNonRoot enforced
```

**Severity choice (Trivy):** the gate fails on HIGH and CRITICAL
vulnerabilities *with a fix available* (`ignore-unfixed: true`). This keeps the
gate actionable — it blocks on what we can actually fix, instead of failing
every build on unfixable base-image/kernel noise. The full table still prints
in the CI log for review.

**Keyless signing:** no private keys exist anywhere. CI mints an OIDC identity
(`.../ci.yml@refs/heads/main`), Fulcio issues a short-lived certificate,
Rekor logs the signature publicly. Signatures bind to the image *digest*, so
the `[ci]` tag-bump commit (which only rewrites k8s YAML) stays valid.
**Key rotation: nothing to rotate** — there are no long-lived keys; trust comes
from the GitHub OIDC issuer + the public Sigstore roots, and the Kyverno
policy pins the exact workflow identity allowed to sign.

**Kyverno is GitOps-managed too:** `k8s/apps/kyverno.yaml` installs Kyverno
v1.19.2 (Helm chart 3.9.2, pinned) via ArgoCD, and `k8s/apps/kyverno-policies.yaml`
syncs `k8s/security/policies/` right after (sync-wave 2, once the CRDs exist).

**Prove it offline** (no cluster needed — the Kyverno CLI runs the policies
against test fixtures, including a real unsigned GHCR image):

```bash
kyverno test k8s/security/tests/disallow-latest    # :latest REJECTED, :sha ALLOWED
kyverno test k8s/security/tests/require-limits     # missing resources REJECTED
kyverno test k8s/security/tests/require-pod-security
kyverno test k8s/security/tests/require-signatures # unsigned image REJECTED (needs network)
```

The negative path is exercised by these CLI tests; CI proves the positive path
every run (Trivy green + cosign signature created). The one thing deliberately
*not* done: planting a fake vulnerability to force a red build — the gate's
config is what's under test, and a passing scan is the honest claim.

## Layout

```
apps/api/        FastAPI service (/health, /version, /echo, /count)
apps/worker/     Node.js health-poller (zero deps)
apps/web/        static frontend showing the serving API version
docker/          container conventions
k8s/base/        Namespace + Deployments/Services for api, worker, web
k8s/apps/        ArgoCD Applications (one per service) — the app-of-apps leaves
k8s/argocd/      root Application (shipit-root) pointing at k8s/apps
k8s/security/    ClusterPolicies (Kyverno) + offline CLI tests proving them
scripts/         bootstrap.sh (Linux/k3s) and bootstrap.ps1 (Windows/k3d)
.github/         CI: test → build → Trivy scan → push → cosign sign → bump image tags
```
