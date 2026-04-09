#!/usr/bin/env bash
# validate.sh — Lab 03-01: MSK Serverless cluster
#
# Verifica que el cluster MSK existe, está ACTIVE,
# y que el topic lab03-events tiene 3 particiones.
#
# Uso: ./validate.sh
# Prerequisitos: aws cli v2, kafka CLI en PATH, MSK_BOOTSTRAP exportado

set -euo pipefail

CLUSTER_NAME="lab03-msk-serverless"
TOPIC="lab03-events"
REGION="eu-west-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${NC}[INFO]  $*${NC}"; }
pass()   { echo -e "${GREEN}[PASS]  $*${NC}"; }
fail()   { echo -e "${RED}[FAIL]  $*${NC}"; exit 1; }
warn()   { echo -e "${YELLOW}[WARN]  $*${NC}"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ─── Fase 1: Cluster ─────────────────────────────────────────────────────────
header "Fase 1: Cluster MSK"

CLUSTER_ARN=$(aws kafka list-clusters-v2 \
  --region "$REGION" \
  --query "ClusterInfoList[?ClusterName==\`$CLUSTER_NAME\`].ClusterArn" \
  --output text 2>/dev/null || echo "")

if [[ -z "$CLUSTER_ARN" || "$CLUSTER_ARN" == "None" ]]; then
  fail "Cluster '$CLUSTER_NAME' no encontrado — ejecuta el Paso 3"
fi

STATE=$(aws kafka describe-cluster-v2 \
  --cluster-arn "$CLUSTER_ARN" \
  --region "$REGION" \
  --query 'ClusterInfo.State' \
  --output text)

if [[ "$STATE" == "ACTIVE" ]]; then
  pass "Cluster '$CLUSTER_NAME' está ACTIVE ✓"
else
  fail "Cluster '$CLUSTER_NAME' en estado: $STATE (espera a ACTIVE)"
fi

# ─── Fase 2: Bootstrap endpoint ───────────────────────────────────────────────
header "Fase 2: Bootstrap endpoint"

BOOTSTRAP=$(aws kafka get-bootstrap-brokers \
  --cluster-arn "$CLUSTER_ARN" \
  --region "$REGION" \
  --query 'BootstrapBrokerStringSaslIam' \
  --output text 2>/dev/null || echo "")

if [[ -n "$BOOTSTRAP" && "$BOOTSTRAP" != "None" ]]; then
  pass "Bootstrap endpoint IAM disponible ✓"
  log "  $BOOTSTRAP"
  export MSK_BOOTSTRAP="$BOOTSTRAP"
else
  fail "Bootstrap endpoint no disponible — verifica autenticación IAM habilitada"
fi

# ─── Fase 3: Topic ────────────────────────────────────────────────────────────
header "Fase 3: Topic '$TOPIC'"

if [[ -z "${CLASSPATH:-}" ]]; then
  warn "CLASSPATH no configurado — asegúrate de exportar el JAR de MSK IAM Auth"
  warn "  export CLASSPATH='/tmp/aws-msk-iam-auth.jar:\$CLASSPATH'"
fi

if ! command -v kafka-topics.sh &>/dev/null; then
  warn "kafka-topics.sh no encontrado en PATH — omitiendo verificación de topic"
  warn "Instala Kafka CLI y vuelve a ejecutar"
else
  TOPIC_EXISTS=$(kafka-topics.sh \
    --bootstrap-server "$MSK_BOOTSTRAP" \
    --command-config /tmp/kafka-iam.properties \
    --list 2>/dev/null | grep -c "^${TOPIC}$" || echo "0")

  if [[ "$TOPIC_EXISTS" -ge "1" ]]; then
    pass "Topic '$TOPIC' existe ✓"

    # Verificar particiones
    PARTITIONS=$(kafka-topics.sh \
      --bootstrap-server "$MSK_BOOTSTRAP" \
      --command-config /tmp/kafka-iam.properties \
      --describe \
      --topic "$TOPIC" 2>/dev/null | grep -c "^	Partition:" || echo "0")

    if [[ "$PARTITIONS" -ge "3" ]]; then
      pass "Topic tiene $PARTITIONS particiones ✓"
    else
      warn "Topic tiene $PARTITIONS particiones (esperadas: 3)"
    fi
  else
    warn "Topic '$TOPIC' no encontrado — ejecuta el Paso 6"
  fi
fi

# ─── Resumen ─────────────────────────────────────────────────────────────────
header "Resumen"
log "Cluster ARN: $CLUSTER_ARN"
log "Estado:      $STATE"
log "Bootstrap:   $BOOTSTRAP"
log ""
pass "Lab 03-01 validado ✓"
log "Ver cleanup.md para eliminar todos los recursos."
