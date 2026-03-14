#!/usr/bin/env bash
# =============================================================================
# Lab03 DynamoDB — Script 03: Streams + Lambda trigger
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

check_prereqs
load_resources

# ---------------------------------------------------------------------------
section "PASO 1 — Habilitar DynamoDB Streams"
# ---------------------------------------------------------------------------

STREAM_STATUS=$(aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --query 'Table.StreamSpecification.StreamEnabled' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$STREAM_STATUS" != "True" ]]; then
  aws dynamodb update-table \
    --table-name "$DYNAMO_TABLE" \
    --stream-specification "StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES" \
    --region "$AWS_REGION"
  aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$AWS_REGION"
  ok "Streams habilitado (NEW_AND_OLD_IMAGES)"
else
  ok "Streams ya estaba habilitado"
fi

STREAM_ARN=$(aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --query 'Table.LatestStreamArn' \
  --output text --region "$AWS_REGION")
save_resource "STREAM_ARN" "$STREAM_ARN"
ok "Stream ARN: $STREAM_ARN"

# ---------------------------------------------------------------------------
section "PASO 2 — IAM Role para Lambda"
# ---------------------------------------------------------------------------

ROLE_EXISTS=$(aws iam get-role --role-name "$LAMBDA_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "None")

if [[ "$ROLE_EXISTS" == "None" ]]; then
  LAMBDA_ROLE_ARN=$(aws iam create-role \
    --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' \
    --query 'Role.Arn' --output text)

  aws iam attach-role-policy \
    --role-name "$LAMBDA_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole

  ok "IAM Role creado: $LAMBDA_ROLE_ARN"
  sleep 15  # propagación IAM
else
  LAMBDA_ROLE_ARN="$ROLE_EXISTS"
  ok "IAM Role ya existe: $LAMBDA_ROLE_ARN"
fi

save_resource "LAMBDA_ROLE_ARN" "$LAMBDA_ROLE_ARN"

# ---------------------------------------------------------------------------
section "PASO 3 — Crear función Lambda"
# ---------------------------------------------------------------------------

# Escribir código Python
cat > /tmp/lambda_function.py << 'PYEOF'
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    logger.info(f"Records recibidos: {len(event['Records'])}")

    for record in event['Records']:
        event_name = record['eventName']
        dynamo_data = record.get('dynamodb', {})

        if event_name == 'INSERT':
            new_image = dynamo_data.get('NewImage', {})
            pk  = new_image.get('PK', {}).get('S', 'N/A')
            sk  = new_image.get('SK', {}).get('S', 'N/A')
            tipo = new_image.get('tipo', {}).get('S', 'UNKNOWN')
            logger.info(f"[INSERT] PK={pk} SK={sk} tipo={tipo}")

            if tipo == 'ORDER':
                total  = new_image.get('total', {}).get('N', '0')
                estado = new_image.get('estado', {}).get('S', 'N/A')
                logger.info(f"  Nuevo pedido: total={total} estado={estado}")

        elif event_name == 'MODIFY':
            new_image = dynamo_data.get('NewImage', {})
            old_image = dynamo_data.get('OldImage', {})
            pk = new_image.get('PK', {}).get('S', 'N/A')

            old_estado = old_image.get('estado', {}).get('S', 'N/A')
            new_estado = new_image.get('estado', {}).get('S', 'N/A')
            if old_estado != new_estado:
                logger.info(f"[MODIFY] PK={pk} estado: {old_estado} -> {new_estado}")
            else:
                logger.info(f"[MODIFY] PK={pk}")

        elif event_name == 'REMOVE':
            old_image = dynamo_data.get('OldImage', {})
            pk  = old_image.get('PK', {}).get('S', 'N/A')
            sk  = old_image.get('SK', {}).get('S', 'N/A')

            # Detectar si fue eliminado por TTL
            user_identity = record.get('userIdentity', {})
            if user_identity.get('principalId') == 'dynamodb.amazonaws.com':
                logger.info(f"[REMOVE-TTL] PK={pk} SK={sk} — expirado por TTL")
            else:
                logger.info(f"[REMOVE] PK={pk} SK={sk}")

    return {'statusCode': 200, 'processed': len(event['Records'])}
PYEOF

cd /tmp && zip -q lambda.zip lambda_function.py

LAMBDA_EXISTS=$(aws lambda get-function \
  --function-name "$LAMBDA_FUNCTION" \
  --query 'Configuration.FunctionArn' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$LAMBDA_EXISTS" == "None" ]]; then
  LAMBDA_ARN=$(aws lambda create-function \
    --function-name "$LAMBDA_FUNCTION" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb:///tmp/lambda.zip \
    --timeout 60 \
    --tags "Project=$PROJECT,Lab=$LAB" \
    --query 'FunctionArn' --output text \
    --region "$AWS_REGION")

  aws lambda wait function-active \
    --function-name "$LAMBDA_FUNCTION" \
    --region "$AWS_REGION"
  ok "Lambda creada: $LAMBDA_ARN"
else
  # Actualizar código si ya existe
  aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION" \
    --zip-file fileb:///tmp/lambda.zip \
    --region "$AWS_REGION" > /dev/null
  LAMBDA_ARN="$LAMBDA_EXISTS"
  ok "Lambda actualizada: $LAMBDA_ARN"
fi

save_resource "LAMBDA_ARN" "$LAMBDA_ARN"

# ---------------------------------------------------------------------------
section "PASO 4 — Event Source Mapping (Stream → Lambda)"
# ---------------------------------------------------------------------------

ESM_EXISTS=$(aws lambda list-event-source-mappings \
  --function-name "$LAMBDA_FUNCTION" \
  --query 'EventSourceMappings[0].UUID' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$ESM_EXISTS" == "None" || "$ESM_EXISTS" == "null" ]]; then
  ESM_UUID=$(aws lambda create-event-source-mapping \
    --function-name "$LAMBDA_FUNCTION" \
    --event-source-arn "$STREAM_ARN" \
    --starting-position LATEST \
    --batch-size 10 \
    --query 'UUID' --output text \
    --region "$AWS_REGION")
  save_resource "ESM_UUID" "$ESM_UUID"
  ok "Event Source Mapping creado: $ESM_UUID"
else
  ok "ESM ya existe: $ESM_EXISTS"
fi

# ---------------------------------------------------------------------------
section "PASO 5 — Prueba del flujo"
# ---------------------------------------------------------------------------

log "Insertando ítem de prueba para disparar el stream..."
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" --item '{
  "PK": {"S": "CUSTOMER#9999"},
  "SK": {"S": "ORDER#2024-02-01#ORD-100"},
  "GSI1PK": {"S": "ORDER#ORD-100"},
  "GSI1SK": {"S": "CUSTOMER#9999"},
  "GSI2PK": {"S": "STATUS#pending"},
  "GSI2SK": {"S": "2024-02-01#ORD-100"},
  "total": {"N": "99.99"},
  "estado": {"S": "pending"},
  "producto": {"S": "Auriculares BT"},
  "tipo": {"S": "ORDER"}
}'

log "Modificando estado del pedido..."
aws dynamodb update-item \
  --table-name "$DYNAMO_TABLE" \
  --key '{"PK": {"S": "CUSTOMER#9999"}, "SK": {"S": "ORDER#2024-02-01#ORD-100"}}' \
  --update-expression "SET estado = :e, GSI2PK = :g" \
  --expression-attribute-values '{":e": {"S": "shipped"}, ":g": {"S": "STATUS#shipped"}}' \
  --region "$AWS_REGION"

log "Esperando 30 seg para que Lambda procese el stream..."
sleep 30

log "Logs de Lambda (últimas invocaciones):"
LOG_STREAM=$(aws logs describe-log-streams \
  --log-group-name "/aws/lambda/${LAMBDA_FUNCTION}" \
  --order-by LastEventTime \
  --descending \
  --limit 1 \
  --query 'logStreams[0].logStreamName' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$LOG_STREAM" != "None" ]]; then
  aws logs get-log-events \
    --log-group-name "/aws/lambda/${LAMBDA_FUNCTION}" \
    --log-stream-name "$LOG_STREAM" \
    --query 'events[-20:].message' \
    --output text --region "$AWS_REGION"
else
  warn "No se encontraron logs aún (puede tardar hasta 60 seg la primera invocación)"
fi

echo ""
ok "Script 03 completado — Streams + Lambda trigger activo"
