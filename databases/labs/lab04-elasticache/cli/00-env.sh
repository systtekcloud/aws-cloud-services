#!/usr/bin/env bash
# =============================================================================
# Lab04 ElastiCache Redis — Variables de entorno y funciones auxiliares
# =============================================================================

set -euo pipefail

export AWS_REGION="eu-west-1"
export LAB="lab04"
export PROJECT="db-labs"
export ENV="lab"

# Redis cluster
export REDIS_CLUSTER_ID="redis-lab-cluster"
export REDIS_ENGINE="redis"
export REDIS_ENGINE_VERSION="7.1"
export REDIS_NODE_TYPE="cache.t3.micro"
export REDIS_NUM_CLUSTERS=2  # primary + 1 replica
export REDIS_PORT=6379

# Subnet Group
export REDIS_SUBNET_GROUP="redis-lab-subnetgroup"

# Red (compartida con lab01)
export VPC_CIDR="10.20.0.0/16"
export SUBNET_PRIVATE_A_CIDR="10.20.10.0/24"
export SUBNET_PRIVATE_B_CIDR="10.20.11.0/24"
export AZ_A="eu-west-1a"
export AZ_B="eu-west-1b"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query 'Account' --output text --region "$AWS_REGION" 2>/dev/null || echo "UNKNOWN")

export RESOURCES_FILE="${BASH_SOURCE[0]%/*}/00-resources-redis.env"

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
  [[ -f "$RESOURCES_FILE" ]] && source "$RESOURCES_FILE" && log "Recursos cargados desde $RESOURCES_FILE"
}

check_prereqs() {
  section "Verificando prerrequisitos"
  command -v aws &>/dev/null || fail "AWS CLI no instalado"
  command -v jq  &>/dev/null || fail "jq no instalado"
  aws sts get-caller-identity --region "$AWS_REGION" --output text &>/dev/null \
    || fail "Sin credenciales AWS válidas"
  ok "AWS CLI OK | Account: $ACCOUNT_ID | Region: $AWS_REGION"
}

[[ -f "$RESOURCES_FILE" ]] && source "$RESOURCES_FILE"

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  log "Entorno Lab04 ElastiCache cargado"
  log "  Cluster: $REDIS_CLUSTER_ID | Region: $AWS_REGION"
fi
