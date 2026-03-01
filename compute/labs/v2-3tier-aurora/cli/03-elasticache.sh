#!/usr/bin/env bash
# v2 — CLI 03: ElastiCache Redis con in-transit encryption + auth token
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v2: Creando ElastiCache Redis ==="

REDIS_AUTH_TOKEN=$(openssl rand -base64 32 | tr -d '/+=')

# SG para Redis — solo desde EC2
SG_REDIS=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-sg-redis" \
  --description "Redis — acepta solo desde EC2 SG" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

aws ec2 create-tags --resources "$SG_REDIS" \
  --tags Key=Name,Value="${PROJECT}-sg-redis" Key=Project,Value="$PROJECT"

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_REDIS" \
  --protocol tcp \
  --port 6379 \
  --source-group "$SG_EC2_ID"

echo "SG Redis: $SG_REDIS"

# Replication Group con automatic failover
aws elasticache create-replication-group \
  --replication-group-id "${PROJECT}-redis" \
  --description "Redis con in-transit encryption y auth" \
  --num-cache-clusters 2 \
  --cache-node-type "cache.t3.micro" \
  --engine redis \
  --engine-version "7.1" \
  --cache-subnet-group-name "$REDIS_SUBNET_GROUP" \
  --security-group-ids "$SG_REDIS" \
  --transit-encryption-enabled \
  --auth-token "$REDIS_AUTH_TOKEN" \
  --automatic-failover-enabled \
  --multi-az-enabled \
  --tags Key=Project,Value="$PROJECT" Key=Lab,Value=v2 > /dev/null

echo "Esperando a que Redis esté disponible (5-10 min)..."
aws elasticache wait replication-group-available \
  --replication-group-id "${PROJECT}-redis"

REDIS_ENDPOINT=$(aws elasticache describe-replication-groups \
  --replication-group-id "${PROJECT}-redis" \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' \
  --output text)

echo "Redis endpoint: $REDIS_ENDPOINT:6379"

cat >> ~/.ec2-lab-env << EOF

# v2 — ElastiCache Redis
export SG_REDIS="$SG_REDIS"
export REDIS_GROUP="${PROJECT}-redis"
export REDIS_ENDPOINT="$REDIS_ENDPOINT"
export REDIS_AUTH_TOKEN="$REDIS_AUTH_TOKEN"
EOF

echo "=== ElastiCache Redis listo ==="
