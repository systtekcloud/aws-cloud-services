#!/usr/bin/env bash
# ==============================================================================
# Lab 01 — RDS MySQL: Paso 3 — Multi-AZ y Read Replica
# ==============================================================================
# Parte A: Habilitar Multi-AZ en la instancia existente
# Parte B: Crear Read Replica
# Parte C: Verificar ReplicaLag alarm
#
# Uso:
#   source cli/00-env.sh && bash cli/03-multi-az-replica.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-env.sh"
check_prereqs

if [[ ! -f "$RESOURCES_FILE" ]]; then
  fail "Ejecuta primero los pasos 01 y 02 antes de este script."
fi
source "$RESOURCES_FILE"

# ==============================================================================
# PARTE A: Multi-AZ
# ==============================================================================
section "Parte A — Habilitar Multi-AZ"

log "CONCEPTO: Multi-AZ crea un standby SÍNCRONO en otra AZ."
log "          El standby NO acepta tráfico — solo es para failover automático."
log "          Esto NO mejora el rendimiento de lectura."
echo ""

aws rds modify-db-instance \
  --db-instance-identifier "$RDS_INSTANCE_ID" \
  --multi-az \
  --apply-immediately \
  --region "$REGION" > /dev/null

log "Multi-AZ solicitado. Esperando a que la instancia esté disponible..."
log "(La conversión puede tardar 10-20 minutos)"

# Loop de verificación manual (wait no detecta transición a Multi-AZ)
MAX_WAIT=1200  # 20 minutos
ELAPSED=0
INTERVAL=30
while true; do
  STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text --region "$REGION")
  MULTI_AZ=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --query 'DBInstances[0].MultiAZ' --output text --region "$REGION")

  log "Status: $STATUS | Multi-AZ: $MULTI_AZ (${ELAPSED}s transcurridos)"

  if [[ "$STATUS" == "available" && "$MULTI_AZ" == "True" ]]; then
    break
  fi

  ELAPSED=$((ELAPSED + INTERVAL))
  if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    fail "Timeout esperando Multi-AZ. Verifica en la consola: $RDS_INSTANCE_ID"
  fi
  sleep $INTERVAL
done

SECONDARY_AZ=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_INSTANCE_ID" \
  --query 'DBInstances[0].SecondaryAvailabilityZone' --output text --region "$REGION")

ok "Multi-AZ habilitado:"
echo "  Primary AZ:   $AZ_A"
echo "  Secondary AZ: $SECONDARY_AZ (standby, invisible para la app)"
echo ""
warn "NOTA EXAMEN: El mismo endpoint sigue funcionando. El standby es invisible."
warn "             NO hay un segundo endpoint para el standby."

# ==============================================================================
# PARTE B: Read Replica
# ==============================================================================
section "Parte B — Crear Read Replica"

log "CONCEPTO: Read Replica es replicación ASÍNCRONA."
log "          SÍ tiene su propio endpoint y acepta lecturas."
log "          NO es failover automático — la promoción es manual."
echo ""

aws rds create-db-instance-read-replica \
  --db-instance-identifier "$RDS_REPLICA_ID" \
  --source-db-instance-identifier "$RDS_INSTANCE_ID" \
  --db-instance-class "$RDS_INSTANCE_CLASS" \
  --availability-zone "$AZ_B" \
  --no-publicly-accessible \
  --vpc-security-group-ids "$SG_RDS" \
  --auto-minor-version-upgrade \
  --tags Key=Project,Value="$PROJECT" Key=Lab,Value="$LAB" Key=Env,Value="$ENV" \
  --region "$REGION" > /dev/null

log "Read Replica solicitada ($RDS_REPLICA_ID). Esperando disponibilidad..."

aws rds wait db-instance-available \
  --db-instance-identifier "$RDS_REPLICA_ID" \
  --region "$REGION"

REPLICA_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_REPLICA_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text --region "$REGION")

echo "REPLICA_ENDPOINT=$REPLICA_ENDPOINT" >> "$RESOURCES_FILE"
ok "Read Replica disponible: $REPLICA_ENDPOINT"

# ==============================================================================
# PARTE C: ReplicaLag Alarm
# ==============================================================================
section "Parte C — Alarm ReplicaLag"

aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_REPLICA_LAG_NAME" \
  --alarm-description "RDS lab01: ReplicaLag > 30s en read replica" \
  --metric-name ReplicaLag \
  --namespace AWS/RDS \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 30 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=DBInstanceIdentifier,Value="$RDS_REPLICA_ID" \
  --alarm-actions "${SNS_ARN:-}" \
  --region "$REGION"
ok "Alarm: $ALARM_REPLICA_LAG_NAME (ReplicaLag > 30s)"

# ==============================================================================
# RESUMEN + INSTRUCCIONES DE VALIDACIÓN
# ==============================================================================
section "Multi-AZ + Read Replica listos"

echo ""
ok "Estado final del lab01:"
echo ""
echo "  MULTI-AZ:"
echo "    Primary endpoint: $RDS_ENDPOINT"
echo "    Standby AZ:       $SECONDARY_AZ (transparente, mismo endpoint)"
echo "    Failover:         automático (~1-2 min)"
echo ""
echo "  READ REPLICA:"
echo "    Replica endpoint: $REPLICA_ENDPOINT"
echo "    Endpoint:         DIFERENTE al primary"
echo "    Uso:              solo lecturas (INSERT/UPDATE falla)"
echo ""

log "Para verificar desde EC2 vía SSM Session Manager:"
echo ""
echo "  # Conectar a la RÉPLICA:"
echo "  mysql -h $REPLICA_ENDPOINT -u $RDS_MASTER_USER -p\$DB_PASS labdb"
echo "  SELECT @@hostname;    # hostname distinto al primary"
echo "  SELECT @@read_only;   # debe devolver 1"
echo "  INSERT INTO t VALUES (1);  # debe fallar (read-only)"
echo ""
log "Cleanup cuando termines: bash cli/99-cleanup.sh"
