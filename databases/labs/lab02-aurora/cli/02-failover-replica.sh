#!/usr/bin/env bash
# =============================================================================
# Lab02 Aurora — Script 02: Failover + Prioridad + Backtrack
# =============================================================================
# Prerequisito: 01-aurora-cluster.sh completado
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

# ---------------------------------------------------------------------------
section "PARTE A — Estado inicial del cluster"
# ---------------------------------------------------------------------------

log "Instancias y roles actuales:"
aws rds describe-db-clusters \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --query 'DBClusters[0].DBClusterMembers[*].{Instance:DBInstanceIdentifier,IsWriter:IsClusterWriter,PromotionTier:PromotionTier}' \
  --output table --region "$AWS_REGION"

WRITER_INSTANCE=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier' \
  --output text --region "$AWS_REGION")

log "Writer actual: $WRITER_INSTANCE"

# ---------------------------------------------------------------------------
section "PARTE B — Configurar Failover Priority"
# ---------------------------------------------------------------------------

# El reader debe tener tier-0 para ser promovido primero
log "Configurando promotion tier-0 para el Reader..."
aws rds modify-db-instance \
  --db-instance-identifier "$AURORA_READER_ID" \
  --promotion-tier 0 \
  --apply-immediately \
  --region "$AWS_REGION"

# El writer tiene tier-1 (o default)
aws rds modify-db-instance \
  --db-instance-identifier "$AURORA_WRITER_ID" \
  --promotion-tier 1 \
  --apply-immediately \
  --region "$AWS_REGION"

ok "Promotion tiers configurados: Reader=0 (alta prio), Writer=1"

# Esperar que las modificaciones se apliquen
log "Esperando que los cambios se apliquen (~30 seg)..."
sleep 30

# ---------------------------------------------------------------------------
section "PARTE C — Simular Failover (Reboot with Failover)"
# ---------------------------------------------------------------------------

echo ""
echo "  ════════════════════════════════════════════════════"
echo "  ⚠️  ATENCIÓN: Esto causará ~20-30 seg de interrupción"
echo "  El Writer actual ($WRITER_INSTANCE) será rebooteado"
echo "  y el Reader pasará a ser el nuevo Writer."
echo "  ════════════════════════════════════════════════════"
echo ""
read -rp "  ¿Continuar con el failover? (yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && { log "Failover cancelado."; exit 0; }

# Iniciar el failover
log "Iniciando failover (Reboot with Failover)..."
FAILOVER_START=$(date +%s)

aws rds reboot-db-instance \
  --db-instance-identifier "$WRITER_INSTANCE" \
  --force-failover \
  --region "$AWS_REGION"

ok "Failover iniciado"

# Monitorizar el cambio de Writer en tiempo real
log "Monitorizando cambio de Writer cada 5 segundos..."
echo ""
MAX_WAIT=120
elapsed=0
INITIAL_WRITER="$WRITER_INSTANCE"
NEW_WRITER=""

while [[ $elapsed -lt $MAX_WAIT ]]; do
  CURRENT_WRITER=$(aws rds describe-db-clusters \
    --db-cluster-identifier "$AURORA_CLUSTER_ID" \
    --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "unknown")

  echo "  $(date +%H:%M:%S) Writer: $CURRENT_WRITER"

  if [[ -n "$CURRENT_WRITER" && "$CURRENT_WRITER" != "$INITIAL_WRITER" && "$CURRENT_WRITER" != "unknown" ]]; then
    NEW_WRITER="$CURRENT_WRITER"
    FAILOVER_END=$(date +%s)
    FAILOVER_DURATION=$((FAILOVER_END - FAILOVER_START))
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

echo ""
if [[ -n "$NEW_WRITER" ]]; then
  ok "Failover completado en ${FAILOVER_DURATION} segundos"
  ok "Nuevo Writer: $NEW_WRITER (antes era: $INITIAL_WRITER)"
else
  warn "Timeout esperando el failover. Verifica manualmente en la consola."
fi

# ---------------------------------------------------------------------------
section "PARTE D — Verificar que el endpoint NO cambió"
# ---------------------------------------------------------------------------

CLUSTER_ENDPOINT="${CLUSTER_ENDPOINT:-$(aws rds describe-db-clusters \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --query 'DBClusters[0].Endpoint' --output text --region "$AWS_REGION")}"

log "Cluster endpoint después del failover: $CLUSTER_ENDPOINT"
log "(Este endpoint siempre apunta al Writer actual — no cambia)"

echo ""
echo "  CONCEPTO SAA-C03:"
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │ El Cluster Endpoint es un CNAME que se actualiza automáticamente │"
echo "  │ en <30 seg tras el failover. Tu app no necesita cambiar nada.    │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""

# ---------------------------------------------------------------------------
section "PARTE E — Backtrack demo"
# ---------------------------------------------------------------------------

AURORA_PW=$(get_aurora_password)

log "Preparando demo de Backtrack..."
log "Paso E1: Crear y popular una tabla de prueba..."

mysql -h "$CLUSTER_ENDPOINT" -u "$AURORA_MASTER_USER" -p"$AURORA_PW" \
  "$AURORA_DB_NAME" << 'EOSQL'
CREATE TABLE IF NOT EXISTS backtrack_demo (
  id INT AUTO_INCREMENT PRIMARY KEY,
  dato VARCHAR(100),
  ts DATETIME DEFAULT NOW()
);
DELETE FROM backtrack_demo;
INSERT INTO backtrack_demo (dato) VALUES
  ('registro original 1'),
  ('registro original 2'),
  ('registro original 3');
SELECT 'Estado ANTES del error:', COUNT(*) as total FROM backtrack_demo;
EOSQL

log "Guardando timestamp para Backtrack..."
BACKTRACK_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "  Timestamp para backtrack: $BACKTRACK_TIMESTAMP"
sleep 5  # Asegurar que el timestamp sea unívoco

log "Paso E2: Simular DROP TABLE accidental..."
mysql -h "$CLUSTER_ENDPOINT" -u "$AURORA_MASTER_USER" -p"$AURORA_PW" \
  "$AURORA_DB_NAME" -e "DROP TABLE backtrack_demo;"

log "Verificando que la tabla ya no existe..."
mysql -h "$CLUSTER_ENDPOINT" -u "$AURORA_MASTER_USER" -p"$AURORA_PW" \
  "$AURORA_DB_NAME" -e "SHOW TABLES LIKE 'backtrack_demo';"

echo ""
echo "  Tabla 'backtrack_demo' eliminada. Iniciando Backtrack..."
echo ""

log "Paso E3: Ejecutar Backtrack al timestamp anterior al DROP..."
aws rds backtrack-db-cluster \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --backtrack-to "$BACKTRACK_TIMESTAMP" \
  --region "$AWS_REGION"

ok "Backtrack solicitado al timestamp: $BACKTRACK_TIMESTAMP"
log "Esperando que el cluster vuelva a estado available..."

wait_cluster_status "available" 300

log "Paso E4: Verificar que la tabla fue restaurada..."
mysql -h "$CLUSTER_ENDPOINT" -u "$AURORA_MASTER_USER" -p"$AURORA_PW" \
  "$AURORA_DB_NAME" -e "SELECT * FROM backtrack_demo;"

ok "Backtrack completado — los datos fueron restaurados sin restaurar un backup"

# ---------------------------------------------------------------------------
section "RESUMEN"
# ---------------------------------------------------------------------------

echo ""
echo "  Resultados del lab:"
echo "    Failover duración: ${FAILOVER_DURATION:-N/A} segundos"
echo "    Writer original:   $INITIAL_WRITER"
echo "    Nuevo Writer:      ${NEW_WRITER:-no detectado}"
echo "    Cluster endpoint:  $CLUSTER_ENDPOINT (no cambió)"
echo "    Backtrack timestamp: $BACKTRACK_TIMESTAMP"
echo ""
echo "  Conceptos SAA-C03 demostrados:"
echo "    ✓ Failover automático Aurora <30 segundos"
echo "    ✓ Cluster endpoint DNS dinámico"
echo "    ✓ Failover priority (promotion tiers)"
echo "    ✓ Backtrack: revert sin restaurar backup (Aurora MySQL only)"
echo ""
ok "Script 02 completado"
