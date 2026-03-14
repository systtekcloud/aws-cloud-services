#!/usr/bin/env bash
# =============================================================================
# Lab02 Aurora — Script 99: Cleanup completo
# =============================================================================
# Elimina en el orden correcto: Reader → Writer → Cluster → SubnetGroup → SG → Secret
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         LAB02 AURORA — CLEANUP COMPLETO              ║"
echo "  ║                                                       ║"
echo "  ║  Se eliminarán:                                       ║"
echo "  ║    • Aurora Reader: $AURORA_READER_ID"
echo "  ║    • Aurora Writer: $AURORA_WRITER_ID"
echo "  ║    • Aurora Cluster: $AURORA_CLUSTER_ID"
echo "  ║    • DB Subnet Group: $AURORA_SUBNET_GROUP"
echo "  ║    • SG: sg-aurora-db-labs"
echo "  ║    • Secret: $AURORA_SECRET_ID"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "  ⚠️  Esta acción NO se puede deshacer."
echo "  Escribe 'CLEANUP LAB02' para confirmar:"
read -r CONFIRM
if [[ "$CONFIRM" != "CLEANUP LAB02" ]]; then
  log "Cleanup cancelado."
  exit 0
fi

echo ""

# ---------------------------------------------------------------------------
section "PASO 1/6 — Deshabilitar deletion protection del cluster"
# ---------------------------------------------------------------------------

safe_run "Deshabilitar deletion protection" \
  aws rds modify-db-cluster \
    --db-cluster-identifier "$AURORA_CLUSTER_ID" \
    --no-deletion-protection \
    --apply-immediately \
    --region "$AWS_REGION"

sleep 5

# ---------------------------------------------------------------------------
section "PASO 2/6 — Eliminar Reader Instance"
# ---------------------------------------------------------------------------

READER_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$AURORA_READER_ID" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "not-found")

if [[ "$READER_STATUS" != "not-found" && "$READER_STATUS" != "deleting" ]]; then
  log "Eliminando Reader ($READER_STATUS)..."
  safe_run "Eliminar Reader" \
    aws rds delete-db-instance \
      --db-instance-identifier "$AURORA_READER_ID" \
      --skip-final-snapshot \
      --region "$AWS_REGION"
else
  log "Reader ya eliminado o en deleting: $READER_STATUS"
fi

# ---------------------------------------------------------------------------
section "PASO 3/6 — Eliminar Writer Instance"
# ---------------------------------------------------------------------------

WRITER_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$AURORA_WRITER_ID" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "not-found")

if [[ "$WRITER_STATUS" != "not-found" && "$WRITER_STATUS" != "deleting" ]]; then
  log "Eliminando Writer ($WRITER_STATUS)..."
  safe_run "Eliminar Writer" \
    aws rds delete-db-instance \
      --db-instance-identifier "$AURORA_WRITER_ID" \
      --skip-final-snapshot \
      --region "$AWS_REGION"
else
  log "Writer ya eliminado o en deleting: $WRITER_STATUS"
fi

# Esperar a que ambas instancias terminen
log "Esperando que todas las instancias terminen (puede tardar 5-10 min)..."
for INSTANCE_ID in "$AURORA_WRITER_ID" "$AURORA_READER_ID"; do
  elapsed=0
  while aws rds describe-db-instances \
    --db-instance-identifier "$INSTANCE_ID" \
    --region "$AWS_REGION" &>/dev/null; do
    echo -n "  [${elapsed}s] Esperando $INSTANCE_ID..."
    sleep 15
    elapsed=$((elapsed + 15))
    echo ""
    [[ $elapsed -gt 600 ]] && { warn "Timeout para $INSTANCE_ID — continúa manualmente"; break; }
  done
done
ok "Todas las instancias eliminadas"

# ---------------------------------------------------------------------------
section "PASO 4/6 — Eliminar DB Cluster"
# ---------------------------------------------------------------------------

safe_run "Eliminar Aurora Cluster" \
  aws rds delete-db-cluster \
    --db-cluster-identifier "$AURORA_CLUSTER_ID" \
    --skip-final-snapshot \
    --region "$AWS_REGION"

# Esperar a que el cluster desaparezca
log "Esperando que el cluster termine..."
elapsed=0
while aws rds describe-db-clusters \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --region "$AWS_REGION" &>/dev/null; do
  echo -n "  [${elapsed}s] ..."
  sleep 15
  elapsed=$((elapsed + 15))
  echo ""
  [[ $elapsed -gt 300 ]] && { warn "Timeout para cluster — continúa manualmente"; break; }
done
ok "Cluster eliminado"

# ---------------------------------------------------------------------------
section "PASO 5/6 — Eliminar DB Subnet Group"
# ---------------------------------------------------------------------------

safe_run "Eliminar DB Subnet Group" \
  aws rds delete-db-subnet-group \
    --db-subnet-group-name "$AURORA_SUBNET_GROUP" \
    --region "$AWS_REGION"

# ---------------------------------------------------------------------------
section "PASO 6/6 — Eliminar SG y Secret"
# ---------------------------------------------------------------------------

# SG Aurora
if [[ -n "${SG_AURORA:-}" ]]; then
  safe_run "Eliminar SG Aurora" \
    aws ec2 delete-security-group \
      --group-id "$SG_AURORA" \
      --region "$AWS_REGION"
else
  # Buscar por nombre
  SG_AURORA_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=sg-aurora-db-labs" \
    --query 'SecurityGroups[0].GroupId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

  if [[ "$SG_AURORA_ID" != "None" ]]; then
    safe_run "Eliminar SG Aurora (by name)" \
      aws ec2 delete-security-group \
        --group-id "$SG_AURORA_ID" \
        --region "$AWS_REGION"
  else
    warn "SG Aurora no encontrado"
  fi
fi

# Secret
safe_run "Eliminar Secret" \
  aws secretsmanager delete-secret \
    --secret-id "$AURORA_SECRET_ID" \
    --force-delete-without-recovery \
    --region "$AWS_REGION"

# ---------------------------------------------------------------------------
section "VERIFICACIÓN FINAL"
# ---------------------------------------------------------------------------

echo ""
log "Verificando que no quedan recursos..."

CLUSTER_CHECK=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --region "$AWS_REGION" 2>&1 | grep -c "DBClusterNotFoundFault\|not found" || echo "0")
[[ "$CLUSTER_CHECK" -gt "0" ]] && ok "Cluster: eliminado" || warn "Cluster: puede que aún exista"

echo ""
echo "  Elimina también el archivo de recursos:"
echo "    rm -f ${RESOURCES_FILE}"
echo ""
ok "Cleanup Lab02 Aurora completado"
