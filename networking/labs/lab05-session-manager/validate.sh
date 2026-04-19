#!/usr/bin/env bash
# validate.sh — Lab 05: Session Manager sin internet
#
# Uso:
#   ./validate.sh internet    → SSM via NAT GW, curl funciona
#   ./validate.sh endpoints   → SSM via endpoints, curl falla (zero internet)
#
# Prerrequisitos:
#   - terragrunt apply ejecutado en el entorno elegido
#   - aws cli v2 con permisos EC2 + SSM
#   - jq instalado

set -euo pipefail

CONFIG="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAGRUNT_DIR="$SCRIPT_DIR/terragrunt"
REGION="eu-west-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "${NC}[INFO]     $*${NC}"; }
pass()     { echo -e "${GREEN}[PASS]     $*${NC}"; }
fail()     { echo -e "${RED}[FAIL]     $*${NC}"; }
expected() { echo -e "${YELLOW}[EXPECTED] $*${NC}"; }
header()   { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

if [[ -z "$CONFIG" || ! "$CONFIG" =~ ^(internet|endpoints)$ ]]; then
  echo "Uso: $0 internet|endpoints"
  exit 1
fi

# Ejecuta un comando via SSM Run Command y devuelve el stdout
ssm_run() {
  local instance_id="$1"
  local command="$2"

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$command\"]" \
    --region "$REGION" \
    --query "Command.CommandId" \
    --output text)

  local attempts=0
  while [[ $attempts -lt 20 ]]; do
    sleep 3
    local status
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --region "$REGION" \
      --query "Status" \
      --output text 2>/dev/null || echo "Pending")

    if [[ "$status" == "Success" ]]; then
      aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --region "$REGION" \
        --query "StandardOutputContent" \
        --output text
      return 0
    elif [[ "$status" == "Failed" || "$status" == "TimedOut" ]]; then
      return 1
    fi
    ((attempts++))
  done
  return 1
}

# --- MAIN -----------------------------------------------------------
header "Lab 05 - Session Manager: config $CONFIG"

cd "$TERRAGRUNT_DIR/$CONFIG"

log "Leyendo outputs..."
INSTANCE_ID=$(terragrunt output -raw instance_id)
MODE=$(terragrunt output -raw ssm_mode)

log "EC2: $INSTANCE_ID"
log "Modo: $MODE"

log "Esperando 2 minutos para que SSM Agent se registre..."
sleep 120

# Verificar que la instancia está registrada en SSM
log "Verificando registro SSM..."
SSM_STATUS=$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --region "$REGION" \
  --query "InstanceInformationList[0].PingStatus" \
  --output text 2>/dev/null || echo "NotFound")

if [[ "$SSM_STATUS" == "Online" ]]; then
  pass "EC2 registrada en SSM (PingStatus: Online)"
else
  fail "EC2 NO esta registrada en SSM (status: $SSM_STATUS)"
  log "Posibles causas: IAM role incorrecto, endpoints no disponibles, NAT GW no activo"
  exit 1
fi

# Fase 1: SSM Run Command funciona
header "Fase 1: SSM Run Command"

if output=$(ssm_run "$INSTANCE_ID" "whoami"); then
  pass "SSM Run Command funciona. Resultado: $output"
else
  fail "SSM Run Command fallo"
  exit 1
fi

# Fase 2: Test de acceso a internet
header "Fase 2: Acceso a internet (curl ifconfig.me)"

if output=$(ssm_run "$INSTANCE_ID" "curl -s --max-time 5 ifconfig.me || echo CURL_FAILED"); then
  if echo "$output" | grep -q "CURL_FAILED"; then
    if [[ "$MODE" == "endpoints" ]]; then
      expected "[$MODE] curl a internet fallo - ZERO INTERNET CONFIRMADO"
      log "SSM funciona via Interface Endpoints pero la EC2 no tiene acceso a internet."
    else
      fail "[$MODE] curl deberia funcionar en modo internet pero fallo"
    fi
  else
    if [[ "$MODE" == "internet" ]]; then
      pass "[$MODE] curl funciona. IP publica (NAT GW): $output"
    else
      fail "[$MODE] curl no deberia funcionar en modo endpoints (zero internet)"
    fi
  fi
fi

# Fase 3: Inventario de endpoints
header "Fase 3: Interface Endpoints activos en la VPC"

VPC_ID=$(terragrunt output -raw vpc_id)

aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --region "$REGION" \
  --query "VpcEndpoints[].{Servicio:ServiceName,Estado:State,Tipo:VpcEndpointType}" \
  --output table

# Resumen de coste
header "Resumen de coste"

case "$MODE" in
  internet)
    log "NAT GW: ~\$0.045/h = ~\$32/mes"
    log "EC2 t3.micro: free tier"
    log "Total: ~\$0.05/h"
    log ""
    log "SSM Agent sale a internet por el NAT GW para contactar el servicio SSM."
    ;;
  endpoints)
    log "3 Interface Endpoints: 3 x \$0.01/h = ~\$0.03/h = ~\$21/mes"
    log "EC2 t3.micro: free tier"
    log "Total: ~\$0.03/h"
    log ""
    log "Interface Endpoints son MAS BARATOS que un NAT GW para trafico de gestion."
    log "Ademas, la EC2 esta completamente aislada de internet - mejor postura de seguridad."
    ;;
esac

echo ""
log "Para destruir: cd $TERRAGRUNT_DIR/$CONFIG && terragrunt destroy"
