# ── Etapa de build ────────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /app

# Instalar dependencias en un directorio separado (para capa cacheada)
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Imagen final ──────────────────────────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

# Copiar dependencias instaladas
COPY --from=builder /install /usr/local

# Copiar código de la aplicación
COPY main.py .

# Usuario no-root (buena práctica de seguridad — SA Associate exam)
RUN useradd -m -u 1000 appuser
USER appuser

# Puerto de la aplicación
EXPOSE 8080

# Health check a nivel Docker (complementa el ECS container healthcheck)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"

# Variables de entorno por defecto
ENV APP_VERSION="0.1.0" \
    APP_ENV="development" \
    USE_DYNAMODB="false"

# Arrancar con uvicorn en modo production
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
