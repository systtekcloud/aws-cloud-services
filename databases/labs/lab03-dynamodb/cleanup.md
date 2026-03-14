# Cleanup — Lab03 DynamoDB

> **Coste si olvidas limpiar:** DynamoDB cobra por storage (~0.25 USD/GB/mes). Una tabla vacía cuesta casi nada, pero Lambda + CloudWatch Logs + SNS también tienen pequeños cargos. Limpia siempre al acabar.

---

## Recursos creados en el lab

| Recurso | Nombre | Coste si queda activo |
|---------|--------|-----------------------|
| DynamoDB Table | `ecommerce-orders` | ~$0.25/GB/mes (storage) |
| Lambda Function | `dynamodb-stream-processor` | Mínimo (free tier) |
| IAM Role | `lambda-dynamodb-stream-role` | Gratis |
| SNS Topic | `dynamodb-lab03-alerts` | Mínimo |
| CloudWatch Alarms | `dynamodb-ecommerce-*` | ~$0.10/alarma/mes |
| CloudWatch Logs | `/aws/lambda/...` | ~$0.50/GB |

---

## Pasos en consola

### 1. Eliminar Event Source Mapping (trigger)

1. **Lambda → Functions → dynamodb-stream-processor**
2. **Configuration → Triggers**
3. Selecciona el trigger de DynamoDB
4. **Delete → Confirm**

### 2. Eliminar Lambda Function

1. **Lambda → Functions → dynamodb-stream-processor**
2. **Actions → Delete**
3. Escribe `delete` y confirma

### 3. Eliminar DynamoDB Table

1. **DynamoDB → Tables → ecommerce-orders**
2. **Actions → Delete table**
3. ☐ Create backup → desmarca
4. Escribe `confirm` y confirma

### 4. Eliminar IAM Role

1. **IAM → Roles → lambda-dynamodb-stream-role**
2. **Delete** → confirma

### 5. Eliminar SNS Topic

1. **SNS → Topics → dynamodb-lab03-alerts**
2. **Delete**

### 6. Eliminar CloudWatch Alarms

1. **CloudWatch → Alarms**
2. Selecciona `dynamodb-ecommerce-read-throttle` y `dynamodb-ecommerce-write-throttle`
3. **Actions → Delete**

---

## Cleanup vía CLI

```bash
set -euo pipefail

echo "=== Cleanup DynamoDB Lab03 ==="
echo "¿Confirmar eliminación de todos los recursos? (yes/no)"
read -r CONFIRM
[[ "$CONFIRM" != "yes" ]] && { echo "Cancelado."; exit 0; }

AWS_REGION="eu-west-1"

# 1. Eliminar Event Source Mapping
echo "[1/7] Eliminando Event Source Mapping..."
ESM_UUID=$(aws lambda list-event-source-mappings \
  --function-name dynamodb-stream-processor \
  --query 'EventSourceMappings[0].UUID' \
  --output text --region $AWS_REGION 2>/dev/null || echo "None")

if [[ "$ESM_UUID" != "None" && -n "$ESM_UUID" ]]; then
  aws lambda delete-event-source-mapping \
    --uuid $ESM_UUID \
    --region $AWS_REGION && echo "  ESM eliminado"
else
  echo "  ESM: no encontrado"
fi

# 2. Eliminar Lambda
echo "[2/7] Eliminando Lambda..."
aws lambda delete-function \
  --function-name dynamodb-stream-processor \
  --region $AWS_REGION 2>/dev/null && echo "  Lambda eliminada" || echo "  Lambda: no encontrada"

# 3. Eliminar tabla DynamoDB
echo "[3/7] Eliminando tabla DynamoDB..."
aws dynamodb delete-table \
  --table-name ecommerce-orders \
  --region $AWS_REGION 2>/dev/null && echo "  Tabla eliminada" || echo "  Tabla: no encontrada"

# 4. Eliminar IAM Role
echo "[4/7] Eliminando IAM Role..."
aws iam detach-role-policy \
  --role-name lambda-dynamodb-stream-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole \
  2>/dev/null || true

aws iam delete-role \
  --role-name lambda-dynamodb-stream-role \
  2>/dev/null && echo "  IAM Role eliminado" || echo "  IAM Role: no encontrado"

# 5. Eliminar SNS Topic
echo "[5/7] Eliminando SNS Topic..."
SNS_ARN=$(aws sns list-topics \
  --query "Topics[?contains(TopicArn,'dynamodb-lab03-alerts')].TopicArn | [0]" \
  --output text --region $AWS_REGION 2>/dev/null || echo "None")

if [[ "$SNS_ARN" != "None" && "$SNS_ARN" != "null" && -n "$SNS_ARN" ]]; then
  aws sns delete-topic --topic-arn $SNS_ARN --region $AWS_REGION \
    && echo "  SNS eliminado"
else
  echo "  SNS: no encontrado"
fi

# 6. Eliminar CloudWatch Alarms
echo "[6/7] Eliminando CloudWatch Alarms..."
aws cloudwatch delete-alarms \
  --alarm-names "dynamodb-ecommerce-read-throttle" "dynamodb-ecommerce-write-throttle" \
  --region $AWS_REGION 2>/dev/null && echo "  Alarmas eliminadas" || echo "  Alarmas: no encontradas"

# 7. Eliminar CloudWatch Log Groups
echo "[7/7] Eliminando CloudWatch Log Groups..."
aws logs delete-log-group \
  --log-group-name "/aws/lambda/dynamodb-stream-processor" \
  --region $AWS_REGION 2>/dev/null && echo "  Log group eliminado" || echo "  Log group: no encontrado"

echo ""
echo "=== Cleanup Lab03 DynamoDB completado ==="
```

---

## Verificación post-cleanup

```bash
# Tabla eliminada
aws dynamodb describe-table --table-name ecommerce-orders --region eu-west-1 2>&1 \
  | grep -i "ResourceNotFoundException"
# Esperado: error ResourceNotFoundException

# Lambda eliminada
aws lambda get-function --function-name dynamodb-stream-processor --region eu-west-1 2>&1 \
  | grep -i "ResourceNotFoundException"
```
