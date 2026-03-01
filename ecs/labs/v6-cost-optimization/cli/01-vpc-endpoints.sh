#!/usr/bin/env bash
# =============================================================================
# Lab v6 — ShopAPI: VPC Endpoints para eliminar tráfico NAT
# =============================================================================
#
# Crea los 5 VPC Endpoints necesarios para que los tasks ECS en subnets
# privadas accedan a ECR, CloudWatch Logs y Secrets Manager sin pasar por NAT:
#
#   1. com.amazonaws.eu-west-1.s3            → Gateway  (GRATIS)
#   2. com.amazonaws.eu-west-1.ecr.api       → Interface ($0.01/h/AZ)
#   3. com.amazonaws.eu-west-1.ecr.dkr       → Interface ($0.01/h/AZ)
#   4. com.amazonaws.eu-west-1.logs          → Interface ($0.01/h/AZ)
#   5. com.amazonaws.eu-west-1.secretsmanager → Interface ($0.01/h/AZ)
#
# Coste total Interface Endpoints: 4 × 3 AZs × $0.01/h × 730 h = $87.60/mes
# Coste Gateway Endpoint S3: GRATIS
#
# Prerrequisitos:
#   - VPC con tag Name=shopapi-vpc
#   - Subnets privadas con tag Type=private
#   - Route tables privadas con tag Type=private
#   - Security Group de tasks con tag Name=shopapi-task-sg
#   - AWS CLI configurado, AWS_REGION=eu-west-1
# =============================================================================

set -euo pipefail

# ─── Variables ────────────────────────────────────────────────────────────────

AWS_REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "${AWS_REGION}")
PROJECT_PREFIX="shopapi"
LAB_VERSION="v6"

echo "=================================================================="
echo "  Lab ${LAB_VERSION} — VPC Endpoints para ${PROJECT_PREFIX}"
echo "  Región: ${AWS_REGION} | Cuenta: ${ACCOUNT_ID}"
echo "=================================================================="

# ─── Descubrir recursos existentes ────────────────────────────────────────────

echo ""
echo ">>> [1/7] Descubriendo recursos de la VPC..."

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT_PREFIX}-vpc" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region "${AWS_REGION}")

if [[ "${VPC_ID}" == "None" ]] || [[ -z "${VPC_ID}" ]]; then
  echo "ERROR: No se encontró la VPC con tag Name=${PROJECT_PREFIX}-vpc"
  echo "  Verifica que el lab v4 está desplegado correctamente"
  exit 1
fi
echo "  VPC: ${VPC_ID}"

# Subnets privadas (3 AZs)
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Type,Values=private" \
  --query 'Subnets[*].SubnetId' \
  --output text \
  --region "${AWS_REGION}" | tr '\t' ' ')

if [[ -z "${PRIVATE_SUBNET_IDS}" ]]; then
  echo "ERROR: No se encontraron subnets privadas con tag Type=private en la VPC ${VPC_ID}"
  exit 1
fi
echo "  Subnets privadas: ${PRIVATE_SUBNET_IDS}"

# Route tables de las subnets privadas
PRIVATE_ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Type,Values=private" \
  --query 'RouteTables[*].RouteTableId' \
  --output text \
  --region "${AWS_REGION}" | tr '\t' ' ')

if [[ -z "${PRIVATE_ROUTE_TABLE_IDS}" ]]; then
  echo "ADVERTENCIA: No se encontraron route tables con tag Type=private"
  echo "  Intentando descubrir por asociación con subnets privadas..."
  # Alternativa: obtener las route tables asociadas a las subnets privadas
  PRIVATE_ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[?Associations[?SubnetId!=`null`]].RouteTableId' \
    --output text \
    --region "${AWS_REGION}" | tr '\t' ' ')
fi
echo "  Route tables privadas: ${PRIVATE_ROUTE_TABLE_IDS}"

# Security Group de los tasks
TASK_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=${PROJECT_PREFIX}-task-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "${AWS_REGION}")

if [[ "${TASK_SG_ID}" == "None" ]] || [[ -z "${TASK_SG_ID}" ]]; then
  echo "ERROR: No se encontró el Security Group con tag Name=${PROJECT_PREFIX}-task-sg"
  exit 1
fi
echo "  Task SG: ${TASK_SG_ID}"

# NAT Gateway (para medir el tráfico antes/después)
NAT_GW_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NatGateways[?State==`available`][0].NatGatewayId' \
  --output text \
  --region "${AWS_REGION}")
echo "  NAT Gateway: ${NAT_GW_ID}"

# ─── Verificar endpoints existentes ───────────────────────────────────────────

echo ""
echo ">>> [2/7] Verificando endpoints existentes..."

EXISTING_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[?State!=`deleted`].ServiceName' \
  --output text \
  --region "${AWS_REGION}")

echo "  Endpoints actuales: ${EXISTING_ENDPOINTS:-ninguno}"

# ─── Medir tráfico NAT ANTES (baseline) ───────────────────────────────────────

echo ""
echo ">>> [3/7] Midiendo tráfico NAT Gateway (baseline)..."

if [[ "${NAT_GW_ID}" != "None" ]] && [[ -n "${NAT_GW_ID}" ]]; then
  BASELINE_BYTES=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/NATGateway \
    --metric-name BytesOutToDestination \
    --dimensions "Name=NatGatewayId,Value=${NAT_GW_ID}" \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 3600 \
    --statistics Sum \
    --query 'Datapoints[0].Sum' \
    --output text \
    --region "${AWS_REGION}" 2>/dev/null || echo "N/A")
  echo "  Bytes NAT (última hora): ${BASELINE_BYTES} bytes"
else
  echo "  NAT Gateway no encontrado — omitiendo medición baseline"
fi

# ─── Endpoint 1: S3 Gateway (GRATIS) ──────────────────────────────────────────

echo ""
echo ">>> [4/7] Creando endpoint S3 Gateway (GRATIS)..."
echo "  Por qué: ECR almacena los layers de imágenes en S3."
echo "  Sin este endpoint, los pulls de ECR siguen pasando por NAT."
echo "  Tipo Gateway: no crea ENI, añade una ruta en la tabla de rutas. Costo $0."

# Verificar si ya existe
S3_ENDPOINT_EXISTS=$(aws ec2 describe-vpc-endpoints \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=service-name,Values=com.amazonaws.${AWS_REGION}.s3" \
    "Name=vpc-endpoint-type,Values=Gateway" \
  --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
  --output text \
  --region "${AWS_REGION}")

if [[ -n "${S3_ENDPOINT_EXISTS}" ]]; then
  echo "  S3 Gateway Endpoint ya existe: ${S3_ENDPOINT_EXISTS} — omitiendo"
  S3_ENDPOINT_ID="${S3_ENDPOINT_EXISTS}"
else
  S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --vpc-endpoint-type Gateway \
    --service-name "com.amazonaws.${AWS_REGION}.s3" \
    --route-table-ids ${PRIVATE_ROUTE_TABLE_IDS} \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[
      {Key=Name,Value=${PROJECT_PREFIX}-vpce-s3},
      {Key=Project,Value=${PROJECT_PREFIX}},
      {Key=Lab,Value=${LAB_VERSION}},
      {Key=Type,Value=Gateway}
    ]" \
    --query 'VpcEndpoint.VpcEndpointId' \
    --output text \
    --region "${AWS_REGION}")
  echo "  S3 Gateway Endpoint creado: ${S3_ENDPOINT_ID}"
fi

# ─── Security Group para Interface Endpoints ──────────────────────────────────

echo ""
echo ">>> [5/7] Creando Security Group para Interface Endpoints..."
echo "  Los Interface Endpoints necesitan un SG que permita HTTPS (443)"
echo "  desde los tasks de ECS."

VPCE_SG_EXISTS=$(aws ec2 describe-security-groups \
  --filters \
    "Name=group-name,Values=${PROJECT_PREFIX}-vpce-sg" \
    "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "${AWS_REGION}")

if [[ "${VPCE_SG_EXISTS}" != "None" ]] && [[ -n "${VPCE_SG_EXISTS}" ]]; then
  echo "  SG ya existe: ${VPCE_SG_EXISTS} — omitiendo creación"
  VPCE_SG_ID="${VPCE_SG_EXISTS}"
else
  VPCE_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_PREFIX}-vpce-sg" \
    --description "SG para VPC Interface Endpoints de ${PROJECT_PREFIX} - HTTPS desde tasks" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[
      {Key=Name,Value=${PROJECT_PREFIX}-vpce-sg},
      {Key=Project,Value=${PROJECT_PREFIX}},
      {Key=Lab,Value=${LAB_VERSION}}
    ]" \
    --query 'GroupId' \
    --output text \
    --region "${AWS_REGION}")
  echo "  SG creado: ${VPCE_SG_ID}"

  # Eliminar la regla de egress "allow all" que AWS añade por defecto
  # (los endpoints no necesitan egress, solo ingress desde los tasks)
  aws ec2 revoke-security-group-egress \
    --group-id "${VPCE_SG_ID}" \
    --protocol -1 \
    --cidr 0.0.0.0/0 \
    --region "${AWS_REGION}" 2>/dev/null || true

  # Añadir regla de ingress: HTTPS desde el SG de los tasks
  aws ec2 authorize-security-group-ingress \
    --group-id "${VPCE_SG_ID}" \
    --protocol tcp \
    --port 443 \
    --source-group "${TASK_SG_ID}" \
    --region "${AWS_REGION}"
  echo "  Regla añadida: TCP 443 desde ${TASK_SG_ID} (Task SG)"
fi

# ─── Función helper para crear Interface Endpoints ────────────────────────────

create_interface_endpoint() {
  local SERVICE_NAME="$1"
  local FRIENDLY_NAME="$2"
  local TAG_NAME="$3"

  echo ""
  echo "  Servicio: ${SERVICE_NAME}"

  # Verificar si ya existe
  EXISTING=$(aws ec2 describe-vpc-endpoints \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=service-name,Values=${SERVICE_NAME}" \
      "Name=vpc-endpoint-type,Values=Interface" \
    --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
    --output text \
    --region "${AWS_REGION}")

  if [[ -n "${EXISTING}" ]]; then
    echo "    Ya existe: ${EXISTING} — omitiendo"
    echo "${EXISTING}"
    return
  fi

  ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --vpc-endpoint-type Interface \
    --service-name "${SERVICE_NAME}" \
    --subnet-ids ${PRIVATE_SUBNET_IDS} \
    --security-group-ids "${VPCE_SG_ID}" \
    --private-dns-enabled \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[
      {Key=Name,Value=${TAG_NAME}},
      {Key=Project,Value=${PROJECT_PREFIX}},
      {Key=Lab,Value=${LAB_VERSION}},
      {Key=Type,Value=Interface},
      {Key=FriendlyName,Value=${FRIENDLY_NAME}}
    ]" \
    --query 'VpcEndpoint.VpcEndpointId' \
    --output text \
    --region "${AWS_REGION}")

  echo "    Creado: ${ENDPOINT_ID}"
  echo "${ENDPOINT_ID}"
}

# ─── Interface Endpoints ───────────────────────────────────────────────────────

echo ""
echo ">>> [6/7] Creando Interface Endpoints ($0.01/hora/AZ cada uno)..."
echo "  PrivateDnsEnabled=true: el hostname público del servicio (ej:"
echo "  ACCOUNT.dkr.ecr.eu-west-1.amazonaws.com) resolverá a la IP"
echo "  privada del endpoint dentro de la VPC. Los tasks no necesitan"
echo "  cambios de configuración."

ECR_API_ENDPOINT_ID=$(create_interface_endpoint \
  "com.amazonaws.${AWS_REGION}.ecr.api" \
  "ECR-API-Auth" \
  "${PROJECT_PREFIX}-vpce-ecr-api")

ECR_DKR_ENDPOINT_ID=$(create_interface_endpoint \
  "com.amazonaws.${AWS_REGION}.ecr.dkr" \
  "ECR-DKR-Pull" \
  "${PROJECT_PREFIX}-vpce-ecr-dkr")

LOGS_ENDPOINT_ID=$(create_interface_endpoint \
  "com.amazonaws.${AWS_REGION}.logs" \
  "CloudWatch-Logs" \
  "${PROJECT_PREFIX}-vpce-logs")

SM_ENDPOINT_ID=$(create_interface_endpoint \
  "com.amazonaws.${AWS_REGION}.secretsmanager" \
  "Secrets-Manager" \
  "${PROJECT_PREFIX}-vpce-secretsmanager")

# ─── Verificar estado de todos los endpoints ───────────────────────────────────

echo ""
echo ">>> [7/7] Verificando estado de todos los endpoints..."
echo "  (Los Interface Endpoints pueden tardar 1-2 minutos en estar disponibles)"

# Esperar hasta 3 minutos
MAX_WAIT=180
WAITED=0
INTERVAL=15

while true; do
  PENDING=$(aws ec2 describe-vpc-endpoints \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Lab,Values=${LAB_VERSION}" \
    --query 'VpcEndpoints[?State==`pending`].VpcEndpointId' \
    --output text \
    --region "${AWS_REGION}")

  if [[ -z "${PENDING}" ]]; then
    echo "  Todos los endpoints disponibles."
    break
  fi

  if (( WAITED >= MAX_WAIT )); then
    echo "  ADVERTENCIA: timeout esperando endpoints. Estado actual:"
    PENDING=true
    break
  fi

  echo "  Esperando endpoints en estado pending... (${WAITED}s / ${MAX_WAIT}s)"
  sleep "${INTERVAL}"
  WAITED=$(( WAITED + INTERVAL ))
done

# Mostrar tabla de estado
echo ""
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Lab,Values=${LAB_VERSION}" \
  --query 'VpcEndpoints[*].{
    Nombre:Tags[?Key==`Name`]|[0].Value,
    ID:VpcEndpointId,
    Tipo:VpcEndpointType,
    Estado:State
  }' \
  --output table \
  --region "${AWS_REGION}"

# ─── Test: comparar tráfico NAT antes/después ─────────────────────────────────

echo ""
echo "=================================================================="
echo "  Test de verificación"
echo "=================================================================="
echo ""

if [[ "${NAT_GW_ID}" != "None" ]] && [[ -n "${NAT_GW_ID}" ]]; then
  echo "Forzando un redeploy para provocar pull de ECR..."
  aws ecs update-service \
    --cluster "${PROJECT_PREFIX}-cluster" \
    --service "${PROJECT_PREFIX}-api-service" \
    --force-new-deployment \
    --region "${AWS_REGION}" \
    --query 'service.deployments[0].{Estado:status,Tasks:desiredCount}' \
    --output json 2>/dev/null || echo "  (No se pudo forzar redeploy — verifica el nombre del servicio)"

  echo ""
  echo "Esperando 90 segundos para que el pull de ECR complete..."
  sleep 90

  AFTER_BYTES=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/NATGateway \
    --metric-name BytesOutToDestination \
    --dimensions "Name=NatGatewayId,Value=${NAT_GW_ID}" \
    --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 \
    --statistics Sum \
    --query 'Datapoints[0].Sum' \
    --output text \
    --region "${AWS_REGION}" 2>/dev/null || echo "N/A")

  echo "  Bytes NAT (últimos 5 min tras redeploy): ${AFTER_BYTES}"
  echo "  Baseline (última hora): ${BASELINE_BYTES}"
  echo "  Si el pull fue por el endpoint, los bytes NAT no deben subir significativamente."
fi

echo ""
echo "  Para verificar manualmente que el DNS resuelve al endpoint privado:"
echo "  (ejecutar dentro de un task de ECS)"
echo ""
echo "    nslookup ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
echo "    # Debe resolver a una IP 10.x.x.x (privada)"
echo ""
echo "    nslookup logs.${AWS_REGION}.amazonaws.com"
echo "    # Debe resolver a una IP 10.x.x.x (privada)"

# ─── Resumen ───────────────────────────────────────────────────────────────────

echo ""
echo "=================================================================="
echo "  Resumen — VPC Endpoints creados"
echo "=================================================================="
echo ""
echo "  S3 Gateway (GRATIS):          ${S3_ENDPOINT_ID}"
echo "  ECR API (Interface):          ${ECR_API_ENDPOINT_ID}"
echo "  ECR DKR (Interface):          ${ECR_DKR_ENDPOINT_ID}"
echo "  CloudWatch Logs (Interface):  ${LOGS_ENDPOINT_ID}"
echo "  Secrets Manager (Interface):  ${SM_ENDPOINT_ID}"
echo "  Security Group Endpoints:     ${VPCE_SG_ID}"
echo ""
echo "  Coste mensual Interface Endpoints:"
echo "    4 endpoints × 3 AZs × \$0.01/hora × 730 horas = \$87.60/mes"
echo "  Ahorro en tráfico NAT (ECR pulls, logs, secrets):"
echo "    Ver cost-analysis.md para el cálculo completo"
echo ""
echo "  Limpieza: bash cli/99-cleanup.sh"
echo "=================================================================="
