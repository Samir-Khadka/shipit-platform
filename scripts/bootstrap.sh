#!/usr/bin/env bash
# ShipIt Phase 1 bootstrap (Linux): k3s + ArgoCD + app-of-apps.
#
# Usage: sudo ./scripts/bootstrap.sh   (run from anywhere; finds the repo root)
#
# Idempotent-ish: skips k3s / ArgoCD install steps that are already done,
# then (re)applies the root app and waits for the demo to go healthy.
set -euo pipefail

ARGOCD_VERSION="v3.5.7"
# Phase 3 pins — verified live (HTTP 200 on the release assets / Helm index).
GATEWAY_API_VERSION="v1.7.0" # standard-install.yaml serves HTTPRoute v1
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (k3s needs it): sudo $0" >&2
  exit 1
fi

# 1. k3s ---------------------------------------------------------------
if ! command -v k3s >/dev/null 2>&1; then
  echo "==> Installing k3s..."
  curl -sfL https://get.k3s.io | sh -
else
  echo "==> k3s already installed, skipping"
fi
KUBECTL="k3s kubectl"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "==> Waiting for node to be Ready..."
$KUBECTL wait --for=condition=Ready --timeout=300s node --all

# 2. ArgoCD ------------------------------------------------------------
if ! $KUBECTL get namespace argocd >/dev/null 2>&1; then
  echo "==> Installing ArgoCD ${ARGOCD_VERSION}..."
  $KUBECTL create namespace argocd
  $KUBECTL apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
else
  echo "==> argocd namespace exists, skipping install"
fi
echo "==> Waiting for ArgoCD server..."
$KUBECTL -n argocd wait --for=condition=available --timeout=600s deployment/argocd-server

# 2.5 Gateway API CRDs (Phase 3) -----------------------------------------
# Flagger's Gateway API provider creates HTTPRoute objects; Linkerd's
# policy controller enforces them. Plain upstream CRDs — applied here (not
# via ArgoCD) because there is no Helm chart in the standard flow and
# vendoring ~2MB of generated CRDs into the repo would just be noise.
# Installed BEFORE the root app so the CRDs exist before Flagger syncs.
echo "==> Installing Gateway API CRDs ${GATEWAY_API_VERSION}..."
$KUBECTL apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
$KUBECTL wait --for=condition=Established --timeout=120s crd/httproutes.gateway.networking.k8s.io

# 3. App-of-apps --------------------------------------------------------
echo "==> Applying the root app-of-apps..."
$KUBECTL apply -f "${REPO_ROOT}/k8s/argocd/root-app.yaml"

echo "==> Waiting for demo apps to sync (this pulls images on first run)..."
for app in shipit-api shipit-worker shipit-web; do
  $KUBECTL -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
    --timeout=600s "application/${app}" \
    || echo "WARN: ${app} not Healthy yet — check the ArgoCD UI"
done

echo "==> Waiting for Kyverno + supply-chain policies (installed by ArgoCD)..."
for app in kyverno kyverno-policies; do
  $KUBECTL -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
    --timeout=600s "application/${app}" \
    || echo "WARN: ${app} not Healthy yet — check the ArgoCD UI"
done
echo "==> ClusterPolicies now enforced:"
$KUBECTL get clusterpolicies -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction 2>/dev/null \
  || echo "WARN: ClusterPolicies not visible yet — Kyverno may still be installing"

# 4. Service mesh + progressive delivery (Phase 3) ------------------------
echo "==> Waiting for Linkerd + Flagger (installed by ArgoCD)..."
for app in linkerd-crds linkerd-control-plane linkerd-viz flagger; do
  $KUBECTL -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
    --timeout=600s "application/${app}" \
    || echo "WARN: ${app} not Healthy yet — check the ArgoCD UI"
done

# The linkerd.io/inject annotation on the shipit namespace only affects pods
# created AFTER it syncs. On a re-run over an existing cluster the demo pods
# predate it, so restart them to get the sidecar (fresh clusters don't need
# this, and the restart is a harmless rolling update there).
echo "==> Restarting shipit workloads so the Linkerd sidecar is injected..."
$KUBECTL -n shipit rollout restart deployment/shipit-api deployment/shipit-worker deployment/shipit-web
$KUBECTL -n shipit rollout status --timeout=300s deployment/shipit-api \
  || echo "WARN: shipit-api rollout — Flagger may have scaled it to 0 already (normal after init)"

echo "==> Waiting for the canary definitions (installed by ArgoCD)..."
$KUBECTL -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  --timeout=600s "application/shipit-canary" \
  || echo "WARN: shipit-canary not Healthy yet — check the ArgoCD UI"

echo "==> Mesh check:"
if $KUBECTL -n shipit get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null | grep -q linkerd-proxy; then
  echo "    linkerd-proxy sidecar present on shipit pods"
else
  echo "    WARN: no linkerd-proxy sidecar found — run: k3s kubectl -n shipit rollout restart deployment/shipit-api deployment/shipit-worker deployment/shipit-web"
fi
$KUBECTL -n shipit get canary shipit-api -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null \
  || echo "    (canary resource not visible yet — Flagger may still be starting)"

# 5. Observability (Phase 4) ----------------------------------------------
# kube-prometheus-stack + Loki + Tempo install via ArgoCD (sync wave 2),
# our ServiceMonitors/Rules/dashboards via observability-config (wave 3).
echo "==> Waiting for the observability stack (installed by ArgoCD)..."
for app in kube-prometheus-stack loki tempo observability-config; do
  $KUBECTL -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
    --timeout=900s "application/${app}" \
    || echo "WARN: ${app} not Healthy yet — check the ArgoCD UI"
done
echo "==> SLO alert rules:"
$KUBECTL -n monitoring get prometheusrule shipit-api-slo -o custom-columns=NAME:.metadata.name 2>/dev/null \
  || echo "    (shipit-api-slo not visible yet — observability-config may still be syncing)"

# 6. Chaos Mesh (Phase 5) ----------------------------------------------------
# The tooling installs via ArgoCD (sync wave 3, after the Kyverno policies
# that carve out its namespace). Experiments are NOT synced — they live in
# k8s/chaos/ and are applied by hand during a demo.
echo "==> Waiting for Chaos Mesh (installed by ArgoCD)..."
$KUBECTL -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  --timeout=600s "application/chaos-mesh" \
  || echo "WARN: chaos-mesh not Healthy yet — check the ArgoCD UI"
$KUBECTL -n chaos-mesh get pods 2>/dev/null | head -5 \
  || echo "    (chaos-mesh pods not visible yet)"

echo ""
echo "Done. Useful next steps:"
echo "  ArgoCD UI:      k3s kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "  Admin password: k3s kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "                    -o jsonpath='{.data.password}' | base64 -d; echo"
echo "  Watch pods:     k3s kubectl -n shipit get pods -w"
echo "  API version:    k3s kubectl -n shipit port-forward svc/shipit-api 8000:8000"
echo "                  then: curl localhost:8000/version"
echo "  Canary demo:    see scripts/demo-canary.md — push a good build, then a"
echo "                  bad one (FAULT_RATE=0.3), and watch Flagger roll it back"
echo "  Chaos demo:     Chaos Mesh is installed (k8s/apps/chaos-mesh.yaml); experiments"
echo "                  are applied by hand, never synced:"
echo "                    k3s kubectl apply -f k8s/chaos/pod-kill-api.yaml"
echo "                    k3s kubectl apply -f k8s/chaos/network-delay-api.yaml"
echo "  linkerd-viz:    k3s kubectl -n linkerd-viz port-forward svc/web 8084:8084"
echo "                  then open https://localhost:8084 (dashboard)"
echo ""
echo "  Phase 4 — Grafana:"
echo "    k3s kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "    then open http://localhost:3000 — dashboards: 'ShipIt Golden Signals', 'ShipIt SLOs'"
echo "    admin password: k3s kubectl -n monitoring get secret kube-prometheus-stack-grafana \\"
echo "                      -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo "    (admin user is 'admin')"
