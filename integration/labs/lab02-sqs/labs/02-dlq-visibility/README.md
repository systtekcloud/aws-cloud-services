# Lab 02-B: DLQ y Visibility Timeout

**Objetivo:** Observar el comportamiento de Visibility Timeout cuando un consumer falla, configurar una DLQ, y monitorizar su profundidad con CloudWatch.

**Tiempo estimado:** 40 min  
**Coste estimado:** $0

---

## Parte A: Visibility Timeout en acción

### Paso 1: Crear queue con timeout corto (para ver el comportamiento rápido)

```bash
# Queue con 10s de visibility timeout (corto para el lab)
MAIN_URL=$(aws sqs create-queue \
  --queue-name lab02-visibility-demo \
  --attributes '{
    "VisibilityTimeout": "10",
    "MessageRetentionPeriod": "300"
  }' \
  --region eu-west-1 \
  --query 'QueueUrl' \
  --output text)

# Enviar un mensaje
aws sqs send-message \
  --queue-url "$MAIN_URL" \
  --message-body "mensaje para demostrar visibility timeout" \
  --region eu-west-1
```

### Paso 2: Simular consumer que falla (no borra el mensaje)

```bash
# 2.1 Recibir el mensaje (empieza el visibility timeout de 10s)
RECEIPT=$(aws sqs receive-message \
  --queue-url "$MAIN_URL" \
  --max-number-of-messages 1 \
  --region eu-west-1 \
  --query 'Messages[0].ReceiptHandle' \
  --output text)

echo "Mensaje recibido (invisible por 10s). ReceiptHandle: ${RECEIPT:0:30}..."

# 2.2 Esperar sin borrar (simula fallo del consumer)
echo "Esperando 12s (el consumer 'falló')..."
sleep 12

# 2.3 El mensaje vuelve a ser visible — otro consumer puede recibirlo
BODY=$(aws sqs receive-message \
  --queue-url "$MAIN_URL" \
  --max-number-of-messages 1 \
  --region eu-west-1 \
  --query 'Messages[0].Body' \
  --output text)
echo "Mensaje de nuevo visible: $BODY"

COUNT=$(aws sqs receive-message \
  --queue-url "$MAIN_URL" \
  --max-number-of-messages 1 \
  --region eu-west-1 \
  --query 'Messages[0].Attributes.ApproximateReceiveCount' \
  --attribute-names ApproximateReceiveCount \
  --output text)
echo "ApproximateReceiveCount: $COUNT (cada fallo incrementa esto)"

# 2.4 Borrar correctamente (simulando proceso exitoso)
RECEIPT2=$(aws sqs receive-message \
  --queue-url "$MAIN_URL" \
  --max-number-of-messages 1 \
  --region eu-west-1 \
  --query 'Messages[0].ReceiptHandle' \
  --output text)

aws sqs delete-message \
  --queue-url "$MAIN_URL" \
  --receipt-handle "$RECEIPT2" \
  --region eu-west-1

echo "Mensaje borrado correctamente"
```

---

## Parte B: Dead Letter Queue

### Paso 3: Crear DLQ y queue principal con redrive policy

```bash
# 3.1 Crear DLQ
DLQ_URL=$(aws sqs create-queue \
  --queue-name lab02-main-dlq \
  --attributes '{"MessageRetentionPeriod": "1209600"}' \
  --region eu-west-1 \
  --query 'QueueUrl' \
  --output text)

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' \
  --output text)

echo "DLQ ARN: $DLQ_ARN"

# 3.2 Crear queue principal con redrive policy
# maxReceiveCount=2: después de 2 fallos → DLQ
MAIN_DLQ_URL=$(aws sqs create-queue \
  --queue-name lab02-main-with-dlq \
  --attributes "{
    \"VisibilityTimeout\": \"10\",
    \"MessageRetentionPeriod\": \"300\",
    \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":2}\"
  }" \
  --region eu-west-1 \
  --query 'QueueUrl' \
  --output text)

echo "Queue principal: $MAIN_DLQ_URL"
```

### Paso 4: Simular 2 fallos → mensaje va a DLQ

```bash
# 4.1 Enviar mensaje
aws sqs send-message \
  --queue-url "$MAIN_DLQ_URL" \
  --message-body "mensaje que fallará 2 veces" \
  --region eu-west-1

echo "=== Fallo 1 ==="
# Recibir y NO borrar (fallo 1)
RECEIPT=$(aws sqs receive-message \
  --queue-url "$MAIN_DLQ_URL" \
  --max-number-of-messages 1 \
  --attribute-names ApproximateReceiveCount \
  --region eu-west-1 \
  --query 'Messages[0].{Handle: ReceiptHandle, Count: Attributes.ApproximateReceiveCount}' \
  --output json)
echo "$RECEIPT"
sleep 12  # Visibility timeout expira

echo "=== Fallo 2 (maxReceiveCount = 2) ==="
RECEIPT=$(aws sqs receive-message \
  --queue-url "$MAIN_DLQ_URL" \
  --max-number-of-messages 1 \
  --attribute-names ApproximateReceiveCount \
  --region eu-west-1 \
  --query 'Messages[0].{Handle: ReceiptHandle, Count: Attributes.ApproximateReceiveCount}' \
  --output json)
echo "$RECEIPT"
sleep 12  # Visibility timeout expira de nuevo

echo "=== Comprobando DLQ ==="
sleep 5
# El mensaje debería estar en la DLQ ahora
aws sqs receive-message \
  --queue-url "$DLQ_URL" \
  --max-number-of-messages 1 \
  --attribute-names All \
  --region eu-west-1 \
  --query 'Messages[0].{Body: Body, ReceiveCount: Attributes.ApproximateReceiveCount}'
```

### Paso 5: CloudWatch Alarm en DLQ

```bash
# 5.1 Crear alarma: si DLQ tiene > 0 mensajes visibles → alerta
aws cloudwatch put-metric-alarm \
  --alarm-name "lab02-dlq-has-messages" \
  --alarm-description "Mensajes en DLQ requieren investigación" \
  --namespace AWS/SQS \
  --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value=lab02-main-dlq \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --region eu-west-1

# 5.2 Ver estado de la alarma
aws cloudwatch describe-alarms \
  --alarm-names "lab02-dlq-has-messages" \
  --region eu-west-1 \
  --query 'MetricAlarms[0].{State: StateValue, Reason: StateReason}'
```

### Paso 6: Redrive — reenviar mensajes de DLQ a la queue original

```bash
# Cuando investigas y corriges el bug, puedes redrive los mensajes
# de la DLQ de vuelta a la queue principal para reprocesarlos.

# Obtener Source Queue ARN
SOURCE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$MAIN_DLQ_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' \
  --output text)

# Iniciar redrive
aws sqs start-message-move-task \
  --source-arn "$DLQ_ARN" \
  --destination-arn "$SOURCE_ARN" \
  --region eu-west-1

echo "Redrive iniciado. Los mensajes de la DLQ vuelven a la queue principal."
```

---

## Limpieza

```bash
aws sqs delete-queue --queue-url "$MAIN_URL" --region eu-west-1 2>/dev/null || true
aws sqs delete-queue --queue-url "$MAIN_DLQ_URL" --region eu-west-1 2>/dev/null || true
aws sqs delete-queue --queue-url "$DLQ_URL" --region eu-west-1 2>/dev/null || true
aws cloudwatch delete-alarms --alarm-names "lab02-dlq-has-messages" --region eu-west-1 2>/dev/null || true
```
