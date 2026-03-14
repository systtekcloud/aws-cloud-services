# Troubleshooting 03 — DynamoDB Streams: Lambda no se dispara

## Escenario

Insertas o modificas ítems en DynamoDB pero la función Lambda no se invoca. En CloudWatch:
- `Invocations` = 0 para la función Lambda
- O los logs de Lambda muestran errores de permisos

---

## Diagnóstico

### Paso 1: Verificar que Streams está habilitado

```bash
aws dynamodb describe-table \
  --table-name ecommerce-orders \
  --query 'Table.StreamSpecification' \
  --output json --region eu-west-1
```

Resultado esperado:
```json
{
  "StreamEnabled": true,
  "StreamViewType": "NEW_AND_OLD_IMAGES"
}
```

Si `StreamEnabled: false` → el stream no está activo.

```bash
# Fix: habilitar streams
aws dynamodb update-table \
  --table-name ecommerce-orders \
  --stream-specification "StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES" \
  --region eu-west-1
```

### Paso 2: Verificar el Event Source Mapping

```bash
aws lambda list-event-source-mappings \
  --function-name dynamodb-stream-processor \
  --region eu-west-1
```

Busca:
- `State`: debe ser `Enabled` (no `Disabled` ni `Creating`)
- `EventSourceArn`: debe coincidir con el Stream ARN de la tabla
- `LastProcessingResult`: si hay un error, aparece aquí

```json
{
  "UUID": "abc-123",
  "EventSourceArn": "arn:aws:dynamodb:eu-west-1:...:table/ecommerce-orders/stream/2024-01-15T12:00:00.000",
  "FunctionArn": "arn:aws:lambda:eu-west-1:...:function:dynamodb-stream-processor",
  "State": "Enabled",
  "LastProcessingResult": "No records processed"
}
```

### Paso 3: Verificar el Stream ARN en el ESM

Si recreas la tabla, **se genera un nuevo Stream ARN**. El Event Source Mapping antiguo apunta al ARN anterior (ya inválido).

```bash
# Stream ARN actual de la tabla
aws dynamodb describe-table \
  --table-name ecommerce-orders \
  --query 'Table.LatestStreamArn' \
  --output text --region eu-west-1

# Stream ARN en el ESM
aws lambda list-event-source-mappings \
  --function-name dynamodb-stream-processor \
  --query 'EventSourceMappings[0].EventSourceArn' \
  --output text --region eu-west-1

# Si son diferentes → el ESM apunta al stream incorrecto
```

---

## Causas y soluciones

### Causa 1 — Stream ARN incorrecto en el ESM (tabla recreada)

**Síntoma:** `LastProcessingResult: "The provided ARN does not have a valid format"`

**Fix:**

```bash
# 1. Obtener el nuevo Stream ARN
NEW_STREAM_ARN=$(aws dynamodb describe-table \
  --table-name ecommerce-orders \
  --query 'Table.LatestStreamArn' \
  --output text --region eu-west-1)

# 2. Eliminar el ESM antiguo
OLD_UUID=$(aws lambda list-event-source-mappings \
  --function-name dynamodb-stream-processor \
  --query 'EventSourceMappings[0].UUID' \
  --output text --region eu-west-1)

aws lambda delete-event-source-mapping \
  --uuid $OLD_UUID --region eu-west-1

# 3. Crear nuevo ESM con el ARN correcto
aws lambda create-event-source-mapping \
  --function-name dynamodb-stream-processor \
  --event-source-arn $NEW_STREAM_ARN \
  --starting-position LATEST \
  --batch-size 10 \
  --region eu-west-1
```

### Causa 2 — IAM Role de Lambda sin permisos para Streams

**Síntoma:** `LastProcessingResult: "The function does not have permission to call GetRecords on the event source"`

**Fix:**

```bash
# Verificar que el role tiene la política correcta
aws iam list-attached-role-policies \
  --role-name lambda-dynamodb-stream-role

# Debe incluir: AWSLambdaDynamoDBExecutionRole
# Si no está, añadirla:
aws iam attach-role-policy \
  --role-name lambda-dynamodb-stream-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole
```

La política `AWSLambdaDynamoDBExecutionRole` incluye:
- `dynamodb:GetRecords`
- `dynamodb:GetShardIterator`
- `dynamodb:DescribeStream`
- `dynamodb:ListStreams`
- `logs:CreateLogGroup/Stream/PutLogEvents`

### Causa 3 — ESM en estado Disabled

```bash
# Ver estado
aws lambda list-event-source-mappings \
  --function-name dynamodb-stream-processor \
  --query 'EventSourceMappings[0].{State:State,UUID:UUID}' \
  --output table --region eu-west-1

# Si State=Disabled, habilitarlo:
ESM_UUID=$(aws lambda list-event-source-mappings \
  --function-name dynamodb-stream-processor \
  --query 'EventSourceMappings[0].UUID' \
  --output text --region eu-west-1)

aws lambda update-event-source-mapping \
  --uuid $ESM_UUID \
  --enabled \
  --region eu-west-1
```

### Causa 4 — Lambda en estado de error continuo (iterator age muy alto)

Si Lambda tiene errores repetidos, el ESM puede entrar en un estado de backoff donde deja de procesar.

```bash
# Ver IteratorAge: si es muy alto, hay records sin procesar acumulados
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name IteratorAge \
  --dimensions Name=FunctionName,Value=dynamodb-stream-processor \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Maximum \
  --region eu-west-1
```

**Fix:** corregir el error en la función Lambda y re-desplegar.

```bash
# Ver los errores en CloudWatch Logs
aws logs filter-log-events \
  --log-group-name /aws/lambda/dynamodb-stream-processor \
  --filter-pattern "ERROR" \
  --start-time $(($(date +%s) - 3600))000 \
  --region eu-west-1
```

---

## Checklist de diagnóstico rápido

```bash
TABLE="ecommerce-orders"
FUNC="dynamodb-stream-processor"
REGION="eu-west-1"

echo "=== CHECKLIST STREAMS ==="

echo "1. Stream habilitado:"
aws dynamodb describe-table --table-name $TABLE \
  --query 'Table.StreamSpecification.StreamEnabled' \
  --output text --region $REGION

echo "2. ESM State:"
aws lambda list-event-source-mappings --function-name $FUNC \
  --query 'EventSourceMappings[0].State' \
  --output text --region $REGION

echo "3. ESM Last Result:"
aws lambda list-event-source-mappings --function-name $FUNC \
  --query 'EventSourceMappings[0].LastProcessingResult' \
  --output text --region $REGION

echo "4. Stream ARN match:"
TABLE_STREAM=$(aws dynamodb describe-table --table-name $TABLE \
  --query 'Table.LatestStreamArn' --output text --region $REGION)
ESM_STREAM=$(aws lambda list-event-source-mappings --function-name $FUNC \
  --query 'EventSourceMappings[0].EventSourceArn' --output text --region $REGION)
[[ "$TABLE_STREAM" == "$ESM_STREAM" ]] && echo "  MATCH ✓" || echo "  MISMATCH ✗"

echo "5. IAM Policy:"
aws iam list-attached-role-policies --role-name lambda-dynamodb-stream-role \
  --query 'AttachedPolicies[*].PolicyName' --output text
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|----------|-----------|
| ¿Qué necesita Lambda para leer un DynamoDB Stream? | Política `AWSLambdaDynamoDBExecutionRole` |
| ¿Qué pasa si se recrea la tabla? | El Stream ARN cambia — hay que actualizar el ESM |
| ¿`LATEST` vs `TRIM_HORIZON` en el ESM? | LATEST: solo records nuevos. TRIM_HORIZON: desde el inicio del stream. |
| ¿DynamoDB Streams retiene registros cuánto tiempo? | **24 horas** |
