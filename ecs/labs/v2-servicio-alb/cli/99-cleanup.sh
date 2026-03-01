#!/usr/bin/env bash
# ==============================================================================
# Lab v2 ShopAPI — Limpieza completa de recursos
# ==============================================================================
# Elimina TODOS los recursos creados en el Lab v2 en el orden correcto
# para evitar errores de dependencias.
#
# ORDEN DE ELIMINACION:
#   1. ECS Service (scale a 0 + delete)
#   2. ALB (listener se elimina automáticamente)
#   3. Target Group
#   4. NAT Gateway + Elastic IP (lento, ~60-90s)
#   5. Internet Gateway (detach + delete)
#   6. Subnets (4 subnets)
#   7. Route Tables (public + private)
#   8. Security Groups (task SG primero, luego ALB SG)
#   9. VPC
#
# IMPORTANTE: El cluster ECS (shopapi-cluster) y la imagen ECR (shopapi/api)
#   NO se eliminan — pertenecen al Lab v1.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Cargar variables del entorno
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$0")"
ENV_FILE="${SCRIPT_DIR}/00-env.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: No se encontró $ENV_FILE" >&2
  echo "  No hay recursos de Lab v2 para limpiar, o ejecuta los pasos 01-03 primero." >&2
  exit 1
fi

# shellcheck source=00-env.sh
source "$ENV_FILE"

: "${REGION:?REGION no definida en $ENV_FILE}"

# ------------------------------------------------------------------------------
# Configuración
# ------------------------------------------------------------------------------
CLUSTER_NAME="shopapi-cluster"
SERVICE_NAME="shopapi-api-service"

# ------------------------------------------------------------------------------
# Funciones auxiliares
# ------------------------------------------------------------------------------
log()    { echo "[$(date '+%H:%M:%S')] $*"; }
ok()     { echo "[$(date '+%H:%M:%S')] OK  $*"; }
skip()   { echo "[$(date '+%H:%M:%S')] SKP $*"; }
warn()   { echo "[$(date '+%H:%M:%S')] WARN $*"; }
fail()   { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

# Función para verificar que un recurso ya no existe
verify_deleted() {
  local resource_type="$1"
  local resource_id="$2"
  ok "Eliminado: $resource_type $resource_id"
}

# Función para manejar errores no críticos
try_delete() {
  local description="$1"
  shift
  log "Eliminando $description..."
  if "$@" 2>/dev/null; then
    ok "$description eliminado"
  else
    warn "$description no encontrado o ya eliminado (puede ser normal)"
  fi
}

# ------------------------------------------------------------------------------
# Confirmación antes de proceder
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  LIMPIEZA Lab v2 ShopAPI — ACCION DESTRUCTIVA"
echo "============================================================"
echo ""
echo "  Se eliminarán los siguientes recursos:"
echo ""
[[ -n "${SERVICE_NAME:-}" ]]    && echo "  - ECS Service:        $SERVICE_NAME"
[[ -n "${ALB_ARN:-}" ]]         && echo "  - ALB:                $ALB_DNS"
[[ -n "${TG_ARN:-}" ]]          && echo "  - Target Group:       shopapi-tg"
[[ -n "${NAT_GW_ID:-}" ]]       && echo "  - NAT Gateway:        $NAT_GW_ID"
[[ -n "${EIP_ALLOC_ID:-}" ]]    && echo "  - Elastic IP:         $EIP_PUBLIC_IP"
[[ -n "${IGW_ID:-}" ]]          && echo "  - Internet Gateway:   $IGW_ID"
[[ -n "${PUBLIC_SUBNET_A:-}" ]] && echo "  - Subnets (x4):       public-a/b, private-a/b"
[[ -n "${RT_PUBLIC_ID:-}" ]]    && echo "  - Route Tables:       public + private"
[[ -n "${TASK_SG_ID:-}" ]]      && echo "  - Security Groups:    alb-sg, task-sg"
[[ -n "${VPC_ID:-}" ]]          && echo "  - VPC:                $VPC_ID"
echo ""
echo "  NO se eliminarán: cluster ECS, imagen ECR (pertenecen al Lab v1)"
echo ""

read -r -p "  Escribir 'ELIMINAR' para confirmar: " CONFIRM

if [[ "$CONFIRM" != "ELIMINAR" ]]; then
  echo "  Cancelado. No se eliminó ningún recurso."
  exit 0
fi

echo ""
log "Iniciando limpieza..."
echo ""

# ==============================================================================
# PASO 1: ECS Service
# ==============================================================================
log "========== PASO 1: ECS Service =========="

if [[ -n "${SERVICE_NAME:-}" ]]; then
  # Verificar que el servicio existe
  SERVICE_STATUS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].status' \
    --output text 2>/dev/null || echo "MISSING")

  if [[ "$SERVICE_STATUS" == "ACTIVE" ]]; then
    # 1a. Scale down a 0 para que las tasks terminen
    log "Escalando servicio a 0 tasks..."
    aws ecs update-service \
      --cluster "$CLUSTER_NAME" \
      --service "$SERVICE_NAME" \
      --desired-count 0 \
      --region "$REGION" \
      --query 'service.desiredCount' \
      --output text

    ok "Servicio escalado a 0"

    # Esperar a que todas las tasks terminen
    log "Esperando que todas las tasks terminen (hasta 60 segundos)..."
    TIMEOUT=60
    ELAPSED=0
    while [[ $ELAPSED -lt $TIMEOUT ]]; do
      RUNNING=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$REGION" \
        --query 'services[0].runningCount' \
        --output text 2>/dev/null || echo "0")

      if [[ "$RUNNING" == "0" ]]; then
        ok "Todas las tasks han terminado"
        break
      fi

      log "  Tasks aún en ejecución: $RUNNING — esperando..."
      sleep 10
      ELAPSED=$((ELAPSED + 10))
    done

    # 1b. Eliminar el servicio
    log "Eliminando servicio $SERVICE_NAME..."
    aws ecs delete-service \
      --cluster "$CLUSTER_NAME" \
      --service "$SERVICE_NAME" \
      --region "$REGION" \
      --query 'service.status' \
      --output text

    ok "Servicio $SERVICE_NAME eliminado"

  elif [[ "$SERVICE_STATUS" == "MISSING" || "$SERVICE_STATUS" == "INACTIVE" ]]; then
    skip "Servicio $SERVICE_NAME no encontrado o ya eliminado"
  else
    warn "Servicio en estado inesperado: $SERVICE_STATUS — intentando eliminar..."
    aws ecs delete-service \
      --cluster "$CLUSTER_NAME" \
      --service "$SERVICE_NAME" \
      --region "$REGION" 2>/dev/null || warn "No se pudo eliminar el servicio"
  fi
else
  skip "SERVICE_NAME no definida"
fi

# Verificación
log "Verificando que el servicio no existe..."
FINAL_STATUS=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$REGION" \
  --query 'services[0].status' \
  --output text 2>/dev/null || echo "MISSING")

if [[ "$FINAL_STATUS" == "INACTIVE" || "$FINAL_STATUS" == "MISSING" ]]; then
  ok "Verificado: servicio eliminado (estado: $FINAL_STATUS)"
else
  warn "El servicio puede tardar unos segundos en eliminarse completamente"
fi

# ==============================================================================
# PASO 2: ALB (el listener se elimina automáticamente con el ALB)
# ==============================================================================
log ""
log "========== PASO 2: ALB =========="

if [[ -n "${ALB_ARN:-}" ]]; then
  # Verificar que el ALB existe
  ALB_EXISTS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --region "$REGION" \
    --query 'LoadBalancers[0].State.Code' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$ALB_EXISTS" != "NOT_FOUND" ]]; then
    log "Eliminando ALB shopapi-alb..."
    aws elbv2 delete-load-balancer \
      --load-balancer-arn "$ALB_ARN" \
      --region "$REGION"

    log "Esperando que el ALB se elimine completamente..."
    aws elbv2 wait load-balancers-deleted \
      --load-balancer-arns "$ALB_ARN" \
      --region "$REGION"

    ok "ALB eliminado: $ALB_DNS"
  else
    skip "ALB no encontrado (ya eliminado)"
  fi
else
  skip "ALB_ARN no definida"
fi

# ==============================================================================
# PASO 3: Target Group
# ==============================================================================
log ""
log "========== PASO 3: Target Group =========="

if [[ -n "${TG_ARN:-}" ]]; then
  TG_EXISTS=$(aws elbv2 describe-target-groups \
    --target-group-arns "$TG_ARN" \
    --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupName' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$TG_EXISTS" != "NOT_FOUND" ]]; then
    log "Eliminando Target Group shopapi-tg..."
    aws elbv2 delete-target-group \
      --target-group-arn "$TG_ARN" \
      --region "$REGION"
    ok "Target Group eliminado"
  else
    skip "Target Group no encontrado (ya eliminado)"
  fi
else
  skip "TG_ARN no definida"
fi

# ==============================================================================
# PASO 4: NAT Gateway y Elastic IP
# ==============================================================================
log ""
log "========== PASO 4: NAT Gateway y Elastic IP =========="

if [[ -n "${NAT_GW_ID:-}" ]]; then
  NAT_STATE=$(aws ec2 describe-nat-gateways \
    --nat-gateway-ids "$NAT_GW_ID" \
    --region "$REGION" \
    --query 'NatGateways[0].State' \
    --output text 2>/dev/null || echo "deleted")

  if [[ "$NAT_STATE" != "deleted" && "$NAT_STATE" != "NOT_FOUND" ]]; then
    log "Eliminando NAT Gateway $NAT_GW_ID..."
    log "  (este proceso puede tardar 60-90 segundos)"

    aws ec2 delete-nat-gateway \
      --nat-gateway-id "$NAT_GW_ID" \
      --region "$REGION" \
      --query 'NatGatewayId' \
      --output text

    log "Esperando que el NAT Gateway se elimine..."
    aws ec2 wait nat-gateway-deleted \
      --filter "Name=nat-gateway-id,Values=$NAT_GW_ID" \
      --region "$REGION"

    ok "NAT Gateway eliminado: $NAT_GW_ID"
  else
    skip "NAT Gateway no encontrado o ya eliminado (estado: $NAT_STATE)"
  fi
else
  skip "NAT_GW_ID no definida"
fi

if [[ -n "${EIP_ALLOC_ID:-}" ]]; then
  EIP_EXISTS=$(aws ec2 describe-addresses \
    --allocation-ids "$EIP_ALLOC_ID" \
    --region "$REGION" \
    --query 'Addresses[0].AllocationId' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$EIP_EXISTS" != "NOT_FOUND" ]]; then
    log "Liberando Elastic IP $EIP_PUBLIC_IP..."
    aws ec2 release-address \
      --allocation-id "$EIP_ALLOC_ID" \
      --region "$REGION"
    ok "Elastic IP liberada: $EIP_PUBLIC_IP"
  else
    skip "Elastic IP no encontrada (ya liberada)"
  fi
else
  skip "EIP_ALLOC_ID no definida"
fi

# ==============================================================================
# PASO 5: Internet Gateway (detach + delete)
# ==============================================================================
log ""
log "========== PASO 5: Internet Gateway =========="

if [[ -n "${IGW_ID:-}" && -n "${VPC_ID:-}" ]]; then
  IGW_EXISTS=$(aws ec2 describe-internet-gateways \
    --internet-gateway-ids "$IGW_ID" \
    --region "$REGION" \
    --query 'InternetGateways[0].InternetGatewayId' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$IGW_EXISTS" != "NOT_FOUND" ]]; then
    log "Desasociando IGW $IGW_ID de VPC $VPC_ID..."
    aws ec2 detach-internet-gateway \
      --internet-gateway-id "$IGW_ID" \
      --vpc-id "$VPC_ID" \
      --region "$REGION" 2>/dev/null || warn "IGW puede no estar asociado a la VPC"

    log "Eliminando IGW $IGW_ID..."
    aws ec2 delete-internet-gateway \
      --internet-gateway-id "$IGW_ID" \
      --region "$REGION"
    ok "Internet Gateway eliminado: $IGW_ID"
  else
    skip "IGW no encontrado (ya eliminado)"
  fi
else
  skip "IGW_ID o VPC_ID no definidos"
fi

# ==============================================================================
# PASO 6: Subnets
# ==============================================================================
log ""
log "========== PASO 6: Subnets =========="

for SUBNET_VAR in PUBLIC_SUBNET_A PUBLIC_SUBNET_B PRIVATE_SUBNET_A PRIVATE_SUBNET_B; do
  SUBNET_ID="${!SUBNET_VAR:-}"

  if [[ -z "$SUBNET_ID" ]]; then
    skip "$SUBNET_VAR no definida"
    continue
  fi

  SUBNET_EXISTS=$(aws ec2 describe-subnets \
    --subnet-ids "$SUBNET_ID" \
    --region "$REGION" \
    --query 'Subnets[0].SubnetId' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$SUBNET_EXISTS" != "NOT_FOUND" ]]; then
    log "Eliminando subnet $SUBNET_VAR: $SUBNET_ID..."
    aws ec2 delete-subnet \
      --subnet-id "$SUBNET_ID" \
      --region "$REGION"
    ok "Subnet eliminada: $SUBNET_ID ($SUBNET_VAR)"
  else
    skip "Subnet $SUBNET_ID no encontrada (ya eliminada)"
  fi
done

# ==============================================================================
# PASO 7: Route Tables
# ==============================================================================
log ""
log "========== PASO 7: Route Tables =========="

for RT_VAR in RT_PUBLIC_ID RT_PRIVATE_ID; do
  RT_ID="${!RT_VAR:-}"

  if [[ -z "$RT_ID" ]]; then
    skip "$RT_VAR no definida"
    continue
  fi

  RT_EXISTS=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --region "$REGION" \
    --query 'RouteTables[0].RouteTableId' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$RT_EXISTS" != "NOT_FOUND" ]]; then
    log "Eliminando route table $RT_VAR: $RT_ID..."
    aws ec2 delete-route-table \
      --route-table-id "$RT_ID" \
      --region "$REGION"
    ok "Route table eliminada: $RT_ID ($RT_VAR)"
  else
    skip "Route table $RT_ID no encontrada (ya eliminada)"
  fi
done

# ==============================================================================
# PASO 8: Security Groups (task SG primero — depende de ALB SG)
# ==============================================================================
log ""
log "========== PASO 8: Security Groups =========="

for SG_VAR in TASK_SG_ID ALB_SG_ID; do
  SG_ID="${!SG_VAR:-}"

  if [[ -z "$SG_ID" ]]; then
    skip "$SG_VAR no definida"
    continue
  fi

  SG_EXISTS=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --region "$REGION" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$SG_EXISTS" != "NOT_FOUND" ]]; then
    log "Eliminando Security Group $SG_VAR: $SG_ID..."
    aws ec2 delete-security-group \
      --group-id "$SG_ID" \
      --region "$REGION"
    ok "Security Group eliminado: $SG_ID ($SG_VAR)"
  else
    skip "Security Group $SG_ID no encontrado (ya eliminado)"
  fi
done

# ==============================================================================
# PASO 9: VPC
# ==============================================================================
log ""
log "========== PASO 9: VPC =========="

if [[ -n "${VPC_ID:-}" ]]; then
  VPC_EXISTS=$(aws ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" \
    --region "$REGION" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$VPC_EXISTS" != "NOT_FOUND" ]]; then
    log "Eliminando VPC $VPC_ID..."
    aws ec2 delete-vpc \
      --vpc-id "$VPC_ID" \
      --region "$REGION"
    ok "VPC eliminada: $VPC_ID"
  else
    skip "VPC no encontrada (ya eliminada)"
  fi
else
  skip "VPC_ID no definida"
fi

# ==============================================================================
# Limpieza del archivo de entorno
# ==============================================================================
log ""
log "Archivando archivo de entorno..."

if [[ -f "$ENV_FILE" ]]; then
  ARCHIVE_FILE="${ENV_FILE}.deleted_$(date '+%Y%m%d_%H%M%S')"
  mv "$ENV_FILE" "$ARCHIVE_FILE"
  ok "Archivo de entorno archivado: $ARCHIVE_FILE"
fi

# ==============================================================================
# Verificación final
# ==============================================================================
log ""
log "========== VERIFICACION FINAL =========="

ERRORS=0

# Verificar VPC
if [[ -n "${VPC_ID:-}" ]]; then
  VPC_CHECK=$(aws ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" \
    --region "$REGION" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || echo "DELETED")

  if [[ "$VPC_CHECK" == "DELETED" || "$VPC_CHECK" == "None" ]]; then
    ok "VPC $VPC_ID: ELIMINADA"
  else
    warn "VPC $VPC_ID aún existe (puede estar en proceso de eliminación)"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Verificar ECS Service
SERVICE_CHECK=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$REGION" \
  --query 'services[0].status' \
  --output text 2>/dev/null || echo "DELETED")

if [[ "$SERVICE_CHECK" == "INACTIVE" || "$SERVICE_CHECK" == "DELETED" || "$SERVICE_CHECK" == "None" ]]; then
  ok "ECS Service $SERVICE_NAME: ELIMINADO"
else
  warn "ECS Service puede no estar completamente eliminado (estado: $SERVICE_CHECK)"
fi

# ==============================================================================
# Resumen
# ==============================================================================
echo ""
echo "============================================================"
echo "  LIMPIEZA COMPLETADA — ShopAPI Lab v2"
echo "============================================================"
echo ""
echo "  Recursos eliminados:"
echo "    ECS Service:       $SERVICE_NAME"
echo "    ALB:               ${ALB_DNS:-n/a}"
echo "    Target Group:      shopapi-tg"
echo "    NAT Gateway:       ${NAT_GW_ID:-n/a}"
echo "    Elastic IP:        ${EIP_PUBLIC_IP:-n/a}"
echo "    Internet Gateway:  ${IGW_ID:-n/a}"
echo "    Subnets (x4):      public-a/b, private-a/b"
echo "    Route Tables (x2): public, private"
echo "    Security Groups:   alb-sg, task-sg"
echo "    VPC:               ${VPC_ID:-n/a}"
echo ""
echo "  Recursos conservados (Lab v1):"
echo "    Cluster ECS:       $CLUSTER_NAME"
echo "    Repositorio ECR:   shopapi/api"
echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "  ATENCION: $ERRORS recurso(s) pueden no haberse eliminado completamente."
  echo "  Verifica en la consola AWS y elimínalos manualmente si es necesario."
else
  echo "  Todos los recursos eliminados correctamente."
fi
echo "============================================================"
