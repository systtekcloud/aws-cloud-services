#!/usr/bin/env bash
# ==============================================================================
# Lab 01 — RDS MySQL: Script de Limpieza Completa
# ==============================================================================
# Elimina TODOS los recursos del lab en el orden correcto (respetando
# dependencias entre recursos AWS).
#
# Orden de eliminación:
#   1. Read Replica
#   2. RDS Primary
#   3. Secrets Manager secret
#   4. DB Subnet Group
#   5. CloudWatch Alarms + Log Groups
#   6. EC2 instance
#   7. VPC Endpoints SSM
#   8. IAM Role + Instance Profile
#   9. NAT Gateway + Elastic IP
#  10. Internet Gateway (detach + delete)
#  11. Route Tables (custom)
#  12. Subnets
#  13. Security Groups
#  14. VPC
#  15. KMS Key (deshabilitar — no se puede eliminar inmediatamente)
#
# Uso:
#   bash cli/99-cleanup.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-env.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${YELLOW}══════════════════════════════════════════${NC}"; \
            echo -e "${YELLOW}  $*${NC}"; \
            echo -e "${YELLOW}══════════════════════════════════════════${NC}\n"; }

safe_run() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then
    ok "$desc"
  else
    warn "$desc — no encontrado o ya eliminado"
  fi
}

# Cargar IDs guardados
if [[ -f "$RESOURCES_FILE" ]]; then
  source "$RESOURCES_FILE"
fi

# ==============================================================================
# CONFIRMACIÓN
# ==============================================================================
section "Script de Limpieza — Lab 01 RDS MySQL"

echo -e "${RED}ATENCIÓN: Esto eliminará PERMANENTEMENTE:${NC}"
echo "  - RDS: $RDS_INSTANCE_ID (primary) + $RDS_REPLICA_ID (replica)"
echo "  - Secret: $SECRET_NAME"
echo "  - EC2: $EC2_INSTANCE_NAME"
echo "  - VPC completa: $VPC_NAME (10.20.0.0/16)"
echo "  - Todos los SGs, subnets, NAT Gateway, IGW"
echo ""

read -r -p "¿Estás seguro? Escribe 'si' para confirmar: " CONFIRM
if [[ "$CONFIRM" != "si" && "$CONFIRM" != "sí" ]]; then
  echo "Operación cancelada."
  exit 0
fi
echo ""

# ==============================================================================
# 1. Read Replica
# ==============================================================================
section "1/15 — Eliminando Read Replica"

REPLICA_EXISTS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_REPLICA_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")

if [[ "$REPLICA_EXISTS" != "NOT_FOUND" ]]; then
  aws rds delete-db-instance \
    --db-instance-identifier "$RDS_REPLICA_ID" \
    --skip-final-snapshot \
    --region "$REGION" > /dev/null
  info "Esperando eliminación de Read Replica (~5 min)..."
  aws rds wait db-instance-deleted \
    --db-instance-identifier "$RDS_REPLICA_ID" \
    --region "$REGION"
  ok "Read Replica eliminada: $RDS_REPLICA_ID"
else
  warn "Read Replica no encontrada: $RDS_REPLICA_ID"
fi

# ==============================================================================
# 2. RDS Primary
# ==============================================================================
section "2/15 — Eliminando RDS Primary"

RDS_EXISTS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_INSTANCE_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")

if [[ "$RDS_EXISTS" != "NOT_FOUND" ]]; then
  aws rds delete-db-instance \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --skip-final-snapshot \
    --delete-automated-backups \
    --region "$REGION" > /dev/null
  info "Esperando eliminación de RDS (~10 min)..."
  aws rds wait db-instance-deleted \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --region "$REGION"
  ok "RDS Primary eliminada: $RDS_INSTANCE_ID"
else
  warn "RDS Primary no encontrada"
fi

# ==============================================================================
# 3. Secrets Manager
# ==============================================================================
section "3/15 — Eliminando Secret"

safe_run "Secret $SECRET_NAME" aws secretsmanager delete-secret \
  --secret-id "$SECRET_NAME" \
  --force-delete-without-recovery \
  --region "$REGION"

# ==============================================================================
# 4. DB Subnet Group
# ==============================================================================
section "4/15 — Eliminando DB Subnet Group"

safe_run "DB Subnet Group $RDS_SUBNET_GROUP" aws rds delete-db-subnet-group \
  --db-subnet-group-name "$RDS_SUBNET_GROUP" \
  --region "$REGION"

# ==============================================================================
# 5. CloudWatch Alarms y Log Groups
# ==============================================================================
section "5/15 — Eliminando CloudWatch Alarms"

for ALARM in "$ALARM_STORAGE_NAME" "$ALARM_CPU_NAME" "$ALARM_REPLICA_LAG_NAME"; do
  safe_run "Alarm $ALARM" aws cloudwatch delete-alarms \
    --alarm-names "$ALARM" --region "$REGION"
done

for LOG_GROUP in "/aws/rds/instance/$RDS_INSTANCE_ID/error" "/aws/rds/instance/$RDS_INSTANCE_ID/slowquery"; do
  safe_run "Log Group $LOG_GROUP" aws logs delete-log-group \
    --log-group-name "$LOG_GROUP" --region "$REGION"
done

# ==============================================================================
# 6. EC2 Instance
# ==============================================================================
section "6/15 — Eliminando EC2"

if [[ -n "${EC2_ID:-}" ]]; then
  aws ec2 terminate-instances --instance-ids "$EC2_ID" --region "$REGION" > /dev/null 2>&1 || true
  aws ec2 wait instance-terminated --instance-ids "$EC2_ID" --region "$REGION" 2>/dev/null || true
  ok "EC2 terminada: $EC2_ID"
fi

# ==============================================================================
# 7. VPC Endpoints SSM
# ==============================================================================
section "7/15 — Eliminando VPC Endpoints"

EP_IDS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID:-none}" "Name=tag:Project,Values=$PROJECT" \
  --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [[ -n "$EP_IDS" ]]; then
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EP_IDS --region "$REGION" > /dev/null
  ok "VPC Endpoints eliminados: $EP_IDS"
fi

# ==============================================================================
# 8. IAM Role + Instance Profile
# ==============================================================================
section "8/15 — Eliminando IAM Role"

safe_run "Detach SSM policy" aws iam detach-role-policy \
  --role-name "$EC2_SSM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
safe_run "Detach SecretsManager policy" aws iam detach-role-policy \
  --role-name "$EC2_SSM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
safe_run "Remove role from profile" aws iam remove-role-from-instance-profile \
  --instance-profile-name "$EC2_SSM_ROLE_NAME" \
  --role-name "$EC2_SSM_ROLE_NAME"
safe_run "Delete instance profile" aws iam delete-instance-profile \
  --instance-profile-name "$EC2_SSM_ROLE_NAME"
safe_run "Delete IAM role" aws iam delete-role \
  --role-name "$EC2_SSM_ROLE_NAME"

# ==============================================================================
# 9. NAT Gateway + Elastic IP
# ==============================================================================
section "9/15 — Eliminando NAT Gateway"

if [[ -n "${NAT_GW_ID:-}" ]]; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID" --region "$REGION" > /dev/null 2>&1 || true
  info "Esperando eliminación del NAT Gateway (~60s)..."
  sleep 60
  ok "NAT Gateway eliminado: $NAT_GW_ID"
fi

if [[ -n "${EIP_ALLOC:-}" ]]; then
  safe_run "Elastic IP liberada" aws ec2 release-address \
    --allocation-id "$EIP_ALLOC" --region "$REGION"
fi

# ==============================================================================
# 10. Internet Gateway
# ==============================================================================
section "10/15 — Eliminando Internet Gateway"

if [[ -n "${IGW_ID:-}" && -n "${VPC_ID:-}" ]]; then
  safe_run "Detach IGW" aws ec2 detach-internet-gateway \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
  safe_run "Delete IGW" aws ec2 delete-internet-gateway \
    --internet-gateway-id "$IGW_ID" --region "$REGION"
fi

# ==============================================================================
# 11. Route Tables (custom)
# ==============================================================================
section "11/15 — Eliminando Route Tables"

for RT_ID in "${RT_PUBLIC:-}" "${RT_PRIVATE:-}"; do
  [[ -z "$RT_ID" ]] && continue
  # Desasociar subnets primero
  ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
    --output text --region "$REGION" 2>/dev/null || echo "")
  for ASSOC_ID in $ASSOC_IDS; do
    safe_run "Disassociate RT $ASSOC_ID" aws ec2 disassociate-route-table \
      --association-id "$ASSOC_ID" --region "$REGION"
  done
  safe_run "Delete RT $RT_ID" aws ec2 delete-route-table \
    --route-table-id "$RT_ID" --region "$REGION"
done

# ==============================================================================
# 12. Subnets
# ==============================================================================
section "12/15 — Eliminando Subnets"

for SUBNET_ID in "${SUBNET_PUBLIC_A:-}" "${SUBNET_PUBLIC_B:-}" "${SUBNET_DB_A:-}" "${SUBNET_DB_B:-}" "${SUBNET_APP_A:-}"; do
  [[ -z "$SUBNET_ID" ]] && continue
  safe_run "Subnet $SUBNET_ID" aws ec2 delete-subnet \
    --subnet-id "$SUBNET_ID" --region "$REGION"
done

# ==============================================================================
# 13. Security Groups
# ==============================================================================
section "13/15 — Eliminando Security Groups"

for SG_ID in "${SG_RDS:-}" "${SG_SSM_EP:-}" "${SG_APP:-}"; do
  [[ -z "$SG_ID" ]] && continue
  safe_run "SG $SG_ID" aws ec2 delete-security-group \
    --group-id "$SG_ID" --region "$REGION"
done

# ==============================================================================
# 14. VPC
# ==============================================================================
section "14/15 — Eliminando VPC"

if [[ -n "${VPC_ID:-}" ]]; then
  safe_run "VPC $VPC_ID" aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
fi

# ==============================================================================
# 15. KMS Key (deshabilitar — no se puede borrar inmediatamente)
# ==============================================================================
section "15/15 — Deshabilitando KMS Key"

if [[ -n "${KMS_KEY_ID:-}" ]]; then
  aws kms schedule-key-deletion \
    --key-id "$KMS_KEY_ID" \
    --pending-window-in-days 7 \
    --region "$REGION" > /dev/null 2>&1 || true
  warn "KMS Key $KMS_KEY_ID programada para eliminación en 7 días (mínimo)"
  warn "Para cancelar: aws kms cancel-key-deletion --key-id $KMS_KEY_ID --region $REGION"
fi

# Limpiar archivo de resources
rm -f "$RESOURCES_FILE"

# ==============================================================================
# RESUMEN
# ==============================================================================
section "Limpieza completada"

ok "Todos los recursos del Lab 01 eliminados:"
echo "  [OK] Read Replica:      $RDS_REPLICA_ID"
echo "  [OK] RDS Primary:       $RDS_INSTANCE_ID"
echo "  [OK] Secrets Manager:   $SECRET_NAME"
echo "  [OK] EC2 App:           $EC2_INSTANCE_NAME"
echo "  [OK] VPC + Red:         $VPC_NAME"
echo "  [OK] IAM roles:         $EC2_SSM_ROLE_NAME"
echo "  [PENDING] KMS Key:      programada para borrado en 7 días"
echo ""
info "Verifica en AWS Console que no quedan recursos:"
echo "  aws rds describe-db-instances --region $REGION"
echo "  aws ec2 describe-vpcs --filters Name=tag:Project,Values=$PROJECT --region $REGION"
