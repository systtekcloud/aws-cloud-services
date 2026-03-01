#!/usr/bin/env bash
# =============================================================================
# v1 — Paso 4: Validación completa
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1090
[[ -f ~/.ec2-lab-env ]] && source ~/.ec2-lab-env
: "${ALB_DNS:?Ejecuta primero 03-compute.sh}"
: "${TG_ARN:?}"
: "${REGION:=eu-west-1}"
: "${PROJECT:=ec2-lab}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; }

# -----------------------------------------------------------------------------
info "1/4 — Estado de targets en el Target Group..."
# -----------------------------------------------------------------------------
echo "Esperando a que los targets estén healthy..."
for i in {1..20}; do
  HEALTHY=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" --region "$REGION" \
    --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' \
    --output text)
  if [[ "$HEALTHY" -ge 2 ]]; then
    ok "$HEALTHY targets healthy"
    break
  fi
  echo "  [${i}] Healthy: $HEALTHY/2 — esperando 15s..."
  sleep 15
done

aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" --region "$REGION" \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Description]' \
  --output table

# -----------------------------------------------------------------------------
info "2/4 — curl al ALB (health check + app)..."
# -----------------------------------------------------------------------------
echo ""
echo "--- GET /health ---"
RESPONSE=$(curl -sf "http://${ALB_DNS}/health" || echo '{"error":"no response"}')
echo "$RESPONSE" | python3 -m json.tool
if echo "$RESPONSE" | grep -q '"healthy"'; then ok "Health check OK"; else fail "Health check FAIL"; fi

echo ""
echo "--- GET / ---"
curl -sf "http://${ALB_DNS}/" | python3 -m json.tool

# -----------------------------------------------------------------------------
info "3/4 — Round-robin: 10 requests, deben alternar instancias..."
# -----------------------------------------------------------------------------
echo ""
echo "Hosts respondiendo (debe haber al menos 2 distintos):"
declare -A HOSTS
for i in {1..10}; do
  HOST=$(curl -sf "http://${ALB_DNS}/" | python3 -c "import sys,json; print(json.load(sys.stdin).get('host','?'))" 2>/dev/null || echo "error")
  AZ=$(curl -sf   "http://${ALB_DNS}/" | python3 -c "import sys,json; print(json.load(sys.stdin).get('az','?'))"   2>/dev/null || echo "error")
  printf "  [%02d] %-30s %s\n" "$i" "$HOST" "$AZ"
  HOSTS["$HOST"]=1
done
UNIQUE_HOSTS=${#HOSTS[@]}
if [[ $UNIQUE_HOSTS -ge 2 ]]; then ok "$UNIQUE_HOSTS hosts distintos (round-robin OK)"; else fail "Solo $UNIQUE_HOSTS host respondió — revisar ASG"; fi

# -----------------------------------------------------------------------------
info "4/4 — Instancias del ASG por AZ..."
# -----------------------------------------------------------------------------
echo ""
aws autoscaling describe-auto-scaling-instances \
  --region "$REGION" \
  --query "AutoScalingInstances[?AutoScalingGroupName=='${PROJECT}-asg-web'].[InstanceId,AvailabilityZone,HealthStatus,LifecycleState]" \
  --output table

echo ""
ok "=== Validación v1 completada. ALB: http://$ALB_DNS ==="
