#!/usr/bin/env bash
# =============================================================================
# Lab05 — Script 99: Cleanup completo (orden inverso de dependencias)
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         LAB05 — CLEANUP COMPLETO DEL STACK              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Se eliminarán TODOS los recursos creados por lab05:"
echo "  Lambda, DynamoDB, SNS, Aurora (reader+writer+cluster),"
echo "  RDS Proxy, Redis, VPC Endpoints, NAT GW, VPC..."
echo ""
read -rp "  ¿Continuar? (escribe 'si' para confirmar): " CONFIRM
[[ "$CONFIRM" != "si" ]] && { log "Cancelado."; exit 0; }

# ─── LAMBDA ───────────────────────────────────────────────────────────────────
section "Lambda — Event Source Mapping"
ESM_UUID=$(aws lambda list-event-source-mappings \
  --function-name "$LAMBDA_FUNCTION" \
  --query 'EventSourceMappings[0].UUID' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
if [[ "$ESM_UUID" != "None" && "$ESM_UUID" != "" ]]; then
  aws lambda delete-event-source-mapping --uuid "$ESM_UUID" --region "$AWS_REGION" 2>/dev/null && \
    ok "Event Source Mapping eliminado" || ok "ESM no encontrado"
fi

section "Lambda — Function"
aws lambda delete-function --function-name "$LAMBDA_FUNCTION" \
  --region "$AWS_REGION" 2>/dev/null && ok "Lambda $LAMBDA_FUNCTION eliminada" || ok "Lambda no encontrada"

section "Lambda — IAM Role"
aws iam detach-role-policy --role-name "$LAMBDA_ROLE" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole" 2>/dev/null || true
aws iam delete-role-policy --role-name "$LAMBDA_ROLE" \
  --policy-name AllowSNSPublish 2>/dev/null || true
aws iam delete-role --role-name "$LAMBDA_ROLE" 2>/dev/null && \
  ok "Lambda IAM Role eliminado" || ok "Lambda role no encontrado"

# ─── SNS ──────────────────────────────────────────────────────────────────────
section "SNS Topic"
if [[ -n "${SNS_TOPIC_ARN:-}" ]]; then
  aws sns delete-topic --topic-arn "$SNS_TOPIC_ARN" --region "$AWS_REGION" 2>/dev/null && \
    ok "SNS Topic eliminado" || ok "SNS Topic no encontrado"
fi

# ─── DYNAMODB ─────────────────────────────────────────────────────────────────
section "DynamoDB Table"
aws dynamodb delete-table --table-name "$DYNAMO_TABLE" \
  --region "$AWS_REGION" 2>/dev/null && ok "Tabla $DYNAMO_TABLE eliminada" || ok "Tabla no encontrada"

# ─── RDS PROXY ────────────────────────────────────────────────────────────────
section "RDS Proxy"
aws rds delete-db-proxy --db-proxy-name "$AURORA_PROXY_ID" \
  --region "$AWS_REGION" 2>/dev/null && log "RDS Proxy eliminándose..." || ok "RDS Proxy no encontrado"

if aws rds describe-db-proxies --db-proxy-name "$AURORA_PROXY_ID" --region "$AWS_REGION" &>/dev/null; then
  log "Esperando eliminación del Proxy (~3 min)..."
  for i in $(seq 1 36); do
    STATUS=$(aws rds describe-db-proxies --db-proxy-name "$AURORA_PROXY_ID" \
      --query 'DBProxies[0].Status' --output text --region "$AWS_REGION" 2>/dev/null || echo "deleted")
    [[ "$STATUS" == "deleted" || "$STATUS" == "None" || "$STATUS" == "" ]] && break
    sleep 5
  done
  ok "RDS Proxy eliminado"
fi

section "RDS Proxy — IAM Role"
aws iam delete-role-policy --role-name "$PROXY_ROLE" \
  --policy-name AllowSecretsManager 2>/dev/null || true
aws iam delete-role --role-name "$PROXY_ROLE" 2>/dev/null && \
  ok "Proxy IAM Role eliminado" || ok "Proxy role no encontrado"

# ─── AURORA ───────────────────────────────────────────────────────────────────
section "Aurora Reader instance"
aws rds delete-db-instance \
  --db-instance-identifier "$AURORA_READER_ID" \
  --skip-final-snapshot \
  --region "$AWS_REGION" 2>/dev/null && log "Reader eliminándose..." || ok "Reader no encontrado"

section "Aurora Writer instance"
aws rds delete-db-instance \
  --db-instance-identifier "$AURORA_WRITER_ID" \
  --skip-final-snapshot \
  --region "$AWS_REGION" 2>/dev/null && log "Writer eliminándose..." || ok "Writer no encontrado"

log "Esperando eliminación de instancias Aurora (~8 min)..."
aws rds wait db-instance-deleted \
  --db-instance-identifier "$AURORA_READER_ID" --region "$AWS_REGION" 2>/dev/null || true
aws rds wait db-instance-deleted \
  --db-instance-identifier "$AURORA_WRITER_ID" --region "$AWS_REGION" 2>/dev/null || true
ok "Instancias Aurora eliminadas"

section "Aurora Cluster"
aws rds delete-db-cluster \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --skip-final-snapshot \
  --region "$AWS_REGION" 2>/dev/null && log "Cluster eliminándose..." || ok "Cluster no encontrado"
aws rds wait db-cluster-deleted \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" --region "$AWS_REGION" 2>/dev/null || true
ok "Cluster Aurora eliminado"

section "DB Subnet Groups"
aws rds delete-db-subnet-group --db-subnet-group-name "$AURORA_SUBNET_GROUP" \
  --region "$AWS_REGION" 2>/dev/null && ok "DB Subnet Group Aurora eliminado" || ok "No encontrado"

section "Secrets Manager"
aws secretsmanager delete-secret \
  --secret-id "$AURORA_SECRET_ID" \
  --force-delete-without-recovery \
  --region "$AWS_REGION" 2>/dev/null && ok "Secret $AURORA_SECRET_ID eliminado" || ok "Secret no encontrado"

# ─── REDIS ────────────────────────────────────────────────────────────────────
section "ElastiCache Redis"
aws elasticache delete-replication-group \
  --replication-group-id "$REDIS_CLUSTER_ID" \
  --region "$AWS_REGION" 2>/dev/null && log "Redis eliminándose..." || ok "Redis no encontrado"

if aws elasticache describe-replication-groups \
    --replication-group-id "$REDIS_CLUSTER_ID" --region "$AWS_REGION" &>/dev/null; then
  log "Esperando eliminación de Redis (~5 min)..."
  aws elasticache wait replication-group-deleted \
    --replication-group-id "$REDIS_CLUSTER_ID" --region "$AWS_REGION" 2>/dev/null || true
fi
ok "Redis eliminado"

section "Cache Subnet Group"
aws elasticache delete-cache-subnet-group \
  --cache-subnet-group-name "$REDIS_SUBNET_GROUP" \
  --region "$AWS_REGION" 2>/dev/null && ok "Cache Subnet Group eliminado" || ok "No encontrado"

# ─── VPC ENDPOINTS ────────────────────────────────────────────────────────────
section "VPC Endpoints"
ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID:-}" "Name=tag:Lab,Values=$LAB" \
  --query 'VpcEndpoints[*].VpcEndpointId' --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [[ -n "$ENDPOINT_IDS" ]]; then
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ENDPOINT_IDS \
    --region "$AWS_REGION" 2>/dev/null && ok "VPC Endpoints eliminados: $ENDPOINT_IDS" || true
else
  ok "No se encontraron VPC Endpoints del lab"
fi
sleep 10

# ─── NAT GATEWAY + EIP ────────────────────────────────────────────────────────
section "NAT Gateway"
NAT_ID="${NAT_GW_ID:-}"
if [[ -n "$NAT_ID" ]]; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" \
    --region "$AWS_REGION" 2>/dev/null && log "NAT GW $NAT_ID eliminándose..." || ok "NAT GW no encontrado"
  log "Esperando eliminación del NAT GW..."
  for i in $(seq 1 30); do
    STATUS=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" \
      --query 'NatGateways[0].State' --output text --region "$AWS_REGION" 2>/dev/null || echo "deleted")
    [[ "$STATUS" == "deleted" ]] && break
    sleep 10
  done
  ok "NAT Gateway eliminado"
fi

section "Elastic IP"
EIP_ALLOC="${EIP_ALLOC_ID:-}"
if [[ -n "$EIP_ALLOC" ]]; then
  aws ec2 release-address --allocation-id "$EIP_ALLOC" \
    --region "$AWS_REGION" 2>/dev/null && ok "EIP liberada" || ok "EIP no encontrada"
fi

# ─── EC2 ──────────────────────────────────────────────────────────────────────
section "EC2 Instance (bastion)"
EC2="${EC2_ID:-}"
if [[ -n "$EC2" ]]; then
  aws ec2 terminate-instances --instance-ids "$EC2" \
    --region "$AWS_REGION" 2>/dev/null && log "EC2 $EC2 terminando..." || ok "EC2 no encontrada"
  aws ec2 wait instance-terminated --instance-ids "$EC2" \
    --region "$AWS_REGION" 2>/dev/null || true
  ok "EC2 terminada"
fi

# ─── IGW ──────────────────────────────────────────────────────────────────────
section "Internet Gateway"
IGW="${IGW_ID:-}"
if [[ -n "$IGW" && -n "${VPC_ID:-}" ]]; then
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" \
    --vpc-id "$VPC_ID" --region "$AWS_REGION" 2>/dev/null && ok "IGW desconectado" || ok "IGW no encontrado"
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" \
    --region "$AWS_REGION" 2>/dev/null && ok "IGW eliminado" || ok "No encontrado"
fi

# ─── ROUTE TABLES ─────────────────────────────────────────────────────────────
section "Route Tables"
for RT_VAR in RT_PUBLIC_ID RT_PRIVATE_APP_ID RT_PRIVATE_DB_ID; do
  RT="${!RT_VAR:-}"
  if [[ -n "$RT" ]]; then
    aws ec2 delete-route-table --route-table-id "$RT" \
      --region "$AWS_REGION" 2>/dev/null && ok "Route Table $RT eliminada" || ok "RT $RT no encontrada o es la principal"
  fi
done

# ─── SUBNETS ──────────────────────────────────────────────────────────────────
section "Subnets"
for SN_VAR in SUBNET_PUBLIC_A SUBNET_PUBLIC_B SUBNET_APP_A SUBNET_APP_B SUBNET_DB_A SUBNET_DB_B; do
  SN="${!SN_VAR:-}"
  if [[ -n "$SN" ]]; then
    aws ec2 delete-subnet --subnet-id "$SN" \
      --region "$AWS_REGION" 2>/dev/null && ok "Subnet $SN eliminada" || ok "Subnet $SN no encontrada"
  fi
done

# ─── SECURITY GROUPS ──────────────────────────────────────────────────────────
section "Security Groups"
for SG_VAR in SG_REDIS SG_AURORA SG_APP SG_ALB; do
  SG="${!SG_VAR:-}"
  if [[ -n "$SG" ]]; then
    aws ec2 delete-security-group --group-id "$SG" \
      --region "$AWS_REGION" 2>/dev/null && ok "SG $SG eliminado" || ok "SG $SG no encontrado o tiene dependencias"
  fi
done

# ─── VPC ──────────────────────────────────────────────────────────────────────
section "VPC"
if [[ -n "${VPC_ID:-}" ]]; then
  aws ec2 delete-vpc --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" 2>/dev/null && ok "VPC $VPC_ID eliminada" || \
    warn "VPC $VPC_ID no eliminada — puede quedar recursos dependientes"
fi

# ─── IAM EC2 ROLE ─────────────────────────────────────────────────────────────
section "IAM Role EC2"
aws iam remove-role-from-instance-profile \
  --instance-profile-name "${EC2_ROLE_NAME:-ec2-lab05-role}-profile" \
  --role-name "${EC2_ROLE_NAME:-ec2-lab05-role}" 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name "${EC2_ROLE_NAME:-ec2-lab05-role}-profile" 2>/dev/null || true
for POLICY in AmazonSSMManagedInstanceCore AmazonDynamoDBReadOnlyAccess SecretsManagerReadWrite; do
  aws iam detach-role-policy \
    --role-name "${EC2_ROLE_NAME:-ec2-lab05-role}" \
    --policy-arn "arn:aws:iam::aws:policy/$POLICY" 2>/dev/null || true
done
aws iam delete-role --role-name "${EC2_ROLE_NAME:-ec2-lab05-role}" 2>/dev/null && \
  ok "EC2 IAM Role eliminado" || ok "EC2 role no encontrado"

# ─── LIMPIAR RESOURCES FILE ───────────────────────────────────────────────────
section "Archivo de recursos"
RESOURCES_FILE="${SCRIPT_DIR}/.lab05-resources"
if [[ -f "$RESOURCES_FILE" ]]; then
  rm -f "$RESOURCES_FILE"
  ok "Archivo $RESOURCES_FILE eliminado"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              CLEANUP LAB05 COMPLETADO                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
ok "Todos los recursos de lab05 han sido eliminados"
echo "  Revisa la consola AWS para confirmar que no queden recursos."
echo "  Si algo falló, ejecuta de nuevo o elimina manualmente desde la consola."
echo ""
