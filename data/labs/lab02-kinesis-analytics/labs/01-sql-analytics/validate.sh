#!/usr/bin/env bash
# validate.sh — Lab 02-01: KDA SQL Analytics
#
# Verifica que la aplicación KDA existe, está RUNNING,
# y que hay datos agregados en S3.
#
# Uso: ./validate.sh
# Prerrequisitos: aws cli v2, jq, aplicación KDA iniciada

set -euo pipefail

APP="lab02-sensor-analytics"
STREAM="lab02-sensor-data"
FIREHOSE="lab02-kda-output"
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
BUCKET="lab02-kda-analytics-${ACCOUNT_ID}"

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

# ─── Fase 1: Recursos de soporte ─────────────────────────────────────────────
header "Fase 1: Recursos de soporte"

KDS_STATUS=$(aws kinesis describe-stream-summary \
  --stream-name "$STREAM" \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.StreamStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$KDS_STATUS" == "ACTIVE" ]]; then
  pass "KDS '$STREAM' está ACTIVE ✓"
else
  fail "KDS '$STREAM' no encontrado (estado: $KDS_STATUS)"
fi

FIREHOSE_STATUS=$(aws firehose describe-delivery-stream \
  --delivery-stream-name "$FIREHOSE" \
  --region "$REGION" \
  --query 'DeliveryStreamDescription.DeliveryStreamStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$FIREHOSE_STATUS" == "ACTIVE" ]]; then
  pass "Firehose '$FIREHOSE' está ACTIVE ✓"
else
  fail "Firehose '$FIREHOSE' no encontrado (estado: $FIREHOSE_STATUS)"
fi

# ─── Fase 2: Aplicación KDA ───────────────────────────────────────────────────
header "Fase 2: Aplicación KDA"

APP_STATUS=$(aws kinesisanalytics describe-application \
  --application-name "$APP" \
  --region "$REGION" \
  --query 'ApplicationDetail.ApplicationStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$APP_STATUS" == "RUNNING" ]]; then
  pass "Aplicación KDA '$APP' está RUNNING ✓"
elif [[ "$APP_STATUS" == "READY" ]]; then
  warn "Aplicación KDA '$APP' está READY pero no iniciada — ejecuta el Paso 5"
else
  fail "Aplicación KDA '$APP' no encontrada (estado: $APP_STATUS)"
fi

# ─── Fase 3: Datos en S3 ─────────────────────────────────────────────────────
header "Fase 3: Datos agregados en S3"

S3_COUNT=$(aws s3 ls "s3://$BUCKET/aggregations/" --recursive 2>/dev/null | wc -l || echo "0")

if [[ "$S3_COUNT" -ge "1" ]]; then
  pass "Hay $S3_COUNT objeto(s) en s3://$BUCKET/aggregations/ ✓"

  # Leer el último archivo y mostrar las agregaciones
  KEY=$(aws s3 ls "s3://$BUCKET/aggregations/" --recursive | sort | tail -1 | awk '{print $4}')
  aws s3 cp "s3://$BUCKET/$KEY" /tmp/kda-validate-output.gz 2>/dev/null
  ROWS=$(zcat /tmp/kda-validate-output.gz 2>/dev/null | wc -l || echo "0")
  log "Filas en el último archivo: $ROWS"

  if [[ "$ROWS" -ge "1" ]]; then
    pass "Datos de agregaciones presentes ✓"
    log "Muestra:"
    zcat /tmp/kda-validate-output.gz 2>/dev/null | head -3 \
      | jq '{sensor: .sensor_id, avg_temp: .avg_temp, count: .record_count}' 2>/dev/null || true
  fi
else
  warn "No hay datos en S3 aún — espera 2-3 minutos y vuelve a ejecutar"
  log "  El buffer de Firehose es 60 segundos + tiempo de procesamiento KDA"
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
header "Resumen"
log "Aplicación: $APP ($APP_STATUS)"
log "Stream KDS: $STREAM"
log "Firehose:   $FIREHOSE"
log "Bucket S3:  $BUCKET"
log ""
if [[ "$APP_STATUS" == "RUNNING" && "$S3_COUNT" -ge "1" ]]; then
  pass "Lab 02-01 validado correctamente ✓"
else
  warn "Lab parcialmente validado — revisa los puntos marcados arriba"
fi
log ""
log "Ver cleanup.md para eliminar todos los recursos."
