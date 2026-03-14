#!/usr/bin/env bash
# =============================================================================
# Lab04 ElastiCache — Script 01: Crear Redis Replication Group
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

check_prereqs

# ---------------------------------------------------------------------------
section "PASO 1 — Obtener red del lab01"
# ---------------------------------------------------------------------------

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=cidr,Values=$VPC_CIDR" "Name=tag:Project,Values=$PROJECT" \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

[[ "$VPC_ID" == "None" ]] && fail "VPC $VPC_CIDR no encontrada. Ejecuta primero lab01/cli/01-vpc-y-sg.sh"
ok "VPC: $VPC_ID"

SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$SUBNET_PRIVATE_A_CIDR" \
  --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")

SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$SUBNET_PRIVATE_B_CIDR" \
  --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")

SG_APP=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=sg-app-db-labs" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

save_resource "VPC_ID" "$VPC_ID"
save_resource "SUBNET_A" "$SUBNET_A"
save_resource "SUBNET_B" "$SUBNET_B"
save_resource "SG_APP" "$SG_APP"
ok "Subnets: $SUBNET_A / $SUBNET_B | SG App: $SG_APP"

# ---------------------------------------------------------------------------
section "PASO 2 — Security Group para Redis"
# ---------------------------------------------------------------------------

SG_REDIS=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=sg-redis-db-labs" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$SG_REDIS" == "None" || -z "$SG_REDIS" ]]; then
  SG_REDIS=$(aws ec2 create-security-group \
    --group-name sg-redis-db-labs \
    --description "ElastiCache Redis lab04 - inbound from sg-app only" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT},{Key=Lab,Value=$LAB}]" \
    --query 'GroupId' --output text --region "$AWS_REGION")

  if [[ "$SG_APP" != "None" ]]; then
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_REDIS" \
      --protocol tcp --port $REDIS_PORT \
      --source-group "$SG_APP" \
      --region "$AWS_REGION"
    ok "Regla inbound $REDIS_PORT desde $SG_APP añadida"
  fi
  ok "SG Redis creado: $SG_REDIS"
else
  ok "SG Redis ya existe: $SG_REDIS"
fi
save_resource "SG_REDIS" "$SG_REDIS"

# ---------------------------------------------------------------------------
section "PASO 3 — Cache Subnet Group"
# ---------------------------------------------------------------------------

SUBNET_GROUP_EXISTS=$(aws elasticache describe-cache-subnet-groups \
  --cache-subnet-group-name "$REDIS_SUBNET_GROUP" \
  --region "$AWS_REGION" 2>/dev/null | jq -r '.CacheSubnetGroups[0].CacheSubnetGroupName' || echo "None")

if [[ "$SUBNET_GROUP_EXISTS" == "None" || "$SUBNET_GROUP_EXISTS" == "null" ]]; then
  aws elasticache create-cache-subnet-group \
    --cache-subnet-group-name "$REDIS_SUBNET_GROUP" \
    --cache-subnet-group-description "Redis subnets for lab04 - private only" \
    --subnet-ids "$SUBNET_A" "$SUBNET_B" \
    --tags "Key=Project,Value=$PROJECT" "Key=Lab,Value=$LAB" \
    --region "$AWS_REGION"
  ok "Cache Subnet Group creado: $REDIS_SUBNET_GROUP"
else
  ok "Cache Subnet Group ya existe: $REDIS_SUBNET_GROUP"
fi

# ---------------------------------------------------------------------------
section "PASO 4 — Crear Replication Group Redis"
# ---------------------------------------------------------------------------

CLUSTER_EXISTS=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --region "$AWS_REGION" 2>/dev/null | jq -r '.ReplicationGroups[0].Status' || echo "None")

if [[ "$CLUSTER_EXISTS" == "None" || -z "$CLUSTER_EXISTS" ]]; then
  log "Creando Replication Group $REDIS_CLUSTER_ID (~5-8 min)..."

  aws elasticache create-replication-group \
    --replication-group-id "$REDIS_CLUSTER_ID" \
    --replication-group-description "Redis lab04 - cache aside y session store" \
    --engine "$REDIS_ENGINE" \
    --engine-version "$REDIS_ENGINE_VERSION" \
    --cache-node-type "$REDIS_NODE_TYPE" \
    --num-cache-clusters "$REDIS_NUM_CLUSTERS" \
    --cache-subnet-group-name "$REDIS_SUBNET_GROUP" \
    --security-group-ids "$SG_REDIS" \
    --automatic-failover-enabled \
    --multi-az-enabled \
    --at-rest-encryption-enabled \
    --transit-encryption-enabled \
    --tags "Key=Project,Value=$PROJECT" "Key=Lab,Value=$LAB" "Key=Env,Value=$ENV" \
    --region "$AWS_REGION"

  log "Esperando disponibilidad..."
  aws elasticache wait replication-group-available \
    --replication-group-id "$REDIS_CLUSTER_ID" \
    --region "$AWS_REGION"
  ok "Replication Group disponible"
else
  ok "Replication Group ya existe con estado: $CLUSTER_EXISTS"
fi

# ---------------------------------------------------------------------------
section "PASO 5 — Obtener endpoints"
# ---------------------------------------------------------------------------

PRIMARY_ENDPOINT=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' \
  --output text --region "$AWS_REGION")

READER_ENDPOINT=$(aws elasticache describe-replication-groups \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --query 'ReplicationGroups[0].NodeGroups[0].ReaderEndpoint.Address' \
  --output text --region "$AWS_REGION")

save_resource "PRIMARY_ENDPOINT" "$PRIMARY_ENDPOINT"
save_resource "READER_ENDPOINT" "$READER_ENDPOINT"

# ---------------------------------------------------------------------------
section "RESUMEN"
# ---------------------------------------------------------------------------
echo ""
echo "  Replication Group: $REDIS_CLUSTER_ID"
echo "  Primary endpoint:  $PRIMARY_ENDPOINT:$REDIS_PORT"
echo "  Reader endpoint:   $READER_ENDPOINT:$REDIS_PORT"
echo "  TLS:               enabled"
echo ""
echo "  Conectar desde EC2 (redis-cli):"
echo "    redis-cli -h $PRIMARY_ENDPOINT -p $REDIS_PORT --tls PING"
echo ""
ok "Script 01 completado"
