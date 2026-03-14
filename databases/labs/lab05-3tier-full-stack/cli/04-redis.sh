#!/usr/bin/env bash
# =============================================================================
# Lab05 — Script 04: ElastiCache Redis (DB tier)
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

[[ -z "${SUBNET_DB_A:-}" ]] && fail "SUBNET_DB_A no encontrado. Ejecuta primero 02-aurora-proxy.sh"
[[ -z "${SG_REDIS:-}" ]]    && fail "SG_REDIS no encontrado. Ejecuta primero 01-vpc-extendida.sh"

section "PASO 1 — Cache Subnet Group (DB tier)"
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name "$REDIS_SUBNET_GROUP" \
  --cache-subnet-group-description "Redis DB tier subnets - lab05" \
  --subnet-ids "$SUBNET_DB_A" "$SUBNET_DB_B" \
  --tags Key=Project,Value=$PROJECT Key=Lab,Value=$LAB \
  --region "$AWS_REGION" 2>/dev/null && ok "Cache Subnet Group creado" || ok "Cache Subnet Group ya existe"

section "PASO 2 — Replication Group Redis"
RG_EXISTS=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --query 'ReplicationGroups[0].Status' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$RG_EXISTS" == "None" ]]; then
  aws elasticache create-replication-group \
    --replication-group-id "$REDIS_CLUSTER_ID" \
    --replication-group-description "Redis lab05 — session store + cache" \
    --num-cache-clusters 2 \
    --cache-node-type "$REDIS_NODE_TYPE" \
    --cache-engine redis \
    --engine-version "$REDIS_ENGINE_VERSION" \
    --cache-subnet-group-name "$REDIS_SUBNET_GROUP" \
    --security-group-ids "$SG_REDIS" \
    --automatic-failover-enabled \
    --multi-az-enabled \
    --at-rest-encryption-enabled \
    --transit-encryption-enabled \
    --snapshot-retention-limit 0 \
    --preferred-cache-cluster-a-zs "$AZ_A" "$AZ_B" \
    --tags Key=Project,Value=$PROJECT Key=Lab,Value=$LAB \
    --region "$AWS_REGION"

  log "Esperando Redis disponible (~5-8 min)..."
  aws elasticache wait replication-group-available \
    --replication-group-id "$REDIS_CLUSTER_ID" --region "$AWS_REGION"
  ok "Redis Replication Group disponible"
else
  ok "Redis ya existe con estado: $RG_EXISTS"
fi

section "PASO 3 — Obtener endpoints"
PRIMARY_ENDPOINT=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' \
  --output text --region "$AWS_REGION")

READER_ENDPOINT=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --query 'ReplicationGroups[0].NodeGroups[0].ReaderEndpoint.Address' \
  --output text --region "$AWS_REGION")

save_resource "REDIS_PRIMARY" "$PRIMARY_ENDPOINT"
save_resource "REDIS_READER"  "$READER_ENDPOINT"
ok "Primary endpoint: $PRIMARY_ENDPOINT"
ok "Reader endpoint:  $READER_ENDPOINT"

section "PASO 4 — Test de conectividad (desde EC2)"
EC2_ID="${EC2_ID:-}"
if [[ -n "$EC2_ID" ]]; then
  log "Probando conectividad a Redis desde EC2 $EC2_ID..."
  aws ssm send-command \
    --instance-ids "$EC2_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
      \"redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls PING\",
      \"redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls SET test-key lab05-ok EX 60\",
      \"redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls GET test-key\",
      \"redis-cli -h $READER_ENDPOINT  -p 6379 --tls GET test-key\"
    ]" \
    --region "$AWS_REGION" \
    --query 'Command.CommandId' --output text 2>/dev/null && \
    ok "Comando SSM enviado. Revisa AWS Systems Manager → Run Command" || \
    warn "No se pudo enviar comando SSM. Verifica EC2_ID y permisos."
else
  warn "EC2_ID no definido. Omitiendo test de conectividad automático."
  echo "  Para probar manualmente desde la EC2:"
  echo "  redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls PING"
fi

section "PASO 5 — Demo: Operaciones Redis básicas"
log "Comandos de referencia para validar Redis en lab05:"
cat <<EOF

  # Desde la EC2 con redis-cli --tls:

  # Ping
  redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls PING

  # Session store (string con TTL)
  redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls \\
    SET "session:user-demo" '{"user_id":"u001","name":"Ana"}' EX 3600

  # Cache de producto
  redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls \\
    SET "product:prod-001" '{"nombre":"Auriculares","precio":299.99}' EX 300

  # Leaderboard con sorted sets
  redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls ZADD leaderboard 1500 "user-001"
  redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls ZADD leaderboard 2300 "user-002"
  redis-cli -h $PRIMARY_ENDPOINT -p 6379 --tls ZREVRANGE leaderboard 0 9 WITHSCORES

  # Leer desde Reader (solo lecturas)
  redis-cli -h $READER_ENDPOINT -p 6379 --tls GET "product:prod-001"

EOF

echo ""
echo "  Redis Primary:  $PRIMARY_ENDPOINT"
echo "  Redis Reader:   $READER_ENDPOINT"
echo "  Subnet Group:   $REDIS_SUBNET_GROUP"
echo "  Node Type:      $REDIS_NODE_TYPE"
echo "  Engine:         Redis $REDIS_ENGINE_VERSION"
echo "  Multi-AZ:       enabled (${AZ_A} / ${AZ_B})"
echo "  TLS:            enabled"
echo ""
ok "Script 04 completado — Redis listo"
