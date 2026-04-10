# Lab 03-B: Message Filtering

**Objetivo:** Usar SNS subscription filter policies para que cada subscriber reciba solo los mensajes relevantes. Sin filtering, todos reciben todo.

**Tiempo estimado:** 30 min  
**Coste estimado:** $0  
**Caso de uso:** Pedidos internacionales → solo van a la queue de aduanas

---

## Arquitectura

```
[Publicador]
     │
     ▼  publish con MessageAttributes
[SNS Topic: lab03-pedidos-filtered]
     │
  ┌──┼──┐
  ▼  ▼  ▼
SQS SQS SQS
dom int  vip
(solo (solo (amount
domestic) intl) >=500)
```

---

## Paso 1: Topic + queues

```bash
TOPIC_ARN=$(aws sns create-topic \
  --name lab03-pedidos-filtered \
  --region eu-west-1 \
  --query 'TopicArn' --output text)

# Crear 3 queues
for q in lab03-domestic lab03-international lab03-vip; do
  aws sqs create-queue --queue-name "$q" --region eu-west-1 > /dev/null
done

DOM_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$(aws sqs get-queue-url --queue-name lab03-domestic --region eu-west-1 --query 'QueueUrl' --output text)" \
  --attribute-names QueueArn --region eu-west-1 --query 'Attributes.QueueArn' --output text)

INT_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$(aws sqs get-queue-url --queue-name lab03-international --region eu-west-1 --query 'QueueUrl' --output text)" \
  --attribute-names QueueArn --region eu-west-1 --query 'Attributes.QueueArn' --output text)

VIP_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$(aws sqs get-queue-url --queue-name lab03-vip --region eu-west-1 --query 'QueueUrl' --output text)" \
  --attribute-names QueueArn --region eu-west-1 --query 'Attributes.QueueArn' --output text)

# Políticas SQS para permitir SNS
for ARN in "$DOM_ARN" "$INT_ARN" "$VIP_ARN"; do
  QURL=$(aws sqs get-queue-url \
    --queue-name "$(echo $ARN | cut -d: -f6)" \
    --region eu-west-1 --query 'QueueUrl' --output text)
  aws sqs set-queue-attributes \
    --queue-url "$QURL" \
    --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"sns.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$ARN\\\",\\\"Condition\\\":{\\\"ArnEquals\\\":{\\\"aws:SourceArn\\\":\\\"$TOPIC_ARN\\\"}}}]}\"}" \
    --region eu-west-1
done
```

## Paso 2: Suscribir con filter policies

```bash
# Suscriptor Domestic: solo pedidos de tipo "domestic"
aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$DOM_ARN" \
  --attributes '{
    "FilterPolicy": "{\"order_type\": [\"domestic\"]}"
  }' \
  --region eu-west-1

# Suscriptor International: solo pedidos de tipo "international"
aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$INT_ARN" \
  --attributes '{
    "FilterPolicy": "{\"order_type\": [\"international\"]}"
  }' \
  --region eu-west-1

# Suscriptor VIP: pedidos con amount >= 500 (cualquier tipo)
aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$VIP_ARN" \
  --attributes '{
    "FilterPolicy": "{\"amount\": [{\"numeric\": [\">=\", 500]}]}"
  }' \
  --region eu-west-1

echo "Suscripciones con filtering creadas"
```

## Paso 3: Publicar y verificar routing

```bash
DOM_URL=$(aws sqs get-queue-url --queue-name lab03-domestic --region eu-west-1 --query 'QueueUrl' --output text)
INT_URL=$(aws sqs get-queue-url --queue-name lab03-international --region eu-west-1 --query 'QueueUrl' --output text)
VIP_URL=$(aws sqs get-queue-url --queue-name lab03-vip --region eu-west-1 --query 'QueueUrl' --output text)

# 3.1 Pedido doméstico de 200€ → solo queue domestic
echo "=== Publicando: pedido doméstico 200€ ==="
aws sns publish \
  --topic-arn "$TOPIC_ARN" \
  --message '{"pedido_id": "DOM-001", "total": 200}' \
  --message-attributes '{
    "order_type": {"DataType": "String", "StringValue": "domestic"},
    "amount":     {"DataType": "Number", "StringValue": "200"}
  }' \
  --region eu-west-1 --query 'MessageId' --output text

sleep 2
echo "  domestic queue: $(aws sqs get-queue-attributes --queue-url $DOM_URL --attribute-names ApproximateNumberOfMessages --region eu-west-1 --query 'Attributes.ApproximateNumberOfMessages' --output text) mensajes"
echo "  international queue: $(aws sqs get-queue-attributes --queue-url $INT_URL --attribute-names ApproximateNumberOfMessages --region eu-west-1 --query 'Attributes.ApproximateNumberOfMessages' --output text) mensajes"
echo "  vip queue: $(aws sqs get-queue-attributes --queue-url $VIP_URL --attribute-names ApproximateNumberOfMessages --region eu-west-1 --query 'Attributes.ApproximateNumberOfMessages' --output text) mensajes"
# Esperado: domestic=1, international=0, vip=0

# 3.2 Pedido internacional de 800€ → international Y vip
echo ""
echo "=== Publicando: pedido internacional 800€ ==="
aws sns publish \
  --topic-arn "$TOPIC_ARN" \
  --message '{"pedido_id": "INT-001", "total": 800}' \
  --message-attributes '{
    "order_type": {"DataType": "String", "StringValue": "international"},
    "amount":     {"DataType": "Number", "StringValue": "800"}
  }' \
  --region eu-west-1 --query 'MessageId' --output text

sleep 2
echo "  domestic queue: $(aws sqs get-queue-attributes --queue-url $DOM_URL --attribute-names ApproximateNumberOfMessages --region eu-west-1 --query 'Attributes.ApproximateNumberOfMessages' --output text) mensajes"
echo "  international queue: $(aws sqs get-queue-attributes --queue-url $INT_URL --attribute-names ApproximateNumberOfMessages --region eu-west-1 --query 'Attributes.ApproximateNumberOfMessages' --output text) mensajes"
echo "  vip queue: $(aws sqs get-queue-attributes --queue-url $VIP_URL --attribute-names ApproximateNumberOfMessages --region eu-west-1 --query 'Attributes.ApproximateNumberOfMessages' --output text) mensajes"
# Esperado: international=1, vip=1, domestic=0 (nuevo)
```

## Paso 4: Filter policy avanzada — múltiples condiciones

```bash
# FilterPolicyScope: MessageBody permite filtrar por contenido del body
# (no solo por MessageAttributes) — disponible desde 2023

# Ejemplo: filtrar por campo dentro del JSON del body
aws sns set-subscription-attributes \
  --subscription-arn "$(aws sns list-subscriptions-by-topic \
    --topic-arn $TOPIC_ARN \
    --region eu-west-1 \
    --query 'Subscriptions[0].SubscriptionArn' --output text)" \
  --attribute-name FilterPolicyScope \
  --attribute-value MessageBody \
  --region eu-west-1

# Con FilterPolicyScope=MessageBody, el FilterPolicy aplica sobre el JSON del body:
# FilterPolicy: {"pedido_id": [{"prefix": "DOM-"}]}
# → Solo pedidos cuyo pedido_id empieza por "DOM-"
```

## Limpieza

```bash
TOPIC_ARN=$(aws sns list-topics --region eu-west-1 --query "Topics[?contains(TopicArn, 'lab03-pedidos-filtered')].TopicArn" --output text)
for sub in $(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region eu-west-1 --query 'Subscriptions[*].SubscriptionArn' --output text); do
  aws sns unsubscribe --subscription-arn "$sub" --region eu-west-1
done
aws sns delete-topic --topic-arn "$TOPIC_ARN" --region eu-west-1
for q in lab03-domestic lab03-international lab03-vip; do
  URL=$(aws sqs get-queue-url --queue-name "$q" --region eu-west-1 --query 'QueueUrl' --output text 2>/dev/null)
  [ -n "$URL" ] && aws sqs delete-queue --queue-url "$URL" --region eu-west-1
done
```
