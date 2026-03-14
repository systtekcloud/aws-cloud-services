#!/usr/bin/env bash
# =============================================================================
# Lab03 DynamoDB — Script 99: Cleanup completo
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

echo ""
echo "  ╔═════════════════════════════════════════════╗"
echo "  ║     LAB03 DYNAMODB — CLEANUP COMPLETO       ║"
echo "  ║                                              ║"
echo "  ║  Se eliminarán:                              ║"
echo "  ║    • DynamoDB Table: $DYNAMO_TABLE"
echo "  ║    • Lambda: $LAMBDA_FUNCTION"
echo "  ║    • IAM Role: $LAMBDA_ROLE"
echo "  ║    • SNS Topic: $SNS_TOPIC_NAME"
echo "  ║    • CloudWatch Alarms + Log Groups          ║"
echo "  ╚═════════════════════════════════════════════╝"
echo ""
read -rp "  Escribe 'CLEANUP LAB03' para confirmar: " CONFIRM
[[ "$CONFIRM" != "CLEANUP LAB03" ]] && { log "Cancelado."; exit 0; }

# 1. ESM
section "PASO 1/7 — Event Source Mapping"
ESM_UUID="${ESM_UUID:-$(aws lambda list-event-source-mappings \
  --function-name "$LAMBDA_FUNCTION" \
  --query 'EventSourceMappings[0].UUID' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")}"
[[ "$ESM_UUID" != "None" && -n "$ESM_UUID" ]] && \
  safe_run "Eliminar ESM" aws lambda delete-event-source-mapping \
    --uuid "$ESM_UUID" --region "$AWS_REGION" || log "ESM: no encontrado"

# 2. Lambda
section "PASO 2/7 — Lambda Function"
safe_run "Eliminar Lambda" aws lambda delete-function \
  --function-name "$LAMBDA_FUNCTION" --region "$AWS_REGION"

# 3. DynamoDB Table
section "PASO 3/7 — DynamoDB Table"
safe_run "Eliminar tabla" aws dynamodb delete-table \
  --table-name "$DYNAMO_TABLE" --region "$AWS_REGION"

# 4. IAM Role
section "PASO 4/7 — IAM Role"
safe_run "Detach policy" aws iam detach-role-policy \
  --role-name "$LAMBDA_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole
safe_run "Eliminar IAM Role" aws iam delete-role --role-name "$LAMBDA_ROLE"

# 5. SNS
section "PASO 5/7 — SNS Topic"
SNS_TOPIC_ARN="${SNS_ARN:-$(aws sns list-topics \
  --query "Topics[?contains(TopicArn,'$SNS_TOPIC_NAME')].TopicArn | [0]" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")}"
[[ "$SNS_TOPIC_ARN" != "None" && -n "$SNS_TOPIC_ARN" ]] && \
  safe_run "Eliminar SNS Topic" aws sns delete-topic \
    --topic-arn "$SNS_TOPIC_ARN" --region "$AWS_REGION" || log "SNS: no encontrado"

# 6. CloudWatch Alarms
section "PASO 6/7 — CloudWatch Alarms"
safe_run "Eliminar alarmas" aws cloudwatch delete-alarms \
  --alarm-names "dynamodb-ecommerce-read-throttle" "dynamodb-ecommerce-write-throttle" \
  --region "$AWS_REGION"

# 7. Log Groups
section "PASO 7/7 — CloudWatch Log Groups"
safe_run "Eliminar log group Lambda" aws logs delete-log-group \
  --log-group-name "/aws/lambda/${LAMBDA_FUNCTION}" --region "$AWS_REGION"

echo ""
ok "Cleanup Lab03 DynamoDB completado"
echo "  Limpia también: rm -f ${RESOURCES_FILE}"
