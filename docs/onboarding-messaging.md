# Onboarding: Messaging API → ShipIt

**Status:** manifests live in `k8s/services/messaging/` (api), ArgoCD app
`messaging`, Flagger canary on `messaging-api`, ServiceMonitor + dashboard
panels. Image: `ghcr.io/samir-khadka/messaging-api:<sha>` (published by that
repo's `shipit-publish` workflow; tag pinned once the Trivy gate is green).

**Render deployment is untouched** — ShipIt is an additional target.

## 1. Create the secret (do this FIRST)

```bash
kubectl -n shipit create secret generic messaging-api-secrets \
  --from-literal=MESSAGING_API_KEYS='<long-random-key-1>,<long-random-key-2>' \
  --from-literal=OTP_PEPPER='<long-random-pepper>'
```

Generate with: `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`

Verify: `kubectl -n shipit get secret messaging-api-secrets`

> Without the secret the app falls back to DEV_MODE defaults
> (`dev-key-change-me`) — fine for a smoke test, never for real traffic.

## 2. Deploy order

```bash
kubectl apply -f k8s/apps/messaging.yaml
# ArgoCD then syncs k8s/services/messaging/
kubectl -n shipit rollout status deploy/messaging-api
```

## 3. Verify

```bash
kubectl -n shipit get pods -l app.kubernetes.io/name=messaging-api
kubectl -n shipit port-forward svc/messaging-api 8000:8000 &
curl localhost:8000/health
# Authenticated smoke test:
curl -H "X-API-Key: <one-of-your-keys>" localhost:8000/v1/... 
kubectl -n shipit get canary messaging-api
```

## 4. Ship a new version (canary demo)

```bash
# In messaging-api: push to main -> image publishes to GHCR, then:
./scripts/bump-service-image.sh messaging-api <new-sha>
git push  # ArgoCD syncs -> Flagger canaries 10% -> 50% -> 100%
```

## Notes

- SQLite lives at `/data` on an `emptyDir` — **ephemeral**. Pod restarts
  wipe message history and OTP state. Production needs Postgres (open item).
- Providers default to `console` (no real SMS/WhatsApp). Real delivery needs
  provider keys as additional secret entries (see the app README).
- `/health` answers GET; HEAD returns 405 (known quirk, harmless — probes
  use GET).
