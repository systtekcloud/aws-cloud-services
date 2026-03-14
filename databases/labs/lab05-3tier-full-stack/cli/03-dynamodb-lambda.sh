#!/usr/bin/env bash
# =============================================================================
# Lab05 — Script 03: DynamoDB + Streams + Lambda + SNS
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
load_resources

section "PASO 1 — Tabla DynamoDB ecommerce-catalog"
TABLE_EXISTS=$(aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --query 'Table.TableStatus' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$TABLE_EXISTS" == "None" ]]; then
  aws dynamodb create-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions \
        AttributeName=PK,AttributeType=S \
        AttributeName=SK,AttributeType=S \
        AttributeName=GSI1PK,AttributeType=S \
        AttributeName=GSI1SK,AttributeType=S \
    --key-schema \
        AttributeName=PK,KeyType=HASH \
        AttributeName=SK,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --global-secondary-indexes '[
      {
        "IndexName": "GSI1-categoria-precio",
        "KeySchema": [
          {"AttributeName":"GSI1PK","KeyType":"HASH"},
          {"AttributeName":"GSI1SK","KeyType":"RANGE"}
        ],
        "Projection": {"ProjectionType":"ALL"}
      }
    ]' \
    --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
    --tags Key=Project,Value=$PROJECT Key=Lab,Value=$LAB \
    --region "$AWS_REGION"

  log "Esperando tabla activa..."
  aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$AWS_REGION"
  ok "Tabla $DYNAMO_TABLE creada"
else
  ok "Tabla $DYNAMO_TABLE ya existe con estado: $TABLE_EXISTS"
fi

# Habilitar TTL
aws dynamodb update-time-to-live \
  --table-name "$DYNAMO_TABLE" \
  --time-to-live-specification "Enabled=true,AttributeName=ttl" \
  --region "$AWS_REGION" 2>/dev/null && ok "TTL habilitado" || ok "TTL ya estaba habilitado"

# Obtener Stream ARN
STREAM_ARN=$(aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --query 'Table.LatestStreamArn' --output text --region "$AWS_REGION")
save_resource "DYNAMO_STREAM_ARN" "$STREAM_ARN"
ok "Stream ARN: $STREAM_ARN"

section "PASO 2 — Datos iniciales en catálogo"
NOW_EPOCH=$(date +%s)
CART_TTL=$((NOW_EPOCH + 3600))  # 1 hora

# Producto 1
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" \
  --item '{
    "PK":     {"S": "PRODUCT#prod-001"},
    "SK":     {"S": "METADATA"},
    "GSI1PK": {"S": "CATEGORIA#electronica"},
    "GSI1SK": {"S": "PRECIO#299.99"},
    "nombre": {"S": "Auriculares Bluetooth Pro"},
    "precio": {"N": "299.99"},
    "stock":  {"N": "150"},
    "activo": {"BOOL": true}
  }' 2>/dev/null

# Stock producto 1
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" \
  --item '{
    "PK":        {"S": "PRODUCT#prod-001"},
    "SK":        {"S": "STOCK#eu-west-1"},
    "disponible":{"N": "150"},
    "reservado": {"N": "12"}
  }' 2>/dev/null

# Producto 2
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" \
  --item '{
    "PK":     {"S": "PRODUCT#prod-002"},
    "SK":     {"S": "METADATA"},
    "GSI1PK": {"S": "CATEGORIA#electronica"},
    "GSI1SK": {"S": "PRECIO#599.00"},
    "nombre": {"S": "Smart Watch Serie X"},
    "precio": {"N": "599.00"},
    "stock":  {"N": "75"},
    "activo": {"BOOL": true}
  }' 2>/dev/null

# Carrito con TTL (expira en 1h)
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" \
  --item "{
    \"PK\":      {\"S\": \"CART#user-demo\"},
    \"SK\":      {\"S\": \"ITEM#prod-001\"},
    \"cantidad\":{\"N\": \"2\"},
    \"precio\":  {\"N\": \"299.99\"},
    \"ttl\":     {\"N\": \"${CART_TTL}\"}
  }" 2>/dev/null

ok "Datos iniciales insertados (2 productos + 1 carrito con TTL)"

section "PASO 3 — SNS Topic para notificaciones"
TOPIC_ARN=$(aws sns create-topic \
  --name "$SNS_TOPIC_NAME" \
  --tags Key=Project,Value=$PROJECT Key=Lab,Value=$LAB \
  --query 'TopicArn' --output text --region "$AWS_REGION" 2>/dev/null || \
  aws sns list-topics --query "Topics[?contains(TopicArn,'$SNS_TOPIC_NAME')].TopicArn | [0]" \
    --output text --region "$AWS_REGION")
save_resource "SNS_TOPIC_ARN" "$TOPIC_ARN"
ok "SNS Topic: $TOPIC_ARN"

section "PASO 4 — IAM Role para Lambda"
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam create-role --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"lambda.amazonaws.com"},
        "Action":"sts:AssumeRole"
      }]
    }' \
    --query 'Role.Arn' --output text)

# Políticas necesarias
aws iam attach-role-policy --role-name "$LAMBDA_ROLE" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole" 2>/dev/null || true

aws iam put-role-policy --role-name "$LAMBDA_ROLE" \
  --policy-name AllowSNSPublish \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":[\"sns:Publish\"],
      \"Resource\":\"${TOPIC_ARN}\"
    }]
  }" 2>/dev/null || true

save_resource "LAMBDA_ROLE_ARN" "$LAMBDA_ROLE_ARN"
ok "Lambda IAM Role: $LAMBDA_ROLE_ARN"
sleep 10  # Propagar IAM

section "PASO 5 — Lambda Function"
# Crear el código Python inline
LAMBDA_TMP_DIR=$(mktemp -d)
cat > "${LAMBDA_TMP_DIR}/lambda_function.py" <<'PYTHON'
import json
import os
import boto3

sns = boto3.client("sns")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]


def lambda_handler(event, context):
    processed = 0
    for record in event.get("Records", []):
        event_name = record["eventName"]
        new_image = record.get("dynamodb", {}).get("NewImage", {})
        old_image = record.get("dynamodb", {}).get("OldImage", {})
        pk = new_image.get("PK", {}).get("S") or old_image.get("PK", {}).get("S", "")

        # Nuevo pedido creado en Aurora → DynamoDB
        if event_name == "INSERT" and pk.startswith("PEDIDO#"):
            pedido_id = pk.replace("PEDIDO#", "")
            usuario_id = new_image.get("usuario_id", {}).get("S", "?")
            total = new_image.get("total", {}).get("N", "0")
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"Nuevo pedido {pedido_id}",
                Message=json.dumps({
                    "evento": "PEDIDO_CREADO",
                    "pedido_id": pedido_id,
                    "usuario_id": usuario_id,
                    "total": float(total),
                }, ensure_ascii=False),
            )
            print(f"[PEDIDO_CREADO] {pedido_id} usuario={usuario_id} total={total}")
            processed += 1

        # Cambio de estado de pedido
        elif event_name == "MODIFY" and pk.startswith("PEDIDO#"):
            new_estado = new_image.get("estado", {}).get("S")
            old_estado = old_image.get("estado", {}).get("S")
            if new_estado and new_estado != old_estado:
                pedido_id = pk.replace("PEDIDO#", "")
                sns.publish(
                    TopicArn=SNS_TOPIC_ARN,
                    Subject=f"Pedido {pedido_id} → {new_estado}",
                    Message=json.dumps({
                        "evento": "PEDIDO_ACTUALIZADO",
                        "pedido_id": pedido_id,
                        "estado_anterior": old_estado,
                        "estado_nuevo": new_estado,
                    }),
                )
                print(f"[PEDIDO_ACTUALIZADO] {pedido_id}: {old_estado} → {new_estado}")
                processed += 1

        # Carrito abandonado (TTL expiration)
        elif event_name == "REMOVE" and pk.startswith("CART#"):
            user_identity = record.get("userIdentity", {})
            if user_identity.get("type") == "Service" and \
               "dynamodb.amazonaws.com" in user_identity.get("principalId", ""):
                user_id = pk.replace("CART#", "")
                sk = old_image.get("SK", {}).get("S", "")
                print(f"[CARRITO_ABANDONADO] user={user_id} item={sk}")
                processed += 1

    return {"statusCode": 200, "processed": processed}
PYTHON

cd "$LAMBDA_TMP_DIR" && zip -q function.zip lambda_function.py

FUNCTION_EXISTS=$(aws lambda get-function --function-name "$LAMBDA_FUNCTION" \
  --region "$AWS_REGION" --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "None")

if [[ "$FUNCTION_EXISTS" == "None" ]]; then
  aws lambda create-function \
    --function-name "$LAMBDA_FUNCTION" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://function.zip \
    --environment "Variables={SNS_TOPIC_ARN=${TOPIC_ARN}}" \
    --timeout 30 \
    --memory-size 256 \
    --tags Project=$PROJECT,Lab=$LAB \
    --region "$AWS_REGION"
  ok "Lambda $LAMBDA_FUNCTION creada"
else
  aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION" \
    --zip-file fileb://function.zip \
    --region "$AWS_REGION" > /dev/null
  ok "Lambda $LAMBDA_FUNCTION actualizada"
fi

rm -rf "$LAMBDA_TMP_DIR"
cd "$SCRIPT_DIR"

section "PASO 6 — Event Source Mapping (Streams → Lambda)"
ESM_EXISTS=$(aws lambda list-event-source-mappings \
  --function-name "$LAMBDA_FUNCTION" \
  --event-source-arn "$STREAM_ARN" \
  --query 'EventSourceMappings[0].UUID' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$ESM_EXISTS" == "None" || "$ESM_EXISTS" == "" ]]; then
  aws lambda create-event-source-mapping \
    --function-name "$LAMBDA_FUNCTION" \
    --event-source-arn "$STREAM_ARN" \
    --starting-position LATEST \
    --batch-size 10 \
    --maximum-retry-attempts 2 \
    --region "$AWS_REGION"
  ok "Event Source Mapping creado"
else
  ok "Event Source Mapping ya existe: $ESM_EXISTS"
fi

section "PASO 7 — Test: insertar pedido de prueba"
TEST_EPOCH=$(date +%s)
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" \
  --item "{
    \"PK\":         {\"S\": \"PEDIDO#test-${TEST_EPOCH}\"},
    \"SK\":         {\"S\": \"METADATA\"},
    \"usuario_id\": {\"S\": \"user-demo\"},
    \"total\":      {\"N\": \"599.98\"},
    \"estado\":     {\"S\": \"pendiente\"},
    \"creado\":     {\"N\": \"${TEST_EPOCH}\"}
  }"
ok "Pedido de prueba insertado (PEDIDO#test-${TEST_EPOCH})"
log "Espera ~30s y revisa CloudWatch Logs del grupo /aws/lambda/$LAMBDA_FUNCTION"

echo ""
echo "  DynamoDB Table:   $DYNAMO_TABLE"
echo "  Stream ARN:       $STREAM_ARN"
echo "  SNS Topic:        $TOPIC_ARN"
echo "  Lambda Function:  $LAMBDA_FUNCTION"
echo ""
ok "Script 03 completado — DynamoDB + Lambda + SNS listos"
