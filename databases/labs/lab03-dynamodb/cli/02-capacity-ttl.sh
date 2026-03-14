#!/usr/bin/env bash
# =============================================================================
# Lab03 DynamoDB — Script 02: Capacity modes + CloudWatch alarms
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

check_prereqs

# ---------------------------------------------------------------------------
section "PASO 1 — Mostrar estado actual de la tabla"
# ---------------------------------------------------------------------------

log "Estado actual de la tabla:"
aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --query 'Table.{Status:TableStatus,BillingMode:BillingModeSummary.BillingMode,ItemCount:ItemCount}' \
  --output table --region "$AWS_REGION"

# ---------------------------------------------------------------------------
section "PASO 2 — Probar modo Provisioned (demostración)"
# ---------------------------------------------------------------------------

echo ""
echo "  Demo: cambiar brevemente a Provisioned para ver los parámetros."
echo "  Luego volvemos a On-Demand (más económico para labs)."
echo ""

aws dynamodb update-table \
  --table-name "$DYNAMO_TABLE" \
  --billing-mode PROVISIONED \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region "$AWS_REGION"

log "Esperando que la tabla vuelva a ACTIVE..."
aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$AWS_REGION"
ok "Tabla en modo Provisioned (5 RCU / 5 WCU)"

# Configurar Application Autoscaling para Read
log "Configurando Application Autoscaling para Read..."
aws application-autoscaling register-scalable-target \
  --service-namespace dynamodb \
  --resource-id "table/${DYNAMO_TABLE}" \
  --scalable-dimension "dynamodb:table:ReadCapacityUnits" \
  --min-capacity 1 --max-capacity 10 \
  --region "$AWS_REGION"

aws application-autoscaling put-scaling-policy \
  --service-namespace dynamodb \
  --resource-id "table/${DYNAMO_TABLE}" \
  --scalable-dimension "dynamodb:table:ReadCapacityUnits" \
  --policy-name "${DYNAMO_TABLE}-read-scaling" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "DynamoDBReadCapacityUtilization"
    }
  }' \
  --region "$AWS_REGION"

ok "Autoscaling configurado (target 70% utilization)"

# ---------------------------------------------------------------------------
section "PASO 3 — Volver a On-Demand (recomendado para labs)"
# ---------------------------------------------------------------------------

log "Restaurando modo On-Demand..."
aws dynamodb update-table \
  --table-name "$DYNAMO_TABLE" \
  --billing-mode PAY_PER_REQUEST \
  --region "$AWS_REGION"

aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$AWS_REGION"
ok "Tabla volvió a modo On-Demand (PAY_PER_REQUEST)"

# ---------------------------------------------------------------------------
section "PASO 4 — CloudWatch Alarms"
# ---------------------------------------------------------------------------

SNS_ARN=$(aws sns create-topic \
  --name "$SNS_TOPIC_NAME" \
  --tags "Key=Project,Value=$PROJECT" "Key=Lab,Value=$LAB" \
  --query 'TopicArn' --output text --region "$AWS_REGION")
save_resource "SNS_ARN" "$SNS_ARN"
ok "SNS Topic: $SNS_ARN"

# Alarma Read Throttle
aws cloudwatch put-metric-alarm \
  --alarm-name "dynamodb-ecommerce-read-throttle" \
  --alarm-description "DynamoDB Read Throttling > 0 en 5 min" \
  --metric-name ReadThrottleEvents \
  --namespace AWS/DynamoDB \
  --dimensions "Name=TableName,Value=${DYNAMO_TABLE}" \
  --period 300 --evaluation-periods 1 \
  --statistic Sum --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$SNS_ARN" \
  --region "$AWS_REGION"

# Alarma Write Throttle
aws cloudwatch put-metric-alarm \
  --alarm-name "dynamodb-ecommerce-write-throttle" \
  --alarm-description "DynamoDB Write Throttling > 0 en 5 min" \
  --metric-name WriteThrottleEvents \
  --namespace AWS/DynamoDB \
  --dimensions "Name=TableName,Value=${DYNAMO_TABLE}" \
  --period 300 --evaluation-periods 1 \
  --statistic Sum --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$SNS_ARN" \
  --region "$AWS_REGION"

ok "Alarmas de throttling configuradas"

# ---------------------------------------------------------------------------
section "PASO 5 — Verificar TTL"
# ---------------------------------------------------------------------------

TTL_STATUS=$(aws dynamodb describe-time-to-live \
  --table-name "$DYNAMO_TABLE" \
  --query 'TimeToLiveDescription.TimeToLiveStatus' \
  --output text --region "$AWS_REGION")
ok "TTL Status: $TTL_STATUS (debe ser ENABLED)"

# Insertar ítem con TTL corto para demostración
TTL_SHORT=$(date -d '+5 minutes' +%s 2>/dev/null || date -v+5M +%s)
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" --item "{
  \"PK\": {\"S\": \"SESSION#temp\"},
  \"SK\": {\"S\": \"TTL-DEMO\"},
  \"ttl\": {\"N\": \"${TTL_SHORT}\"},
  \"info\": {\"S\": \"Este ítem expirará en 5 min (eliminación hasta 48h después)\"},
  \"tipo\": {\"S\": \"SESSION\"}
}"
ok "Ítem TTL insertado (expiración en 5 min)"

# ---------------------------------------------------------------------------
section "RESUMEN"
# ---------------------------------------------------------------------------
echo ""
echo "  Tabla:        $DYNAMO_TABLE"
echo "  Billing mode: PAY_PER_REQUEST (On-Demand)"
echo "  TTL:          ENABLED (atributo: ttl)"
echo "  Alarmas:      read-throttle + write-throttle → $SNS_ARN"
echo ""
ok "Script 02 completado"
