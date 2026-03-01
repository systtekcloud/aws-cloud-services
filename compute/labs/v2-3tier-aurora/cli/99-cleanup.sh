#!/usr/bin/env bash
# v2 — Cleanup: Aurora + ElastiCache + Secrets (NO borra recursos v1)
set -euo pipefail

source ~/.ec2-lab-env

echo "ADVERTENCIA: Esto borrará Aurora, ElastiCache y Secrets de v2."
echo "Los recursos de v1 (VPC, ALB, ASG) NO se borran."
read -rp "Escribe 'borrar' para confirmar: " CONFIRM
[ "$CONFIRM" == "borrar" ] || { echo "Abortado."; exit 0; }

echo "=== v2: Limpiando recursos ==="

# 1) Secrets Manager
for SECRET in "${PROJECT}/aurora/credentials" "${PROJECT}/redis/auth-token"; do
  aws secretsmanager delete-secret \
    --secret-id "$SECRET" \
    --force-delete-without-recovery 2>/dev/null && echo "Secret borrado: $SECRET" || true
done

# 2) Aurora cluster (borrar instancias primero, luego cluster)
for INSTANCE in "${PROJECT}-aurora-writer" "${PROJECT}-aurora-reader"; do
  aws rds delete-db-instance \
    --db-instance-identifier "$INSTANCE" \
    --skip-final-snapshot 2>/dev/null && echo "Aurora instance: $INSTANCE borrada" || true
done

echo "Esperando borrado de instancias Aurora..."
aws rds wait db-instance-deleted \
  --db-instance-identifier "${PROJECT}-aurora-writer" 2>/dev/null || true

aws rds delete-db-cluster \
  --db-cluster-identifier "${AURORA_CLUSTER}" \
  --skip-final-snapshot 2>/dev/null && echo "Aurora cluster borrado" || true

# 3) ElastiCache
aws elasticache delete-replication-group \
  --replication-group-id "$REDIS_GROUP" \
  --retain-primary-cluster 2>/dev/null || \
aws elasticache delete-replication-group \
  --replication-group-id "$REDIS_GROUP" 2>/dev/null && echo "Redis borrado" || true

# 4) Subnet groups
aws rds delete-db-subnet-group \
  --db-subnet-group-name "$AURORA_SUBNET_GROUP" 2>/dev/null || true
aws elasticache delete-cache-subnet-group \
  --cache-subnet-group-name "$REDIS_SUBNET_GROUP" 2>/dev/null || true

# 5) Security Groups (esperar a que las ENIs se liberen)
sleep 30
for SG in "$SG_AURORA" "$SG_REDIS"; do
  aws ec2 delete-security-group --group-id "$SG" 2>/dev/null && \
    echo "SG borrado: $SG" || echo "INFO: SG $SG aún en uso, borrar manualmente"
done

# 6) Subnets DB
for SUBNET in "$SUBNET_DB_A" "$SUBNET_DB_B" "$SUBNET_DB_C"; do
  aws ec2 delete-subnet --subnet-id "$SUBNET" 2>/dev/null && \
    echo "Subnet borrada: $SUBNET" || true
done

echo "=== v2 limpiado. Recursos v1 intactos. ==="
