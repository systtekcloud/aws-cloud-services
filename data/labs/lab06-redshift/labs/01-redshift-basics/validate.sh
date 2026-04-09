#!/usr/bin/env bash
# validate.sh — Lab 06-01: Redshift Serverless
set -euo pipefail

REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
BUCKET="lab06-redshift-${ACCOUNT_ID}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${NC}[INFO]  $*${NC}"; }
pass()   { echo -e "${GREEN}[PASS]  $*${NC}"; }
fail()   { echo -e "${RED}[FAIL]  $*${NC}"; exit 1; }
warn()   { echo -e "${YELLOW}[WARN]  $*${NC}"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $*${NC}\n${BLUE}══════════════════════════════════════${NC}"; }

header "Fase 1: S3 y datos"
if aws s3 ls "s3://$BUCKET" &>/dev/null; then
  pass "Bucket '$BUCKET' existe ✓"
else
  fail "Bucket '$BUCKET' no encontrado — ejecuta el Paso 1"
fi

DATA=$(aws s3 ls "s3://$BUCKET/data/orders.csv" 2>/dev/null | wc -l || echo 0)
[[ "$DATA" -ge 1 ]] && pass "orders.csv subido ✓" || fail "orders.csv no encontrado en S3"

header "Fase 2: Redshift Serverless Namespace"
NS_STATE=$(aws redshift-serverless get-namespace \
  --namespace-name lab06-namespace \
  --region "$REGION" \
  --query 'namespace.status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$NS_STATE" == "AVAILABLE" ]]; then
  pass "Namespace 'lab06-namespace' AVAILABLE ✓"
else
  fail "Namespace no encontrado (estado: $NS_STATE) — ejecuta el Paso 3"
fi

header "Fase 3: Redshift Serverless Workgroup"
WG_STATE=$(aws redshift-serverless get-workgroup \
  --workgroup-name lab06-workgroup \
  --region "$REGION" \
  --query 'workgroup.status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

ENDPOINT=$(aws redshift-serverless get-workgroup \
  --workgroup-name lab06-workgroup \
  --region "$REGION" \
  --query 'workgroup.endpoint.address' \
  --output text 2>/dev/null || echo "")

if [[ "$WG_STATE" == "AVAILABLE" ]]; then
  pass "Workgroup 'lab06-workgroup' AVAILABLE ✓"
  log "  Endpoint: $ENDPOINT:5439"
else
  fail "Workgroup no encontrado (estado: $WG_STATE) — ejecuta el Paso 3"
fi

header "Fase 4: IAM Role"
ROLE_ARN=$(aws iam get-role --role-name lab06-redshift-role \
  --query 'Role.Arn' --output text 2>/dev/null || echo "")
[[ -n "$ROLE_ARN" ]] && pass "IAM role 'lab06-redshift-role' existe ✓" \
  || fail "IAM role no encontrado — ejecuta el Paso 2"

header "Resumen"
pass "Infraestructura de Lab 06-01 validada ✓"
log "Namespace: lab06-namespace ($NS_STATE)"
log "Workgroup: lab06-workgroup ($WG_STATE)"
log "Endpoint:  $ENDPOINT:5439"
log ""
warn "⚠️  Conecta al Query Editor v2 en la consola para ejecutar COPY y las queries SQL (Pasos 4–6)"
warn "⚠️  Recuerda eliminar el workgroup al terminar — ver cleanup.md"
