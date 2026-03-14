#!/usr/bin/env bash
# =============================================================================
# Lab05 — Script 02: Aurora MySQL + RDS Proxy
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

[[ -z "${VPC_ID:-}" ]] && fail "VPC_ID no encontrado. Ejecuta primero 01-vpc-extendida.sh"

section "PASO 1 — Obtener subnets DB tier"
SUBNET_DB_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$SUBNET_DB_A_CIDR" \
  --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")
SUBNET_DB_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$SUBNET_DB_B_CIDR" \
  --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")
save_resource "SUBNET_DB_A" "$SUBNET_DB_A"
save_resource "SUBNET_DB_B" "$SUBNET_DB_B"
ok "Subnets DB: $SUBNET_DB_A / $SUBNET_DB_B"

section "PASO 2 — DB Subnet Group (DB tier)"
aws rds create-db-subnet-group \
  --db-subnet-group-name "$AURORA_SUBNET_GROUP" \
  --db-subnet-group-description "Aurora DB tier subnets - lab05" \
  --subnet-ids $SUBNET_DB_A $SUBNET_DB_B \
  --tags Key=Project,Value=$PROJECT Key=Lab,Value=$LAB \
  --region "$AWS_REGION" 2>/dev/null && ok "DB Subnet Group creado" || ok "DB Subnet Group ya existe"

section "PASO 3 — Secret Secrets Manager"
AURORA_PASSWORD=$(aws secretsmanager get-random-password \
  --password-length 20 --exclude-punctuation \
  --query 'RandomPassword' --output text --region "$AWS_REGION")

SECRET_ARN=$(aws secretsmanager create-secret \
  --name "$AURORA_SECRET_ID" \
  --secret-string "{\"username\":\"admin\",\"password\":\"${AURORA_PASSWORD}\"}" \
  --tags Key=Project,Value=$PROJECT Key=Lab,Value=$LAB \
  --query 'ARN' --output text --region "$AWS_REGION" 2>/dev/null || \
  aws secretsmanager describe-secret --secret-id "$AURORA_SECRET_ID" \
    --query 'ARN' --output text --region "$AWS_REGION")
save_resource "AURORA_SECRET_ARN" "$SECRET_ARN"
ok "Secret: $SECRET_ARN"

section "PASO 4 — Aurora Cluster + Writer + Reader"
# Cluster
aws rds create-db-cluster \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --engine aurora-mysql --engine-version 8.0.mysql_aurora.3.04.0 \
  --master-username admin --master-user-password "$AURORA_PASSWORD" \
  --database-name "$AURORA_DB_NAME" \
  --db-subnet-group-name "$AURORA_SUBNET_GROUP" \
  --vpc-security-group-ids "${SG_AURORA:-}" \
  --backup-retention-period 1 --no-publicly-accessible --storage-encrypted \
  --tags Key=Project,Value=$PROJECT Key=Lab,Value=$LAB \
  --region "$AWS_REGION" 2>/dev/null && ok "Cluster creado" || ok "Cluster ya existe"

# Writer
aws rds create-db-instance \
  --db-instance-identifier "$AURORA_WRITER_ID" \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --engine aurora-mysql --db-instance-class db.t3.medium \
  --availability-zone "$AZ_A" --no-publicly-accessible \
  --tags Key=Project,Value=$PROJECT Key=Lab,Value=$LAB Key=Role,Value=writer \
  --region "$AWS_REGION" 2>/dev/null && log "Writer creando..." || ok "Writer ya existe"

# Reader
aws rds create-db-instance \
  --db-instance-identifier "$AURORA_READER_ID" \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --engine aurora-mysql --db-instance-class db.t3.medium \
  --availability-zone "$AZ_B" --no-publicly-accessible \
  --tags Key=Project,Value=$PROJECT Key=Lab,Value=$LAB Key=Role,Value=reader \
  --region "$AWS_REGION" 2>/dev/null && log "Reader creando..." || ok "Reader ya existe"

log "Esperando Writer instance disponible (~8 min)..."
aws rds wait db-instance-available \
  --db-instance-identifier "$AURORA_WRITER_ID" --region "$AWS_REGION"
aws rds wait db-instance-available \
  --db-instance-identifier "$AURORA_READER_ID" --region "$AWS_REGION"
ok "Aurora Writer + Reader disponibles"

CLUSTER_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --query 'DBClusters[0].Endpoint' --output text --region "$AWS_REGION")
save_resource "CLUSTER_ENDPOINT" "$CLUSTER_ENDPOINT"

# Actualizar secret con endpoint
aws secretsmanager update-secret \
  --secret-id "$AURORA_SECRET_ID" \
  --secret-string "{\"username\":\"admin\",\"password\":\"${AURORA_PASSWORD}\",\"host\":\"${CLUSTER_ENDPOINT}\",\"port\":3306,\"dbname\":\"${AURORA_DB_NAME}\"}" \
  --region "$AWS_REGION"

section "PASO 5 — IAM Role para RDS Proxy"
PROXY_ROLE_ARN=$(aws iam get-role --role-name $PROXY_ROLE \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam create-role --role-name $PROXY_ROLE \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"rds.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --query 'Role.Arn' --output text)

aws iam put-role-policy --role-name $PROXY_ROLE --policy-name AllowSecretsManager \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\",\"secretsmanager:DescribeSecret\"],\"Resource\":\"${SECRET_ARN}\"}]}" \
  2>/dev/null || true
save_resource "PROXY_ROLE_ARN" "$PROXY_ROLE_ARN"
ok "Proxy IAM Role: $PROXY_ROLE_ARN"
sleep 10

section "PASO 6 — RDS Proxy"
PROXY_EXISTS=$(aws rds describe-db-proxies --db-proxy-name "$AURORA_PROXY_ID" \
  --query 'DBProxies[0].Status' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$PROXY_EXISTS" == "None" ]]; then
  aws rds create-db-proxy \
    --db-proxy-name "$AURORA_PROXY_ID" --engine-family MYSQL \
    --auth "[{\"AuthScheme\":\"SECRETS\",\"SecretArn\":\"${SECRET_ARN}\",\"IAMAuth\":\"DISABLED\"}]" \
    --role-arn "$PROXY_ROLE_ARN" \
    --vpc-subnet-ids $SUBNET_DB_A $SUBNET_DB_B \
    --vpc-security-group-ids "${SG_AURORA:-}" \
    --region "$AWS_REGION"

  aws rds register-db-proxy-targets \
    --db-proxy-name "$AURORA_PROXY_ID" \
    --db-cluster-identifiers "$AURORA_CLUSTER_ID" \
    --region "$AWS_REGION"

  log "Esperando RDS Proxy disponible (~5 min)..."
  aws rds wait db-proxy-available \
    --db-proxy-name "$AURORA_PROXY_ID" --region "$AWS_REGION"
  ok "RDS Proxy disponible"
else
  ok "RDS Proxy ya existe con estado: $PROXY_EXISTS"
fi

PROXY_ENDPOINT=$(aws rds describe-db-proxies \
  --db-proxy-name "$AURORA_PROXY_ID" \
  --query 'DBProxies[0].Endpoint' --output text --region "$AWS_REGION")
save_resource "PROXY_ENDPOINT" "$PROXY_ENDPOINT"

echo ""
echo "  Cluster Endpoint: $CLUSTER_ENDPOINT"
echo "  Proxy Endpoint:   $PROXY_ENDPOINT"
echo "  Secret:           $AURORA_SECRET_ID"
echo ""
ok "Script 02 completado — Aurora + RDS Proxy listos"
