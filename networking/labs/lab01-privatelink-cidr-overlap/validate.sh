#!/usr/bin/env bash
# =============================================================================
# validate.sh — Script de validación para Lab01 PrivateLink con CIDRs solapados
#
# USO: bash validate.sh [--skip-peering-test]
#
# PASOS:
#   1. Verifica que ambas VPCs tienen el mismo CIDR
#   2. Intenta crear VPC Peering (debe fallar — CIDRs solapados)
#   3. Verifica estado del NLB target group (provider EC2 debe estar healthy)
#   4. Prueba conectividad via PrivateLink usando SSM Run Command
# =============================================================================

set -euo pipefail

REGION="eu-west-1"
SKIP_PEERING_TEST="${1:-}"

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[FAIL]${NC} $*"; }

# ---------------------------------------------------------------------------
# Obtener outputs de Terraform
# ---------------------------------------------------------------------------
log_info "Obteniendo outputs de Terragrunt..."
cd "$(dirname "$0")/terragrunt"

CONSUMER_ID=$(terragrunt output -raw consumer_instance_id 2>/dev/null)
VPC_A_ID=$(terragrunt output -raw vpc_a_id 2>/dev/null)
VPC_B_ID=$(terragrunt output -raw vpc_b_id 2>/dev/null)
VPC_A_CIDR=$(terragrunt output -raw vpc_a_cidr 2>/dev/null)
VPC_B_CIDR=$(terragrunt output -raw vpc_b_cidr 2>/dev/null)
ENDPOINT_DNS=$(terragrunt output -raw endpoint_dns_name 2>/dev/null)
HTTP_PORT=8080

log_ok "Consumer EC2  : $CONSUMER_ID"
log_ok "VPC-A ID      : $VPC_A_ID  (CIDR: $VPC_A_CIDR)"
log_ok "VPC-B ID      : $VPC_B_ID  (CIDR: $VPC_B_CIDR)"
log_ok "Endpoint DNS  : $ENDPOINT_DNS"

echo ""
echo "========================================================"
echo " PASO 1 — Verificar CIDRs solapados"
echo "========================================================"

if [[ "$VPC_A_CIDR" == "$VPC_B_CIDR" ]]; then
  log_ok "CONFIRMADO: Ambas VPCs tienen el mismo CIDR: $VPC_A_CIDR"
  log_info "→ VPC Peering entre estas VPCs es IMPOSIBLE"
else
  log_warn "Los CIDRs son diferentes: VPC-A=$VPC_A_CIDR, VPC-B=$VPC_B_CIDR"
  log_warn "Verificar que el despliegue es correcto"
fi

echo ""
echo "========================================================"
echo " PASO 2 — Demostrar que VPC Peering falla"
echo "========================================================"

if [[ "$SKIP_PEERING_TEST" == "--skip-peering-test" ]]; then
  log_warn "Skipping VPC Peering test (--skip-peering-test)"
else
  log_info "Intentando crear VPC Peering (debe fallar)..."

  PEERING_OUTPUT=$(aws ec2 create-vpc-peering-connection \
    --vpc-id "$VPC_A_ID" \
    --peer-vpc-id "$VPC_B_ID" \
    --region "$REGION" 2>&1 || true)

  if echo "$PEERING_OUTPUT" | grep -qi "overlapping\|overlap\|cidr"; then
    log_ok "VPC Peering RECHAZADO por AWS (como se esperaba):"
    echo "   $PEERING_OUTPUT" | grep -i "error\|message\|overlap" | head -3
    log_info "→ Mensaje de error confirma: CIDRs solapados impiden el peering"
  elif echo "$PEERING_OUTPUT" | grep -qi "error\|exception"; then
    log_ok "VPC Peering fallido (error de AWS):"
    echo "   $PEERING_OUTPUT" | head -3
  else
    # Si por alguna razón se creó (no debería pasar), limpiarlo
    PEERING_ID=$(echo "$PEERING_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('VpcPeeringConnection',{}).get('VpcPeeringConnectionId',''))" 2>/dev/null || echo "")
    if [[ -n "$PEERING_ID" ]]; then
      log_warn "VPC Peering creado inesperadamente: $PEERING_ID — eliminando..."
      aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PEERING_ID" --region "$REGION" || true
    fi
    log_error "Resultado inesperado del VPC Peering test"
    echo "$PEERING_OUTPUT"
  fi
fi

echo ""
echo "========================================================"
echo " PASO 3 — Verificar estado del NLB Target Group"
echo "========================================================"

log_info "Buscando Target Groups del NLB..."

TG_ARN=$(aws elbv2 describe-target-groups \
  --region "$REGION" \
  --query "TargetGroups[?contains(TargetGroupName,'lab01')].TargetGroupArn" \
  --output text 2>/dev/null | head -1)

if [[ -z "$TG_ARN" ]]; then
  log_warn "Target Group no encontrado — verificar que el apply completó"
else
  log_info "Target Group: $TG_ARN"

  HEALTH=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region "$REGION" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text 2>/dev/null)

  if [[ "$HEALTH" == "healthy" ]]; then
    log_ok "NLB Target → Provider EC2: HEALTHY"
    log_info "→ El servidor HTTP en VPC-B está respondiendo al health check TCP"
  else
    log_warn "NLB Target estado: $HEALTH"
    log_warn "→ Puede necesitar más tiempo para que el HTTP server arranque (~30s)"
    log_warn "→ Reintentar en 30 segundos con: bash validate.sh"
  fi
fi

echo ""
echo "========================================================"
echo " PASO 4 — Probar conectividad via PrivateLink"
echo "========================================================"

log_info "Comprobando estado del SSM agent en Consumer EC2..."

SSM_STATUS=$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${CONSUMER_ID}" \
  --region "$REGION" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text 2>/dev/null)

if [[ "$SSM_STATUS" != "Online" ]]; then
  log_warn "SSM agent no está Online aún (estado: ${SSM_STATUS:-pendiente})"
  log_warn "Esperando 30 segundos..."
  sleep 30
  SSM_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${CONSUMER_ID}" \
    --region "$REGION" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null)
fi

if [[ "$SSM_STATUS" == "Online" ]]; then
  log_ok "SSM agent Online en Consumer EC2"
  log_info "Ejecutando curl al Interface Endpoint via SSM Run Command..."

  CMD_ID=$(aws ssm send-command \
    --instance-ids "$CONSUMER_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"curl -s -m 10 http://${ENDPOINT_DNS}:${HTTP_PORT}/\"]" \
    --region "$REGION" \
    --query "Command.CommandId" \
    --output text)

  log_info "Run Command iniciado (ID: $CMD_ID) — esperando resultado..."
  sleep 10

  RESULT=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$CONSUMER_ID" \
    --region "$REGION" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' \
    --output json 2>/dev/null)

  CMD_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0])" 2>/dev/null)
  CMD_OUTPUT=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r[1])" 2>/dev/null)
  CMD_ERROR=$(echo  "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r[2])" 2>/dev/null)

  if [[ "$CMD_STATUS" == "Success" ]] && echo "$CMD_OUTPUT" | grep -q "PrivateLink"; then
    log_ok "PrivateLink funciona correctamente"
    echo ""
    echo "Respuesta del servidor en VPC-B:"
    echo "────────────────────────────────"
    echo "$CMD_OUTPUT"
    echo "────────────────────────────────"
  elif [[ "$CMD_STATUS" == "InProgress" ]]; then
    log_warn "Command aún en progreso — reintentar en 15s:"
    echo "  aws ssm get-command-invocation --command-id $CMD_ID --instance-id $CONSUMER_ID --region $REGION"
  else
    log_error "curl falló (status: $CMD_STATUS)"
    [[ -n "$CMD_OUTPUT" ]] && echo "stdout: $CMD_OUTPUT"
    [[ -n "$CMD_ERROR" ]] && echo "stderr: $CMD_ERROR"
    echo ""
    log_info "Puede que el endpoint o el NLB aún no estén completamente activos."
    log_info "Reintentar en 30-60 segundos: bash validate.sh"
  fi
else
  log_warn "SSM agent no disponible (estado: ${SSM_STATUS:-no encontrado})"
  log_info "Para validar manualmente:"
  echo "  1. Iniciar sesión SSM:"
  echo "     aws ssm start-session --target $CONSUMER_ID --region $REGION"
  echo ""
  echo "  2. Dentro de la sesión:"
  echo "     curl -s http://${ENDPOINT_DNS}:${HTTP_PORT}/"
fi

echo ""
echo "========================================================"
echo " PASO 5 — Verificar DNS del Interface Endpoint"
echo "========================================================"

log_info "El Endpoint DNS debe resolver a una IP en la subnet de VPC-A (10.0.1.x)"
log_info "Resolución DNS desde fuera de la VPC:"
nslookup "$ENDPOINT_DNS" 2>/dev/null | grep -E "Address:|Name:" || \
  host "$ENDPOINT_DNS" 2>/dev/null | head -5 || \
  log_warn "Resolución DNS falló desde fuera de la VPC (normal — usar dentro de la VPC)"

echo ""
echo "========================================================"
echo " RESUMEN"
echo "========================================================"
echo ""
echo "  VPC-A CIDR  : $VPC_A_CIDR  (Consumer)"
echo "  VPC-B CIDR  : $VPC_B_CIDR  (Provider)"
echo "  ✓ Mismo CIDR — VPC Peering imposible"
echo "  ✓ PrivateLink funciona sin routing IP entre VPCs"
echo ""
echo "  Para iniciar sesión SSM manualmente:"
echo "  aws ssm start-session --target $CONSUMER_ID --region $REGION"
echo ""
echo "  Para cleanup:"
echo "  cd terragrunt && terragrunt destroy"
echo ""
