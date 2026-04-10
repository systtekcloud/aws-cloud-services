# Lab 02-A: Standard Queue vs FIFO Queue

**Objetivo:** Crear y comparar el comportamiento real de Standard vs FIFO queues. Observar la diferencia en ordering y deduplicación.

**Tiempo estimado:** 30 min  
**Coste estimado:** $0 (free tier)

---

## Paso 1: Crear Standard Queue

```bash
# 1.1 Crear queue Standard con long polling
STANDARD_URL=$(aws sqs create-queue \
  --queue-name lab02-standard \
  --attributes '{
    "VisibilityTimeout": "60",
    "MessageRetentionPeriod": "86400",
    "ReceiveMessageWaitTimeSeconds": "20"
  }' \
  --region eu-west-1 \
  --query 'QueueUrl' \
  --output text)

echo "Standard URL: $STANDARD_URL"

STANDARD_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$STANDARD_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' \
  --output text)
```

## Paso 2: Crear FIFO Queue

```bash
# 2.1 FIFO requiere sufijo .fifo en el nombre
FIFO_URL=$(aws sqs create-queue \
  --queue-name lab02-fifo.fifo \
  --attributes '{
    "FifoQueue": "true",
    "ContentBasedDeduplication": "true",
    "VisibilityTimeout": "60",
    "ReceiveMessageWaitTimeSeconds": "20"
  }' \
  --region eu-west-1 \
  --query 'QueueUrl' \
  --output text)

echo "FIFO URL: $FIFO_URL"
```

## Paso 3: Enviar mensajes y comparar ordering

```bash
# 3.1 Enviar 5 mensajes numerados a la Standard Queue
echo "=== Enviando a Standard Queue ==="
for i in 1 2 3 4 5; do
  aws sqs send-message \
    --queue-url "$STANDARD_URL" \
    --message-body "Mensaje numero $i" \
    --region eu-west-1 \
    --query 'MessageId' \
    --output text
done

# 3.2 Recibir mensajes de Standard Queue
echo "=== Recibiendo de Standard Queue (orden puede variar) ==="
for i in {1..5}; do
  aws sqs receive-message \
    --queue-url "$STANDARD_URL" \
    --max-number-of-messages 1 \
    --wait-time-seconds 5 \
    --region eu-west-1 \
    --query 'Messages[0].Body' \
    --output text 2>/dev/null || echo "(vacío)"
done
# OBSERVACIÓN: el orden NO es garantizado en Standard

# 3.3 Enviar a FIFO Queue (requiere MessageGroupId)
echo "=== Enviando a FIFO Queue ==="
for i in 1 2 3 4 5; do
  aws sqs send-message \
    --queue-url "$FIFO_URL" \
    --message-body "Mensaje numero $i" \
    --message-group-id "grupo-principal" \
    --region eu-west-1 \
    --query 'MessageId' \
    --output text
done

# 3.4 Recibir de FIFO Queue
echo "=== Recibiendo de FIFO Queue (orden garantizado) ==="
for i in {1..5}; do
  aws sqs receive-message \
    --queue-url "$FIFO_URL" \
    --max-number-of-messages 1 \
    --wait-time-seconds 5 \
    --region eu-west-1 \
    --query 'Messages[0].Body' \
    --output text 2>/dev/null || echo "(vacío)"
done
# OBSERVACIÓN: siempre verás 1, 2, 3, 4, 5 en ese orden
```

## Paso 4: Deduplicación en FIFO

```bash
# 4.1 ContentBasedDeduplication está activo (calculado del body)
# Enviar el mismo mensaje 3 veces en 5 minutos = solo 1 se entrega

echo "=== Test deduplicación FIFO ==="
for i in 1 2 3; do
  aws sqs send-message \
    --queue-url "$FIFO_URL" \
    --message-body "mensaje-deduplicado" \
    --message-group-id "test-dedup" \
    --region eu-west-1 \
    --query '{MessageId: MessageId, SequenceNumber: SequenceNumber}' \
    --output json
done
# Los 3 envíos devolverán el MISMO MessageId — SQS deduplica

# Recibir — solo debería llegar 1 mensaje
aws sqs receive-message \
  --queue-url "$FIFO_URL" \
  --max-number-of-messages 10 \
  --wait-time-seconds 5 \
  --region eu-west-1 \
  --query 'Messages[*].Body'

# 4.2 Con MessageDeduplicationId explícito (más control)
aws sqs send-message \
  --queue-url "$FIFO_URL" \
  --message-body "pago-procesado" \
  --message-group-id "pagos" \
  --message-deduplication-id "pago-id-789" \
  --region eu-west-1

# Enviar de nuevo con mismo deduplication-id → no llega
aws sqs send-message \
  --queue-url "$FIFO_URL" \
  --message-body "pago-procesado-duplicado" \
  --message-group-id "pagos" \
  --message-deduplication-id "pago-id-789" \
  --region eu-west-1
```

## Paso 5: MessageGroupId y paralelismo en FIFO

```bash
# En FIFO, el MessageGroupId determina el "shard lógico"
# Mensajes del mismo grupo = en orden entre sí
# Mensajes de grupos distintos = pueden procesarse en paralelo

# Ejemplo: pedidos de distintos usuarios (cada userId = su propio grupo)
for user_id in user-1 user-2 user-3; do
  for order in A B C; do
    aws sqs send-message \
      --queue-url "$FIFO_URL" \
      --message-body "{\"user\": \"$user_id\", \"order\": \"$order\"}" \
      --message-group-id "$user_id" \
      --region eu-west-1 \
      --query 'MessageId' \
      --output text
  done
done

# Los pedidos de user-1 llegan en orden A→B→C
# Pero user-1, user-2, user-3 se pueden procesar en paralelo
```

## Limpieza

```bash
aws sqs delete-queue --queue-url "$STANDARD_URL" --region eu-west-1
aws sqs delete-queue --queue-url "$FIFO_URL" --region eu-west-1
```
