# ---- builder: install deps into /install ----
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- runtime: non-root, minimal ----
FROM python:3.12-slim AS runtime
# Patch OS packages for the Trivy gate (Debian security updates).
RUN useradd --create-home --uid 10001 appuser \
    && apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /install /usr/local
COPY main.py .
USER appuser
EXPOSE 8000
ENV APP_VERSION=v1.0.0
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
