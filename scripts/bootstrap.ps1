# ShipIt Phase 1 bootstrap (Windows): k3d + ArgoCD + app-of-apps.
#
# Run in PowerShell (as your normal user; Docker Desktop must be running):
#   .\scripts\bootstrap.ps1
#
# Idempotent-ish: reuses the k3d cluster / ArgoCD install if already present,
# then (re)applies the root app and waits for the demo to go healthy.
$ErrorActionPreference = "Stop"

$ArgocdVersion = "v3.5.7"
$GatewayApiVersion = "v1.7.0"  # Phase 3 pin — standard-install.yaml serves HTTPRoute v1 (verified live)
$ClusterName = "shipit"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Require-Command($name, $hint) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "$name not found. $hint"
  }
}

Require-Command docker "Install Docker Desktop and make sure it is running."
Require-Command kubectl "Install kubectl: winget install Kubernetes.kubectl"

# --- k3d ----------------------------------------------------------------
if (-not (Get-Command k3d -ErrorAction SilentlyContinue)) {
  Write-Host "==> Installing k3d..."
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    choco install k3d -y
  } else {
    $tools = Join-Path $env:USERPROFILE ".shipit-tools"
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    $url = "https://github.com/k3d-io/k3d/releases/download/v5.8.3/k3d-windows-amd64.exe"
    Invoke-WebRequest -Uri $url -OutFile (Join-Path $tools "k3d.exe")
    $env:Path = "$tools;$env:Path"
    Write-Host "    k3d installed to $tools (added to PATH for this session)"
  }
}

if (-not (k3d cluster list 2>$null | Select-String "^\s*$ClusterName\s")) {
  Write-Host "==> Creating k3d cluster '$ClusterName'..."
  k3d cluster create $ClusterName --wait
} else {
  Write-Host "==> k3d cluster '$ClusterName' exists, reusing"
}
kubectl config use-context "k3d-$ClusterName" | Out-Null

# --- ArgoCD ---------------------------------------------------------------
if (-not (kubectl get namespace argocd 2>$null)) {
  Write-Host "==> Installing ArgoCD $ArgocdVersion..."
  kubectl create namespace argocd
  kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ArgocdVersion/manifests/install.yaml"
} else {
  Write-Host "==> argocd namespace exists, skipping install"
}
Write-Host "==> Waiting for ArgoCD server..."
kubectl -n argocd wait --for=condition=available --timeout=600s deployment/argocd-server

# --- Gateway API CRDs (Phase 3) --------------------------------------------
# Flagger's Gateway API provider creates HTTPRoute objects; Linkerd's policy
# controller enforces them. Installed here (not via ArgoCD) because there is
# no Helm chart in the standard flow — and before the root app so the CRDs
# exist before Flagger syncs.
Write-Host "==> Installing Gateway API CRDs $GatewayApiVersion..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GatewayApiVersion/standard-install.yaml"
kubectl wait --for=condition=Established --timeout=120s crd/httproutes.gateway.networking.k8s.io

# --- App-of-apps -----------------------------------------------------------
Write-Host "==> Applying the root app-of-apps..."
kubectl apply -f (Join-Path $RepoRoot "k8s\argocd\root-app.yaml")

Write-Host "==> Waiting for demo apps to sync (this pulls images on first run)..."
foreach ($app in @("shipit-api", "shipit-worker", "shipit-web")) {
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy `
    --timeout=600s "application/$app"
  if ($LASTEXITCODE -ne 0) { Write-Warning "$app not Healthy yet — check the ArgoCD UI" }
}

Write-Host "==> Waiting for Kyverno + supply-chain policies (installed by ArgoCD)..."
foreach ($app in @("kyverno", "kyverno-policies")) {
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy `
    --timeout=600s "application/$app"
  if ($LASTEXITCODE -ne 0) { Write-Warning "$app not Healthy yet — check the ArgoCD UI" }
}
Write-Host "==> ClusterPolicies now enforced:"
kubectl get clusterpolicies -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction 2>$null
if ($LASTEXITCODE -ne 0) { Write-Warning "ClusterPolicies not visible yet — Kyverno may still be installing" }

# --- Service mesh + progressive delivery (Phase 3) --------------------------
Write-Host "==> Waiting for Linkerd + Flagger (installed by ArgoCD)..."
foreach ($app in @("linkerd-crds", "linkerd-control-plane", "linkerd-viz", "flagger")) {
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy `
    --timeout=600s "application/$app"
  if ($LASTEXITCODE -ne 0) { Write-Warning "$app not Healthy yet — check the ArgoCD UI" }
}

# The linkerd.io/inject annotation on the shipit namespace only affects pods
# created AFTER it syncs. On a re-run over an existing cluster the demo pods
# predate it, so restart them to get the sidecar (harmless rolling update on
# a fresh cluster).
Write-Host "==> Restarting shipit workloads so the Linkerd sidecar is injected..."
kubectl -n shipit rollout restart deployment/shipit-api deployment/shipit-worker deployment/shipit-web
kubectl -n shipit rollout status --timeout=300s deployment/shipit-api
if ($LASTEXITCODE -ne 0) { Write-Warning "shipit-api rollout — Flagger may have scaled it to 0 already (normal after init)" }

Write-Host "==> Waiting for the canary definitions (installed by ArgoCD)..."
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy `
  --timeout=600s "application/shipit-canary"
if ($LASTEXITCODE -ne 0) { Write-Warning "shipit-canary not Healthy yet — check the ArgoCD UI" }

Write-Host "==> Mesh check:"
$hasProxy = kubectl -n shipit get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{" "}{end}{end}' 2>$null | Select-String "linkerd-proxy"
if ($hasProxy) {
  Write-Host "    linkerd-proxy sidecar present on shipit pods"
} else {
  Write-Warning "no linkerd-proxy sidecar found — run: kubectl -n shipit rollout restart deployment/shipit-api deployment/shipit-worker deployment/shipit-web"
}
kubectl -n shipit get canary shipit-api -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "    (canary resource not visible yet — Flagger may still be starting)" }

Write-Host ""
Write-Host "Done. Useful next steps:"
Write-Host "  ArgoCD UI:      kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080"
Write-Host "  Admin password: [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}')))"
Write-Host "  Watch pods:     kubectl -n shipit get pods -w"
Write-Host "  API version:    kubectl -n shipit port-forward svc/shipit-api 8000:8000  # then: curl localhost:8000/version"
Write-Host "  Canary demo:    see scripts/demo-canary.md — push a good build, then a bad one"
Write-Host "                  (FAULT_RATE=0.3), and watch Flagger roll it back"
Write-Host "  linkerd-viz:    kubectl -n linkerd-viz port-forward svc/web 8084:8084  # https://localhost:8084"
