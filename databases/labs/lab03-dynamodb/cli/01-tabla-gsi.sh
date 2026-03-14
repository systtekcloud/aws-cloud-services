#!/usr/bin/env bash
# =============================================================================
# Lab03 DynamoDB — Script 01: Crear tabla + GSIs + datos de ejemplo
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

check_prereqs

# ---------------------------------------------------------------------------
section "PASO 1 — Crear tabla DynamoDB"
# ---------------------------------------------------------------------------

TABLE_EXISTS=$(aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --query 'Table.TableStatus' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$TABLE_EXISTS" == "None" ]]; then
  log "Creando tabla $DYNAMO_TABLE..."
  aws dynamodb create-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions \
      AttributeName=PK,AttributeType=S \
      AttributeName=SK,AttributeType=S \
    --key-schema \
      AttributeName=PK,KeyType=HASH \
      AttributeName=SK,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --tags "Key=Project,Value=$PROJECT" "Key=Lab,Value=$LAB" "Key=Env,Value=$ENV" \
    --region "$AWS_REGION"

  aws dynamodb wait table-exists \
    --table-name "$DYNAMO_TABLE" \
    --region "$AWS_REGION"
  ok "Tabla creada: $DYNAMO_TABLE"
else
  ok "Tabla ya existe con estado: $TABLE_EXISTS"
fi

# ---------------------------------------------------------------------------
section "PASO 2 — Añadir GSI-1 y GSI-2"
# ---------------------------------------------------------------------------

# Verificar si ya tienen GSIs
GSI_COUNT=$(aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --query 'length(Table.GlobalSecondaryIndexes)' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "0")

if [[ "$GSI_COUNT" == "0" || "$GSI_COUNT" == "None" ]]; then
  log "Creando GSI-1 (por OrderID) y GSI-2 (por Status)..."
  aws dynamodb update-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions \
      AttributeName=PK,AttributeType=S \
      AttributeName=SK,AttributeType=S \
      AttributeName=GSI1PK,AttributeType=S \
      AttributeName=GSI1SK,AttributeType=S \
      AttributeName=GSI2PK,AttributeType=S \
      AttributeName=GSI2SK,AttributeType=S \
    --global-secondary-index-updates '[
      {
        "Create": {
          "IndexName": "GSI1",
          "KeySchema": [
            {"AttributeName": "GSI1PK", "KeyType": "HASH"},
            {"AttributeName": "GSI1SK", "KeyType": "RANGE"}
          ],
          "Projection": {"ProjectionType": "ALL"}
        }
      },
      {
        "Create": {
          "IndexName": "GSI2",
          "KeySchema": [
            {"AttributeName": "GSI2PK", "KeyType": "HASH"},
            {"AttributeName": "GSI2SK", "KeyType": "RANGE"}
          ],
          "Projection": {"ProjectionType": "ALL"}
        }
      }
    ]' \
    --region "$AWS_REGION"

  log "Esperando que los GSIs estén activos (~2-3 min)..."
  # Hacer polling manual porque wait no verifica GSI status
  for i in {1..20}; do
    STATUSES=$(aws dynamodb describe-table \
      --table-name "$DYNAMO_TABLE" \
      --query 'Table.GlobalSecondaryIndexes[*].IndexStatus' \
      --output text --region "$AWS_REGION")
    echo "  GSI status: $STATUSES"
    if [[ "$STATUSES" == *"ACTIVE"* ]] && [[ "$STATUSES" != *"CREATING"* ]]; then
      ok "GSIs activos"
      break
    fi
    sleep 15
  done
else
  ok "GSIs ya existen ($GSI_COUNT índices)"
fi

# ---------------------------------------------------------------------------
section "PASO 3 — Habilitar TTL"
# ---------------------------------------------------------------------------

TTL_STATUS=$(aws dynamodb describe-time-to-live \
  --table-name "$DYNAMO_TABLE" \
  --query 'TimeToLiveDescription.TimeToLiveStatus' \
  --output text --region "$AWS_REGION")

if [[ "$TTL_STATUS" != "ENABLED" ]]; then
  aws dynamodb update-time-to-live \
    --table-name "$DYNAMO_TABLE" \
    --time-to-live-specification "Enabled=true,AttributeName=ttl" \
    --region "$AWS_REGION"
  ok "TTL habilitado (atributo: ttl)"
else
  ok "TTL ya estaba habilitado"
fi

# ---------------------------------------------------------------------------
section "PASO 4 — Insertar datos de ejemplo"
# ---------------------------------------------------------------------------

log "Insertando perfiles de clientes..."
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" --item '{
  "PK": {"S": "CUSTOMER#1001"}, "SK": {"S": "PROFILE"},
  "nombre": {"S": "Ana García"}, "email": {"S": "ana@example.com"},
  "ciudad": {"S": "Madrid"}, "tipo": {"S": "PROFILE"}
}'

aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" --item '{
  "PK": {"S": "CUSTOMER#1002"}, "SK": {"S": "PROFILE"},
  "nombre": {"S": "Carlos López"}, "email": {"S": "carlos@example.com"},
  "ciudad": {"S": "Barcelona"}, "tipo": {"S": "PROFILE"}
}'

log "Insertando pedidos..."
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" --item '{
  "PK": {"S": "CUSTOMER#1001"}, "SK": {"S": "ORDER#2024-01-10#ORD-001"},
  "GSI1PK": {"S": "ORDER#ORD-001"}, "GSI1SK": {"S": "CUSTOMER#1001"},
  "GSI2PK": {"S": "STATUS#completed"}, "GSI2SK": {"S": "2024-01-10#ORD-001"},
  "total": {"N": "89.99"}, "estado": {"S": "completed"},
  "producto": {"S": "Libro AWS SAA-C03"}, "tipo": {"S": "ORDER"}
}'

aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" --item '{
  "PK": {"S": "CUSTOMER#1001"}, "SK": {"S": "ORDER#2024-01-20#ORD-003"},
  "GSI1PK": {"S": "ORDER#ORD-003"}, "GSI1SK": {"S": "CUSTOMER#1001"},
  "GSI2PK": {"S": "STATUS#pending"}, "GSI2SK": {"S": "2024-01-20#ORD-003"},
  "total": {"N": "149.00"}, "estado": {"S": "pending"},
  "producto": {"S": "Teclado mecánico"}, "tipo": {"S": "ORDER"}
}'

aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" --item '{
  "PK": {"S": "CUSTOMER#1002"}, "SK": {"S": "ORDER#2024-01-18#ORD-002"},
  "GSI1PK": {"S": "ORDER#ORD-002"}, "GSI1SK": {"S": "CUSTOMER#1002"},
  "GSI2PK": {"S": "STATUS#pending"}, "GSI2SK": {"S": "2024-01-18#ORD-002"},
  "total": {"N": "259.99"}, "estado": {"S": "pending"},
  "producto": {"S": "Monitor 27\""}, "tipo": {"S": "ORDER"}
}'

# Ítem con TTL
TTL_VAL=$(date -d '+2 days' +%s 2>/dev/null || date -v+2d +%s)
aws dynamodb put-item --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" --item "{
  \"PK\": {\"S\": \"SESSION#abc123\"}, \"SK\": {\"S\": \"USER#1001\"},
  \"ttl\": {\"N\": \"${TTL_VAL}\"},
  \"datos\": {\"S\": \"Sesión activa\"}, \"tipo\": {\"S\": \"SESSION\"}
}"

ok "Datos de ejemplo insertados"

# ---------------------------------------------------------------------------
section "PASO 5 — Verificaciones"
# ---------------------------------------------------------------------------

ITEM_COUNT=$(aws dynamodb scan \
  --table-name "$DYNAMO_TABLE" \
  --select COUNT \
  --query 'Count' --output text --region "$AWS_REGION")
ok "Items en tabla: $ITEM_COUNT"

log "Ejecutando AP1 (Query pedidos cliente 1001)..."
aws dynamodb query \
  --table-name "$DYNAMO_TABLE" \
  --key-condition-expression "PK = :pk AND begins_with(SK, :sk_prefix)" \
  --expression-attribute-values '{":pk": {"S": "CUSTOMER#1001"}, ":sk_prefix": {"S": "ORDER#"}}' \
  --query 'Items[*].{pedido:SK.S, total:total.N, estado:estado.S}' \
  --output table --region "$AWS_REGION"

log "Ejecutando AP4 (Query pedidos STATUS#pending via GSI2)..."
aws dynamodb query \
  --table-name "$DYNAMO_TABLE" \
  --index-name GSI2 \
  --key-condition-expression "GSI2PK = :status" \
  --expression-attribute-values '{":status": {"S": "STATUS#pending"}}' \
  --query 'Items[*].{pedido:SK.S, total:total.N}' \
  --output table --region "$AWS_REGION"

echo ""
ok "Script 01 completado — tabla, GSIs, TTL y datos listos"
