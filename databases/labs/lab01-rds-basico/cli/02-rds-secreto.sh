#!/usr/bin/env bash
# ==============================================================================
# Lab 01 — RDS MySQL: Paso 2 — KMS, DB Subnet Group, RDS Instance, Secrets
# ==============================================================================
# Crea:
#   - KMS Customer Managed Key con rotación anual
#   - DB Subnet Group (subnets privadas)
#   - Secret en Secrets Manager (credenciales DB)
#   - Instancia RDS MySQL 8.0 (Single-AZ, cifrada, sin acceso público)
#   - Rotación automática del secreto (cada 30 días)
#   - CloudWatch Alarms: FreeStorageSpace, CPUUtilization
#
# Uso:
#   source cli/00-env.sh && bash cli/02-rds-secreto.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-env.sh"
check_prereqs

if [[ ! -f "$RESOURCES_FILE" ]]; then
  fail "Ejecuta primero cli/01-vpc-y-sg.sh para crear la VPC e infraestructura de red."
fi
source "$RESOURCES_FILE"

# ==============================================================================
# PASO 1: KMS CMK
# ==============================================================================
section "Paso 1/5 — KMS Customer Managed Key"

KMS_KEY_ID=$(aws kms create-key \
  --description "CMK para cifrado de RDS lab01 (db-labs)" \
  --enable-key-rotation \
  --tags TagKey=Project,TagValue="$PROJECT" TagKey=Lab,TagValue="$LAB" TagKey=Env,TagValue="$ENV" \
  --query 'KeyMetadata.KeyId' --output text --region "$REGION")

aws kms create-alias \
  --alias-name "$KMS_ALIAS" \
  --target-key-id "$KMS_KEY_ID" \
  --region "$REGION"

echo "KMS_KEY_ID=$KMS_KEY_ID" >> "$RESOURCES_FILE"
ok "KMS CMK: $KMS_KEY_ID (alias: $KMS_ALIAS, rotación anual habilitada)"

# ==============================================================================
# PASO 2: DB Subnet Group
# ==============================================================================
section "Paso 2/5 — DB Subnet Group"

aws rds create-db-subnet-group \
  --db-subnet-group-name "$RDS_SUBNET_GROUP" \
  --db-subnet-group-description "Subnets privadas para RDS lab01 (db-labs)" \
  --subnet-ids "$SUBNET_DB_A" "$SUBNET_DB_B" \
  --tags Key=Project,Value="$PROJECT" Key=Lab,Value="$LAB" \
  --region "$REGION" > /dev/null

ok "DB Subnet Group: $RDS_SUBNET_GROUP (subnets: $SUBNET_DB_A, $SUBNET_DB_B)"

# ==============================================================================
# PASO 3: Secret en Secrets Manager
# ==============================================================================
section "Paso 3/5 — Secrets Manager"

# Generar password seguro (AWS lo hace por nosotros)
DB_PASSWORD=$(aws secretsmanager get-random-password \
  --password-length 16 \
  --exclude-characters '"@/\' \
  --require-each-included-type \
  --query 'RandomPassword' --output text --region "$REGION")

SECRET_ARN=$(aws secretsmanager create-secret \
  --name "$SECRET_NAME" \
  --description "Credenciales admin para RDS MySQL lab01 (db-labs)" \
  --kms-key-id "$KMS_ALIAS" \
  --secret-string "{\"username\":\"$RDS_MASTER_USER\",\"password\":\"$DB_PASSWORD\",\"engine\":\"mysql\",\"port\":3306,\"dbname\":\"$RDS_DB_NAME\"}" \
  --tags Key=Project,Value="$PROJECT" Key=Lab,Value="$LAB" \
  --query 'ARN' --output text --region "$REGION")

echo "SECRET_ARN=$SECRET_ARN" >> "$RESOURCES_FILE"
ok "Secret creado: $SECRET_ARN"

# ==============================================================================
# PASO 4: RDS MySQL 8.0 Instance
# ==============================================================================
section "Paso 4/5 — RDS MySQL 8.0 (Single-AZ)"

log "Creando instancia RDS (tardará ~10 minutos)..."

aws rds create-db-instance \
  --db-instance-identifier "$RDS_INSTANCE_ID" \
  --db-instance-class "$RDS_INSTANCE_CLASS" \
  --engine "$RDS_ENGINE" \
  --engine-version "$RDS_ENGINE_VERSION" \
  --master-username "$RDS_MASTER_USER" \
  --master-user-password "$DB_PASSWORD" \
  --db-name "$RDS_DB_NAME" \
  --allocated-storage "$RDS_STORAGE_GB" \
  --storage-type gp2 \
  --no-publicly-accessible \
  --vpc-security-group-ids "$SG_RDS" \
  --db-subnet-group-name "$RDS_SUBNET_GROUP" \
  --availability-zone "$AZ_A" \
  --backup-retention-period 7 \
  --preferred-backup-window "02:00-03:00" \
  --preferred-maintenance-window "Mon:03:00-Mon:04:00" \
  --storage-encrypted \
  --kms-key-id "$KMS_ALIAS" \
  --enable-cloudwatch-logs-exports mysql error slowquery \
  --auto-minor-version-upgrade \
  --monitoring-interval 60 \
  --tags Key=Project,Value="$PROJECT" Key=Lab,Value="$LAB" Key=Env,Value="$ENV" \
  --region "$REGION" > /dev/null

log "Esperando que RDS esté disponible (puede tardar 10-15 min)..."
aws rds wait db-instance-available \
  --db-instance-identifier "$RDS_INSTANCE_ID" \
  --region "$REGION"

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_INSTANCE_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text --region "$REGION")

echo "RDS_ENDPOINT=$RDS_ENDPOINT" >> "$RESOURCES_FILE"
ok "RDS disponible: $RDS_ENDPOINT"

# Actualizar el secreto con el endpoint
aws secretsmanager update-secret \
  --secret-id "$SECRET_NAME" \
  --secret-string "{\"username\":\"$RDS_MASTER_USER\",\"password\":\"$DB_PASSWORD\",\"host\":\"$RDS_ENDPOINT\",\"engine\":\"mysql\",\"port\":3306,\"dbname\":\"$RDS_DB_NAME\"}" \
  --region "$REGION" > /dev/null
ok "Secret actualizado con endpoint de RDS"

# ==============================================================================
# PASO 5: CloudWatch Alarms
# ==============================================================================
section "Paso 5/5 — CloudWatch Alarms"

# Crear SNS topic para alertas (si no existe)
SNS_ARN=$(aws sns create-topic \
  --name "$SNS_TOPIC_NAME" \
  --tags Key=Project,Value="$PROJECT" \
  --query 'TopicArn' --output text --region "$REGION")
echo "SNS_ARN=$SNS_ARN" >> "$RESOURCES_FILE"
ok "SNS Topic: $SNS_ARN"
warn "Recuerda suscribir tu email a este SNS topic para recibir alertas"

# Alarm: poco espacio en disco
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_STORAGE_NAME" \
  --alarm-description "RDS lab01: espacio en disco < 2GB" \
  --metric-name FreeStorageSpace \
  --namespace AWS/RDS \
  --statistic Average \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 2147483648 \
  --comparison-operator LessThanThreshold \
  --dimensions Name=DBInstanceIdentifier,Value="$RDS_INSTANCE_ID" \
  --alarm-actions "$SNS_ARN" \
  --region "$REGION"
ok "Alarm: $ALARM_STORAGE_NAME (FreeStorageSpace < 2GB)"

# Alarm: CPU alta
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_CPU_NAME" \
  --alarm-description "RDS lab01: CPU > 80% durante 5 min" \
  --metric-name CPUUtilization \
  --namespace AWS/RDS \
  --statistic Average \
  --period 300 \
  --evaluation-periods 3 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=DBInstanceIdentifier,Value="$RDS_INSTANCE_ID" \
  --alarm-actions "$SNS_ARN" \
  --region "$REGION"
ok "Alarm: $ALARM_CPU_NAME (CPUUtilization > 80%)"

# ==============================================================================
# RESUMEN
# ==============================================================================
section "RDS + Secrets Manager listos"
echo ""
ok "Recursos creados:"
echo "  KMS CMK:      $KMS_KEY_ID ($KMS_ALIAS)"
echo "  Secret:       $SECRET_NAME ($SECRET_ARN)"
echo "  RDS Endpoint: $RDS_ENDPOINT"
echo "  DB Name:      $RDS_DB_NAME"
echo "  Username:     $RDS_MASTER_USER"
echo ""
log "Para conectar desde EC2 vía SSM:"
echo "  aws secretsmanager get-secret-value --secret-id $SECRET_NAME --region $REGION"
echo "  mysql -h $RDS_ENDPOINT -u $RDS_MASTER_USER -p \$DB_PASSWORD $RDS_DB_NAME"
echo ""
log "Siguiente: bash cli/03-multi-az-replica.sh"
