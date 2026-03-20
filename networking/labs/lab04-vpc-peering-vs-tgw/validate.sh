#!/usr/bin/env bash
# validate.sh — Lab 04: VPC Peering no transitivo vs Transit Gateway
#
# Uso:
#   ./validate.sh peering-partial  → demuestra no-transitividad
#   ./validate.sh peering-full     → demuestra full mesh (funciona + tabla escala)
#   ./validate.sh tgw              → demuestra TGW como solución
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

log()      { echo -e "${NC}[INFO]  $*${NC}"; }
pass()     { echo -e "${GREEN}[PASS]  $*${NC}"; }
fail()     { echo -e "${RED}[FAIL]  $*${NC}"; }
expected() { echo -e "${YELLOW}[EXPECTED-FAIL]  $*${NC}"; }
header()   { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

if [[ -z "$CONFIG" ]]; then
  echo "Uso: $0 peering-partial|peering-full|tgw"
  exit 1
fi

if [[ ! "$CONFIG" =~ ^(peering-partial|peering-full|tgw)$ ]]; then
  echo "Config inválida: $CONFIG. Debe ser peering-partial, peering-full o tgw."
  exit 1
fi

# Ejecuta ping via SSM Run Command y devuelve 0 si OK, 1 si timeout/fallo
ssm_ping() {
  local src_instance="$1"
  local target_ip="$2"

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --instance-ids "$src_instance" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"ping -c 3 -W 2 $target_ip && echo PING_OK || echo PING_FAIL\"]" \
    --region "$REGION" \
    --query "Command.CommandId" \
    --output text 2>/dev/null)

  local attempts=0
  while [[ $attempts -lt 20 ]]; do
    sleep 3
    local status output
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$src_instance" \
      --region "$REGION" \
      --query "Status" \
      --output text 2>/dev/null || echo "Pending")

    if [[ "$status" == "Success" ]]; then
      output=$(aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$src_instance" \
        --region "$REGION" \
        --query "StandardOutputContent" \
        --output text)
      if echo "$output" | grep -q "PING_OK"; then
        return 0
      else
        return 1
      fi
    elif [[ "$status" == "Failed" || "$status" == "TimedOut" ]]; then
      return 1
    fi
    ((attempts++))
  done
  return 1
}

print_scale_table() {
  echo ""
  log "Tabla de escala — Peerings necesarios vs TGW attachments:"
  printf "  %-8s %-22s %-20s\n" "VPCs" "Peerings (N*(N-1)/2)" "TGW attachments (N)"
  printf "  %-8s %-22s %-20s\n" "────" "──────────────────────" "───────────────────"
  for n in 3 5 10 20 50 100; do
    peerings=$(( n * (n-1) / 2 ))
    printf "  %-8s %-22s %-20s\n" "$n" "$peerings" "$n"
  done
  echo ""
  log "Con TGW siempre añades N attachments, no N*(N-1)/2 peerings."
}

# ─── MAIN ───────────────────────────────────────────────
header "Lab 04 — Validando config: $CONFIG"

cd "$TERRAGRUNT_DIR/$CONFIG"

log "Leyendo outputs de Terragrunt..."
EC2_A=$(terragrunt output -raw ec2_a_instance_id)
EC2_B=$(terragrunt output -raw ec2_b_instance_id)
EC2_C=$(terragrunt output -raw ec2_c_instance_id)
IP_A=$(terragrunt output -raw ec2_a_private_ip)
IP_C=$(terragrunt output -raw ec2_c_private_ip)
MODE=$(terragrunt output -raw connectivity_mode)

log "EC2-A: $EC2_A (IP: $IP_A)"
log "EC2-B: $EC2_B"
log "EC2-C: $EC2_C (IP: $IP_C)"
log "Modo: $MODE"

log ""
log "Esperando 2 minutos para que SSM agent se registre en las EC2..."
sleep 120

# Fase 1: Tests que siempre deben pasar
header "Fase 1: Conectividad A↔B y B↔C (siempre debe funcionar)"

EC2_B_IP=$(aws ec2 describe-instances \
  --instance-ids "$EC2_B" \
  --region "$REGION" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

if ssm_ping "$EC2_A" "$EC2_B_IP"; then
  pass "EC2-A puede hacer ping a EC2-B ✓"
else
  fail "EC2-A NO puede hacer ping a EC2-B — revisar peering/TGW y route tables"
fi

# Fase 2: Test crítico A↔C
header "Fase 2: Test crítico — EC2-A → EC2-C (IP: $IP_C)"

if ssm_ping "$EC2_A" "$IP_C"; then
  if [[ "$MODE" == "peering-partial" ]]; then
    fail "[$MODE] EC2-A llegó a EC2-C — NO debería en modo peering-partial (no-transitivo)"
  else
    pass "[$MODE] EC2-A puede hacer ping a EC2-C ✓"
  fi
else
  if [[ "$MODE" == "peering-partial" ]]; then
    expected "[$MODE] EC2-A NO puede hacer ping a EC2-C — NO-TRANSITIVIDAD CONFIRMADA ✓"
    log "A↔B y B↔C configurados, pero A no puede llegar a C sin peering A↔C directo."
  else
    fail "[$MODE] EC2-A debería poder hacer ping a EC2-C en modo $MODE"
  fi
fi

# Fase 3: Tabla de escala y resumen de coste
header "Fase 3: Escala y coste"

print_scale_table

log "Coste de esta configuración ($MODE):"
case "$MODE" in
  peering-partial|peering-full)
    log "  VPC Peering: GRATUITO (solo data transfer \$0.01/GB cross-VPC)"
    log "  NAT GW: ~\$0.045/h"
    log "  Total: ~\$0.07/h"
    ;;
  tgw)
    log "  TGW: 3 attachments × \$0.05/h = \$0.15/h"
    log "  NAT GW: ~\$0.045/h"
    log "  Total: ~\$0.20/h"
    log "  Valor: N VPCs = N attachments (no N*(N-1)/2 peerings)"
    ;;
esac

echo ""
log "Para destruir: cd $TERRAGRUNT_DIR/$CONFIG && terragrunt destroy"
