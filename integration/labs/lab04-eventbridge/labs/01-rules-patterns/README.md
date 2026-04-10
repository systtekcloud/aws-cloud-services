# Lab 04-A: Rules y Event Patterns

**Objetivo:** Crear un custom event bus, publicar eventos con `put-events`, configurar reglas con event patterns complejos y múltiples targets.

**Tiempo estimado:** 40 min  
**Coste estimado:** $0 (free tier 1M eventos/mes)

---

## Paso 1: Crear custom event bus

```bash
BUS_ARN=$(aws events create-event-bus \
  --name lab04-eventos \
  --region eu-west-1 \
  --query 'EventBusArn' \
  --output text)

echo "Event Bus ARN: $BUS_ARN"

# Verificar
aws events describe-event-bus \
  --name lab04-eventos \
  --region eu-west-1
```

## Paso 2: Crear target — CloudWatch Log Group (para observar eventos)

```bash
# Log group para capturar todos los eventos del bus
aws logs create-log-group \
  --log-group-name /aws/events/lab04-eventos \
  --region eu-west-1

# Dar permisos a EventBridge para escribir en CloudWatch Logs
aws logs put-resource-policy \
  --policy-name EventBridgeToCloudWatch \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "events.amazonaws.com"},
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:eu-west-1:*:log-group:/aws/events/lab04-eventos:*"
    }]
  }' \
  --region eu-west-1

LOG_GROUP_ARN="arn:aws:logs:eu-west-1:$(aws sts get-caller-identity --query Account --output text):log-group:/aws/events/lab04-eventos"
```

## Paso 3: Regla — capturar todos los eventos del bus

```bash
# Regla 1: catch-all (para observación)
aws events put-rule \
  --name lab04-catch-all \
  --event-bus-name lab04-eventos \
  --event-pattern '{"source": [{"prefix": ""}]}' \
  --state ENABLED \
  --region eu-west-1

# Target: CloudWatch Logs
aws events put-targets \
  --rule lab04-catch-all \
  --event-bus-name lab04-eventos \
  --targets "[{
    \"Id\": \"catch-all-logs\",
    \"Arn\": \"$LOG_GROUP_ARN\"
  }]" \
  --region eu-west-1
```

## Paso 4: SQS targets para reglas específicas

```bash
# Queue para pedidos de alto valor
HIGH_VALUE_URL=$(aws sqs create-queue \
  --queue-name lab04-high-value-orders \
  --region eu-west-1 --query 'QueueUrl' --output text)

HIGH_VALUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$HIGH_VALUE_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 --query 'Attributes.QueueArn' --output text)

# Política SQS para permitir EventBridge
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws sqs set-queue-attributes \
  --queue-url "$HIGH_VALUE_URL" \
  --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"events.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$HIGH_VALUE_ARN\\\"}]}\"}" \
  --region eu-west-1

# Queue para pedidos internacionales
INTL_URL=$(aws sqs create-queue \
  --queue-name lab04-international-orders \
  --region eu-west-1 --query 'QueueUrl' --output text)

INTL_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$INTL_URL" \
  --attribute-names QueueArn \
  --region eu-west-1 --query 'Attributes.QueueArn' --output text)

aws sqs set-queue-attributes \
  --queue-url "$INTL_URL" \
  --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"events.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$INTL_ARN\\\"}]}\"}" \
  --region eu-west-1
```

## Paso 5: Reglas con event patterns complejos

```bash
# Regla 2: pedidos de alto valor (>= 500€)
aws events put-rule \
  --name lab04-high-value \
  --event-bus-name lab04-eventos \
  --event-pattern '{
    "source": ["com.miempresa.pedidos"],
    "detail-type": ["PedidoCreado"],
    "detail": {
      "total": [{"numeric": [">=", 500]}]
    }
  }' \
  --state ENABLED \
  --region eu-west-1

aws events put-targets \
  --rule lab04-high-value \
  --event-bus-name lab04-eventos \
  --targets "[{\"Id\": \"high-value-queue\", \"Arn\": \"$HIGH_VALUE_ARN\"}]" \
  --region eu-west-1

# Regla 3: pedidos internacionales con input transformer
# (transforma el evento antes de enviarlo — sin Lambda intermedia)
aws events put-rule \
  --name lab04-international \
  --event-bus-name lab04-eventos \
  --event-pattern '{
    "source": ["com.miempresa.pedidos"],
    "detail-type": ["PedidoCreado"],
    "detail": {
      "tipo": ["international"]
    }
  }' \
  --state ENABLED \
  --region eu-west-1

aws events put-targets \
  --rule lab04-international \
  --event-bus-name lab04-eventos \
  --targets "[{
    \"Id\": \"international-queue\",
    \"Arn\": \"$INTL_ARN\",
    \"InputTransformer\": {
      \"InputPathsMap\": {
        \"pedido_id\": \"$.detail.pedido_id\",
        \"total\": \"$.detail.total\",
        \"pais\": \"$.detail.pais_destino\"
      },
      \"InputTemplate\": \"{\\\"pedido\\\": \\\"<pedido_id>\\\", \\\"total\\\": <total>, \\\"aduanas_pais\\\": \\\"<pais>\\\"}\"
    }
  }]" \
  --region eu-west-1
```

## Paso 6: Publicar eventos y verificar routing

```bash
# 6.1 Pedido doméstico de 200€ → no llega a ninguna regla específica
aws events put-events \
  --entries "[{
    \"Source\": \"com.miempresa.pedidos\",
    \"DetailType\": \"PedidoCreado\",
    \"Detail\": \"{\\\"pedido_id\\\": \\\"PED-001\\\", \\\"total\\\": 200, \\\"tipo\\\": \\\"domestic\\\"}\",
    \"EventBusName\": \"lab04-eventos\"
  }]" \
  --region eu-west-1

# 6.2 Pedido de alto valor (800€) → va a high-value queue
aws events put-events \
  --entries "[{
    \"Source\": \"com.miempresa.pedidos\",
    \"DetailType\": \"PedidoCreado\",
    \"Detail\": \"{\\\"pedido_id\\\": \\\"PED-002\\\", \\\"total\\\": 800, \\\"tipo\\\": \\\"domestic\\\"}\",
    \"EventBusName\": \"lab04-eventos\"
  }]" \
  --region eu-west-1

# 6.3 Pedido internacional → va a international queue (con input transformer)
aws events put-events \
  --entries "[{
    \"Source\": \"com.miempresa.pedidos\",
    \"DetailType\": \"PedidoCreado\",
    \"Detail\": \"{\\\"pedido_id\\\": \\\"PED-003\\\", \\\"total\\\": 350, \\\"tipo\\\": \\\"international\\\", \\\"pais_destino\\\": \\\"FR\\\"}\",
    \"EventBusName\": \"lab04-eventos\"
  }]" \
  --region eu-west-1

sleep 3

# Verificar high-value queue
echo "=== High Value Queue ==="
aws sqs receive-message --queue-url "$HIGH_VALUE_URL" --region eu-west-1 \
  --query 'Messages[0].Body' --output text | python3 -m json.tool 2>/dev/null

# Verificar international queue (debería tener el payload transformado)
echo ""
echo "=== International Queue (payload transformado) ==="
aws sqs receive-message --queue-url "$INTL_URL" --region eu-west-1 \
  --query 'Messages[0].Body' --output text
# Debería verse: {"pedido": "PED-003", "total": 350, "aduanas_pais": "FR"}

# Ver todos los eventos en CloudWatch Logs
echo ""
echo "=== Todos los eventos en CloudWatch Logs ==="
aws logs filter-log-events \
  --log-group-name /aws/events/lab04-eventos \
  --region eu-west-1 \
  --query 'events[*].message' --output text
```

## Paso 7: Test del event pattern matcher (herramienta de consola)

```bash
# Probar si un evento hace match con un pattern SIN publicarlo
aws events test-event-pattern \
  --event-pattern '{
    "source": ["com.miempresa.pedidos"],
    "detail": {"total": [{"numeric": [">=", 500]}]}
  }' \
  --event '{
    "source": "com.miempresa.pedidos",
    "detail-type": "PedidoCreado",
    "detail": {"total": 800}
  }' \
  --region eu-west-1
# Resultado: {"Result": true}

aws events test-event-pattern \
  --event-pattern '{
    "source": ["com.miempresa.pedidos"],
    "detail": {"total": [{"numeric": [">=", 500]}]}
  }' \
  --event '{
    "source": "com.miempresa.pedidos",
    "detail-type": "PedidoCreado",
    "detail": {"total": 200}
  }' \
  --region eu-west-1
# Resultado: {"Result": false}
```

## Limpieza

```bash
aws events remove-targets --rule lab04-catch-all --event-bus-name lab04-eventos --ids catch-all-logs --region eu-west-1
aws events remove-targets --rule lab04-high-value --event-bus-name lab04-eventos --ids high-value-queue --region eu-west-1
aws events remove-targets --rule lab04-international --event-bus-name lab04-eventos --ids international-queue --region eu-west-1
aws events delete-rule --name lab04-catch-all --event-bus-name lab04-eventos --region eu-west-1
aws events delete-rule --name lab04-high-value --event-bus-name lab04-eventos --region eu-west-1
aws events delete-rule --name lab04-international --event-bus-name lab04-eventos --region eu-west-1
aws events delete-event-bus --name lab04-eventos --region eu-west-1
aws sqs delete-queue --queue-url "$HIGH_VALUE_URL" --region eu-west-1
aws sqs delete-queue --queue-url "$INTL_URL" --region eu-west-1
aws logs delete-log-group --log-group-name /aws/events/lab04-eventos --region eu-west-1
```
