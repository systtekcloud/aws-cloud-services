#!/usr/bin/env bash
# validate.sh — Lab 05-01: EMR Serverless
set -euo pipefail

REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
INPUT_BUCKET="lab05-emr-input-${ACCOUNT_ID}"
OUTPUT_BUCKET="lab05-emr-output-${ACCOUNT_ID}"
LOGS_BUCKET="lab05-emr-logs-${ACCOUNT_ID}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${NC}[INFO]  $*${NC}"; }
pass()   { echo -e "${GREEN}[PASS]  $*${NC}"; }
fail()   { echo -e "${RED}[FAIL]  $*${NC}"; exit 1; }
warn()   { echo -e "${YELLOW}[WARN]  $*${NC}"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $*${NC}\n${BLUE}══════════════════════════════════════${NC}"; }

header "Fase 1: S3 Buckets"
for BUCKET in "$INPUT_BUCKET" "$OUTPUT_BUCKET" "$LOGS_BUCKET"; do
  if aws s3 ls "s3://$BUCKET" &>/dev/null; then
    pass "Bucket '$BUCKET' ✓"
  else
    fail "Bucket '$BUCKET' no encontrado"
  fi
done

# Verificar script y dataset en input
SCRIPT=$(aws s3 ls "s3://$INPUT_BUCKET/scripts/wordcount.py" 2>/dev/null | wc -l)
DATA=$(aws s3 ls "s3://$INPUT_BUCKET/input/text.txt" 2>/dev/null | wc -l)
[[ "$SCRIPT" -ge 1 ]] && pass "Script wordcount.py subido ✓" || fail "Script wordcount.py no encontrado"
[[ "$DATA" -ge 1 ]]   && pass "Dataset de entrada subido ✓"  || fail "Dataset de entrada no encontrado"

header "Fase 2: Aplicación EMR Serverless"
APP_ID=$(aws emr-serverless list-applications \
  --region "$REGION" \
  --query 'applications[?name==`lab05-spark-app`].id' \
  --output text 2>/dev/null || echo "")

if [[ -z "$APP_ID" || "$APP_ID" == "None" ]]; then
  fail "Aplicación EMR 'lab05-spark-app' no encontrada"
fi

APP_STATE=$(aws emr-serverless get-application \
  --application-id "$APP_ID" \
  --region "$REGION" \
  --query 'application.state' \
  --output text 2>/dev/null || echo "UNKNOWN")

[[ "$APP_STATE" == "CREATED" || "$APP_STATE" == "STARTED" || "$APP_STATE" == "STOPPED" ]] \
  && pass "Aplicación '$APP_ID' en estado $APP_STATE ✓" \
  || warn "Aplicación en estado: $APP_STATE"

header "Fase 3: Job Run"
JOB_STATE=$(aws emr-serverless list-job-runs \
  --application-id "$APP_ID" \
  --region "$REGION" \
  --query 'jobRuns[0].state' \
  --output text 2>/dev/null || echo "NOT_FOUND")

JOB_ID=$(aws emr-serverless list-job-runs \
  --application-id "$APP_ID" \
  --region "$REGION" \
  --query 'jobRuns[0].id' \
  --output text 2>/dev/null || echo "")

if [[ "$JOB_STATE" == "SUCCESS" ]]; then
  pass "Job run completado con SUCCESS ✓"
elif [[ "$JOB_STATE" == "RUNNING" || "$JOB_STATE" == "PENDING" || "$JOB_STATE" == "SCHEDULED" ]]; then
  warn "Job en estado: $JOB_STATE — espera a que termine"
else
  warn "Job estado: $JOB_STATE (esperado: SUCCESS)"
fi

header "Fase 4: Output en S3"
OUTPUT_COUNT=$(aws s3 ls "s3://$OUTPUT_BUCKET/wordcount-output/" --recursive 2>/dev/null | wc -l || echo 0)
if [[ "$OUTPUT_COUNT" -ge 2 ]]; then
  pass "Output generado en S3 ($OUTPUT_COUNT archivos) ✓"
  # Mostrar top 5
  aws s3 cp "s3://$OUTPUT_BUCKET/wordcount-output/" /tmp/wc-validate/ \
    --recursive --exclude "_SUCCESS" --quiet 2>/dev/null || true
  if ls /tmp/wc-validate/part-* 2>/dev/null; then
    log "Top 5 palabras:"
    cat /tmp/wc-validate/part-* 2>/dev/null | sort -t',' -k2 -rn | head -5 \
      | awk -F',' '{printf "  %-20s %s\n", $1, $2}'
  fi
else
  warn "Output no encontrado — ejecuta el job primero (Paso 5)"
fi

header "Resumen"
pass "Lab 05-01 validado ✓"
log "App ID: $APP_ID | Job: $JOB_ID ($JOB_STATE)"
log ""
warn "⚠️  Recuerda ejecutar el cleanup para evitar costes adicionales"
