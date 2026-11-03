# docker/

Container conventions for ShipIt. Each service owns its Dockerfile at
`apps/<service>/Dockerfile`:

- multi-stage builds (dependency install / syntax check up front, slim runtime)
- run as non-root (`appuser` for Python, `node` for Node, unprivileged nginx)
- versioned via the `APP_VERSION` env var (api) — never `:latest` in deploys
  from Phase 2 on (Kyverno enforces this)

Shared notes and base-image decisions go here as the platform grows.
