#!/usr/bin/env bash
# ==============================================================================
# Lab 01 — RDS MySQL: Variables de entorno comunes
# ==============================================================================
# USO: source cli/00-env.sh  (ejecutar antes de cualquier otro script)
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuración del lab
# ------------------------------------------------------------------------------
export REGION="eu-west-1"
export AZ_A="eu-west-1a"
export AZ_B="eu-west-1b"
export PROJECT="db-labs"
export LAB="lab01"
export ENV="lab"

# ------------------------------------------------------------------------------
# Naming convention: db-lab-rds-*
# ------------------------------------------------------------------------------
export PREFIX="db-lab-rds"

# VPC
export VPC_NAME="vpc-db-labs"
export VPC_CIDR="10.20.0.0/16"

# Subnets
export SUBNET_PUBLIC_A_CIDR="10.20.1.0/24"
export SUBNET_PUBLIC_B_CIDR="10.20.2.0/24"
export SUBNET_DB_A_CIDR="10.20.11.0/24"
export SUBNET_DB_B_CIDR="10.20.12.0/24"
export SUBNET_APP_A_CIDR="10.20.21.0/24"

export SUBNET_PUBLIC_A_NAME="public-a"
export SUBNET_PUBLIC_B_NAME="public-b"
export SUBNET_DB_A_NAME="private-db-a"
export SUBNET_DB_B_NAME="private-db-b"
export SUBNET_APP_A_NAME="private-app-a"

# Security Groups
export SG_APP_NAME="sg-app-db-labs"
export SG_RDS_NAME="sg-rds-db-labs"
export SG_SSM_EP_NAME="sg-ssm-ep-db-labs"

# NAT/IGW
export IGW_NAME="igw-db-labs"
export NAT_NAME="nat-db-labs"
export RT_PUBLIC_NAME="rt-public-db-labs"
export RT_PRIVATE_NAME="rt-private-db-labs"

# IAM
export EC2_SSM_ROLE_NAME="role-ec2-ssm-db-labs"
export EC2_INSTANCE_NAME="db-lab-rds-app"

# RDS
export RDS_INSTANCE_ID="db-lab-rds-instance"
export RDS_REPLICA_ID="db-lab-rds-replica"
export RDS_SUBNET_GROUP="db-lab-rds-subnetgroup"
export RDS_ENGINE="mysql"
export RDS_ENGINE_VERSION="8.0"
export RDS_INSTANCE_CLASS="db.t3.micro"
export RDS_STORAGE_GB="20"
export RDS_DB_NAME="labdb"
export RDS_MASTER_USER="admin"

# KMS
export KMS_ALIAS="alias/db-lab-rds-key"

# Secrets Manager
export SECRET_NAME="db-lab-rds-credentials"

# CloudWatch
export ALARM_STORAGE_NAME="db-lab-rds-storage-low"
export ALARM_CPU_NAME="db-lab-rds-cpu-high"
export ALARM_REPLICA_LAG_NAME="db-lab-rds-replica-lag"
export SNS_TOPIC_NAME="db-labs-rds-alerts"

# Archivo donde se guardan los IDs generados en runtime
export RESOURCES_FILE="$(dirname "${BASH_SOURCE[0]}")/00-resources.env"

# ------------------------------------------------------------------------------
# Auto-detectar Account ID
# ------------------------------------------------------------------------------
if command -v aws &>/dev/null; then
  export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
fi

# ------------------------------------------------------------------------------
# Funciones de logging
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${YELLOW}══════════════════════════════════════════${NC}"; \
            echo -e "${YELLOW}  $*${NC}"; \
            echo -e "${YELLOW}══════════════════════════════════════════${NC}\n"; }

# Ejecutar comando con manejo de error graceful (no falla el script)
safe_run() {
  local description="$1"; shift
  if "$@" 2>/dev/null; then
    ok "$description"
  else
    warn "$description — recurso no encontrado o ya eliminado, continuando..."
  fi
}

# ------------------------------------------------------------------------------
# Verificación de prerequisitos
# ------------------------------------------------------------------------------
check_prereqs() {
  local ERRORS=0

  if ! command -v aws &>/dev/null; then
    warn "AWS CLI no encontrado. Instalar: pip install awscli"; ERRORS=$((ERRORS+1))
  fi

  if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
    warn "Credenciales AWS no configuradas. Ejecutar: aws configure"; ERRORS=$((ERRORS+1))
  fi

  if ! command -v jq &>/dev/null; then
    warn "jq no encontrado (opcional pero recomendado). Instalar: sudo apt-get install jq"
  fi

  if [[ $ERRORS -gt 0 ]]; then
    fail "Prerequisitos faltantes. Corrígelos antes de continuar."
  fi

  ok "Prerequisitos verificados"
  log "Account: $ACCOUNT_ID | Region: $REGION | Project: $PROJECT"
}

# Cargar IDs generados en ejecuciones anteriores si el archivo existe
if [[ -f "$RESOURCES_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$RESOURCES_FILE"
fi

log "Variables de entorno cargadas para lab01-rds-basico"
log "Cuenta: ${ACCOUNT_ID:-desconocida} | Región: $REGION"
