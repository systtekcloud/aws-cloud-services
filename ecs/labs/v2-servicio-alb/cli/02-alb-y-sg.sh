#!/usr/bin/env bash
# ==============================================================================
# Lab v2 ShopAPI — Paso 2: Security Groups, ALB y Target Group
# ==============================================================================
# Requiere haber ejecutado primero 01-vpc-networking.sh
#
# Crea:
#   - SG para el ALB:   shopapi-alb-sg  (inbound 80 desde 0.0.0.0/0)
#   - SG para las Tasks: shopapi-task-sg (inbound 8080 solo desde alb-sg)
#   - ALB internet-facing en subnets públicas
#   - Target Group tipo IP en puerto 8080 con health check /health
#   - Listener HTTP:80 → forward al Target Group
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Cargar variables del paso anterior
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$0")"
ENV_FILE="${SCRIPT_DIR}/00-env.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: No se encontró $ENV_FILE" >&2
  echo "  Ejecuta primero: ./01-vpc-networking.sh" >&2
  exit 1
fi

# shellcheck source=00-env.sh
source "$ENV_FILE"

# Verificar variables mínimas
: "${VPC_ID:?Variable VPC_ID no está definida en $ENV_FILE}"
: "${PUBLIC_SUBNET_A:?Variable PUBLIC_SUBNET_A no está definida}"
: "${PUBLIC_SUBNET_B:?Variable PUBLIC_SUBNET_B no está definida}"
: "${REGION:?Variable REGION no está definida}"

# ------------------------------------------------------------------------------
# Funciones auxiliares
# ------------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] OK  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
log "=========================================="
log " Iniciando creacion de SGs y ALB"
log "=========================================="
log "  VPC:     $VPC_ID"
log "  SubnetA: $PUBLIC_SUBNET_A"
log "  SubnetB: $PUBLIC_SUBNET_B"

# ------------------------------------------------------------------------------
# 1. Security Group para el ALB
# ------------------------------------------------------------------------------
log "Creando Security Group para el ALB..."

ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name "shopapi-alb-sg" \
  --description "ShopAPI ALB — permite trafico HTTP desde Internet" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=shopapi-alb-sg},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'GroupId' \
  --output text)

ok "ALB SG creado: $ALB_SG_ID"

log "Añadiendo regla inbound: TCP 80 desde 0.0.0.0/0..."

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region "$REGION"

# Regla outbound por defecto (0.0.0.0/0) ya existe al crear el SG
ok "Regla inbound HTTP:80 añadida al ALB SG"

# ------------------------------------------------------------------------------
# 2. Security Group para las ECS Tasks
# ------------------------------------------------------------------------------
log "Creando Security Group para las ECS Tasks..."

TASK_SG_ID=$(aws ec2 create-security-group \
  --group-name "shopapi-task-sg" \
  --description "ShopAPI Tasks — permite trafico solo desde el ALB SG" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=shopapi-task-sg},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'GroupId' \
  --output text)

ok "Task SG creado: $TASK_SG_ID"

log "Añadiendo regla inbound: TCP 8080 solo desde SG $ALB_SG_ID (encadenamiento de SGs)..."

aws ec2 authorize-security-group-ingress \
  --group-id "$TASK_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$REGION"

ok "Regla inbound TCP:8080 desde ALB SG añadida al Task SG"

# Verificar el encadenamiento
log "Verificando SG chaining..."
TASK_SG_RULES=$(aws ec2 describe-security-groups \
  --group-ids "$TASK_SG_ID" \
  --region "$REGION" \
  --query 'SecurityGroups[0].IpPermissions[*].{port:FromPort,source:UserIdGroupPairs[0].GroupId}' \
  --output table)
echo "$TASK_SG_RULES"

# ------------------------------------------------------------------------------
# 3. Application Load Balancer
# ------------------------------------------------------------------------------
log "Creando ALB internet-facing (shopapi-alb)..."
log "  Subnets: $PUBLIC_SUBNET_A, $PUBLIC_SUBNET_B"

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "shopapi-alb" \
  --subnets "$PUBLIC_SUBNET_A" "$PUBLIC_SUBNET_B" \
  --security-groups "$ALB_SG_ID" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --tags "Key=Name,Value=shopapi-alb" "Key=Lab,Value=v2" \
  --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

ok "ALB creado: $ALB_DNS"
ok "  ARN: $ALB_ARN"

# ------------------------------------------------------------------------------
# 4. Target Group (tipo IP, puerto 8080)
# ------------------------------------------------------------------------------
log "Creando Target Group (tipo IP, puerto 8080)..."

TG_ARN=$(aws elbv2 create-target-group \
  --name "shopapi-tg" \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path "/health" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher "HttpCode=200" \
  --tags "Key=Name,Value=shopapi-tg" "Key=Lab,Value=v2" \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

ok "Target Group creado: $TG_ARN"

# Reducir el deregistration delay a 60 segundos (mejor para demos/rolling updates)
log "Configurando deregistration delay a 60 segundos..."

aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TG_ARN" \
  --attributes "Key=deregistration_delay.timeout_seconds,Value=60" \
  --region "$REGION"

ok "Deregistration delay configurado: 60 segundos"

# ------------------------------------------------------------------------------
# 5. Listener HTTP:80 → forward al Target Group
# ------------------------------------------------------------------------------
log "Creando Listener HTTP:80 → ${TG_ARN}..."

LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
  --tags "Key=Name,Value=shopapi-listener-http" "Key=Lab,Value=v2" \
  --region "$REGION" \
  --query 'Listeners[0].ListenerArn' \
  --output text)

ok "Listener HTTP:80 creado: $LISTENER_ARN"

# ------------------------------------------------------------------------------
# 6. Actualizar el archivo de entorno con los nuevos IDs
# ------------------------------------------------------------------------------
log "Actualizando $ENV_FILE con los IDs de SGs y ALB..."

# Reemplazar líneas vacías con los valores reales
sed -i \
  -e "s|^export ALB_SG_ID=\"\"$|export ALB_SG_ID=\"${ALB_SG_ID}\"|" \
  -e "s|^export TASK_SG_ID=\"\"$|export TASK_SG_ID=\"${TASK_SG_ID}\"|" \
  -e "s|^export ALB_ARN=\"\"$|export ALB_ARN=\"${ALB_ARN}\"|" \
  -e "s|^export ALB_DNS=\"\"$|export ALB_DNS=\"${ALB_DNS}\"|" \
  -e "s|^export TG_ARN=\"\"$|export TG_ARN=\"${TG_ARN}\"|" \
  -e "s|^export LISTENER_ARN=\"\"$|export LISTENER_ARN=\"${LISTENER_ARN}\"|" \
  "$ENV_FILE"

ok "Archivo de entorno actualizado"

# ------------------------------------------------------------------------------
# 7. Verificacion rápida
# ------------------------------------------------------------------------------
log "Verificando ALB activo..."

ALB_STATE=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region "$REGION" \
  --query 'LoadBalancers[0].State.Code' \
  --output text)

log "  Estado del ALB: $ALB_STATE"

if [[ "$ALB_STATE" != "active" ]]; then
  log "  (El ALB puede tardar unos segundos en ponerse activo, es normal)"
fi

# ------------------------------------------------------------------------------
# 8. Resumen final
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  RESUMEN DE SGs Y ALB — ShopAPI Lab v2"
echo "============================================================"
echo "  Security Groups:"
echo "    ALB SG:  $ALB_SG_ID  (inbound 80 desde 0.0.0.0/0)"
echo "    Task SG: $TASK_SG_ID  (inbound 8080 desde $ALB_SG_ID)"
echo ""
echo "  ALB:"
echo "    Nombre:  shopapi-alb"
echo "    DNS:     $ALB_DNS"
echo "    ARN:     $ALB_ARN"
echo ""
echo "  Target Group:"
echo "    Nombre:  shopapi-tg"
echo "    Puerto:  8080"
echo "    HC Path: /health"
echo "    ARN:     $TG_ARN"
echo ""
echo "  Listener:"
echo "    HTTP:80 → shopapi-tg"
echo "    ARN:     $LISTENER_ARN"
echo "============================================================"
echo ""
echo "  Siguiente paso: ./03-ecs-service.sh"
echo "============================================================"
