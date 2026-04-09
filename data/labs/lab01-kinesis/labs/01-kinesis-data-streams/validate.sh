#!/usr/bin/env bash
# validate.sh — Lab 01: Kinesis Data Streams
#
# Verifica que el stream lab01-kds existe, está ACTIVE,
# puede recibir records y los records son legibles.
#
# Uso: ./validate.sh
# Prerrequisitos: aws cli v2, jq, credenciales activas

set -euo pipefail

STREAM="lab01-kds"
REGION="eu-west-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${NC}[INFO]  $*${NC}"; }
pass()   { echo -e "${GREEN}[PASS]  $*${NC}"; }
fail()   { echo -e "${RED}[FAIL]  $*${NC}"; exit 1; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ─── Fase 1: Stream existe y está ACTIVE ─────────────────────────────────────
header "Fase 1: Verificar stream"

STATUS=$(aws kinesis describe-stream-summary \
  --stream-name "$STREAM" \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.StreamStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$STATUS" == "ACTIVE" ]]; then
  pass "Stream '$STREAM' existe y está ACTIVE"
else
  fail "Stream '$STREAM' no encontrado o no ACTIVE (estado: $STATUS). Ejecuta el Paso 1 del lab."
fi

SHARDS=$(aws kinesis describe-stream-summary \
  --stream-name "$STREAM" \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.OpenShardCount' \
  --output text)

if [[ "$SHARDS" == "2" ]]; then
  pass "Stream tiene 2 shards ✓"
else
  fail "Stream tiene $SHARDS shards — se esperaban 2"
fi

RETENTION=$(aws kinesis describe-stream-summary \
  --stream-name "$STREAM" \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.RetentionPeriodHours' \
  --output text)

log "Retención actual: ${RETENTION}h"
if [[ "$RETENTION" -le "24" ]]; then
  pass "Retención en valor mínimo (${RETENTION}h) — sin coste extra ✓"
else
  echo -e "${YELLOW}[WARN]  Retención = ${RETENTION}h (>24h genera coste adicional)${NC}"
fi

# ─── Fase 2: Capacidad de escribir y leer ────────────────────────────────────
header "Fase 2: Escribir y leer record de prueba"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TEST_DATA=$(echo -n "{\"device\":\"validate-test\",\"ts\":\"$TIMESTAMP\"}" | base64)

RESULT=$(aws kinesis put-record \
  --stream-name "$STREAM" \
  --partition-key "validate-test" \
  --data "$TEST_DATA" \
  --region "$REGION" \
  --output json)

SHARD_ID=$(echo "$RESULT" | jq -r '.ShardId')
SEQ=$(echo "$RESULT" | jq -r '.SequenceNumber')

if [[ -n "$SHARD_ID" && -n "$SEQ" ]]; then
  pass "Record escrito en $SHARD_ID (seq: ${SEQ:0:20}…) ✓"
else
  fail "No se pudo escribir el record de prueba"
fi

# Leer el record recién escrito
ITERATOR=$(aws kinesis get-shard-iterator \
  --stream-name "$STREAM" \
  --shard-id "$SHARD_ID" \
  --shard-iterator-type AT_SEQUENCE_NUMBER \
  --starting-sequence-number "$SEQ" \
  --region "$REGION" \
  --query 'ShardIterator' \
  --output text)

RECORDS=$(aws kinesis get-records \
  --shard-iterator "$ITERATOR" \
  --limit 1 \
  --region "$REGION")

COUNT=$(echo "$RECORDS" | jq '.Records | length')
if [[ "$COUNT" -ge "1" ]]; then
  DATA=$(echo "$RECORDS" | jq -r '.Records[0].Data | @base64d')
  pass "Record leído correctamente: $DATA ✓"
else
  fail "No se pudo leer el record de prueba"
fi

# ─── Fase 3: Distribución de PartitionKeys ───────────────────────────────────
header "Fase 3: PartitionKey y distribución entre shards"

log "Enviando 4 records con 2 partition keys distintas..."
for pk in "sensor-001" "sensor-002" "sensor-001" "sensor-002"; do
  aws kinesis put-record \
    --stream-name "$STREAM" \
    --partition-key "$pk" \
    --data "$(echo -n "{\"device\":\"$pk\"}" | base64)" \
    --region "$REGION" \
    --output json > /dev/null
done

log "Contando records por shard..."
ALL_SHARDS=$(aws kinesis list-shards \
  --stream-name "$STREAM" \
  --region "$REGION" \
  --query 'Shards[].ShardId' \
  --output text)

TOTAL=0
for SHARD in $ALL_SHARDS; do
  ITER=$(aws kinesis get-shard-iterator \
    --stream-name "$STREAM" \
    --shard-id "$SHARD" \
    --shard-iterator-type TRIM_HORIZON \
    --region "$REGION" \
    --query 'ShardIterator' \
    --output text)
  COUNT=$(aws kinesis get-records \
    --shard-iterator "$ITER" \
    --limit 100 \
    --region "$REGION" \
    | jq '.Records | length')
  log "  $SHARD: $COUNT records"
  TOTAL=$((TOTAL + COUNT))
done

if [[ "$TOTAL" -ge "5" ]]; then
  pass "Records distribuidos entre shards. Total leído: $TOTAL ✓"
else
  fail "Se esperaban al menos 5 records, se leyeron $TOTAL"
fi

# ─── Resumen ─────────────────────────────────────────────────────────────────
header "Resumen"
log "Stream:    $STREAM"
log "Shards:    $SHARDS"
log "Retención: ${RETENTION}h"
log ""
pass "Lab 01 validado correctamente ✓"
log ""
log "Limpieza: aws kinesis delete-stream --stream-name $STREAM --region $REGION"
