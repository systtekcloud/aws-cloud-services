#!/usr/bin/env bash
# validate.sh — Lab 03: NAT Gateway Multi-AZ
#
# Uso:
#   ./validate.sh single-az   → demuestra el SPOF
#   ./validate.sh multi-az    → demuestra la HA
#   ./validate.sh both        → ejecuta ambos en secuencia
#
# Prerrequisitos:
#   - terragrunt apply ya ejecutado en el entorno elegido
#   - aws cli v2 configurado con permisos EC2 + SSM
#   - jq instalado

set -euo pipefail

CONFIG="${1:-both}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAGRUNT_DIR="$SCRIPT_DIR/terragrunt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${NC}[INFO] $*${NC}"; }
pass() { echo -e "${GREEN}[PASS] $*${NC}"; }
fail() { echo -e "${RED}[FAIL] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }

# Ejecuta un comando via SSM Run Command y devuelve el output
ssm_run() {
  local instance_id="$1"
  local command="$2"
  local region="${3:-eu-west-1}"

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$command\"]" \
    --region "$region" \
    --query "Command.CommandId" \
    --output text)

  # Esperar resultado (máx 30s)
  local attempts=0
  while [[ $attempts -lt 15 ]]; do
    sleep 2
    local status
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --region "$region" \
      --query "Status" \
      --output text 2>/dev/null || echo "Pending")

    if [[ "$status" == "Success" ]]; then
      aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --region "$region" \
        --query "StandardOutputContent" \
        --output text
      return 0
    elif [[ "$status" == "Failed" ]]; then
      return 1
    fi
    ((attempts++))
  done
  return 1
}

validate_config() {
  local config="$1"
  local env_dir="$TERRAGRUNT_DIR/$config"

  echo ""
  log "===== Validando configuración: $config ====="

  # Leer outputs de Terragrunt
  cd "$env_dir"
  local ec2_a ec2_b nat_a_id nat_ha
  ec2_a=$(terragrunt output -raw ec2_a_instance_id)
  ec2_b=$(terragrunt output -raw ec2_b_instance_id)
  nat_a_id=$(terragrunt output -raw nat_gateway_a_id)
  nat_ha=$(terragrunt output -raw nat_ha_enabled)

  log "EC2-A: $ec2_a"
  log "EC2-B: $ec2_b"
  log "NAT-A: $nat_a_id"
  log "HA activo: $nat_ha"

  # --- Fase 1: Conectividad inicial ---
  log ""
  log "Fase 1: Verificando conectividad inicial desde ambas EC2..."

  local ip_a ip_b
  if ip_a=$(ssm_run "$ec2_a" "curl -s --max-time 5 ifconfig.me"); then
    pass "EC2-A tiene conectividad a internet. IP pública: $ip_a"
  else
    fail "EC2-A NO tiene conectividad. Revisar NAT GW y route table."
    return 1
  fi

  if ip_b=$(ssm_run "$ec2_b" "curl -s --max-time 5 ifconfig.me"); then
    pass "EC2-B tiene conectividad a internet. IP pública: $ip_b"
  else
    fail "EC2-B NO tiene conectividad antes del fallo. Algo está mal."
    return 1
  fi

  # --- Fase 2: Simular fallo AZ-a ---
  log ""
  warn "Fase 2: Simulando fallo de AZ-a — eliminando NAT GW-a ($nat_a_id)..."
  aws ec2 delete-nat-gateway --nat-gateway-id "$nat_a_id" --region eu-west-1 > /dev/null
  log "Esperando 35 segundos para propagación de rutas..."
  sleep 35

  # --- Fase 3: Verificar comportamiento tras el fallo ---
  log ""
  log "Fase 3: Verificando conectividad de EC2-B tras fallo de AZ-a..."

  if ssm_run "$ec2_b" "curl -s --max-time 5 ifconfig.me" > /dev/null 2>&1; then
    if [[ "$nat_ha" == "true" ]]; then
      pass "[$config] EC2-B mantiene conectividad via NAT-B — HA funcionando correctamente."
    else
      fail "[$config] EC2-B debería haber perdido conectividad en single-az pero no lo hizo."
    fi
  else
    if [[ "$nat_ha" == "false" ]]; then
      pass "[$config] EC2-B perdió conectividad cuando AZ-a falló — SPOF confirmado."
      warn "Este es el comportamiento ESPERADO en single-az — demuestra el problema."
    else
      fail "[$config] EC2-B debería mantener conectividad en multi-az pero la perdió."
    fi
  fi

  # --- Resumen de coste ---
  echo ""
  log "===== Coste estimado ====="
  if [[ "$nat_ha" == "true" ]]; then
    log "Configuración multi-az: 2x NAT GW = ~\$0.09/h = ~\$64/mes"
    log "Beneficio: eliminación del SPOF + eliminación del cross-AZ data transfer charge (\$0.01/GB)"
  else
    log "Configuración single-az: 1x NAT GW = ~\$0.045/h = ~\$32/mes"
    warn "Riesgo: SPOF demostrado. Todo el tráfico AZ-b pasa por AZ-a (cross-AZ \$0.01/GB adicional)"
  fi

  warn ""
  warn "IMPORTANTE: El NAT GW-a fue eliminado durante la validación."
  warn "Para restaurar el lab ejecuta: cd $env_dir && terragrunt apply"
  warn "Para destruir definitivamente: cd $env_dir && terragrunt destroy"
}

case "$CONFIG" in
  single-az|multi-az)
    validate_config "$CONFIG"
    ;;
  both)
    validate_config "single-az"
    validate_config "multi-az"
    ;;
  *)
    echo "Uso: $0 single-az|multi-az|both"
    exit 1
    ;;
esac
