#!/usr/bin/env bash
# v2 — CLI 02: Aurora MySQL Multi-AZ
# Cluster (writer + reader) en subnets DB privadas
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v2: Creando Aurora MySQL Multi-AZ ==="

DB_NAME="${PROJECT//-/}db"    # ej: ec2labdb (sin guiones)
DB_USER="admin"
DB_PASS=$(openssl rand -base64 24 | tr -d '/+=')

# Security Group para Aurora — solo acepta desde SG de EC2
SG_AURORA=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-sg-aurora" \
  --description "Aurora — acepta solo desde EC2 SG" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

aws ec2 create-tags --resources "$SG_AURORA" \
  --tags Key=Name,Value="${PROJECT}-sg-aurora" Key=Project,Value="$PROJECT"

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_AURORA" \
  --protocol tcp \
  --port 3306 \
  --source-group "$SG_EC2_ID"

echo "SG Aurora: $SG_AURORA"

# Aurora Cluster
aws rds create-db-cluster \
  --db-cluster-identifier "${PROJECT}-aurora-cluster" \
  --engine aurora-mysql \
  --engine-version "8.0.mysql_aurora.3.04.0" \
  --master-username "$DB_USER" \
  --master-user-password "$DB_PASS" \
  --database-name "$DB_NAME" \
  --db-subnet-group-name "$AURORA_SUBNET_GROUP" \
  --vpc-security-group-ids "$SG_AURORA" \
  --backup-retention-period 1 \
  --storage-encrypted \
  --tags Key=Project,Value="$PROJECT" Key=Lab,Value=v2 > /dev/null

echo "Cluster Aurora iniciando..."

# Writer instance
aws rds create-db-instance \
  --db-instance-identifier "${PROJECT}-aurora-writer" \
  --db-cluster-identifier "${PROJECT}-aurora-cluster" \
  --db-instance-class db.t3.medium \
  --engine aurora-mysql \
  --tags Key=Project,Value="$PROJECT" Key=Role,Value=writer > /dev/null

# Reader instance (segunda AZ)
aws rds create-db-instance \
  --db-instance-identifier "${PROJECT}-aurora-reader" \
  --db-cluster-identifier "${PROJECT}-aurora-cluster" \
  --db-instance-class db.t3.medium \
  --engine aurora-mysql \
  --tags Key=Project,Value="$PROJECT" Key=Role,Value=reader > /dev/null

echo "Esperando a que Aurora esté disponible (5-10 min)..."
aws rds wait db-instance-available \
  --db-instance-identifier "${PROJECT}-aurora-writer"

# Obtener endpoints
AURORA_WRITER=$(aws rds describe-db-clusters \
  --db-cluster-identifier "${PROJECT}-aurora-cluster" \
  --query 'DBClusters[0].Endpoint' --output text)

AURORA_READER=$(aws rds describe-db-clusters \
  --db-cluster-identifier "${PROJECT}-aurora-cluster" \
  --query 'DBClusters[0].ReaderEndpoint' --output text)

echo "Aurora Writer: $AURORA_WRITER"
echo "Aurora Reader: $AURORA_READER"

cat >> ~/.ec2-lab-env << EOF

# v2 — Aurora
export SG_AURORA="$SG_AURORA"
export AURORA_CLUSTER="${PROJECT}-aurora-cluster"
export AURORA_WRITER="$AURORA_WRITER"
export AURORA_READER="$AURORA_READER"
export DB_NAME="$DB_NAME"
export DB_USER="$DB_USER"
export DB_PASS="$DB_PASS"
EOF

echo "=== Aurora MySQL Multi-AZ listo ==="
echo "IMPORTANTE: Detener el cluster al terminar el lab para ahorrar costes:"
echo "  aws rds stop-db-cluster --db-cluster-identifier ${PROJECT}-aurora-cluster"
