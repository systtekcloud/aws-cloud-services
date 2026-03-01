#!/usr/bin/env bash
# v2 — CLI 05: Validación 3-tier completa
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v2: Validación 3-tier ==="

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].DNSName' --output text)

# 1) Health check básico
echo ""
echo "--- 1. Health check ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${ALB_DNS}/health")
if [ "$HTTP_CODE" == "200" ]; then
  echo "OK: /health devuelve 200"
else
  echo "ERROR: /health devuelve $HTTP_CODE"
  exit 1
fi

# 2) Respuesta completa /health (debe incluir db y cache)
echo ""
echo "--- 2. Health con DB + Cache ---"
RESPONSE=$(curl -s "http://${ALB_DNS}/health")
echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

DB_STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('db','unknown'))" 2>/dev/null || echo "no-json")
CACHE_STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cache','unknown'))" 2>/dev/null || echo "no-json")

echo "DB status: $DB_STATUS | Cache status: $CACHE_STATUS"

# 3) DB check endpoint
echo ""
echo "--- 3. DB check ---"
curl -s "http://${ALB_DNS}/db-check" | python3 -m json.tool 2>/dev/null || \
  echo "INFO: /db-check no disponible o app aún actualizándose"

# 4) Verificar Aurora: writer y reader en AZs distintas
echo ""
echo "--- 4. Aurora Multi-AZ ---"
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=${AURORA_CLUSTER}" \
  --query 'DBInstances[*].[DBInstanceIdentifier,AvailabilityZone,DBInstanceStatus]' \
  --output table

# 5) Estado del replication group Redis
echo ""
echo "--- 5. ElastiCache Redis ---"
aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_GROUP" \
  --query 'ReplicationGroups[0].{Status:Status,AutoFailover:AutomaticFailover,MultiAZ:MultiAZ,Encrypted:TransitEncryptionEnabled}' \
  --output table

# 6) Verificar secret en Secrets Manager
echo ""
echo "--- 6. Secrets Manager ---"
aws secretsmanager describe-secret \
  --secret-id "${PROJECT}/aurora/credentials" \
  --query '{Name:Name,RotationEnabled:RotationEnabled}' \
  --output table

# 7) ASG: instancias healthy
echo ""
echo "--- 7. ASG instancias ---"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,AvailabilityZone,HealthStatus]' \
  --output table

echo ""
echo "=== Validación 3-tier completada ==="
echo "ALB: http://${ALB_DNS}"
