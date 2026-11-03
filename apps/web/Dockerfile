# ---- check: syntax-verify the JS ----
FROM node:20-slim AS check
WORKDIR /app
COPY app.js config.js ./
RUN node --check app.js && node --check config.js

# ---- runtime: unprivileged nginx (non-root, listens on 8080) ----
FROM nginxinc/nginx-unprivileged:alpine AS runtime
# Patch OS packages for the Trivy gate (Alpine security updates). Runs as the
# nginx user already, so this stays rootless at runtime.
USER root
RUN apk update && apk upgrade --no-cache
USER nginx
COPY --from=check /app/app.js /app/config.js /usr/share/nginx/html/
COPY index.html /usr/share/nginx/html/
EXPOSE 8080
