# ShipIt runbook

Practical operations for the platform. Every command here is meant to be
run on the machine hosting the cluster (your laptop via k3d, or Oracle
Ampere later) — replace `k3s kubectl` with `kubectl` on k3d/Windows.

## Bootstrap

```bash
# Linux (needs sudo)
sudo ./scripts/bootstrap.sh

# Windows (PowerShell, Docker Desktop running)
.\scripts\bootstrap.ps1
```

The script is idempotent-ish: it skips install steps that are already done,
reapplies the root app, and waits for every Application to go Healthy. On a
re-run over an existing cluster it also restarts the shipit workloads so the
Linkerd sidecar gets injected into pods that predate the mesh.

After bootstrap:

```bash
# ArgoCD UI (admin / initial password)
k3s kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080
k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Grafana (admin / password from the secret below)
k3s kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80  # http://localhost:3000
k3s kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## Adding a new service

Say you want a fourth service, `notifier`. The checklist:

1. **Code + Dockerfile** in `apps/notifier/` (the image must run non-root —
   Kyverno's `require-pod-security` enforces it).
2. **CI matrix**: add `notifier` to `service: [api, worker, web]` in
   `.github/workflows/ci.yml`. The build context is `apps/<service>` and the
   tag-bump job rewrites `k8s/base/<service>.yaml`.
3. **Manifests** `k8s/base/notifier.yaml`: Deployment + Service. The image
   line must look like `image: ghcr.io/samir-khadka/shipit-notifier:<sha>` —
   the tag-bump `sed` replaces everything after the colon on a matching
   `shipit-<svc>:` line, so keep that exact shape. Set CPU/memory
   requests+limits on every container and `runAsNonRoot: true`
   (both are Enforce policies).
4. **ArgoCD: nothing to do.** All three service Applications
   (`k8s/apps/api.yaml`, `worker.yaml`, `web.yaml`) sync the whole
   `k8s/base` path, so `k8s/base/notifier.yaml` is picked up automatically
   on the next sync.
5. **Push to main.** CI builds, scans, signs, bumps the tag; ArgoCD syncs.
   Verify: `k3s kubectl -n argocd get application notifier` → Healthy.
6. **Optional extras**: a Flagger Canary (copy `k8s/canary/api-canary.yaml` +
   MetricTemplates, retarget the Deployment), a ServiceMonitor in
   `k8s/observability/config/` for the Golden Signals dashboard, chaos
   experiments in `k8s/chaos/`.

## Common failures

### ImagePullBackOff on a shipit pod

The image tag in `k8s/base/*.yaml` doesn't exist in GHCR — usually a
tag-bump race (two CI runs, the older one lost) or a failed build.

```bash
k3s kubectl -n shipit get pods                      # which pod, which image
k3s kubectl -n shipit describe pod <pod> | grep -A3 Events
# fix: check the CI run for that SHA; if the build failed, fix and push —
# the next green run bumps the tag again and ArgoCD self-heals.
```

### ArgoCD app OutOfSync / Degraded

```bash
k3s kubectl -n argocd get applications
# OutOfSync with automated selfHeal: wait a minute, then look at the diff
# in the ArgoCD UI (https://localhost:8080). If selfHeal is fighting a
# controller (like Flagger mutating replicas), the app needs an
# ignoreDifferences entry — see k8s/apps/api.yaml for the pattern.
```

### Flagger canary stuck in "Halted"

A halted canary means the analysis failed — that is the system working.
Traffic stays on the primary; nothing serves the bad build.

```bash
k3s kubectl -n shipit describe canary shipit-api   # events show which check failed
k3s kubectl -n flagger logs -l app.kubernetes.io/name=flagger --tail=50
# Push a fixed build: the next revision restarts the analysis from scratch.
# There is no "resume" button — a new push is the resume.
```

### Kyverno blocking a pod (you see the policy name in the event)

```bash
k3s kubectl get events -A --field-selector reason=PolicyViolation | head
# Common causes: image without a cosign signature (did CI sign it?),
# a :latest tag, missing requests/limits, running as root.
# Test the fix offline first:
kyverno test k8s/security/tests/require-limits
kyverno test k8s/security/tests/require-pod-security
```

### Prometheus / Loki / Tempo down

```bash
k3s kubectl -n argocd get application kube-prometheus-stack loki tempo observability-config
# Degraded → check the UI for the failing resource; often a PVC or OOMKill
# on the free-tier node (these components have modest limits by design —
# raise them in k8s/observability/*-values.yaml if the node allows it).
k3s kubectl -n monitoring get pods
k3s kubectl -n monitoring top pods   # needs metrics-server; k3s ships it
```

### Chaos experiment won't go away

Experiments are self-terminating (`duration`), but if one lingers:

```bash
k3s kubectl get podchaos,networkchaos -A
k3s kubectl delete -f k8s/chaos/<experiment>.yaml
# Nuclear option (keeps Chaos Mesh installed, removes all experiments):
k3s kubectl delete podchaos,networkchaos --all -A
```

### Starting over

```bash
# k3s: uninstall and re-bootstrap (deletes EVERYTHING on the node)
sudo /usr/local/bin/k3s-uninstall.sh && sudo ./scripts/bootstrap.sh
# k3d (Windows): delete the cluster in Docker Desktop, then .\scripts\bootstrap.ps1
```

## Where things live

| What | Where |
|---|---|
| Demo app code | `apps/api`, `apps/worker`, `apps/web` |
| CI (test → scan → sign → bump) | `.github/workflows/ci.yml` |
| Workload manifests | `k8s/base/` |
| ArgoCD Applications | `k8s/apps/` (root: `k8s/argocd/root-app.yaml`) |
| Canary + metrics | `k8s/canary/` |
| Kyverno policies + CLI tests | `k8s/security/` |
| Observability values/dashboards/rules | `k8s/observability/` |
| Chaos experiments (manual apply) | `k8s/chaos/` |
| Bootstrap + demos | `scripts/` |
