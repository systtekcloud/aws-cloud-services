#!/usr/bin/env bash
# =============================================================================
# Lab04 ElastiCache — Script 99: Cleanup completo
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

echo ""
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║   LAB04 ELASTICACHE — CLEANUP COMPLETO        ║"
echo "  ║                                                ║"
echo "  ║  Se eliminarán:                                ║"
echo "  ║    • Replication Group: $REDIS_CLUSTER_ID"
echo "  ║    • Cache Subnet Group: $REDIS_SUBNET_GROUP"
echo "  ║    • SG: sg-redis-db-labs                      ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo ""
read -rp "  Escribe 'CLEANUP LAB04' para confirmar: " CONFIRM
[[ "$CONFIRM" != "CLEANUP LAB04" ]] && { log "Cancelado."; exit 0; }

# 1. Replication Group
section "PASO 1/3 — Eliminar Replication Group"
CLUSTER_STATUS=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --query 'ReplicationGroups[0].Status' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "not-found")

if [[ "$CLUSTER_STATUS" != "not-found" && "$CLUSTER_STATUS" != "deleting" ]]; then
  log "Eliminando Replication Group ($CLUSTER_STATUS)..."
  aws elasticache delete-replication-group \
    --replication-group-id "$REDIS_CLUSTER_ID" \
    --no-retain-primary-cluster \
    --region "$AWS_REGION"

  log "Esperando eliminación (~3-5 min)..."
  aws elasticache wait replication-group-deleted \
    --replication-group-id "$REDIS_CLUSTER_ID" \
    --region "$AWS_REGION" 2>/dev/null && ok "Replication Group eliminado" || \
    warn "Timeout — verifica en la consola"
else
  log "Replication Group: $CLUSTER_STATUS"
fi

# 2. Cache Subnet Group
section "PASO 2/3 — Eliminar Cache Subnet Group"
safe_run "Eliminar subnet group" \
  aws elasticache delete-cache-subnet-group \
    --cache-subnet-group-name "$REDIS_SUBNET_GROUP" \
    --region "$AWS_REGION"

# 3. Security Group
section "PASO 3/3 — Eliminar Security Group"
SG_ID="${SG_REDIS:-$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=sg-redis-db-labs" \
  --query 'SecurityGroups[0].GroupId' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")}"

if [[ "$SG_ID" != "None" && -n "$SG_ID" ]]; then
  safe_run "Eliminar SG Redis" \
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION"
else
  log "SG Redis: no encontrado"
fi

echo ""
ok "Cleanup Lab04 ElastiCache completado"
echo "  Limpia también: rm -f ${RESOURCES_FILE}"
