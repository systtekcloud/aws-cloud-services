#!/usr/bin/env bash
# =============================================================================
# Lab04 ElastiCache — Script 02: Demo cache-aside + session store
# =============================================================================
# Este script ejecuta los demos en la EC2 via SSM Session Manager.
# Prerrequisito: 01-redis-cluster.sh completado.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

[[ -z "${PRIMARY_ENDPOINT:-}" ]] && \
  fail "PRIMARY_ENDPOINT no encontrado. Ejecuta primero 01-redis-cluster.sh"

# ---------------------------------------------------------------------------
section "VERIFICACIÓN: Conectividad Redis"
# ---------------------------------------------------------------------------

log "Verificando acceso al cluster Redis..."
log "Nota: ejecutar redis-cli desde la EC2 (no desde aquí)"
log ""
log "Obtén el Instance ID de la EC2:"
EC2_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$EC2_ID" != "None" && -n "$EC2_ID" ]]; then
  ok "EC2 encontrada: $EC2_ID"
  log ""
  log "Conectar via SSM:"
  log "  aws ssm start-session --target $EC2_ID --region $AWS_REGION"
else
  warn "EC2 no encontrada en el proyecto. Usa la EC2 del lab01 si está activa."
fi

# ---------------------------------------------------------------------------
section "GENERAR SCRIPT DE DEMO PARA LA EC2"
# ---------------------------------------------------------------------------

DEMO_SCRIPT="/tmp/redis-demo.sh"

cat > "$DEMO_SCRIPT" << EODEMOSCRIPT
#!/usr/bin/env bash
# Script a ejecutar en la EC2 via SSM

PRIMARY="${PRIMARY_ENDPOINT}"
READER="${READER_ENDPOINT}"
PORT="${REDIS_PORT}"

echo "=== Instalando redis-tools ==="
which redis-cli &>/dev/null || sudo apt-get install -y redis-tools 2>/dev/null || sudo yum install -y redis 2>/dev/null

echo "=== Test de conectividad ==="
redis-cli -h \$PRIMARY -p \$PORT --tls PING && echo "  ✓ Primary OK" || echo "  ✗ Primary FAIL"
redis-cli -h \$READER  -p \$PORT --tls PING && echo "  ✓ Reader OK"  || echo "  ✗ Reader FAIL"

echo ""
echo "=== Info del cluster ==="
redis-cli -h \$PRIMARY -p \$PORT --tls INFO replication | grep -E "role:|connected_slaves:|master_host:"

echo ""
echo "=== Cache-Aside demo ==="
# Simular MISS + guardado + HIT
redis-cli -h \$PRIMARY -p \$PORT --tls DEL "customer:1001"

echo "  1. Primer acceso (MISS — simula consulta a DB):"
time redis-cli -h \$PRIMARY -p \$PORT --tls GET "customer:1001"
# Simulamos el tiempo de DB
echo '{"nombre":"Ana García","ciudad":"Madrid","pedidos":5}' | \
  xargs -I{} redis-cli -h \$PRIMARY -p \$PORT --tls SETEX "customer:1001" 300 "{}"
echo "  → Guardado en caché (TTL 300s)"

echo ""
echo "  2. Segundo acceso (HIT — desde Redis):"
time redis-cli -h \$PRIMARY -p \$PORT --tls GET "customer:1001"

echo ""
echo "=== Session Store demo ==="
SESSION_ID=\$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "test-session-\$RANDOM")
redis-cli -h \$PRIMARY -p \$PORT --tls SETEX "session:\$SESSION_ID" 3600 \
  '{"user_id":"1001","nombre":"Ana","carrito":{"libro":1}}'
echo "  Sesión creada: \$SESSION_ID"
echo "  TTL: \$(redis-cli -h \$PRIMARY -p \$PORT --tls TTL "session:\$SESSION_ID")s"
echo "  Datos: \$(redis-cli -h \$PRIMARY -p \$PORT --tls GET "session:\$SESSION_ID")"

echo ""
echo "=== Sorted Set (Leaderboard) demo ==="
redis-cli -h \$PRIMARY -p \$PORT --tls DEL leaderboard
redis-cli -h \$PRIMARY -p \$PORT --tls ZADD leaderboard 1500 "ana" 2300 "carlos" 1800 "maria" 3100 "pedro"
echo "  Top 3:"
redis-cli -h \$PRIMARY -p \$PORT --tls ZREVRANGE leaderboard 0 2 WITHSCORES

echo ""
echo "=== Stats Redis ==="
redis-cli -h \$PRIMARY -p \$PORT --tls INFO stats | grep -E "keyspace_hits:|keyspace_misses:"
redis-cli -h \$PRIMARY -p \$PORT --tls INFO keyspace
EODEMOSCRIPT

chmod +x "$DEMO_SCRIPT"
ok "Script de demo generado: $DEMO_SCRIPT"

# ---------------------------------------------------------------------------
section "INSTRUCCIONES PARA EJECUTAR EN LA EC2"
# ---------------------------------------------------------------------------

echo ""
echo "  Para ejecutar el demo completo:"
echo ""
echo "  1. Copia el script a la EC2:"
echo "     aws ssm start-session --target $EC2_ID --region $AWS_REGION"
echo ""
echo "  2. En la EC2, ejecuta:"
echo "     sudo apt-get install -y redis-tools"
echo "     PRIMARY=$PRIMARY_ENDPOINT"
echo "     READER=$READER_ENDPOINT"
echo "     PORT=$REDIS_PORT"
echo ""
echo "  3. Test básico:"
echo "     redis-cli -h \$PRIMARY -p \$PORT --tls PING"
echo ""
echo "  O sube el script generado:"
cat "$DEMO_SCRIPT"
echo ""
ok "Script 02 completado — revisa las instrucciones de arriba"
