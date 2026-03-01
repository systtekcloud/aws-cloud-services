#!/usr/bin/env bash
# ── Lab v6 — Cleanup: VPC Endpoints + Capacity Providers ─────────────────────
# Elimina los recursos creados en v6:
#   - VPC Endpoints privados (coste por hora)
#   - Configuración de Capacity Providers revertida a FARGATE puro
# Los recursos de v1-v5 (cluster, servicio, ALB) NO se eliminan.
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-1}"
CLUSTER="shopapi-cluster"
API_SERVICE="shopapi-api"
WORKER_SERVICE="shopapi-worker"

echo "═══════════════════════════════════════════════════════"
echo "Lab v6 — Cleanup de optimización de costes"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "⚠️  Este script eliminará:"
echo "   1. VPC Endpoints privados de ECS/ECR (coste ~\$7-10/mes por endpoint)"
echo "   2. Revertirá Capacity Providers a FARGATE puro"
echo "   3. Revertirá el servicio API a arquitectura X86_64"
echo ""
echo "   NO eliminará: cluster, servicios, ALB, VPC, red (creados en v1-v5)"
echo ""
read -rp "¿Confirmar limpieza de recursos v6? [y/N]: " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "Operación cancelada."
  exit 0
fi

# ── 1. Eliminar VPC Endpoints ─────────────────────────────────────────────────
echo ""
echo "1️⃣  Buscando y eliminando VPC Endpoints de ShopAPI..."

# Obtener la VPC del cluster
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=shopapi" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  # Intentar obtener por nombre
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=shopapi-vpc" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")
fi

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  echo "   VPC encontrada: $VPC_ID"

  # Listar VPC Endpoints en la VPC con tag de shopapi
  ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=vpc-endpoint-state,Values=available,pending" \
    --query 'VpcEndpoints[?contains(ServiceName, `ecr`) || contains(ServiceName, `logs`) || contains(ServiceName, `secretsmanager`) || contains(ServiceName, `s3`)].VpcEndpointId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  if [[ -n "$ENDPOINT_IDS" && "$ENDPOINT_IDS" != "None" ]]; then
    echo "   Endpoints encontrados: $ENDPOINT_IDS"
    # shellcheck disable=SC2086
    aws ec2 delete-vpc-endpoints \
      --vpc-endpoint-ids $ENDPOINT_IDS \
      --region "$AWS_REGION" \
      --query 'Unsuccessful[].Error' \
      --output text

    echo "   ✅ VPC Endpoints eliminados"
    echo "   💡 Los endpoints tardan 1-2 minutos en desaparecer del estado"
  else
    echo "   ℹ️  No se encontraron VPC Endpoints de shopapi en $VPC_ID"
  fi

  # Eliminar Security Group de VPC Endpoints si existe
  SG_ID=$(aws ec2 describe-security-groups \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=group-name,Values=shopapi-vpce-sg" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    echo "   Eliminando Security Group de endpoints: $SG_ID"
    aws ec2 delete-security-group \
      --group-id "$SG_ID" \
      --region "$AWS_REGION" 2>/dev/null && \
      echo "   ✅ Security Group eliminado" || \
      echo "   ⚠️  No se pudo eliminar el SG (puede tener dependencias)"
  fi
else
  echo "   ⚠️  VPC shopapi no encontrada — saltar eliminación de endpoints"
fi

# ── 2. Revertir Capacity Providers del servicio API ──────────────────────────
echo ""
echo "2️⃣  Revirtiendo Capacity Providers del servicio API a FARGATE puro..."

if aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$API_SERVICE" \
  --query 'services[0].status' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null | grep -q "ACTIVE"; then

  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$API_SERVICE" \
    --capacity-provider-strategy \
      'capacityProvider=FARGATE,base=2,weight=1' \
    --region "$AWS_REGION" \
    --query 'service.{service:serviceName,providers:capacityProviderStrategy}' \
    --output json

  echo "   ✅ Servicio API revertido a FARGATE puro"
else
  echo "   ℹ️  Servicio API no encontrado o inactivo — saltar"
fi

# ── 3. Revertir Capacity Providers del servicio Worker ────────────────────────
echo ""
echo "3️⃣  Revirtiendo Capacity Providers del Worker a FARGATE/SPOT equilibrado..."

if aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$WORKER_SERVICE" \
  --query 'services[0].status' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null | grep -q "ACTIVE"; then

  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$WORKER_SERVICE" \
    --capacity-provider-strategy \
      'capacityProvider=FARGATE,base=1,weight=1' \
      'capacityProvider=FARGATE_SPOT,base=0,weight=3' \
    --region "$AWS_REGION" \
    --query 'service.{service:serviceName,providers:capacityProviderStrategy}' \
    --output json

  echo "   ✅ Worker revertido a estrategia equilibrada"
else
  echo "   ℹ️  Worker service no encontrado o inactivo — saltar"
fi

# ── 4. Verificar Task Definitions ARM64 registradas ──────────────────────────
echo ""
echo "4️⃣  Task Definitions ARM64 registradas (informativo, no se eliminan):"
echo ""
echo "   Las Task Definitions no suponen coste — solo las revisiones activas"
echo "   corriendo en un servicio generan gasto."
echo ""

TD_REVISIONS=$(aws ecs list-task-definitions \
  --family-prefix "shopapi-api" \
  --query 'taskDefinitionArns[-5:]' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [[ -n "$TD_REVISIONS" ]]; then
  echo "   Últimas 5 revisiones de shopapi-api:"
  for td in $TD_REVISIONS; do
    ARCH=$(aws ecs describe-task-definition \
      --task-definition "$td" \
      --query 'taskDefinition.runtimePlatform.cpuArchitecture' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "X86_64")
    echo "     - $td (${ARCH:-X86_64})"
  done
fi

# ── Resumen ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "✅ Cleanup v6 completado"
echo ""
echo "Recursos eliminados:"
echo "  - VPC Endpoints privados (ahorro ~\$7-10/mes/endpoint)"
echo "  - Configuración de Capacity Providers revertida"
echo ""
echo "Recursos mantenidos (v1-v5):"
echo "  - ECS Cluster: $CLUSTER"
echo "  - Servicios: $API_SERVICE, $WORKER_SERVICE"
echo "  - ALB, VPC, subnets, security groups base"
echo "  - Imágenes ARM64 en ECR (no generan coste adicional)"
echo ""
echo "Para continuar con v7 (Enterprise GitOps):"
echo "  cd ../v7-enterprise-gitops"
echo "═══════════════════════════════════════════════════════"
