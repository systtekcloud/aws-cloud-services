#!/usr/bin/env bash
# =============================================================================
# Lab02 Aurora — Script 01: Crear Aurora MySQL Cluster (Writer + Reader)
# =============================================================================
# Prerequisito: source cli/00-env.sh (o tener la red del lab01 activa)
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

check_prereqs

# ---------------------------------------------------------------------------
section "PASO 1 — Obtener IDs de red (de lab01 o crear nuevos)"
# ---------------------------------------------------------------------------

# Intentar leer la VPC del lab01
if [[ -f "${SCRIPT_DIR}/../../../lab01-rds-basico/cli/00-resources.env" ]]; then
  source "${SCRIPT_DIR}/../../../lab01-rds-basico/cli/00-resources.env"
  log "Reutilizando red de lab01: VPC=$VPC_ID"
else
  # Si no hay lab01, buscar la VPC por CIDR
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=cidr,Values=$VPC_CIDR" "Name=tag:Project,Values=$PROJECT" \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

  if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
    fail "No se encontró la VPC $VPC_CIDR. Ejecuta primero lab01/cli/01-vpc-y-sg.sh"
  fi
  log "VPC encontrada: $VPC_ID"
fi

# Subnets privadas
SUBNET_PRIVATE_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=cidrBlock,Values=$SUBNET_PRIVATE_A_CIDR" \
  --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")

SUBNET_PRIVATE_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=cidrBlock,Values=$SUBNET_PRIVATE_B_CIDR" \
  --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")

[[ "$SUBNET_PRIVATE_A" == "None" ]] && fail "Subnet privada A no encontrada ($SUBNET_PRIVATE_A_CIDR)"
[[ "$SUBNET_PRIVATE_B" == "None" ]] && fail "Subnet privada B no encontrada ($SUBNET_PRIVATE_B_CIDR)"

ok "Subnet A: $SUBNET_PRIVATE_A ($AZ_A)"
ok "Subnet B: $SUBNET_PRIVATE_B ($AZ_B)"

# SG de la EC2 (para la regla inbound de Aurora)
SG_APP=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=sg-app-db-labs" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$SG_APP" == "None" ]]; then
  warn "SG sg-app-db-labs no encontrado. Asegúrate de que el lab01 está desplegado."
fi

save_resource "VPC_ID" "$VPC_ID"
save_resource "SUBNET_PRIVATE_A" "$SUBNET_PRIVATE_A"
save_resource "SUBNET_PRIVATE_B" "$SUBNET_PRIVATE_B"
save_resource "SG_APP" "$SG_APP"

# ---------------------------------------------------------------------------
section "PASO 2 — Security Group para Aurora"
# ---------------------------------------------------------------------------

# Verificar si ya existe
SG_AURORA=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=sg-aurora-db-labs" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$SG_AURORA" == "None" || -z "$SG_AURORA" ]]; then
  SG_AURORA=$(aws ec2 create-security-group \
    --group-name sg-aurora-db-labs \
    --description "Aurora MySQL lab02 - inbound from sg-app only" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT},{Key=Lab,Value=$LAB},{Key=ManagedBy,Value=cli}]" \
    --query 'GroupId' --output text --region "$AWS_REGION")
  ok "SG Aurora creado: $SG_AURORA"

  # Regla inbound: solo desde sg-app-db-labs
  if [[ "$SG_APP" != "None" ]]; then
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_AURORA" \
      --protocol tcp --port 3306 \
      --source-group "$SG_APP" \
      --region "$AWS_REGION"
    ok "Regla inbound 3306 desde $SG_APP añadida"
  else
    warn "SG_APP no encontrado, añade manualmente la regla inbound 3306"
  fi
else
  ok "SG Aurora ya existe: $SG_AURORA"
fi

save_resource "SG_AURORA" "$SG_AURORA"

# ---------------------------------------------------------------------------
section "PASO 3 — DB Subnet Group"
# ---------------------------------------------------------------------------

SUBNET_GROUP_EXISTS=$(aws rds describe-db-subnet-groups \
  --db-subnet-group-name "$AURORA_SUBNET_GROUP" \
  --region "$AWS_REGION" 2>/dev/null | jq -r '.DBSubnetGroups[0].DBSubnetGroupName' || echo "None")

if [[ "$SUBNET_GROUP_EXISTS" == "None" || "$SUBNET_GROUP_EXISTS" == "null" ]]; then
  aws rds create-db-subnet-group \
    --db-subnet-group-name "$AURORA_SUBNET_GROUP" \
    --db-subnet-group-description "Aurora subnets for lab02 - private subnets only" \
    --subnet-ids "$SUBNET_PRIVATE_A" "$SUBNET_PRIVATE_B" \
    --tags "Key=Project,Value=$PROJECT" "Key=Lab,Value=$LAB" "Key=ManagedBy,Value=cli" \
    --region "$AWS_REGION"
  ok "DB Subnet Group creado: $AURORA_SUBNET_GROUP"
else
  ok "DB Subnet Group ya existe: $AURORA_SUBNET_GROUP"
fi

# ---------------------------------------------------------------------------
section "PASO 4 — Secreto en Secrets Manager"
# ---------------------------------------------------------------------------

SECRET_EXISTS=$(aws secretsmanager describe-secret \
  --secret-id "$AURORA_SECRET_ID" \
  --region "$AWS_REGION" 2>/dev/null | jq -r '.ARN' || echo "None")

if [[ "$SECRET_EXISTS" == "None" || -z "$SECRET_EXISTS" ]]; then
  AURORA_PASSWORD=$(aws secretsmanager get-random-password \
    --password-length 20 \
    --exclude-punctuation \
    --query 'RandomPassword' --output text --region "$AWS_REGION")

  SECRET_ARN=$(aws secretsmanager create-secret \
    --name "$AURORA_SECRET_ID" \
    --description "Aurora MySQL admin credentials for lab02" \
    --secret-string "{\"username\":\"${AURORA_MASTER_USER}\",\"password\":\"${AURORA_PASSWORD}\"}" \
    --tags "Key=Project,Value=$PROJECT" "Key=Lab,Value=$LAB" "Key=ManagedBy,Value=cli" \
    --query 'ARN' --output text --region "$AWS_REGION")

  ok "Secret creado: $SECRET_ARN"
else
  SECRET_ARN="$SECRET_EXISTS"
  ok "Secret ya existe: $SECRET_ARN"
  AURORA_PASSWORD=$(aws secretsmanager get-secret-value \
    --secret-id "$AURORA_SECRET_ID" \
    --query 'SecretString' --output text --region "$AWS_REGION" | jq -r '.password')
fi

save_resource "SECRET_AURORA_ARN" "$SECRET_ARN"

# ---------------------------------------------------------------------------
section "PASO 5 — Crear el DB Cluster Aurora"
# ---------------------------------------------------------------------------

CLUSTER_EXISTS=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --region "$AWS_REGION" 2>/dev/null | jq -r '.DBClusters[0].Status' || echo "None")

if [[ "$CLUSTER_EXISTS" == "None" || -z "$CLUSTER_EXISTS" ]]; then
  log "Creando Aurora cluster $AURORA_CLUSTER_ID..."

  aws rds create-db-cluster \
    --db-cluster-identifier "$AURORA_CLUSTER_ID" \
    --engine "$AURORA_ENGINE" \
    --engine-version "$AURORA_ENGINE_VERSION" \
    --master-username "$AURORA_MASTER_USER" \
    --master-user-password "$AURORA_PASSWORD" \
    --db-subnet-group-name "$AURORA_SUBNET_GROUP" \
    --vpc-security-group-ids "$SG_AURORA" \
    --database-name "$AURORA_DB_NAME" \
    --backup-retention-period 1 \
    --no-publicly-accessible \
    --storage-encrypted \
    --backtrack-window 3600 \
    --deletion-protection \
    --tags "Key=Project,Value=$PROJECT" "Key=Lab,Value=$LAB" \
           "Key=ManagedBy,Value=cli" "Key=Env,Value=$ENV" \
    --region "$AWS_REGION"

  ok "Cluster creado (sin instancias aún)"
else
  ok "Cluster ya existe con estado: $CLUSTER_EXISTS"
fi

# ---------------------------------------------------------------------------
section "PASO 6 — Crear Writer Instance"
# ---------------------------------------------------------------------------

WRITER_EXISTS=$(aws rds describe-db-instances \
  --db-instance-identifier "$AURORA_WRITER_ID" \
  --region "$AWS_REGION" 2>/dev/null | jq -r '.DBInstances[0].DBInstanceStatus' || echo "None")

if [[ "$WRITER_EXISTS" == "None" ]]; then
  log "Creando Writer instance..."
  aws rds create-db-instance \
    --db-instance-identifier "$AURORA_WRITER_ID" \
    --db-cluster-identifier "$AURORA_CLUSTER_ID" \
    --engine "$AURORA_ENGINE" \
    --db-instance-class "$AURORA_INSTANCE_CLASS" \
    --availability-zone "$AZ_A" \
    --no-publicly-accessible \
    --tags "Key=Project,Value=$PROJECT" "Key=Lab,Value=$LAB" \
           "Key=ManagedBy,Value=cli" "Key=Role,Value=writer" \
    --region "$AWS_REGION"

  log "Esperando Writer instance (puede tardar 5-8 min)..."
  aws rds wait db-instance-available \
    --db-instance-identifier "$AURORA_WRITER_ID" \
    --region "$AWS_REGION"
  ok "Writer instance disponible: $AURORA_WRITER_ID"
else
  ok "Writer ya existe con estado: $WRITER_EXISTS"
fi

# ---------------------------------------------------------------------------
section "PASO 7 — Crear Reader Instance"
# ---------------------------------------------------------------------------

READER_EXISTS=$(aws rds describe-db-instances \
  --db-instance-identifier "$AURORA_READER_ID" \
  --region "$AWS_REGION" 2>/dev/null | jq -r '.DBInstances[0].DBInstanceStatus' || echo "None")

if [[ "$READER_EXISTS" == "None" ]]; then
  log "Creando Reader instance..."
  aws rds create-db-instance \
    --db-instance-identifier "$AURORA_READER_ID" \
    --db-cluster-identifier "$AURORA_CLUSTER_ID" \
    --engine "$AURORA_ENGINE" \
    --db-instance-class "$AURORA_INSTANCE_CLASS" \
    --availability-zone "$AZ_B" \
    --no-publicly-accessible \
    --tags "Key=Project,Value=$PROJECT" "Key=Lab,Value=$LAB" \
           "Key=ManagedBy,Value=cli" "Key=Role,Value=reader" \
    --region "$AWS_REGION"

  log "Esperando Reader instance (~5 min)..."
  aws rds wait db-instance-available \
    --db-instance-identifier "$AURORA_READER_ID" \
    --region "$AWS_REGION"
  ok "Reader instance disponible: $AURORA_READER_ID"
else
  ok "Reader ya existe con estado: $READER_EXISTS"
fi

# ---------------------------------------------------------------------------
section "PASO 8 — Actualizar secret con endpoints"
# ---------------------------------------------------------------------------

CLUSTER_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --query 'DBClusters[0].Endpoint' --output text --region "$AWS_REGION")

READER_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$AURORA_CLUSTER_ID" \
  --query 'DBClusters[0].ReaderEndpoint' --output text --region "$AWS_REGION")

aws secretsmanager update-secret \
  --secret-id "$AURORA_SECRET_ID" \
  --secret-string "{
    \"username\": \"${AURORA_MASTER_USER}\",
    \"password\": \"${AURORA_PASSWORD}\",
    \"writer_host\": \"${CLUSTER_ENDPOINT}\",
    \"reader_host\": \"${READER_ENDPOINT}\",
    \"port\": 3306,
    \"dbname\": \"${AURORA_DB_NAME}\"
  }" \
  --region "$AWS_REGION"

save_resource "CLUSTER_ENDPOINT" "$CLUSTER_ENDPOINT"
save_resource "READER_ENDPOINT" "$READER_ENDPOINT"

# ---------------------------------------------------------------------------
section "RESUMEN FINAL"
# ---------------------------------------------------------------------------

echo ""
echo "  Aurora Cluster:    $AURORA_CLUSTER_ID"
echo "  Writer endpoint:   $CLUSTER_ENDPOINT"
echo "  Reader endpoint:   $READER_ENDPOINT"
echo "  Puerto:            3306"
echo "  DB:                $AURORA_DB_NAME"
echo "  Secret:            $AURORA_SECRET_ID"
echo ""
echo "  Conectar desde EC2 (SSM):"
echo "    PASS=\$(aws secretsmanager get-secret-value --secret-id $AURORA_SECRET_ID --query SecretString --output text | jq -r '.password')"
echo "    mysql -h $CLUSTER_ENDPOINT -u admin -p\"\$PASS\" $AURORA_DB_NAME"
echo ""
ok "Lab02 Aurora Cluster — Setup completo"
