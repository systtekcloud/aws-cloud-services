#!/usr/bin/env bash
# v2 — CLI 01: Subnets de base de datos + subnet group
# Prerequisito: source ~/.ec2-lab-env (v1 desplegado)
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v2: Creando subnets de base de datos ==="

# Obtener AZs usadas en v1
AZ_A=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_APP_A" \
  --query 'Subnets[0].AvailabilityZone' --output text)
AZ_B=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_APP_B" \
  --query 'Subnets[0].AvailabilityZone' --output text)
AZ_C=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_APP_C" \
  --query 'Subnets[0].AvailabilityZone' --output text)

# Subnets DB (capa 3): CIDRs 10.0.21-23.0/24
SUBNET_DB_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.21.0/24" \
  --availability-zone "$AZ_A" \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources "$SUBNET_DB_A" \
  --tags Key=Name,Value="${PROJECT}-db-${AZ_A}" Key=Project,Value="$PROJECT"

SUBNET_DB_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.22.0/24" \
  --availability-zone "$AZ_B" \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources "$SUBNET_DB_B" \
  --tags Key=Name,Value="${PROJECT}-db-${AZ_B}" Key=Project,Value="$PROJECT"

SUBNET_DB_C=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.23.0/24" \
  --availability-zone "$AZ_C" \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources "$SUBNET_DB_C" \
  --tags Key=Name,Value="${PROJECT}-db-${AZ_C}" Key=Project,Value="$PROJECT"

echo "Subnets DB creadas: $SUBNET_DB_A | $SUBNET_DB_B | $SUBNET_DB_C"

# Asociar subnets DB a la route table privada (solo tráfico local, sin NAT)
# Obtener la RT privada de AZ-A como referencia
RT_PRIVATE=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT}-rt-private-${AZ_A}" \
  --query 'RouteTables[0].RouteTableId' --output text)

for SUBNET in "$SUBNET_DB_A" "$SUBNET_DB_B" "$SUBNET_DB_C"; do
  aws ec2 associate-route-table \
    --subnet-id "$SUBNET" \
    --route-table-id "$RT_PRIVATE" > /dev/null
done

# Aurora DB Subnet Group
aws rds create-db-subnet-group \
  --db-subnet-group-name "${PROJECT}-aurora-subnet-group" \
  --db-subnet-group-description "Aurora Multi-AZ subnet group" \
  --subnet-ids "$SUBNET_DB_A" "$SUBNET_DB_B" "$SUBNET_DB_C" \
  --tags Key=Project,Value="$PROJECT" > /dev/null

# ElastiCache Subnet Group
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name "${PROJECT}-redis-subnet-group" \
  --cache-subnet-group-description "ElastiCache Redis subnet group" \
  --subnet-ids "$SUBNET_DB_A" "$SUBNET_DB_B" "$SUBNET_DB_C" > /dev/null

echo "Subnet groups creados para Aurora y ElastiCache"

# Guardar en env
cat >> ~/.ec2-lab-env << EOF

# v2 — DB subnets
export SUBNET_DB_A="$SUBNET_DB_A"
export SUBNET_DB_B="$SUBNET_DB_B"
export SUBNET_DB_C="$SUBNET_DB_C"
export AURORA_SUBNET_GROUP="${PROJECT}-aurora-subnet-group"
export REDIS_SUBNET_GROUP="${PROJECT}-redis-subnet-group"
EOF

echo "=== Subnets DB listas ==="
