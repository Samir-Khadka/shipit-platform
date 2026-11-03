# ---- check: syntax-verify the worker ----
FROM node:20-slim AS check
WORKDIR /app
COPY package.json worker.js ./
RUN node --check worker.js

# ---- runtime: non-root 'node' user ships with the image ----
FROM node:20-slim AS runtime
WORKDIR /app
COPY --from=check /app/package.json /app/worker.js ./
USER node
ENV API_URL=http://localhost:8000
CMD ["node", "worker.js"]
