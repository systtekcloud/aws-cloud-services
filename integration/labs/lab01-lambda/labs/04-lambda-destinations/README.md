# Lab 01-D: Lambda Destinations y DLQ

**Objetivo:** Entender el flujo completo de invocaciones asíncronas con reintentos, y configurar Lambda Destinations y DLQ para manejar éxitos y fallos.

**Tiempo estimado:** 45 min  
**Coste estimado:** $0  
**Región:** eu-west-1

---

## Flujo de invocación asíncrona

```
Fuente (S3, SNS, EventBridge, etc.)
          │
          ▼
    [Internal Event Queue]
    (gestionada por Lambda)
          │
          ▼ Intento 1
       Lambda handler
          │
    ┌─────┴─────┐
  Éxito       Error
    │           │
    │     [espera ~1min]
    │           │
    │        Intento 2
    │           │
    │     ┌─────┴─────┐
    │   Éxito       Error
    │     │           │
    │     │     [espera ~2min]
    │     │           │
    │     │        Intento 3  (configurable: 0–2 reintentos)
    │     │           │
    │     │         Error definitivo
    │     │           │
    ▼     ▼           ▼
OnSuccess  OnSuccess  OnFailure / DLQ
```

---

## DLQ vs Lambda Destinations

| Aspecto | DLQ | Lambda Destinations |
|---------|-----|---------------------|
| Activación | Solo en fallo definitivo | Éxito Y fallo |
| Payload enviado | Solo el evento original | Evento + contexto + respuesta del handler |
| Targets | SQS, SNS | SQS, SNS, EventBridge, otra Lambda |
| Información de debugging | Mínima | Completa (stack trace, response) |
| Configuración | `DeadLetterConfig` en la función | `EventInvokeConfig` |
| Compatibilidad | Legacy, ampliamente soportado | Moderno (2019+) |

**Regla práctica:** usa Destinations para workflows nuevos. Usa DLQ si necesitas compatibilidad con sistemas que ya leen de SQS/SNS para reintentos manuales.

---

## Paso 1: Crear infraestructura de destinos

```bash
# 1.1 Queue para éxitos
SUCCESS_QUEUE_URL=$(aws sqs create-queue \
  --queue-name lab01-destinations-success \
  --region eu-west-1 \
  --query 'QueueUrl' \
  --output text)

SUCCESS_QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$SUCCESS_QUEUE_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' \
  --output text)

# 1.2 Queue para fallos (Destination OnFailure)
FAILURE_QUEUE_URL=$(aws sqs create-queue \
  --queue-name lab01-destinations-failure \
  --region eu-west-1 \
  --query 'QueueUrl' \
  --output text)

FAILURE_QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$FAILURE_QUEUE_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' \
  --output text)

echo "Success queue: $SUCCESS_QUEUE_ARN"
echo "Failure queue: $FAILURE_QUEUE_ARN"

# 1.3 DLQ (para el flujo alternativo con DLQ)
DLQ_URL=$(aws sqs create-queue \
  --queue-name lab01-dlq \
  --region eu-west-1 \
  --query 'QueueUrl' \
  --output text)

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' \
  --output text)
```

### Paso 2: Función con comportamiento configurable (éxito/fallo)

```bash
cat > /tmp/lambda-destinations/handler.py << 'EOF'
import json

def handler(event, context):
    """
    Si el evento tiene 'fail': True, lanza excepción.
    Si no, retorna éxito con el evento.
    """
    if event.get('fail'):
        raise ValueError(f"Error intencional para demostrar Destinations: {event.get('reason', 'sin razón')}")
    
    return {
        'statusCode': 200,
        'message': 'Procesado correctamente',
        'received': event
    }
EOF

mkdir -p /tmp/lambda-destinations
cat > /tmp/lambda-destinations/handler.py << 'EOF'
import json

def handler(event, context):
    if event.get('fail'):
        raise ValueError("Error intencional")
    return {'statusCode': 200, 'received': event}
EOF

cd /tmp/lambda-destinations && zip function.zip handler.py

ROLE_ARN=$(aws iam get-role --role-name lab01-lambda-basic-role --query 'Role.Arn' --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Actualizar el rol para que pueda enviar a SQS
cat > /tmp/destinations-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sqs:SendMessage",
      "Resource": [
        "$SUCCESS_QUEUE_ARN",
        "$FAILURE_QUEUE_ARN",
        "$DLQ_ARN"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name lab01-lambda-basic-role \
  --policy-name lab01-sqs-destinations \
  --policy-document file:///tmp/destinations-policy.json

# Crear la función
aws lambda create-function \
  --function-name lab01-destinations \
  --runtime python3.12 \
  --handler handler.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/lambda-destinations/function.zip \
  --timeout 10 \
  --memory-size 128 \
  --region eu-west-1
```

### Paso 3: Configurar Destinations

```bash
# 3.1 Configurar OnSuccess y OnFailure destinations
aws lambda put-function-event-invoke-config \
  --function-name lab01-destinations \
  --maximum-retry-attempts 1 \
  --destination-config '{
    "OnSuccess": {
      "Destination": "'"$SUCCESS_QUEUE_ARN"'"
    },
    "OnFailure": {
      "Destination": "'"$FAILURE_QUEUE_ARN"'"
    }
  }' \
  --region eu-west-1

# 3.2 Verificar configuración
aws lambda get-function-event-invoke-config \
  --function-name lab01-destinations \
  --region eu-west-1
```

### Paso 4: Probar éxito → OnSuccess destination

```bash
# 4.1 Invocación async con payload de éxito
aws lambda invoke \
  --function-name lab01-destinations \
  --invocation-type Event \
  --payload '{"message": "proceso exitoso", "data": {"id": 123}}' \
  --cli-binary-format raw-in-base64-out \
  --region eu-west-1 \
  /tmp/dest-async-out.json

echo "Invocación asíncrona enviada (202):"
cat /tmp/dest-async-out.json

# 4.2 Esperar y leer mensaje de éxito en la queue
sleep 10
echo "=== Mensaje en queue de ÉXITO ==="
aws sqs receive-message \
  --queue-url "$SUCCESS_QUEUE_URL" \
  --region eu-west-1 \
  --query 'Messages[0].Body' \
  --output text | python3 -m json.tool

# Verás algo como:
# {
#   "version": "1.0",
#   "timestamp": "...",
#   "requestContext": {
#     "requestId": "...",
#     "functionArn": "...",
#     "condition": "Success",
#     "approximateInvokeCount": 1
#   },
#   "requestPayload": {"message": "proceso exitoso", ...},
#   "responseContext": {"statusCode": 200},
#   "responsePayload": {"statusCode": 200, "received": {...}}
# }
```

### Paso 5: Probar fallo → OnFailure destination

```bash
# 5.1 Invocación que falla
aws lambda invoke \
  --function-name lab01-destinations \
  --invocation-type Event \
  --payload '{"fail": true, "reason": "datos inválidos"}' \
  --cli-binary-format raw-in-base64-out \
  --region eu-west-1 \
  /tmp/dest-fail-out.json

# 5.2 Esperar reintentos + envío a OnFailure (1 reintento = ~2 min total)
echo "Esperando reintentos y destination OnFailure (~2 min)..."
sleep 120

echo "=== Mensaje en queue de FALLO ==="
aws sqs receive-message \
  --queue-url "$FAILURE_QUEUE_URL" \
  --region eu-west-1 \
  --query 'Messages[0].Body' \
  --output text | python3 -m json.tool

# Verás:
# {
#   "requestContext": { "condition": "RetriesExhausted", "approximateInvokeCount": 2 },
#   "requestPayload": {"fail": true, ...},
#   "responseContext": { "statusCode": 200, "executedVersion": "$LATEST",
#                        "functionError": "Unhandled" },
#   "responsePayload": { "errorMessage": "Error intencional", "errorType": "ValueError", ... }
# }

# CLAVE: el payload de OnFailure incluye el stack trace completo
# El DLQ clásico solo tendría el evento original sin el error
```

---

## Parte B: Event Source Mapping con bisect-on-error

Cuando Lambda consume de Kinesis o DynamoDB Streams, un error en un mensaje bloquea el shard completo hasta que se resuelva. `bisect-on-error` divide el batch a la mitad para aislar el mensaje problemático.

```bash
# Crear SQS queue para ESM
ESM_QUEUE_URL=$(aws sqs create-queue \
  --queue-name lab01-esm-queue \
  --region eu-west-1 \
  --query 'QueueUrl' \
  --output text)

ESM_QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$ESM_QUEUE_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' \
  --output text)

# Permisos para leer de SQS
aws iam attach-role-policy \
  --role-name lab01-lambda-basic-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole

# Crear Event Source Mapping con DLQ en el ESM
aws lambda create-event-source-mapping \
  --function-name lab01-destinations \
  --event-source-arn "$ESM_QUEUE_ARN" \
  --batch-size 10 \
  --maximum-batching-window-in-seconds 5 \
  --function-response-types ReportBatchItemFailures \
  --region eu-west-1

# ReportBatchItemFailures: permite devolver solo los IDs de mensajes fallidos
# en lugar de fallar el batch completo
```

---

## Resumen: Cuándo usar cada mecanismo

```
¿Tu función es invocada de forma async (S3, SNS, EventBridge)?
  └─ Usa Lambda Destinations (OnSuccess + OnFailure)
     • OnSuccess → siguiente paso del workflow (SQS, EventBridge, otra Lambda)
     • OnFailure → queue de dead letters con contexto completo

¿Tu función consume de una queue/stream (SQS, Kinesis, DDB Streams)?
  └─ Usa DLQ en el Event Source Mapping + ReportBatchItemFailures
     • DLQ en el ESM → mensajes que fallaron tras todos los reintentos
     • ReportBatchItemFailures → no bloquear el batch completo

¿Necesitas compatibilidad con sistemas legacy?
  └─ DLQ clásico en la función (DeadLetterConfig)
```

---

## Limpieza

```bash
aws lambda delete-function --function-name lab01-destinations --region eu-west-1
aws sqs delete-queue --queue-url "$SUCCESS_QUEUE_URL" --region eu-west-1
aws sqs delete-queue --queue-url "$FAILURE_QUEUE_URL" --region eu-west-1
aws sqs delete-queue --queue-url "$DLQ_URL" --region eu-west-1
aws sqs delete-queue --queue-url "$ESM_QUEUE_URL" --region eu-west-1
```

Ver [cleanup.md](../../cleanup.md) para eliminar todos los recursos de lab01.
