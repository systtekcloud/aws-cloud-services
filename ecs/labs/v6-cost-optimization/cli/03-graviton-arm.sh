#!/usr/bin/env bash
# ── Lab v6 — Graviton ARM64: ~20% de ahorro en Fargate ───────────────────────
# Migra la imagen y Task Definition a arquitectura ARM64 (Graviton).
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPO="shopapi/api"
APP_VERSION="${APP_VERSION:-0.6.0-arm64}"
CLUSTER="shopapi-cluster"
API_SERVICE="shopapi-api"

echo "═══════════════════════════════════════════════════════"
echo "Lab v6 — Graviton ARM64"
echo "Ahorro estimado: ~20% en compute Fargate"
echo "═══════════════════════════════════════════════════════"

# ── Verificar compatibilidad ARM64 ────────────────────────────────────────────
echo ""
echo "1️⃣  Verificando compatibilidad de dependencias con ARM64..."
echo ""
echo "Dependencias en requirements.txt:"
echo "  - fastapi:  ✅ Python puro, compatible ARM64"
echo "  - uvicorn:  ✅ Python puro, compatible ARM64"
echo "  - boto3:    ✅ Python puro, compatible ARM64"
echo "  - pydantic: ✅ Binarios disponibles para ARM64"
echo ""
echo "⚠️  Dependencias que pueden fallar en ARM64:"
echo "   - numpy/pandas: verificar si hay wheels ARM64 en PyPI"
echo "   - pillow: requiere librerías nativas (normalmente sí disponible)"
echo "   - cryptography: requiere compilación (normalmente disponible)"
echo ""

# ── Verificar si Docker soporta buildx multi-plataforma ───────────────────────
echo "2️⃣  Verificando soporte de docker buildx..."

if docker buildx version &>/dev/null; then
  echo "  ✅ Docker Buildx disponible"
else
  echo "  ❌ Docker Buildx no disponible. Instalar Docker Desktop o añadir el plugin."
  echo "     En Linux: docker buildx install"
  exit 1
fi

# Crear builder multi-plataforma si no existe
if ! docker buildx inspect shopapi-builder &>/dev/null; then
  echo "  Creando builder multi-arch..."
  docker buildx create --name shopapi-builder --use --platform linux/amd64,linux/arm64
else
  docker buildx use shopapi-builder
fi

docker buildx inspect --bootstrap shopapi-builder | grep -E "Platforms|Name"

# ── Build y push de imagen ARM64 ──────────────────────────────────────────────
echo ""
echo "3️⃣  Build de imagen ARM64 y push a ECR..."

APP_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
APP_DIR="${APP_DIR}/app"

if [[ ! -f "${APP_DIR}/Dockerfile" ]]; then
  echo "  ❌ No se encuentra el Dockerfile en ${APP_DIR}"
  echo "     Ajustar la ruta o ejecutar desde la raíz del proyecto."
  exit 1
fi

# Login ECR
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

IMAGE_ARM="${ECR_REGISTRY}/${ECR_REPO}:${APP_VERSION}"

# Build solo ARM64 (más rápido que multi-arch para este test)
docker buildx build \
  --platform linux/arm64 \
  --tag "$IMAGE_ARM" \
  --build-arg APP_VERSION="$APP_VERSION" \
  --push \
  "${APP_DIR}"

echo ""
echo "  ✅ Imagen ARM64 publicada: $IMAGE_ARM"

# Verificar la arquitectura de la imagen en ECR
echo ""
echo "  Verificando arquitectura en ECR:"
aws ecr describe-images \
  --repository-name "$ECR_REPO" \
  --image-ids imageTag="$APP_VERSION" \
  --query 'imageDetails[0].{tag:imageTags[0],digest:imageDigest,size:imageSizeInBytes}' \
  --output json \
  --region "$AWS_REGION" || echo "  (imagen recién subida, puede tardar unos segundos)"

# ── Registrar Task Definition ARM64 ───────────────────────────────────────────
echo ""
echo "4️⃣  Registrando Task Definition con runtimePlatform ARM64..."

CURRENT_TD=$(aws ecs describe-task-definition \
  --task-definition shopapi-api \
  --query 'taskDefinition' \
  --output json \
  --region "$AWS_REGION")

# Actualizar campos: imagen + runtimePlatform
NEW_TD=$(echo "$CURRENT_TD" | python3 -c "
import json, sys
td = json.load(sys.stdin)

# Limpiar campos que no se pueden incluir al registrar
for key in ['taskDefinitionArn','revision','status','requiresAttributes',
            'compatibilities','registeredAt','registeredBy']:
    td.pop(key, None)

# Actualizar imagen del container
for c in td.get('containerDefinitions', []):
    c['image'] = '${IMAGE_ARM}'

# Añadir/actualizar runtimePlatform para ARM64
td['runtimePlatform'] = {
    'cpuArchitecture': 'ARM64',
    'operatingSystemFamily': 'LINUX'
}

print(json.dumps(td, indent=2))
")

TD_ARN=$(echo "$NEW_TD" | aws ecs register-task-definition \
  --cli-input-json /dev/stdin \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text \
  --region "$AWS_REGION")

echo "  ✅ Task Definition ARM64 registrada: $TD_ARN"

# ── Actualizar el servicio ─────────────────────────────────────────────────────
echo ""
echo "5️⃣  Actualizando el ECS Service con la nueva Task Definition ARM64..."

aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$API_SERVICE" \
  --task-definition "$TD_ARN" \
  --region "$AWS_REGION" \
  --query 'service.{nombre:serviceName,td:taskDefinition}' \
  --output json

echo ""
echo "  Monitoreando deployment (Ctrl+C para salir)..."
aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services "$API_SERVICE" \
  --region "$AWS_REGION" && echo "  ✅ Servicio estable con ARM64"

# ── Comparativa de precios ────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "💰 Comparativa de precios Fargate (eu-west-1)"
echo ""
printf "%-15s %-20s %-20s %-15s\n" "Arquitectura" "vCPU/hora" "GB/hora" "Ahorro"
printf "%-15s %-20s %-20s %-15s\n" "─────────────" "──────────────────" "──────────────────" "─────────────"
printf "%-15s %-20s %-20s %-15s\n" "X86_64"  "\$0.04856" "\$0.00532" "base"
printf "%-15s %-20s %-20s %-15s\n" "ARM64"   "\$0.03868" "\$0.00425" "~20%"
echo ""
echo "Para 4 tasks API (1vCPU/2GB, 720h/mes):"
printf "  X86_64: 4 × (0.04856 + 2×0.00532) × 720 = \$"
python3 -c "print(f'{4 * (0.04856 + 2*0.00532) * 720:.2f}')"
printf "  ARM64:  4 × (0.03868 + 2×0.00425) × 720 = \$"
python3 -c "print(f'{4 * (0.03868 + 2*0.00425) * 720:.2f}')"
echo "═══════════════════════════════════════════════════════"
