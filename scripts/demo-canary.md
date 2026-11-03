# Demo: canary releases with automatic rollback (Phase 3)

**The one-liner:** push a good build → watch Flagger shift traffic 10% → 50% →
100%. Push a bad build (`FAULT_RATE=0.3`) → watch the error budget burn and
Flagger roll it back by itself. Nobody runs `kubectl rollout undo`.

**Prerequisites:** `./scripts/bootstrap.sh` (Linux) or `.\scripts\bootstrap.ps1`
(Windows) has run clean — Linkerd, Flagger, and the `shipit-api` Canary are
all Healthy in ArgoCD.

---

## 0. Start the load generator (do this first, leave it running)

Flagger's analysis needs live traffic, and there is a Linkerd subtlety that
decides *where* that traffic must come from: **traffic splitting happens in
the caller's sidecar proxy (client-side)**. Requests from outside the mesh —
your laptop via port-forward, curl from the node — always land on the primary
and never exercise the canary. So the load generator must run *inside* the
`shipit` namespace (which carries `linkerd.io/inject: enabled`).

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loadgen
  namespace: shipit
spec:
  replicas: 2
  selector:
    matchLabels:
      app: loadgen
  template:
    metadata:
      labels:
        app: loadgen
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: curl
          image: curlimages/curl:8.23.0   # pinned (Kyverno disallows :latest)
          command: ["/bin/sh", "-c"]
          args:
            - |
              while true; do
                curl -s -o /dev/null -w "%{http_code}\n" \
                  -X POST http://shipit-api:8000/echo \
                  -H 'Content-Type: application/json' \
                  -d '{"message":"canary-probe"}';
                sleep 0.2;
              done
          resources:                       # Kyverno require-requests-limits
            requests: {cpu: 25m, memory: 32Mi}
            limits:   {cpu: 100m, memory: 64Mi}
EOF
```

Two replicas × ~5 rps ≈ 10 rps of meshed `POST /echo` traffic — plenty for
Flagger's 1-minute metric windows. (`/echo` is one of the two endpoints the
`FAULT_RATE` injector faults; `/health` is the other.)

Sanity check — the canary should be `Initialized` and the pods meshed:

```bash
kubectl -n shipit get canary shipit-api
kubectl -n shipit get pods -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
# every api/worker pod line should include "linkerd-proxy"
```

---

## 1. The good canary: ship v2 and watch it promote

In `k8s/base/api.yaml`, bump the version (this is the same GitOps loop as
Phase 1 — the `[ci]` tag-bump keeps working underneath):

```yaml
env:
  - name: APP_VERSION
    value: v2.0.0
```

```bash
git add k8s/base/api.yaml
git commit -m "demo: ship api v2.0.0"
git push origin main
```

What happens, in order:

1. CI builds, Trivy-scans, cosign-signs, and pushes the image, then commits
   `[ci] bump image tags to <sha>` — the Kyverno gates from Phase 2 still
   guard every step.
2. ArgoCD syncs the new image into the `shipit-api` Deployment. (It leaves
   `/spec/replicas` and the Service `/spec/selector` alone — see the
   `ignoreDifferences` on the `shipit-api` app. That's the ArgoCD↔Flagger
   truce.)
3. Flagger notices the pod-template change, scales the canary up, and the
   analysis starts: **10% → 50% → 100%**, one 30-second step at a time, each
   gated on the canary's own success rate ≥ 99% and p99 ≤ 500ms (queried from
   Linkerd's Prometheus).
4. All checks pass → Flagger promotes: the primary is updated to v2.0.0, the
   canary scales back to 0.

**Watch it live** (three terminals):

```bash
# T1 — Flagger's decisions, in plain English
kubectl -n flagger logs -l app.kubernetes.io/name=flagger -f | grep -i "canary\|promotion\|advance"

# T2 — the Canary resource status
kubectl -n shipit describe canary shipit-api
# ..or watch the weight move: kubectl -n shipit get canary shipit-api -w

# T3 — the HTTPRoute weights Flagger rewrites each step
kubectl -n shipit get httproute shipit-api -o yaml | grep -A3 "weight:"
```

And the money view — which version is actually serving traffic:

```bash
kubectl -n shipit port-forward svc/shipit-api 8000:8000 &
# NOTE: this port-forward is NOT meshed, so it always hits the primary.
# During the canary it shows v1.0.0; after promotion it flips to v2.0.0.
while true; do curl -s localhost:8000/version; echo; sleep 2; done
```

For the meshed view (sees the split), ask the loadgen's-eye view instead —
or just trust Flagger's events. The web frontend (`apps/web`) shows the
serving version too once it's port-forwarded.

When it's done: `kubectl -n shipit get canary shipit-api` shows
`Succeeded`, and `/version` reports `v2.0.0` everywhere.

---

## 2. The bad canary: burn the error budget, watch the rollback

Same loop, but this time the release is deliberately faulty. `FAULT_RATE`
is a **demo-only** knob in `apps/api` (default `0` = off): at `0.3`, `/echo`
and `/health` return HTTP 500 for ~30% of requests.

> **Why 0.3 and not 1.0?** At `1.0` the canary pods never pass their
> readiness probe, so Flagger rolls back on the *progress deadline* without
> ever running a metric check — a rollback, but a boring one. At `0.3` the
> pods go ready, take real traffic, and the *error budget* burns: the
> canary-scoped success rate drops to ~70%, below the 99% threshold, and the
> rollback is driven by metrics — the actual Phase 3 story.

In `k8s/base/api.yaml`:

```yaml
env:
  - name: APP_VERSION
    value: v3.0.0
  - name: FAULT_RATE
    value: "0.3"
```

```bash
git add k8s/base/api.yaml
git commit -m "demo: ship api v3.0.0 (faulty — FAULT_RATE=0.3)"
git push origin main
```

What happens:

1. Same CI → tag-bump → ArgoCD sync as before. Note the supply-chain gates
   don't stop this — the image is properly built, scanned, and signed; it's
   *behaviorally* bad, which is exactly what canaries are for.
2. Flagger shifts 10% of traffic to the faulty canary.
3. Within one or two 30s checks, the canary's success rate (≈70%) trips the
   `min: 99` threshold. After 3 failed checks Flagger **halts the analysis,
   scales the canary to 0, and leaves the primary (v2.0.0) serving 100%**.
4. The Canary status goes to `Failed` — with events naming the exact metric
   that burned.

**Watch it:**

```bash
# The moment of failure, in Flagger's own words:
kubectl -n flagger logs -l app.kubernetes.io/name=flagger -f | grep -i "halt\|rollback\|failed"

# Expected: something like
#   Halt shipit-api.shipit advancement success rate 70.12% < 99%
#   Rolling back shipit-api.shipit failed canary deployment

kubectl -n shipit describe canary shipit-api | grep -A5 "Events:"
```

Verify the rollback landed — the primary still serves v2.0.0, and the
faulty pods are gone:

```bash
curl -s localhost:8000/version   # -> {"service":"shipit-api","version":"v2.0.0"}
kubectl -n shipit get pods -l app.kubernetes.io/name=shipit-api
# only shipit-api-primary-* pods remain; no canary pods
```

Then clean up the demo knob (so the next real release isn't faulty):

```yaml
# k8s/base/api.yaml — remove the FAULT_RATE env var (or set "0")
```

```bash
git add k8s/base/api.yaml && git commit -m "demo: FAULT_RATE back to 0" && git push origin main
kubectl -n shipit delete deployment loadgen   # stop the load generator
```

---

## 3. Where to look (the observability tour)

| What | Command |
|------|---------|
| Flagger's brain | `kubectl -n flagger logs -l app.kubernetes.io/name=flagger -f` |
| Canary status | `kubectl -n shipit describe canary shipit-api` |
| Live HTTPRoute weights | `kubectl -n shipit get httproute shipit-api -o yaml` |
| Canary-scoped metrics | `kubectl -n shipit describe metrictemplate shipit-api-success-rate` |
| Linkerd dashboard | `kubectl -n linkerd-viz port-forward svc/web 8084:8084` → https://localhost:8084 |
| Raw Prometheus (what Flagger queries) | `kubectl -n linkerd-viz port-forward svc/prometheus 9090:9090` → http://localhost:9090, try `sum(rate(response_total{namespace="shipit",direction="inbound"}[1m])) by (deployment)` |
| ArgoCD apps | `kubectl -n argocd get applications` |

---

## How the pieces fit (architecture)

```
push to main
  └─► CI (test → Trivy → cosign → GHCR → [ci] tag-bump)   [Phase 0+2]
        └─► ArgoCD syncs shipit-api Deployment             [Phase 1]
              └─► Flagger sees new pod template
                    ├─► canary pods up (10% of traffic via HTTPRoute,
                    │   enforced by Linkerd sidecars — client-side)
                    ├─► analysis: 30s checks against Linkerd Prometheus
                    │   (canary-scoped: deployment="shipit-api" exact match,
                    │   so the primary's healthy traffic can't dilute it)
                    ├─► all green → 50% → 100% → promote (primary := canary)
                    └─► budget burned → halt → canary to 0 → primary keeps serving
```

**Why `gatewayapi:v1` and not Flagger's `linkerd` provider?** In Flagger
1.45.0 the `linkerd` provider drives SMI TrafficSplits, which Linkerd 2.14 no
longer implements — the supported Flagger+Linkerd path (see
`flagger/kustomize/linkerd`) is the Gateway API provider, so Flagger manages
an `HTTPRoute` and Linkerd's data plane enforces the split. Verified against
the Flagger v1.45.0 source, not just the docs.

**ArgoCD ↔ Flagger truce:** Flagger mutates the `shipit-api` Deployment's
`/spec/replicas` (scales the canary) and the apex Service's `/spec/selector`
(points direct traffic at the primary). The `shipit-api` ArgoCD app declares
`ignoreDifferences` on both plus `RespectIgnoreDifferences=true`, so selfHeal
doesn't revert Flagger's live state. Everything Flagger *creates* (primary
Deployment, `-canary`/`-primary` Services, HTTPRoute) carries no ArgoCD
tracking annotation, so prune ignores it.

**Kyverno in Phase 3:** the `require-image-signatures` policy only matches
`ghcr.io/samir-khadka/shipit-*`, so upstream Linkerd/Flagger images are
unaffected. `linkerd`, `linkerd-viz`, and `flagger` namespaces are explicitly
excluded from `require-requests-limits` and `require-pod-security` (documented
in the policies — upstream charts don't set complete resources/pod security
contexts, and forking their specs isn't worth it). Injected `linkerd-proxy`
sidecars *do* get resources via the control-plane app's `proxy.resources`
values, so shipit pods still pass the gates.
