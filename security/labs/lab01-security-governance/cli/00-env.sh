#!/usr/bin/env bash
# =============================================================================
# 00-env.sh — Variables de entorno y funciones comunes
# Lab: Security & Governance (lab01)
#
# USO: source ./cli/00-env.sh
#      o incluir en cada script: source "$(dirname "$0")/00-env.sh"
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# REGIÓN Y CUENTAS — Ajusta estos valores con tus IDs reales
# -----------------------------------------------------------------------------
export AWS_DEFAULT_REGION="eu-west-1"
export AWS_REGION="eu-west-1"

# Management Account (la cuenta desde la que ejecutas)
export MGMT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")

# Cuentas miembro (rellenar tras crearlas en Fase 1)
export LOGS_ACCOUNT_ID="${LOGS_ACCOUNT_ID:-222222222222}"   # Log Archive Account
export DEV_ACCOUNT_ID="${DEV_ACCOUNT_ID:-333333333333}"     # Dev Account (opcional)

# Email base — ajustar a tu email real
export LAB_EMAIL_BASE="${LAB_EMAIL_BASE:-tuemail@gmail.com}"

# -----------------------------------------------------------------------------
# OUs de Organizations (rellenar tras Fase 1)
# -----------------------------------------------------------------------------
export ROOT_ID="${ROOT_ID:-}"
export OU_SECURITY="${OU_SECURITY:-}"
export OU_SHARED="${OU_SHARED:-}"
export OU_WORKLOADS="${OU_WORKLOADS:-}"
export OU_DEV="${OU_DEV:-}"

# -----------------------------------------------------------------------------
# IAM Identity Center (rellenar tras Fase 2)
# -----------------------------------------------------------------------------
export IDC_INSTANCE_ARN="${IDC_INSTANCE_ARN:-}"
export IDC_IDENTITY_STORE_ID="${IDC_IDENTITY_STORE_ID:-}"

# Permission Set ARNs
export ADMIN_PS="${ADMIN_PS:-}"
export DEV_PS="${DEV_PS:-}"
export RO_PS="${RO_PS:-}"
export OPS_PS="${OPS_PS:-}"

# User IDs en Identity Store
export LAB_ADMIN_USER_ID="${LAB_ADMIN_USER_ID:-}"
export LAB_DEV_USER_ID="${LAB_DEV_USER_ID:-}"

# -----------------------------------------------------------------------------
# SCPs (rellenar tras Fase 3)
# -----------------------------------------------------------------------------
export SCP_TRAIL_ID="${SCP_TRAIL_ID:-}"
export SCP_REGIONS_ID="${SCP_REGIONS_ID:-}"
export SCP_S3_ID="${SCP_S3_ID:-}"

# -----------------------------------------------------------------------------
# Recursos de logging (rellenar tras Fase 4)
# -----------------------------------------------------------------------------
export KMS_LOG_KEY_ARN="${KMS_LOG_KEY_ARN:-}"
export BUCKET_NAME="org-cloudtrail-logs-${LOGS_ACCOUNT_ID}"
export TRAIL_NAME="lab-org-trail"
export LOG_GROUP_NAME="/aws/cloudtrail/lab-org-trail"
export SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-}"

# -----------------------------------------------------------------------------
# Recursos de aplicación (rellenar tras Fase 6)
# -----------------------------------------------------------------------------
export KMS_APP_KEY_ARN="${KMS_APP_KEY_ARN:-}"
export SECRET_ARN="${SECRET_ARN:-}"
export INSTANCE_ID="${INSTANCE_ID:-}"
export SG_ID="${SG_ID:-}"

# -----------------------------------------------------------------------------
# Tags comunes para todos los recursos del lab
# -----------------------------------------------------------------------------
export LAB_TAG_KEY="Project"
export LAB_TAG_VALUE="security-lab01"
export LAB_TAGS="Key=${LAB_TAG_KEY},Value=${LAB_TAG_VALUE}"

# -----------------------------------------------------------------------------
# Colores para output
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Funciones de utilidad
# -----------------------------------------------------------------------------

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_ok() {
  echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Esperar a que un recurso exista (polling genérico)
# Uso: wait_for "descripción" "comando" "valor_esperado" [intentos] [espera_seg]
wait_for() {
  local desc="$1"
  local cmd="$2"
  local expected="$3"
  local max_attempts="${4:-20}"
  local wait_sec="${5:-15}"

  log_info "Esperando: $desc"
  for i in $(seq 1 $max_attempts); do
    result=$(eval "$cmd" 2>/dev/null || echo "")
    if [[ "$result" == "$expected" ]]; then
      log_ok "$desc — listo"
      return 0
    fi
    echo "  Intento $i/$max_attempts — estado: ${result:-n/a} (esperando ${wait_sec}s)"
    sleep $wait_sec
  done
  log_error "Timeout esperando: $desc"
  return 1
}

# Asumir rol cross-account
# Uso: assume_role ACCOUNT_ID SESSION_NAME
# Exporta las credenciales temporales en el entorno actual
assume_role() {
  local account_id="$1"
  local session_name="${2:-lab-session}"
  local role_name="${3:-OrganizationAccountAccessRole}"

  log_info "Asumiendo rol en cuenta $account_id (session: $session_name)"
  local creds
  creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${account_id}:role/${role_name}" \
    --role-session-name "$session_name" \
    --query 'Credentials' \
    --output json)

  export AWS_ACCESS_KEY_ID=$(echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKeyId'])")
  export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['SecretAccessKey'])")
  export AWS_SESSION_TOKEN=$(echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['SessionToken'])")

  log_ok "Credenciales asumidas para cuenta $account_id"
  aws sts get-caller-identity --query '[Account,Arn]' --output text
}

# Volver a la cuenta Management (desactiva credenciales temporales)
restore_mgmt_account() {
  unset AWS_ACCESS_KEY_ID
  unset AWS_SECRET_ACCESS_KEY
  unset AWS_SESSION_TOKEN
  log_ok "Credenciales restauradas a Management Account"
  aws sts get-caller-identity --query '[Account,Arn]' --output text
}

# Verificar que estamos en la Management Account
assert_management_account() {
  local current
  current=$(aws sts get-caller-identity --query Account --output text)
  if [[ "$current" != "$MGMT_ACCOUNT_ID" ]]; then
    log_error "Este script debe ejecutarse desde la Management Account ($MGMT_ACCOUNT_ID)"
    log_error "Cuenta actual: $current"
    exit 1
  fi
}

# Guardar IDs importantes en un archivo de estado
# Uso: save_state KEY VALUE
STATE_FILE="$(dirname "${BASH_SOURCE[0]}")/.lab-state.env"
save_state() {
  local key="$1"
  local value="$2"
  # Crear o actualizar el archivo de estado
  if grep -q "^export ${key}=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s|^export ${key}=.*|export ${key}=\"${value}\"|" "$STATE_FILE"
  else
    echo "export ${key}=\"${value}\"" >> "$STATE_FILE"
  fi
  log_info "Estado guardado: $key=$value"
}

# Cargar estado previo si existe
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    log_info "Estado cargado desde $STATE_FILE"
  fi
}

# Confirmar acción destructiva
confirm_action() {
  local msg="${1:-¿Continuar?}"
  echo -e "${YELLOW}⚠️  $msg${NC}"
  read -r -p "Escribe 'yes' para confirmar: " answer
  if [[ "$answer" != "yes" ]]; then
    log_warn "Cancelado por el usuario"
    exit 0
  fi
}

# -----------------------------------------------------------------------------
# Auto-cargar estado si existe
# -----------------------------------------------------------------------------
load_state 2>/dev/null || true

# Mostrar configuración actual
echo ""
echo "=== Lab Security & Governance — Configuración ==="
echo "  Management Account : ${MGMT_ACCOUNT_ID}"
echo "  Log Archive Account: ${LOGS_ACCOUNT_ID}"
echo "  Dev Account        : ${DEV_ACCOUNT_ID}"
echo "  Región             : ${AWS_DEFAULT_REGION}"
echo "  State file         : ${STATE_FILE}"
echo "=================================================="
echo ""
