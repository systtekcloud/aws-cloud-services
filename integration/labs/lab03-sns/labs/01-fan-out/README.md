# Lab 03-A: Fan-out Pattern

**Objetivo:** Implementar el patrón fan-out: un topic SNS entrega el mismo evento a múltiples SQS queues. Demostrar desacoplamiento: cada subscriber recibe independientemente.

**Tiempo estimado:** 35 min  
**Coste estimado:** $0  
**Caso de uso:** Pedido creado → notifica inventario + facturación + email simultáneamente

---

## Arquitectura

```
[CLI publish]
      │
      ▼
[SNS Topic: lab03-pedidos]
      │
  ┌───┼───┐
  ▼   ▼   ▼
SQS SQS SQS
inv fac email
```

---

## Paso 1: Crear el topic SNS

```bash
TOPIC_ARN=$(aws sns create-topic \
  --name lab03-pedidos \
  --region eu-west-1 \
  --query 'TopicArn' \
  --output text)

echo "Topic ARN: $TOPIC_ARN"
```

## Paso 2: Crear las queues SQS de cada subscriber

```bash
# Queue de Inventario
INV_URL=$(aws sqs create-queue \
  --queue-name lab03-inventario \
  --region eu-west-1 \
  --query 'QueueUrl' --output text)

INV_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$INV_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' --output text)

# Queue de Facturación
FAC_URL=$(aws sqs create-queue \
  --queue-name lab03-facturacion \
  --region eu-west-1 \
  --query 'QueueUrl' --output text)

FAC_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$FAC_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' --output text)

# Queue de Email
EMAIL_URL=$(aws sqs create-queue \
  --queue-name lab03-email \
  --region eu-west-1 \
  --query 'QueueUrl' --output text)

EMAIL_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$EMAIL_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 \
  --query 'Attributes.QueueArn' --output text)
```

## Paso 3: Dar permisos a SNS para escribir en las queues

```bash
# SQS requiere una resource policy que permita a SNS enviar mensajes
for QUEUE_URL in "$INV_URL" "$FAC_URL" "$EMAIL_URL"; do
  QUEUE_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn \
    --region eu-west-1 \
    --query 'Attributes.QueueArn' --output text)

  QUEUE_NAME=$(echo "$QUEUE_ARN" | cut -d: -f6)

  aws sqs set-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attributes "{
      \"Policy\": \"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"sns.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$QUEUE_ARN\\\",\\\"Condition\\\":{\\\"ArnEquals\\\":{\\\"aws:SourceArn\\\":\\\"$TOPIC_ARN\\\"}}}]}\"
    }" \
    --region eu-west-1

  echo "Policy aplicada a: $QUEUE_NAME"
done
```

## Paso 4: Suscribir las queues al topic

```bash
# Suscripción Inventario
INV_SUB=$(aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$INV_ARN" \
  --region eu-west-1 \
  --query 'SubscriptionArn' --output text)

# Suscripción Facturación
FAC_SUB=$(aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$FAC_ARN" \
  --region eu-west-1 \
  --query 'SubscriptionArn' --output text)

# Suscripción Email queue
EMAIL_SUB=$(aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$EMAIL_ARN" \
  --region eu-west-1 \
  --query 'SubscriptionArn' --output text)

echo "Suscripciones creadas:"
echo "  Inventario:  $INV_SUB"
echo "  Facturación: $FAC_SUB"
echo "  Email:       $EMAIL_SUB"
```

## Paso 5: Publicar un evento y verificar fan-out

```bash
# 5.1 Publicar evento "pedido creado"
MSG_ID=$(aws sns publish \
  --topic-arn "$TOPIC_ARN" \
  --message '{"pedido_id": "PED-001", "cliente": "Sergi", "total": 149.99, "items": 3}' \
  --subject "pedido-creado" \
  --region eu-west-1 \
  --query 'MessageId' --output text)

echo "Publicado MessageId: $MSG_ID"

# 5.2 Verificar que los 3 subscribers recibieron el mensaje
sleep 2
echo ""
echo "=== Queue Inventario ==="
aws sqs receive-message \
  --queue-url "$INV_URL" \
  --max-number-of-messages 1 \
  --region eu-west-1 \
  --query 'Messages[0].Body' --output text | python3 -m json.tool 2>/dev/null | grep -E '"Message"|"Subject"'

echo ""
echo "=== Queue Facturación ==="
aws sqs receive-message \
  --queue-url "$FAC_URL" \
  --max-number-of-messages 1 \
  --region eu-west-1 \
  --query 'Messages[0].Body' --output text | python3 -m json.tool 2>/dev/null | grep -E '"Message"|"Subject"'

echo ""
echo "=== Queue Email ==="
aws sqs receive-message \
  --queue-url "$EMAIL_URL" \
  --max-number-of-messages 1 \
  --region eu-west-1 \
  --query 'Messages[0].Body' --output text | python3 -m json.tool 2>/dev/null | grep -E '"Message"|"Subject"'
```

> **Observación:** Los 3 subscribers reciben el mismo mensaje. El payload que llega a SQS es un envelope SNS con el mensaje original en el campo `"Message"`.

## Paso 6: Observar el envelope SNS

```bash
# El mensaje en SQS tiene este formato (SNS envelope):
# {
#   "Type": "Notification",
#   "MessageId": "...",
#   "TopicArn": "arn:aws:sns:...",
#   "Subject": "pedido-creado",
#   "Message": "{\"pedido_id\": \"PED-001\", ...}",   ← tu mensaje original
#   "Timestamp": "...",
#   "SignatureVersion": "1",
#   "Signature": "...",
#   "MessageAttributes": {}
# }

# En Lambda con trigger SNS, el handler recibe event['Records'][0]['Sns']['Message']
# En Lambda con trigger SQS (fan-out SNS→SQS→Lambda):
#   body = json.loads(record['body'])
#   mensaje_original = json.loads(body['Message'])
```

## Limpieza

```bash
aws sns unsubscribe --subscription-arn "$INV_SUB" --region eu-west-1
aws sns unsubscribe --subscription-arn "$FAC_SUB" --region eu-west-1
aws sns unsubscribe --subscription-arn "$EMAIL_SUB" --region eu-west-1
aws sns delete-topic --topic-arn "$TOPIC_ARN" --region eu-west-1
aws sqs delete-queue --queue-url "$INV_URL" --region eu-west-1
aws sqs delete-queue --queue-url "$FAC_URL" --region eu-west-1
aws sqs delete-queue --queue-url "$EMAIL_URL" --region eu-west-1
```
