# ShipIt Phase 1 bootstrap (Windows): k3d + ArgoCD + app-of-apps.
#
# Run in PowerShell (as your normal user; Docker Desktop must be running):
#   .\scripts\bootstrap.ps1
#
# Idempotent-ish: reuses the k3d cluster / ArgoCD install if already present,
# then (re)applies the root app and waits for the demo to go healthy.
$ErrorActionPreference = "Stop"

$ArgocdVersion = "v3.5.7"
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

# --- App-of-apps -----------------------------------------------------------
Write-Host "==> Applying the root app-of-apps..."
kubectl apply -f (Join-Path $RepoRoot "k8s\argocd\root-app.yaml")

Write-Host "==> Waiting for demo apps to sync (this pulls images on first run)..."
foreach ($app in @("shipit-api", "shipit-worker", "shipit-web")) {
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy `
    --timeout=600s "application/$app"
  if ($LASTEXITCODE -ne 0) { Write-Warning "$app not Healthy yet — check the ArgoCD UI" }
}

Write-Host ""
Write-Host "Done. Useful next steps:"
Write-Host "  ArgoCD UI:      kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080"
Write-Host "  Admin password: [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}')))"
Write-Host "  Watch pods:     kubectl -n shipit get pods -w"
Write-Host "  API version:    kubectl -n shipit port-forward svc/shipit-api 8000:8000  # then: curl localhost:8000/version"
