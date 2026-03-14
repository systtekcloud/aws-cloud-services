#!/usr/bin/env bash
# =============================================================================
# Lab02 Aurora — Variables de entorno y funciones auxiliares
# =============================================================================
# Uso: source cli/00-env.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables del proyecto
# ---------------------------------------------------------------------------
export AWS_REGION="eu-west-1"
export LAB="lab02"
export PROJECT="db-labs"
export ENV="lab"

# Cluster
export AURORA_CLUSTER_ID="db-lab-aurora-cluster"
export AURORA_WRITER_ID="db-lab-aurora-writer"
export AURORA_READER_ID="db-lab-aurora-reader"
export AURORA_ENGINE="aurora-mysql"
export AURORA_ENGINE_VERSION="8.0.mysql_aurora.3.04.0"
export AURORA_INSTANCE_CLASS="db.t3.medium"
export AURORA_DB_NAME="auroradb"
export AURORA_MASTER_USER="admin"

# Subnet Group
export AURORA_SUBNET_GROUP="aurora-lab-subnetgroup"

# Secreto
export AURORA_SECRET_ID="lab02/aurora/admin"

# Red (reutiliza la del lab01 si está activa)
export VPC_CIDR="10.20.0.0/16"
export SUBNET_PRIVATE_A_CIDR="10.20.10.0/24"
export SUBNET_PRIVATE_B_CIDR="10.20.11.0/24"
export AZ_A="eu-west-1a"
export AZ_B="eu-west-1b"

# Auto-detect account
export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query 'Account' --output text --region "$AWS_REGION" 2>/dev/null || echo "UNKNOWN")

# Archivo de recursos generados en tiempo de ejecución
export RESOURCES_FILE="${BASH_SOURCE[0]%/*}/00-resources-aurora.env"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()     { echo "[$(date +%H:%M:%S)] $*"; }
ok()      { echo "[$(date +%H:%M:%S)] ✓ $*"; }
warn()    { echo "[$(date +%H:%M:%S)] ⚠ $*" >&2; }
fail()    { echo "[$(date +%H:%M:%S)] ✗ ERROR: $*" >&2; exit 1; }
section() { echo; echo "════════════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════════════"; }

# ---------------------------------------------------------------------------
# safe_run — ejecuta un comando, avisa si falla pero no detiene el script
# Uso: safe_run "descripción" aws ec2 ...
# ---------------------------------------------------------------------------
safe_run() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then
    ok "$desc"
  else
    warn "$desc — no encontrado o ya eliminado (continuando...)"
  fi
}

# ---------------------------------------------------------------------------
# Guardar un recurso en el archivo de entorno
# Uso: save_resource CLAVE valor
# ---------------------------------------------------------------------------
save_resource() {
  local key="$1"
  local val="$2"
  touch "$RESOURCES_FILE"
  # Eliminar línea anterior si existe
  sed -i "/^${key}=/d" "$RESOURCES_FILE" 2>/dev/null || true
  echo "${key}=${val}" >> "$RESOURCES_FILE"
  log "  Guardado: ${key}=${val}"
}

# ---------------------------------------------------------------------------
# Cargar recursos guardados
# ---------------------------------------------------------------------------
load_resources() {
  if [[ -f "$RESOURCES_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$RESOURCES_FILE"
    log "Recursos cargados desde $RESOURCES_FILE"
  else
    warn "No se encontró $RESOURCES_FILE — algunos IDs pueden faltar"
  fi
}

# ---------------------------------------------------------------------------
# Verificar prerrequisitos
# ---------------------------------------------------------------------------
check_prereqs() {
  section "Verificando prerrequisitos"

  command -v aws  &>/dev/null || fail "AWS CLI no instalado"
  command -v jq   &>/dev/null || fail "jq no instalado: sudo apt install jq"
  command -v mysql &>/dev/null || warn "mysql client no instalado (opcional para tests)"

  # Comprobar credenciales AWS
  aws sts get-caller-identity --region "$AWS_REGION" --output text &>/dev/null \
    || fail "Sin credenciales AWS válidas. Ejecuta: aws configure"

  ok "AWS CLI: $(aws --version 2>&1 | head -1)"
  ok "Account: $ACCOUNT_ID"
  ok "Region: $AWS_REGION"
}

# ---------------------------------------------------------------------------
# Esperar a que el cluster Aurora esté en un estado dado
# Uso: wait_cluster_status "available" [timeout_seconds]
# ---------------------------------------------------------------------------
wait_cluster_status() {
  local target_status="$1"
  local timeout="${2:-600}"
  local elapsed=0
  local interval=15

  log "Esperando que el cluster '$AURORA_CLUSTER_ID' llegue a estado '$target_status'..."
  while [[ $elapsed -lt $timeout ]]; do
    local current
    current=$(aws rds describe-db-clusters \
      --db-cluster-identifier "$AURORA_CLUSTER_ID" \
      --query 'DBClusters[0].Status' \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "not-found")

    if [[ "$current" == "$target_status" ]]; then
      ok "Cluster en estado: $target_status"
      return 0
    fi
    echo -n "  [$elapsed/${timeout}s] Status: $current ..."
    sleep $interval
    elapsed=$((elapsed + interval))
    echo ""
  done
  fail "Timeout: el cluster no llegó a '$target_status' en ${timeout}s"
}

# ---------------------------------------------------------------------------
# Obtener password del secret de Aurora
# ---------------------------------------------------------------------------
get_aurora_password() {
  aws secretsmanager get-secret-value \
    --secret-id "$AURORA_SECRET_ID" \
    --query 'SecretString' \
    --output text \
    --region "$AWS_REGION" | jq -r '.password'
}

# ---------------------------------------------------------------------------
# Auto-cargar recursos al hacer source de este fichero
# ---------------------------------------------------------------------------
if [[ -f "$RESOURCES_FILE" ]]; then
  source "$RESOURCES_FILE"
fi

# ---------------------------------------------------------------------------
# Mostrar resumen de variables si se hace source directamente
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Fue llamado con source
  log "Entorno Lab02 Aurora cargado"
  log "  Cluster:   $AURORA_CLUSTER_ID"
  log "  Writer:    $AURORA_WRITER_ID"
  log "  Reader:    $AURORA_READER_ID"
  log "  Region:    $AWS_REGION"
  log "  Account:   $ACCOUNT_ID"
fi
