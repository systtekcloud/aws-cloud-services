# Cleanup — Lab05 3-Tier Full Stack

> **Coste si olvidas limpiar:** ~0.24 USD/hora = ~170 USD/mes. Ejecuta SIEMPRE al terminar.

## Orden de eliminación

```
Lambda ESM → Lambda → SNS → DynamoDB → RDS Proxy → Aurora (reader+writer+cluster)
→ DB Subnet Groups → Redis → Cache Subnet Group → EC2 → VPC Endpoints
→ NAT GW → EIP → IGW → Route Tables → Subnets → SGs → VPC
→ IAM Roles → Secrets Manager → KMS (schedule 7d)
```

---

## CLI — Cleanup completo

```bash
#!/usr/bin/env bash
# 99-cleanup.sh — Lab05 3-Tier Full Stack

set -euo pipefail
REGION="eu-west-1"

echo "  Escribe 'CLEANUP LAB05' para confirmar:"
read -r C
[[ "$C" != "CLEANUP LAB05" ]] && { echo "Cancelado."; exit 0; }

# Obtener IDs guardados
source ./cli/00-resources-lab05.env 2>/dev/null || true

safe() { "$@" 2>/dev/null && echo "  ✓ $1" || echo "  - $1 (no encontrado)"; }

echo "[1/14] Lambda Event Source Mapping"
ESM=$(aws lambda list-event-source-mappings \
  --function-name ecommerce-catalog-stream \
  --query 'EventSourceMappings[0].UUID' --output text --region $REGION 2>/dev/null || echo "")
[[ -n "$ESM" && "$ESM" != "None" ]] && safe aws lambda delete-event-source-mapping --uuid $ESM --region $REGION

echo "[2/14] Lambda Functions"
safe aws lambda delete-function --function-name ecommerce-catalog-stream --region $REGION

echo "[3/14] SNS Topic"
SNS_ARN=$(aws sns list-topics --query "Topics[?contains(TopicArn,'ecommerce-pedidos-notif')].TopicArn|[0]" \
  --output text --region $REGION 2>/dev/null || echo "")
[[ -n "$SNS_ARN" && "$SNS_ARN" != "None" ]] && safe aws sns delete-topic --topic-arn $SNS_ARN --region $REGION

echo "[4/14] DynamoDB Table"
safe aws dynamodb delete-table --table-name ecommerce-catalog --region $REGION

echo "[5/14] RDS Proxy (deregistrar targets primero)"
safe aws rds deregister-db-proxy-targets \
  --db-proxy-name aurora-lab05-proxy \
  --db-cluster-identifiers aurora-lab05 --region $REGION
sleep 10
safe aws rds delete-db-proxy --db-proxy-name aurora-lab05-proxy --region $REGION
aws rds wait db-proxy-deleted --db-proxy-name aurora-lab05-proxy --region $REGION 2>/dev/null || true

echo "[6/14] Aurora Reader Instance"
safe aws rds delete-db-instance \
  --db-instance-identifier aurora-lab05-reader \
  --skip-final-snapshot --region $REGION

echo "[7/14] Aurora Writer Instance"
safe aws rds modify-db-cluster \
  --db-cluster-identifier aurora-lab05 --no-deletion-protection --apply-immediately --region $REGION
safe aws rds delete-db-instance \
  --db-instance-identifier aurora-lab05-writer \
  --skip-final-snapshot --region $REGION

echo "  Esperando que las instancias Aurora terminen (~10 min)..."
for ID in aurora-lab05-writer aurora-lab05-reader; do
  while aws rds describe-db-instances --db-instance-identifier $ID --region $REGION &>/dev/null; do
    echo -n "."; sleep 15; done
done; echo ""

echo "[8/14] Aurora Cluster"
safe aws rds delete-db-cluster \
  --db-cluster-identifier aurora-lab05 \
  --skip-final-snapshot --region $REGION
while aws rds describe-db-clusters --db-cluster-identifier aurora-lab05 --region $REGION &>/dev/null; do
  echo -n "."; sleep 15; done; echo ""

echo "[9/14] DB Subnet Group"
safe aws rds delete-db-subnet-group --db-subnet-group-name aurora-lab05-subnetgroup --region $REGION

echo "[10/14] Redis Replication Group"
safe aws elasticache delete-replication-group \
  --replication-group-id redis-lab05 --no-retain-primary-cluster --region $REGION
aws elasticache wait replication-group-deleted --replication-group-id redis-lab05 --region $REGION 2>/dev/null || true

echo "[11/14] Cache Subnet Group"
safe aws elasticache delete-cache-subnet-group \
  --cache-subnet-group-name redis-lab05-subnetgroup --region $REGION

echo "[12/14] EC2 + VPC Endpoints"
[[ -n "${EC2_ID:-}" ]] && safe aws ec2 terminate-instances --instance-ids $EC2_ID --region $REGION

for EP_ID in ${VPC_ENDPOINT_IDS:-}; do
  safe aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EP_ID --region $REGION
done

echo "[13/14] NAT GW + EIP + IGW + Route Tables"
[[ -n "${NAT_GW_ID:-}" ]] && {
  safe aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW_ID --region $REGION
  echo "  Esperando NAT GW deletion (~60s)..."
  sleep 60
}
[[ -n "${EIP_ALLOC:-}" ]] && safe aws ec2 release-address --allocation-id $EIP_ALLOC --region $REGION
[[ -n "${IGW_ID:-}" ]] && {
  safe aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION
  safe aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION
}
for RT_ID in ${RT_IDS:-}; do
  safe aws ec2 delete-route-table --route-table-id $RT_ID --region $REGION
done

echo "[14/14] Subnets + SGs + VPC + IAM + Secrets"
for SN_ID in ${SUBNET_IDS:-}; do
  safe aws ec2 delete-subnet --subnet-id $SN_ID --region $REGION
done
for SG_ID in ${SG_IDS:-}; do
  safe aws ec2 delete-security-group --group-id $SG_ID --region $REGION
done
[[ -n "${VPC_ID:-}" ]] && safe aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION

# IAM Roles
for ROLE in lambda-catalog-stream-role rds-proxy-lab05-role ec2-app-lab05-role; do
  aws iam list-attached-role-policies --role-name $ROLE \
    --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null | \
    tr '\t' '\n' | while read PA; do
      aws iam detach-role-policy --role-name $ROLE --policy-arn $PA 2>/dev/null || true
    done
  safe aws iam delete-role-policy --role-name $ROLE --policy-name AllowSNSPublish 2>/dev/null || true
  safe aws iam delete-role-policy --role-name $ROLE --policy-name AllowSecretsManager 2>/dev/null || true
  safe aws iam delete-role --role-name $ROLE
done

# Secrets Manager
safe aws secretsmanager delete-secret \
  --secret-id lab05/aurora/admin \
  --force-delete-without-recovery --region $REGION

echo ""
echo "=== Cleanup Lab05 completado ==="
```

---

## Verificación post-cleanup

```bash
# Aurora
aws rds describe-db-clusters --db-cluster-identifier aurora-lab05 --region eu-west-1 2>&1 | grep -i "not found"
# Redis
aws elasticache describe-replication-groups --replication-group-id redis-lab05 --region eu-west-1 2>&1 | grep -i "not found"
# DynamoDB
aws dynamodb describe-table --table-name ecommerce-catalog --region eu-west-1 2>&1 | grep -i "ResourceNotFoundException"
```
