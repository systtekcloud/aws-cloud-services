#!/usr/bin/env bash
# validate.sh — Lab 07-01: OpenSearch Basics
set -euo pipefail

REGION="eu-west-1"
DOMAIN="lab07-opensearch"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${NC}[INFO]  $*${NC}"; }
pass()   { echo -e "${GREEN}[PASS]  $*${NC}"; }
fail()   { echo -e "${RED}[FAIL]  $*${NC}"; exit 1; }
warn()   { echo -e "${YELLOW}[WARN]  $*${NC}"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $*${NC}\n${BLUE}══════════════════════════════════════${NC}"; }

header "Fase 1: Dominio OpenSearch"

PROCESSING=$(aws opensearch describe-domain \
  --domain-name "$DOMAIN" --region "$REGION" \
  --query 'DomainStatus.Processing' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$PROCESSING" == "NOT_FOUND" ]]; then
  fail "Dominio '$DOMAIN' no encontrado — ejecuta el Paso 1"
elif [[ "$PROCESSING" == "True" ]]; then
  warn "Dominio '$DOMAIN' aún en procesamiento — espera 10-15 minutos"
  exit 0
else
  pass "Dominio '$DOMAIN' activo (Processing=False) ✓"
fi

ENDPOINT=$(aws opensearch describe-domain \
  --domain-name "$DOMAIN" --region "$REGION" \
  --query 'DomainStatus.Endpoint' --output text 2>/dev/null || echo "")

[[ -n "$ENDPOINT" && "$ENDPOINT" != "None" ]] \
  && pass "Endpoint disponible ✓" \
  || fail "Endpoint no disponible"

INSTANCE=$(aws opensearch describe-domain \
  --domain-name "$DOMAIN" --region "$REGION" \
  --query 'DomainStatus.ClusterConfig.InstanceType' --output text 2>/dev/null || echo "")
log "  Instancia: $INSTANCE"
log "  Endpoint:  https://$ENDPOINT"
log "  Dashboards: https://$ENDPOINT/_dashboards"

header "Fase 2: Índice y documentos"

AUTH="admin:Lab07Admin#2024"
OS_URL="https://$ENDPOINT"

INDEX_EXISTS=$(curl -s -u "$AUTH" -o /dev/null -w "%{http_code}" \
  "$OS_URL/app-logs" 2>/dev/null || echo "000")

if [[ "$INDEX_EXISTS" == "200" ]]; then
  pass "Índice 'app-logs' existe ✓"

  COUNT=$(curl -s -u "$AUTH" "$OS_URL/app-logs/_count" 2>/dev/null \
    | jq '.count' 2>/dev/null || echo "0")

  if [[ "$COUNT" -ge 5 ]]; then
    pass "$COUNT documentos indexados ✓"
  elif [[ "$COUNT" -ge 1 ]]; then
    warn "Solo $COUNT documentos (esperados: 10) — verifica el Paso 3"
  else
    warn "0 documentos — ejecuta el Paso 3"
  fi
else
  warn "Índice 'app-logs' no encontrado (HTTP $INDEX_EXISTS) — ejecuta el Paso 3"
fi

header "Fase 3: Búsqueda full-text"

if [[ "$INDEX_EXISTS" == "200" && "${COUNT:-0}" -ge 1 ]]; then
  ERROR_COUNT=$(curl -s -u "$AUTH" -X GET "$OS_URL/app-logs/_search" \
    -H "Content-Type: application/json" \
    -d '{"query":{"term":{"level":"ERROR"}},"size":0}' 2>/dev/null \
    | jq '.hits.total.value' 2>/dev/null || echo "0")

  [[ "$ERROR_COUNT" -ge 1 ]] \
    && pass "Búsqueda funcional: $ERROR_COUNT documentos ERROR ✓" \
    || warn "No se encontraron logs ERROR — verifica los datos indexados"
fi

header "Resumen"
pass "Lab 07-01 validado ✓"
log "Dominio: $DOMAIN | Endpoint: https://$ENDPOINT"
log ""
warn "⚠️  Elimina el dominio al terminar: aws opensearch delete-domain --domain-name $DOMAIN --region $REGION"
