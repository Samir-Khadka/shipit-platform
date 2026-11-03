# Onboarding: TaskBoard → ShipIt

**Status:** manifests live in `k8s/services/taskboard/` (api + web), ArgoCD app
`taskboard`, Flagger canary on `taskboard-api`, ServiceMonitor + dashboard
panels. Images: `ghcr.io/samir-khadka/taskboard-devops-api:e0bef825` and
`ghcr.io/samir-khadka/taskboard-devops-web:e0bef825` (published by that
repo's `shipit-publish` workflow).

**Render deployment is untouched** — ShipIt is an additional target.

## 1. Create the secret (do this FIRST)

The API will CrashLoop without `DATABASE_URL`. Use your existing Neon
Postgres connection string:

```bash
kubectl -n shipit create secret generic taskboard-api-secret \
  --from-literal=DATABASE_URL='postgresql://<user>:<password>@<host>/<db>?sslmode=require'
```

Verify: `kubectl -n shipit get secret taskboard-api-secret`

## 2. Deploy order

ArgoCD syncs automatically once the apps exist (bootstrap installs them).
If applying by hand:

```bash
kubectl apply -f k8s/apps/taskboard.yaml        # ArgoCD Application
# ArgoCD then syncs k8s/services/taskboard/ (api + web)
kubectl -n shipit rollout status deploy/taskboard-api
kubectl -n shipit rollout status deploy/taskboard-web
```

## 3. Verify

```bash
# Pods running (2/2 each, non-root)
kubectl -n shipit get pods -l app.kubernetes.io/part-of=shipit | grep taskboard

# API health
kubectl -n shipit port-forward svc/taskboard-api 3000:3000 &
curl localhost:3000/health

# Web UI (proxies /api to the API service)
kubectl -n shipit port-forward svc/taskboard-web 8080:8080 &
curl -s localhost:8080/healthz

# Canary status
kubectl -n shipit get canary taskboard-api
```

## 4. Ship a new version (canary demo)

```bash
# In taskboard-devops: push to main -> image publishes to GHCR,
# then bump the tag here:
./scripts/bump-service-image.sh taskboard-devops-api <new-sha>
git push  # ArgoCD syncs -> Flagger canaries 10% -> 50% -> 100%
kubectl -n shipit get canary taskboard-api -w
```

## Notes

- The web UI calls the API at `taskboard-api:3000` (same namespace, set via
  `API_HOST` env). No ingress is configured — add one when you want public
  traffic.
- Postgres stays on Neon (free tier). The cluster holds no database.
- Resource footprint: api 100m/128Mi req, web 50m/64Mi req.
