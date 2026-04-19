#!/usr/bin/env bash
# validate.sh — Lab 06: NACL Stateless Demo
#
# Demuestra que los NACLs son stateless:
# 1. curl funciona con NACL completo (efimeros outbound permitidos)
# 2. Elimina regla efimeros → curl cuelga (request entra, response bloqueada)
# 3. Flow Logs muestran ACCEPT inbound 80 + REJECT outbound efimeros
# 4. Restaura la regla → curl funciona de nuevo
# 5. Flow Logs muestran ACCEPT en todo
#
# Uso: ./validate.sh
# Prerrequisitos: terragrunt apply ejecutado, aws cli v2, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAGRUNT_DIR="$SCRIPT_DIR/terragrunt/lab06"
REGION="eu-west-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "${NC}[INFO]     $*${NC}"; }
pass()     { echo -e "${GREEN}[PASS]     $*${NC}"; }
fail()     { echo -e "${RED}[FAIL]     $*${NC}"; }
expected() { echo -e "${YELLOW}[EXPECTED] $*${NC}"; }
header()   { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# Leer outputs
cd "$TERRAGRUNT_DIR"
log "Leyendo outputs de Terraform..."
ALB_DNS=$(terragrunt output -raw alb_dns_name)
NACL_ID=$(terragrunt output -raw nacl_id)
LOG_GROUP=$(terragrunt output -raw flow_log_group)

log "ALB: http://$ALB_DNS"
log "NACL: $NACL_ID"
log "Flow Logs: $LOG_GROUP"

# Esperar health check ALB
log "Esperando que el ALB health check este healthy (~60s)..."
sleep 60

# --- Fase 1: Baseline ----------------------------------------
header "Fase 1: Baseline (NACL completo, efimeros outbound permitidos)"

log "Reglas NACL actuales:"
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_ID" \
  --region "$REGION" \
  --query "NetworkAcls[0].Entries[].{Num:RuleNumber,Dir:Egress,Port:PortRange,Action:RuleAction}" \
  --output table

if curl -s --max-time 10 "http://$ALB_DNS" | grep -q "Lab 06"; then
  pass "curl HTTP funciona - NACL completo permite el flujo completo"
else
  fail "curl fallo con NACL completo - revisar ALB health check y security groups"
  exit 1
fi

# --- Fase 2: Eliminar regla efimeros -------------------------
header "Fase 2: Eliminar regla outbound de efimeros (rule 200)"

log "Eliminando regla 200 outbound (puertos 1024-65535)..."
aws ec2 delete-network-acl-entry \
  --network-acl-id "$NACL_ID" \
  --egress \
  --rule-number 200 \
  --region "$REGION"

log "Esperando 5 segundos para propagacion..."
sleep 5

log "Probando curl (timeout 8s - deberia colgar)..."
if curl -s --max-time 8 "http://$ALB_DNS" > /dev/null 2>&1; then
  fail "curl deberia haber fallado con NACL sin efimeros outbound"
else
  expected "curl timeout - request llega a nginx (NACL inbound 80 OK) pero response bloqueada (NACL outbound efimeros eliminada)"
  log ""
  log "Diferencia clave con Security Groups:"
  log "  SG (stateful):    permitir 80 inbound -> response sale automaticamente"
  log "  NACL (stateless): permitir 80 inbound -> response BLOQUEADA sin regla outbound 1024-65535"
fi

# --- Fase 3: Flow Logs ---------------------------------------
header "Fase 3: VPC Flow Logs - visualizando ACCEPT vs REJECT"

log "Esperando 90 segundos para que Flow Logs lleguen a CloudWatch..."
sleep 90

END_TIME=$(date +%s)000
START_TIME=$(( END_TIME - 300000 ))

log "Consultando CloudWatch Insights..."
QUERY_ID=$(aws logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --query-string 'fields @timestamp, srcPort, dstPort, action, protocol
    | filter protocol = 6
    | filter (dstPort = 80 or srcPort >= 1024)
    | stats count(*) as paquetes by dstPort, srcPort, action
    | sort action asc, paquetes desc
    | limit 20' \
  --region "$REGION" \
  --query "queryId" \
  --output text)

log "Query iniciada ($QUERY_ID). Esperando resultados..."
sleep 15

aws logs get-query-results \
  --query-id "$QUERY_ID" \
  --region "$REGION" \
  --query "results[*][*].{campo:field,valor:value}" \
  --output table 2>/dev/null || log "Flow Logs aun procesando - normal si el deploy es reciente"

log ""
log "Interpretacion esperada:"
log "  dstPort=80   action=ACCEPT -> request entrante (inbound rule 100 permite 80)"
log "  srcPort>=1024 action=REJECT -> response bloqueada (outbound rule 200 eliminada)"

# --- Fase 4: Restaurar ---------------------------------------
header "Fase 4: Restaurar regla de efimeros + contraste Flow Logs"

log "Restaurando regla 200 outbound (puertos 1024-65535)..."
aws ec2 create-network-acl-entry \
  --network-acl-id "$NACL_ID" \
  --egress \
  --rule-number 200 \
  --protocol tcp \
  --port-range From=1024,To=65535 \
  --cidr-block "0.0.0.0/0" \
  --rule-action allow \
  --region "$REGION"

sleep 5

if curl -s --max-time 10 "http://$ALB_DNS" | grep -q "Lab 06"; then
  pass "curl funciona de nuevo - regla de efimeros restaurada"
else
  fail "curl sigue fallando tras restaurar la regla"
fi

# --- Resumen -------------------------------------------------
header "Resumen: SG (stateful) vs NACL (stateless)"

echo ""
printf "%-22s %-17s %-20s\n" "Caracteristica" "Security Group" "NACL"
printf "%-22s %-17s %-20s\n" "──────────────────────" "─────────────────" "────────────────────"
printf "%-22s %-17s %-20s\n" "Estado"           "Stateful"          "Stateless"
printf "%-22s %-17s %-20s\n" "Reglas respuesta" "Automaticas"       "Manuales (efimeros)"
printf "%-22s %-17s %-20s\n" "Nivel"            "ENI (instancia)"   "Subnet"
printf "%-22s %-17s %-20s\n" "Evaluacion"       "Todas las reglas"  "Primera coincidencia"
printf "%-22s %-17s %-20s\n" "Default"          "Deny all inbound"  "Allow all"
echo ""
log "Para destruir: cd $TERRAGRUNT_DIR && terragrunt destroy"
