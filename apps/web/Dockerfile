# ---- check: syntax-verify the JS ----
FROM node:20-slim AS check
WORKDIR /app
COPY app.js config.js ./
RUN node --check app.js && node --check config.js

# ---- runtime: unprivileged nginx (non-root, listens on 8080) ----
FROM nginxinc/nginx-unprivileged:alpine AS runtime
COPY --from=check /app/app.js /app/config.js /usr/share/nginx/html/
COPY index.html /usr/share/nginx/html/
EXPOSE 8080
