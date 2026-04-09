# Lab 01-A: Lambda Fundamentos

**Objetivo:** Crear, invocar y observar una función Lambda con AWS CLI. Entender el execution model real: cold start, warm start, invocación síncrona vs asíncrona, y event sources básicos.

**Tiempo estimado:** 45 min  
**Coste estimado:** $0 (free tier)  
**Región:** eu-west-1

---

## Prereqs

```bash
# Verificar AWS CLI configurado
aws sts get-caller-identity

# Verificar permisos mínimos necesarios
# lambda:CreateFunction, lambda:InvokeFunction, lambda:GetFunction
# iam:CreateRole, iam:AttachRolePolicy, iam:PassRole
# logs:GetLogEvents, logs:FilterLogEvents
```

---

## Paso 1: IAM Execution Role

Lambda necesita un rol para asumir en el momento de ejecución. El mínimo necesario es poder escribir logs en CloudWatch.

```bash
# 1.1 Trust policy para Lambda
cat > /tmp/lambda-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# 1.2 Crear el rol
aws iam create-role \
  --role-name lab01-lambda-basic-role \
  --assume-role-policy-document file:///tmp/lambda-trust-policy.json \
  --tags Key=Lab,Value=lab01-lambda

# 1.3 Adjuntar la managed policy de CloudWatch Logs
aws iam attach-role-policy \
  --role-name lab01-lambda-basic-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# 1.4 Guardar el ARN del rol (necesario para crear la función)
ROLE_ARN=$(aws iam get-role \
  --role-name lab01-lambda-basic-role \
  --query 'Role.Arn' \
  --output text)

echo "Role ARN: $ROLE_ARN"
```

> **Por qué mínimo privilegio:** AWSLambdaBasicExecutionRole solo permite escribir logs. Si tu función necesita acceder a S3, DynamoDB, etc., añades políticas adicionales al mismo rol. Nunca uses `AdministratorAccess` en un rol Lambda.

---

## Paso 2: Crear la función Lambda

```bash
# 2.1 Código Python de la función
mkdir -p /tmp/lambda-lab01
cat > /tmp/lambda-lab01/handler.py << 'EOF'
import json
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
    """
    Handler Lambda. Recibe un evento, loguea información útil
    sobre el execution environment, y devuelve una respuesta.
    
    context.aws_request_id: único por invocación
    context.function_name: nombre de la función
    context.memory_limit_in_mb: límite de memoria configurado
    """
    logger.info(f"Request ID: {context.aws_request_id}")
    logger.info(f"Function: {context.function_name}")
    logger.info(f"Memory limit: {context.memory_limit_in_mb} MB")
    logger.info(f"Remaining time: {context.get_remaining_time_in_millis()} ms")
    logger.info(f"Event received: {json.dumps(event)}")
    
    # Detectar si es cold start leyendo variable de entorno personalizada
    # (en cold start esta variable no existe en el global scope inicializado)
    is_cold = os.environ.get('_COLD_START_MARKER') is None
    os.environ['_COLD_START_MARKER'] = 'warm'
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Hola desde Lambda',
            'event_received': event,
            'context': {
                'request_id': context.aws_request_id,
                'function_name': context.function_name,
                'memory_mb': context.memory_limit_in_mb,
            }
        })
    }
EOF

# 2.2 Empaquetar en ZIP
cd /tmp/lambda-lab01 && zip function.zip handler.py

# 2.3 Crear la función (espera ~5s tras crear el rol por propagación IAM)
sleep 10

aws lambda create-function \
  --function-name lab01-fundamentos \
  --runtime python3.12 \
  --handler handler.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/lambda-lab01/function.zip \
  --timeout 30 \
  --memory-size 128 \
  --environment "Variables={ENV=lab}" \
  --region eu-west-1 \
  --tags Lab=lab01-lambda

# 2.4 Verificar que está activa
aws lambda get-function \
  --function-name lab01-fundamentos \
  --region eu-west-1 \
  --query 'Configuration.[FunctionName,State,Runtime,MemorySize,Timeout]'
```

---

## Paso 3: Invocación síncrona

```bash
# 3.1 Invocación básica con payload JSON
aws lambda invoke \
  --function-name lab01-fundamentos \
  --payload '{"key": "value", "test": true}' \
  --cli-binary-format raw-in-base64-out \
  --region eu-west-1 \
  /tmp/lambda-response.json

# Ver la respuesta
cat /tmp/lambda-response.json | python3 -m json.tool

# 3.2 Ver el status code HTTP de la invocación (no del payload)
# 200 = Lambda ejecutó OK (aunque tu función devuelva error interno)
# 4xx/5xx = error de Lambda (throttling, etc.)

# 3.3 Segunda invocación (warm start — mismo execution environment)
aws lambda invoke \
  --function-name lab01-fundamentos \
  --payload '{"second": "invocation"}' \
  --cli-binary-format raw-in-base64-out \
  --region eu-west-1 \
  /tmp/lambda-response-2.json
```

---

## Paso 4: Invocación asíncrona

```bash
# 4.1 Invocación async — Lambda encola el evento y responde inmediatamente (202)
aws lambda invoke \
  --function-name lab01-fundamentos \
  --invocation-type Event \
  --payload '{"async": true, "message": "procesa en background"}' \
  --cli-binary-format raw-in-base64-out \
  --region eu-west-1 \
  /tmp/lambda-async-response.json

echo "Código de respuesta (debería ser 202):"
cat /tmp/lambda-async-response.json
```

---

## Paso 5: Ver logs en CloudWatch

```bash
# 5.1 Obtener el log group de la función
LOG_GROUP="/aws/lambda/lab01-fundamentos"

# 5.2 Listar los log streams (uno por execution environment)
aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --order-by LastEventTime \
  --descending \
  --limit 5 \
  --region eu-west-1 \
  --query 'logStreams[*].[logStreamName,lastEventTimestamp]'

# 5.3 Leer eventos del stream más reciente
STREAM=$(aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --order-by LastEventTime \
  --descending \
  --limit 1 \
  --region eu-west-1 \
  --query 'logStreams[0].logStreamName' \
  --output text)

aws logs get-log-events \
  --log-group-name "$LOG_GROUP" \
  --log-stream-name "$STREAM" \
  --region eu-west-1 \
  --query 'events[*].message' \
  --output text
```

> **Tip:** Cada log stream = un execution environment. Si ves múltiples streams con invocaciones simultáneas, hay múltiples entornos activos (concurrencia > 1).

---

## Paso 6: Medir cold start con CloudWatch Logs Insights

```bash
# 6.1 Hacer varias invocaciones para generar datos
for i in {1..5}; do
  aws lambda invoke \
    --function-name lab01-fundamentos \
    --payload "{\"invocation\": $i}" \
    --cli-binary-format raw-in-base64-out \
    --region eu-west-1 \
    /tmp/lambda-out-$i.json > /dev/null
  sleep 2
done

# 6.2 Query de Logs Insights para ver init duration (cold starts)
# En la consola: CloudWatch → Logs Insights → selecciona /aws/lambda/lab01-fundamentos
# Ejecuta esta query:
cat << 'EOF'
fields @timestamp, @duration, @initDuration, @billedDuration, @memorySize, @maxMemoryUsed
| filter @type = "REPORT"
| sort @timestamp desc
| limit 20
EOF

# @initDuration solo aparece en cold starts
# @duration = tiempo real del handler
# @billedDuration = max(1ms ceiling de @duration)
```

---

## Paso 7: S3 Event Trigger

```bash
# 7.1 Crear bucket para trigger
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="lab01-lambda-trigger-$ACCOUNT_ID"

aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

# 7.2 Dar permiso a S3 para invocar la función
aws lambda add-permission \
  --function-name lab01-fundamentos \
  --statement-id s3-trigger \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$BUCKET_NAME" \
  --source-account "$ACCOUNT_ID" \
  --region eu-west-1

# 7.3 Crear la notificación en el bucket
cat > /tmp/s3-notification.json << EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "$(aws lambda get-function --function-name lab01-fundamentos --region eu-west-1 --query Configuration.FunctionArn --output text)",
      "Events": ["s3:ObjectCreated:*"]
    }
  ]
}
EOF

aws s3api put-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" \
  --notification-configuration file:///tmp/s3-notification.json

# 7.4 Subir un objeto para disparar la función
echo "test content" | aws s3 cp - s3://$BUCKET_NAME/test.txt

# 7.5 Ver logs tras 5 segundos
sleep 5
aws logs filter-log-events \
  --log-group-name "/aws/lambda/lab01-fundamentos" \
  --filter-pattern "s3" \
  --region eu-west-1 \
  --query 'events[*].message' \
  --output text
```

---

## Validación

```bash
# validate.sh checks:

# 1. Función existe y está activa
aws lambda get-function \
  --function-name lab01-fundamentos \
  --region eu-west-1 \
  --query 'Configuration.State' \
  --output text | grep -q "Active" && echo "PASS: función activa" || echo "FAIL"

# 2. Invocación retorna 200
RESULT=$(aws lambda invoke \
  --function-name lab01-fundamentos \
  --payload '{"validate": true}' \
  --cli-binary-format raw-in-base64-out \
  --region eu-west-1 \
  /tmp/validate-out.json \
  --query 'StatusCode' \
  --output text)
[ "$RESULT" = "200" ] && echo "PASS: invocación OK (200)" || echo "FAIL: status $RESULT"

# 3. Logs aparecen en CloudWatch
LOG_COUNT=$(aws logs filter-log-events \
  --log-group-name "/aws/lambda/lab01-fundamentos" \
  --region eu-west-1 \
  --query 'length(events)' \
  --output text)
[ "$LOG_COUNT" -gt "0" ] && echo "PASS: logs presentes ($LOG_COUNT eventos)" || echo "FAIL: no hay logs"
```

---

## Limpieza

Ver [cleanup.md](../../cleanup.md) para eliminar todos los recursos de lab01.

## Siguiente sub-lab

[02-concurrency-scaling →](../02-concurrency-scaling/)
