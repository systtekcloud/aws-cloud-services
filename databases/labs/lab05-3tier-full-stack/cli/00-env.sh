#!/usr/bin/env bash
# =============================================================================
# Lab05 3-Tier Full Stack — Variables de entorno y funciones auxiliares
# =============================================================================

set -euo pipefail

export AWS_REGION="eu-west-1"
export LAB="lab05"
export PROJECT="db-labs"
export ENV="lab"

# Red
export VPC_NAME="vpc-lab05-3tier"
export VPC_CIDR="10.20.0.0/16"
export SUBNET_PUBLIC_A_CIDR="10.20.0.0/24"
export SUBNET_PUBLIC_B_CIDR="10.20.1.0/24"
export SUBNET_APP_A_CIDR="10.20.10.0/24"
export SUBNET_APP_B_CIDR="10.20.11.0/24"
export SUBNET_DB_A_CIDR="10.20.20.0/24"
export SUBNET_DB_B_CIDR="10.20.21.0/24"
export AZ_A="eu-west-1a"
export AZ_B="eu-west-1b"

# Aurora
export AURORA_CLUSTER_ID="aurora-lab05"
export AURORA_WRITER_ID="aurora-lab05-writer"
export AURORA_READER_ID="aurora-lab05-reader"
export AURORA_DB_NAME="ecommerce"
export AURORA_SUBNET_GROUP="aurora-lab05-subnetgroup"
export AURORA_SECRET_ID="lab05/aurora/admin"
export AURORA_PROXY_ID="aurora-lab05-proxy"

# Redis
export REDIS_CLUSTER_ID="redis-lab05"
export REDIS_SUBNET_GROUP="redis-lab05-subnetgroup"

# DynamoDB
export DYNAMO_TABLE="ecommerce-catalog"
export LAMBDA_FUNCTION="ecommerce-catalog-stream"
export SNS_TOPIC_NAME="ecommerce-pedidos-notif"

# IAM Roles
export LAMBDA_ROLE="lambda-catalog-stream-role"
export PROXY_ROLE="rds-proxy-lab05-role"
export EC2_ROLE="ec2-app-lab05-role"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query 'Account' --output text --region "$AWS_REGION" 2>/dev/null || echo "UNKNOWN")

export RESOURCES_FILE="${BASH_SOURCE[0]%/*}/00-resources-lab05.env"

# ---------------------------------------------------------------------------
log()     { echo "[$(date +%H:%M:%S)] $*"; }
ok()      { echo "[$(date +%H:%M:%S)] ✓ $*"; }
warn()    { echo "[$(date +%H:%M:%S)] ⚠ $*" >&2; }
fail()    { echo "[$(date +%H:%M:%S)] ✗ ERROR: $*" >&2; exit 1; }
section() { echo; echo "════════════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════════════"; }

safe_run() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then ok "$desc"
  else warn "$desc — no encontrado o ya eliminado (continuando...)"; fi
}

save_resource() {
  touch "$RESOURCES_FILE"
  sed -i "/^${1}=/d" "$RESOURCES_FILE" 2>/dev/null || true
  echo "${1}=${2}" >> "$RESOURCES_FILE"
}

load_resources() {
  [[ -f "$RESOURCES_FILE" ]] && source "$RESOURCES_FILE" \
    && log "Recursos cargados desde $RESOURCES_FILE"
}

check_prereqs() {
  section "Verificando prerrequisitos"
  command -v aws  &>/dev/null || fail "AWS CLI no instalado"
  command -v jq   &>/dev/null || fail "jq no instalado"
  command -v zip  &>/dev/null || fail "zip no instalado"
  aws sts get-caller-identity --region "$AWS_REGION" --output text &>/dev/null \
    || fail "Sin credenciales AWS válidas"
  ok "Account: $ACCOUNT_ID | Region: $AWS_REGION"
}

[[ -f "$RESOURCES_FILE" ]] && source "$RESOURCES_FILE"

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  log "Entorno Lab05 3-Tier cargado"
  log "  VPC CIDR: $VPC_CIDR | Aurora: $AURORA_CLUSTER_ID | Redis: $REDIS_CLUSTER_ID"
fi
