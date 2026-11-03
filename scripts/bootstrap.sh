#!/usr/bin/env bash
# ShipIt Phase 1 bootstrap (Linux): k3s + ArgoCD + app-of-apps.
#
# Usage: sudo ./scripts/bootstrap.sh   (run from anywhere; finds the repo root)
#
# Idempotent-ish: skips k3s / ArgoCD install steps that are already done,
# then (re)applies the root app and waits for the demo to go healthy.
set -euo pipefail

ARGOCD_VERSION="v3.5.7"
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

# 3. App-of-apps --------------------------------------------------------
echo "==> Applying the root app-of-apps..."
$KUBECTL apply -f "${REPO_ROOT}/k8s/argocd/root-app.yaml"

echo "==> Waiting for demo apps to sync (this pulls images on first run)..."
for app in shipit-api shipit-worker shipit-web; do
  $KUBECTL -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
    --timeout=600s "application/${app}" \
    || echo "WARN: ${app} not Healthy yet — check the ArgoCD UI"
done

echo ""
echo "Done. Useful next steps:"
echo "  ArgoCD UI:      k3s kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "  Admin password: k3s kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "                    -o jsonpath='{.data.password}' | base64 -d; echo"
echo "  Watch pods:     k3s kubectl -n shipit get pods -w"
echo "  API version:    k3s kubectl -n shipit port-forward svc/shipit-api 8000:8000"
echo "                  then: curl localhost:8000/version"
