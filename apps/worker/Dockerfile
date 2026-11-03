# ---- check: syntax-verify the worker ----
FROM node:20-slim AS check
WORKDIR /app
COPY package.json worker.js ./
RUN node --check worker.js

# ---- runtime: non-root 'node' user ships with the image ----
FROM node:20-slim AS runtime
WORKDIR /app
COPY --from=check /app/package.json /app/worker.js ./
# The worker has zero npm dependencies (global fetch only): drop npm itself
# to shrink the attack surface — its bundled libs carried HIGH CVEs that
# Trivy flags, and none of that code ever executes here.
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx
USER node
ENV API_URL=http://localhost:8000
CMD ["node", "worker.js"]
