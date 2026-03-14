#!/usr/bin/env bash
# =============================================================================
# Lab03 DynamoDB — Variables de entorno y funciones auxiliares
# =============================================================================
# Uso: source cli/00-env.sh
# =============================================================================

set -euo pipefail

export AWS_REGION="eu-west-1"
export LAB="lab03"
export PROJECT="db-labs"
export ENV="lab"

# DynamoDB
export DYNAMO_TABLE="ecommerce-orders"

# Lambda
export LAMBDA_FUNCTION="dynamodb-stream-processor"
export LAMBDA_ROLE="lambda-dynamodb-stream-role"

# SNS / Alarmas
export SNS_TOPIC_NAME="dynamodb-lab03-alerts"

# Auto-detect account
export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query 'Account' --output text --region "$AWS_REGION" 2>/dev/null || echo "UNKNOWN")

# Archivo de recursos
export RESOURCES_FILE="${BASH_SOURCE[0]%/*}/00-resources-dynamo.env"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()     { echo "[$(date +%H:%M:%S)] $*"; }
ok()      { echo "[$(date +%H:%M:%S)] ✓ $*"; }
warn()    { echo "[$(date +%H:%M:%S)] ⚠ $*" >&2; }
fail()    { echo "[$(date +%H:%M:%S)] ✗ ERROR: $*" >&2; exit 1; }
section() { echo; echo "════════════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════════════"; }

safe_run() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then
    ok "$desc"
  else
    warn "$desc — no encontrado o ya eliminado (continuando...)"
  fi
}

save_resource() {
  local key="$1" val="$2"
  touch "$RESOURCES_FILE"
  sed -i "/^${key}=/d" "$RESOURCES_FILE" 2>/dev/null || true
  echo "${key}=${val}" >> "$RESOURCES_FILE"
}

load_resources() {
  if [[ -f "$RESOURCES_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$RESOURCES_FILE"
    log "Recursos cargados desde $RESOURCES_FILE"
  fi
}

check_prereqs() {
  section "Verificando prerrequisitos"
  command -v aws  &>/dev/null || fail "AWS CLI no instalado"
  command -v jq   &>/dev/null || fail "jq no instalado"
  command -v zip  &>/dev/null || fail "zip no instalado: sudo apt install zip"
  aws sts get-caller-identity --region "$AWS_REGION" --output text &>/dev/null \
    || fail "Sin credenciales AWS válidas"
  ok "AWS CLI: $(aws --version 2>&1 | head -1)"
  ok "Account: $ACCOUNT_ID | Region: $AWS_REGION"
}

# Cargar automáticamente si existen
if [[ -f "$RESOURCES_FILE" ]]; then
  source "$RESOURCES_FILE"
fi

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  log "Entorno Lab03 DynamoDB cargado"
  log "  Tabla:    $DYNAMO_TABLE"
  log "  Lambda:   $LAMBDA_FUNCTION"
  log "  Region:   $AWS_REGION"
fi
