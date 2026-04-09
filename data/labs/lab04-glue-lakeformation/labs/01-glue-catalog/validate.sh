#!/usr/bin/env bash
# validate.sh — Lab 04-01: Glue Catalog + Crawler + Athena
set -euo pipefail

REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
RAW_BUCKET="lab04-glue-raw-${ACCOUNT_ID}"
RESULTS_BUCKET="lab04-glue-results-${ACCOUNT_ID}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${NC}[INFO]  $*${NC}"; }
pass()   { echo -e "${GREEN}[PASS]  $*${NC}"; }
fail()   { echo -e "${RED}[FAIL]  $*${NC}"; exit 1; }
warn()   { echo -e "${YELLOW}[WARN]  $*${NC}"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $*${NC}\n${BLUE}══════════════════════════════════════${NC}"; }

header "Fase 1: S3"
for BUCKET in "$RAW_BUCKET" "$RESULTS_BUCKET"; do
  if aws s3 ls "s3://$BUCKET" &>/dev/null; then
    pass "Bucket '$BUCKET' existe ✓"
  else
    fail "Bucket '$BUCKET' no encontrado"
  fi
done
COUNT=$(aws s3 ls "s3://$RAW_BUCKET/sales/" --recursive 2>/dev/null | wc -l || echo 0)
[[ "$COUNT" -ge 2 ]] && pass "Datos CSV presentes ($COUNT archivos) ✓" || fail "Datos CSV no encontrados en s3://$RAW_BUCKET/sales/"

header "Fase 2: Glue Catalog"
DB_EXISTS=$(aws glue get-database --name lab04_ecommerce --region "$REGION" \
  --query 'Database.Name' --output text 2>/dev/null || echo "")
[[ "$DB_EXISTS" == "lab04_ecommerce" ]] && pass "Base de datos 'lab04_ecommerce' existe ✓" || fail "Base de datos no encontrada"

TABLE_EXISTS=$(aws glue get-tables --database-name lab04_ecommerce --region "$REGION" \
  --query 'TableList[0].Name' --output text 2>/dev/null || echo "")
[[ -n "$TABLE_EXISTS" && "$TABLE_EXISTS" != "None" ]] && pass "Tabla '$TABLE_EXISTS' en Catalog ✓" || fail "No hay tablas en lab04_ecommerce"

PARTITIONS=$(aws glue get-table --database-name lab04_ecommerce --name "$TABLE_EXISTS" \
  --region "$REGION" --query 'Table.PartitionKeys[].Name' --output text 2>/dev/null || echo "")
[[ -n "$PARTITIONS" ]] && pass "Particiones detectadas: $PARTITIONS ✓" || warn "No se detectaron particiones"

header "Fase 3: Crawler"
CRAWLER_STATE=$(aws glue get-crawler --name lab04-sales-crawler --region "$REGION" \
  --query 'Crawler.State' --output text 2>/dev/null || echo "NOT_FOUND")
[[ "$CRAWLER_STATE" == "READY" ]] && pass "Crawler 'lab04-sales-crawler' en estado READY ✓" \
  || warn "Crawler estado: $CRAWLER_STATE"

header "Resumen"
pass "Lab 04-01 validado ✓"
log "Base de datos: lab04_ecommerce | Tabla: $TABLE_EXISTS | Crawler: $CRAWLER_STATE"
