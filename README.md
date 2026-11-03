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
| 3 | Flagger + Linkerd canaries with auto-rollback | ✅ done |
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

> **cosign ↔ Kyverno compatibility:** cosign v3 defaults to storing signatures
> via the OCI 1.1 referrers API, but Kyverno v1.19.2 only looks up the legacy
> `.sig` tag scheme. CI therefore uses cosign **v2.4.3**, which writes `.sig`
> tags, so signer and verifier agree. (Caught during Phase 2 verification:
> v3 referrer-stored signatures were invisible to Kyverno's `verifyImages` —
> failing closed — while v2 tag signatures verify correctly.)

**Kyverno is GitOps-managed too:** `k8s/apps/kyverno.yaml` installs Kyverno
v1.19.2 (Helm chart 3.9.2, pinned) via ArgoCD, and `k8s/apps/kyverno-policies.yaml`
syncs `k8s/security/policies/` right after (sync-wave 2, once the CRDs exist).

**Prove it offline** (no cluster needed — the Kyverno CLI runs the policies
against test fixtures, including a real unsigned GHCR image):

```bash
kyverno test k8s/security/tests/disallow-latest    # :latest REJECTED, :sha ALLOWED
kyverno test k8s/security/tests/require-limits     # missing resources REJECTED
kyverno test k8s/security/tests/require-pod-security
kyverno test k8s/security/tests/require-signatures # unsigned REJECTED, signed ALLOWED (needs network)
```

The negative path is exercised by these CLI tests; CI proves the positive path
every run (Trivy green + cosign signature created, and the CLI test suite
includes a signed-image ALLOWED case against a real CI-signed GHCR image).
The one thing deliberately *not* done: planting a fake vulnerability to force
a red build — the gate's config is what's under test, and a passing scan is
the honest claim.

## Phase 3: progressive delivery — canaries with automatic rollback

Push a release; Flagger + Linkerd shift traffic 10% → 50% → 100% while
watching the canary's error budget. Burn the budget and the release rolls
itself back — no human `kubectl` involved.

```
push to main → CI → ArgoCD syncs shipit-api → Flagger sees new pod template
  → canary pods up, HTTPRoute splits 10/50/100 (Linkerd sidecars enforce it)
  → 30s metric checks vs Linkerd Prometheus (viz-bundled; no separate stack)
  → green: promote (primary := canary) | red: halt, canary → 0, primary serves
```

**Install it:** `./scripts/bootstrap.sh` (or `bootstrap.ps1`) — it installs the
Gateway API CRDs (v1.7.0, pinned), then ArgoCD syncs Linkerd (CRDs 1.8.0 →
control plane 1.16.11 → viz 30.12.11, all pinned) and Flagger 1.45.0, all as
GitOps-managed Applications under `k8s/apps/`. The mesh injects a sidecar
into every `shipit` pod (`linkerd.io/inject: enabled` on the namespace).

**Demo it:** `scripts/demo-canary.md` — the full walkthrough: ship a good
`v2.0.0` and watch it promote, then ship a faulty `v3.0.0` with
`FAULT_RATE=0.3` (a demo-only knob in `apps/api` that 500s `/echo` and
`/health` at the configured probability, default `0` = off) and watch
Flagger halt the analysis and roll back to the primary on metrics alone.

**Design notes worth knowing:**

- **Provider:** Flagger 1.45.0's `linkerd` provider drives SMI TrafficSplits,
  which Linkerd 2.14 no longer implements. The supported path (mirroring
  `flagger/kustomize/linkerd`, verified against the Flagger source) is
  `mesh-provider=gatewayapi:v1`: Flagger manages a Gateway API `HTTPRoute`
  attached to the apex Service, Linkerd's data plane enforces the split.
- **Canary-scoped metrics** (`k8s/canary/metrics.yaml`): Flagger's built-in
  Linkerd queries use `deployment=~"{{ target }}"`, a regex that also matches
  the `-primary` deployment — the primary's healthy traffic would dilute the
  canary's signal. The custom MetricTemplates use an exact
  `deployment="shipit-api"` match, so the analysis judges the canary alone:
  success rate < 99% or p99 > 500ms → rollback.
- **ArgoCD ↔ Flagger truce** (`k8s/apps/api.yaml`): Flagger mutates the
  Deployment's `/spec/replicas` and the apex Service's `/spec/selector` at
  runtime; `ignoreDifferences` + `RespectIgnoreDifferences=true` stop selfHeal
  from reverting them. Flagger-created resources carry no ArgoCD tracking
  annotation, so prune leaves them alone.
- **Kyverno compatibility:** `require-image-signatures` only matches
  `ghcr.io/samir-khadka/shipit-*` (upstream images unaffected).
  `linkerd`/`linkerd-viz`/`flagger` namespaces are explicitly excluded from
  `require-requests-limits` and `require-pod-security` — documented in the
  policies, with a CLI test proving the carve-out. Injected `linkerd-proxy`
  sidecars get resources from the control-plane app's `proxy.resources`
  values, so shipit pods still pass every gate.
- **Client-side routing caveat:** the split is enforced in the *caller's*
  sidecar, so canary traffic must originate inside the mesh — the demo's load
  generator runs as a Deployment in the `shipit` namespace. Port-forwards from
  your laptop always hit the primary (handy for confirming the rollback).

*Verified: manifests pass yamllint + kubeconform (Kubernetes 1.33; CRDs
validated field-by-field against the Flagger v1.45.0 source), api pytest
suite green (9/9, incl. 4 new FAULT_RATE tests), Kyverno CLI tests green
(9/9, incl. the new carve-out case), all version pins checked live (Helm
indexes, release assets, chart values). The live canary demo itself runs on
your machine via `scripts/` — same constraint as Phase 1 (this sandbox can't
run k3s).*

## Layout

```
apps/api/        FastAPI service (/health, /version, /echo, /count; FAULT_RATE demo fault injector)
apps/worker/     Node.js health-poller (zero deps)
apps/web/        static frontend showing the serving API version
docker/          container conventions
k8s/base/        Namespace + Deployments/Services for api, worker, web
k8s/apps/        ArgoCD Applications (one per service) — the app-of-apps leaves
k8s/argocd/      root Application (shipit-root) pointing at k8s/apps
k8s/canary/      Flagger Canary + MetricTemplates for shipit-api (Phase 3)
k8s/security/    ClusterPolicies (Kyverno) + offline CLI tests proving them
scripts/         bootstrap.sh (Linux/k3s) and bootstrap.ps1 (Windows/k3d),
                 demo-canary.md (the canary walkthrough)
.github/         CI: test → build → Trivy scan → push → cosign sign → bump image tags
```
