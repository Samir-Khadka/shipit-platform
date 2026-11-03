# ---- check: syntax-verify the worker ----
FROM node:20-slim AS check
WORKDIR /app
COPY package.json worker.js ./
RUN node --check worker.js

# ---- runtime: non-root 'node' user ships with the image ----
FROM node:20-slim AS runtime
# Patch OS packages for the Trivy gate (Debian security updates), then drop
# npm itself — the worker has zero npm deps (global fetch only), so none of
# that code needs to ship. Smaller image, smaller attack surface.
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx
WORKDIR /app
COPY --from=check /app/package.json /app/worker.js ./
USER node
ENV API_URL=http://localhost:8000
CMD ["node", "worker.js"]
