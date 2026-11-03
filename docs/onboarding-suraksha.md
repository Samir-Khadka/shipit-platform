# Onboarding: Suraksha → ShipIt

**Status:** manifests live in `k8s/services/suraksha/` (api, which also serves
the Leaflet frontend), ArgoCD app `suraksha`, Flagger canary on `suraksha`,
ServiceMonitor + dashboard panels. Image:
`ghcr.io/samir-khadka/suraksha:f0617a1c` (published by that repo's
`shipit-publish` workflow).

**Render deployment is untouched** — ShipIt is an additional target.

## 1. Secrets

None required. Optional env for live integrations (add as a Secret and wire
into the Deployment if you want them):

- `MESSAGING_API_URL` / `MESSAGING_API_KEY` — SMS/WhatsApp dispatch
- `HTTPS_PROXY` / `SSL_CERT_FILE` — sandbox proxy settings (not needed on
  the laptop cluster)

## 2. Deploy order

```bash
kubectl apply -f k8s/apps/suraksha.yaml
# ArgoCD then syncs k8s/services/suraksha/
kubectl -n shipit rollout status deploy/suraksha
```

## 3. Verify

```bash
kubectl -n shipit get pods -l app.kubernetes.io/name=suraksha
kubectl -n shipit port-forward svc/suraksha 8000:8000 &
curl localhost:8000/api/health
# Frontend:
curl -s localhost:8000/ | head -5
kubectl -n shipit get canary suraksha
```

## 4. Ship a new version (canary demo)

```bash
# In suraksha: push to main -> image publishes to GHCR, then:
./scripts/bump-service-image.sh suraksha <new-sha>
git push  # ArgoCD syncs -> Flagger canaries 10% -> 50% -> 100%
```

## Notes

- Single process serves API + static frontend; no separate web deployment.
- Data-honesty contract holds: every response carries `data_label`
  (live/verified/model/sample). BIPAD stays Planned (unreachable).
- Resource footprint: 100m/256Mi req, 1000m/1Gi lim (ephemeris compute).
- Cold start pulls a larger image than the demo services; the 180s canary
  progress deadline accounts for it.
