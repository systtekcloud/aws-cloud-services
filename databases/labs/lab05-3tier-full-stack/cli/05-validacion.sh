#!/usr/bin/env bash
# =============================================================================
# Lab05 — Script 05: Validación E2E del stack completo
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

PASS=0
FAIL=0
WARN=0

check() {
  local label="$1"
  local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    ok "  [OK] $label"
    ((PASS++))
  else
    warn "  [FAIL] $label"
    ((FAIL++))
  fi
}

check_output() {
  local label="$1"
  local cmd="$2"
  local expected="$3"
  local output
  output=$(eval "$cmd" 2>/dev/null || echo "ERROR")
  if [[ "$output" == *"$expected"* ]]; then
    ok "  [OK] $label → $output"
    ((PASS++))
  else
    warn "  [FAIL] $label → got: $output"
    ((FAIL++))
  fi
}

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         LAB05 — Validación E2E del Stack Completo        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ─── VPC ──────────────────────────────────────────────────────────────────────
section "VPC y Red"
check_output "VPC existe" \
  "aws ec2 describe-vpcs --vpc-ids ${VPC_ID:-vpc-none} --query 'Vpcs[0].State' --output text --region $AWS_REGION" \
  "available"

check_output "Subnet App A existe" \
  "aws ec2 describe-subnets --subnet-ids ${SUBNET_APP_A:-subnet-none} --query 'Subnets[0].State' --output text --region $AWS_REGION" \
  "available"

check_output "Subnet DB A existe" \
  "aws ec2 describe-subnets --subnet-ids ${SUBNET_DB_A:-subnet-none} --query 'Subnets[0].State' --output text --region $AWS_REGION" \
  "available"

DYNAMO_ENDPOINT_COUNT=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID:-}" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.dynamodb" \
  --query 'length(VpcEndpoints)' --output text --region "$AWS_REGION" 2>/dev/null || echo 0)
if [[ "$DYNAMO_ENDPOINT_COUNT" -gt 0 ]]; then
  ok "  [OK] VPC Endpoint DynamoDB (Gateway) existe"
  ((PASS++))
else
  warn "  [FAIL] VPC Endpoint DynamoDB no encontrado"
  ((FAIL++))
fi

# ─── AURORA ───────────────────────────────────────────────────────────────────
section "Aurora MySQL"
check_output "Cluster Aurora disponible" \
  "aws rds describe-db-clusters --db-cluster-identifier $AURORA_CLUSTER_ID --query 'DBClusters[0].Status' --output text --region $AWS_REGION" \
  "available"

check_output "Writer instance disponible" \
  "aws rds describe-db-instances --db-instance-identifier $AURORA_WRITER_ID --query 'DBInstances[0].DBInstanceStatus' --output text --region $AWS_REGION" \
  "available"

check_output "Reader instance disponible" \
  "aws rds describe-db-instances --db-instance-identifier $AURORA_READER_ID --query 'DBInstances[0].DBInstanceStatus' --output text --region $AWS_REGION" \
  "available"

check_output "Secret Aurora existe en Secrets Manager" \
  "aws secretsmanager describe-secret --secret-id $AURORA_SECRET_ID --query 'Name' --output text --region $AWS_REGION" \
  "$AURORA_SECRET_ID"

# ─── RDS PROXY ────────────────────────────────────────────────────────────────
section "RDS Proxy"
PROXY_STATUS=$(aws rds describe-db-proxies \
  --db-proxy-name "$AURORA_PROXY_ID" \
  --query 'DBProxies[0].Status' --output text --region "$AWS_REGION" 2>/dev/null || echo "not-found")
if [[ "$PROXY_STATUS" == "available" ]]; then
  ok "  [OK] RDS Proxy estado: available"
  ((PASS++))
else
  warn "  [FAIL] RDS Proxy estado: $PROXY_STATUS"
  ((FAIL++))
fi

PROXY_TARGETS=$(aws rds describe-db-proxy-targets \
  --db-proxy-name "$AURORA_PROXY_ID" \
  --query 'Targets[0].TargetHealth.State' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
if [[ "$PROXY_TARGETS" == "AVAILABLE" ]]; then
  ok "  [OK] Proxy targets en estado AVAILABLE"
  ((PASS++))
else
  warn "  [WARN] Proxy targets estado: $PROXY_TARGETS (puede tardar unos minutos)"
  ((WARN++))
fi

# ─── DYNAMODB ─────────────────────────────────────────────────────────────────
section "DynamoDB"
check_output "Tabla $DYNAMO_TABLE activa" \
  "aws dynamodb describe-table --table-name $DYNAMO_TABLE --query 'Table.TableStatus' --output text --region $AWS_REGION" \
  "ACTIVE"

TTL_STATUS=$(aws dynamodb describe-time-to-live \
  --table-name "$DYNAMO_TABLE" \
  --query 'TimeToLiveDescription.TimeToLiveStatus' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
if [[ "$TTL_STATUS" == "ENABLED" ]]; then
  ok "  [OK] TTL habilitado en la tabla"
  ((PASS++))
else
  warn "  [FAIL] TTL no habilitado (estado: $TTL_STATUS)"
  ((FAIL++))
fi

STREAM_STATUS=$(aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --query 'Table.StreamSpecification.StreamEnabled' --output text --region "$AWS_REGION" 2>/dev/null || echo "false")
if [[ "$STREAM_STATUS" == "True" || "$STREAM_STATUS" == "true" ]]; then
  ok "  [OK] DynamoDB Streams habilitado"
  ((PASS++))
else
  warn "  [FAIL] DynamoDB Streams no habilitado"
  ((FAIL++))
fi

ITEM_COUNT=$(aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --query 'Table.ItemCount' --output text --region "$AWS_REGION" 2>/dev/null || echo 0)
ok "  [INFO] Items en tabla: $ITEM_COUNT"

# ─── LAMBDA ───────────────────────────────────────────────────────────────────
section "Lambda + SNS"
check_output "Lambda $LAMBDA_FUNCTION existe" \
  "aws lambda get-function --function-name $LAMBDA_FUNCTION --query 'Configuration.State' --output text --region $AWS_REGION" \
  "Active"

check_output "SNS Topic existe" \
  "aws sns get-topic-attributes --topic-arn ${SNS_TOPIC_ARN:-arn:aws:sns:eu-west-1:000:none} --query 'Attributes.TopicArn' --output text --region $AWS_REGION" \
  "$SNS_TOPIC_NAME"

ESM_STATE=$(aws lambda list-event-source-mappings \
  --function-name "$LAMBDA_FUNCTION" \
  --query 'EventSourceMappings[0].State' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
if [[ "$ESM_STATE" == "Enabled" ]]; then
  ok "  [OK] Event Source Mapping activo"
  ((PASS++))
else
  warn "  [WARN] Event Source Mapping estado: $ESM_STATE"
  ((WARN++))
fi

# ─── REDIS ────────────────────────────────────────────────────────────────────
section "ElastiCache Redis"
REDIS_STATUS=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --query 'ReplicationGroups[0].Status' --output text --region "$AWS_REGION" 2>/dev/null || echo "not-found")
if [[ "$REDIS_STATUS" == "available" ]]; then
  ok "  [OK] Redis Replication Group: available"
  ((PASS++))
else
  warn "  [FAIL] Redis estado: $REDIS_STATUS"
  ((FAIL++))
fi

REDIS_MULTI_AZ=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --query 'ReplicationGroups[0].MultiAZ' --output text --region "$AWS_REGION" 2>/dev/null || echo "disabled")
if [[ "$REDIS_MULTI_AZ" == "enabled" ]]; then
  ok "  [OK] Redis Multi-AZ habilitado"
  ((PASS++))
else
  warn "  [FAIL] Redis Multi-AZ no habilitado"
  ((FAIL++))
fi

REDIS_TLS=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --query 'ReplicationGroups[0].TransitEncryptionEnabled' --output text --region "$AWS_REGION" 2>/dev/null || echo "false")
if [[ "$REDIS_TLS" == "True" || "$REDIS_TLS" == "true" ]]; then
  ok "  [OK] Redis TLS (transit encryption) habilitado"
  ((PASS++))
else
  warn "  [FAIL] Redis TLS no habilitado"
  ((FAIL++))
fi

# ─── RESUMEN ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    RESUMEN VALIDACIÓN                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  ✅ Checks OK:      $PASS"
echo "  ⚠️  Warnings:      $WARN"
echo "  ❌ Checks FAIL:    $FAIL"
echo ""
echo "  Endpoints:"
echo "  Aurora Cluster:   ${CLUSTER_ENDPOINT:-no disponible}"
echo "  RDS Proxy:        ${PROXY_ENDPOINT:-no disponible}"
echo "  Redis Primary:    ${REDIS_PRIMARY:-no disponible}"
echo "  Redis Reader:     ${REDIS_READER:-no disponible}"
echo "  DynamoDB Table:   $DYNAMO_TABLE"
echo "  Lambda Function:  $LAMBDA_FUNCTION"
echo "  SNS Topic ARN:    ${SNS_TOPIC_ARN:-no disponible}"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
  ok "Stack completo operativo. Procede con las fases de validación manual."
else
  warn "Hay $FAIL checks fallidos. Revisa los servicios indicados antes de continuar."
fi
