# Lab 04-B: Cross-Account Event Bus

**Objetivo:** Configurar un event bus central en una cuenta de Observabilidad/Security que recibe eventos de múltiples cuentas de workload. Patrón real en arquitecturas multi-cuenta.

**Tiempo estimado:** 30 min (requiere 2 cuentas AWS para el ejercicio completo; se documenta el patrón con una cuenta para el lab)  
**Coste estimado:** $0

---

## Arquitectura

```
Cuenta Workload (A)           Cuenta Security/Obs (B)
┌─────────────────┐           ┌──────────────────────────┐
│  Custom Bus A   │──events──→│  Custom Bus Central      │
│  (put-events)   │           │  (resource policy abierta│
│                 │           │   para cuenta A)          │
└─────────────────┘           │         │                │
                              │    ┌────┼────┐           │
                              │    ▼    ▼    ▼           │
                              │  Lambda CW  SQS          │
                              │  (alert)(logs)(archive)  │
                              └──────────────────────────┘
```

---

## Paso 1: Crear el bus central (simula cuenta B)

```bash
CENTRAL_BUS_ARN=$(aws events create-event-bus \
  --name lab04-central-bus \
  --region eu-west-1 \
  --query 'EventBusArn' \
  --output text)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Central Bus ARN: $CENTRAL_BUS_ARN"
```

## Paso 2: Resource policy — permitir envío desde otra cuenta

```bash
# En un escenario real, SENDER_ACCOUNT_ID sería el ID de la cuenta workload
# En este lab de una sola cuenta, usamos la misma cuenta
SENDER_ACCOUNT_ID="$ACCOUNT_ID"  # En producción: ID de la cuenta workload

aws events put-permission \
  --event-bus-name lab04-central-bus \
  --action events:PutEvents \
  --principal "$SENDER_ACCOUNT_ID" \
  --statement-id "allow-workload-account" \
  --region eu-west-1

# Verificar la policy resultante
aws events describe-event-bus \
  --name lab04-central-bus \
  --region eu-west-1 \
  --query 'Policy'
```

> **En producción con Organization:** usar `--condition '{"Type": "StringEquals", "Key": "aws:PrincipalOrgID", "Value": "o-xxxx"}'` para permitir toda la organización sin especificar cada cuenta.

## Paso 3: Crear regla en el bus central para procesar eventos recibidos

```bash
# Log group para auditoría
aws logs create-log-group \
  --log-group-name /aws/events/lab04-central-bus \
  --region eu-west-1

aws logs put-resource-policy \
  --policy-name EventBridgeCentralLogs \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"events.amazonaws.com\"},
      \"Action\": [\"logs:CreateLogStream\", \"logs:PutLogEvents\"],
      \"Resource\": \"arn:aws:logs:eu-west-1:$ACCOUNT_ID:log-group:/aws/events/lab04-central-bus:*\"
    }]
  }" \
  --region eu-west-1

CENTRAL_LOG_ARN="arn:aws:logs:eu-west-1:$ACCOUNT_ID:log-group:/aws/events/lab04-central-bus"

# Regla: capturar todos los eventos en el bus central
aws events put-rule \
  --name lab04-central-catch-all \
  --event-bus-name lab04-central-bus \
  --event-pattern '{"source": [{"prefix": ""}]}' \
  --state ENABLED \
  --region eu-west-1

aws events put-targets \
  --rule lab04-central-catch-all \
  --event-bus-name lab04-central-bus \
  --targets "[{\"Id\": \"central-logs\", \"Arn\": \"$CENTRAL_LOG_ARN\"}]" \
  --region eu-west-1
```

## Paso 4: Bus workload — reenviar al bus central

```bash
# Bus de la cuenta workload (simula cuenta A)
WORKLOAD_BUS_ARN=$(aws events create-event-bus \
  --name lab04-workload-bus \
  --region eu-west-1 \
  --query 'EventBusArn' \
  --output text)

# Regla en el bus workload: reenviar ciertos eventos al bus central
aws events put-rule \
  --name lab04-forward-to-central \
  --event-bus-name lab04-workload-bus \
  --event-pattern '{
    "source": [{"prefix": "com.miempresa"}],
    "detail-type": ["AlertaSeguridad", "EventoAuditoria", "ErrorCritico"]
  }' \
  --state ENABLED \
  --region eu-west-1

# Target: el bus central (cross-account en prod, mismo account en lab)
aws events put-targets \
  --rule lab04-forward-to-central \
  --event-bus-name lab04-workload-bus \
  --targets "[{
    \"Id\": \"forward-to-central\",
    \"Arn\": \"$CENTRAL_BUS_ARN\",
    \"RoleArn\": \"$(aws iam get-role --role-name lab04-eventbridge-role 2>/dev/null --query 'Role.Arn' --output text || echo 'PENDING_ROLE')\"
  }]" \
  --region eu-west-1 2>/dev/null || echo "Nota: necesita rol IAM para cross-bus routing"

# Rol IAM para que EventBridge pueda poner eventos en otro bus
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "events.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam create-role \
  --role-name lab04-eventbridge-cross-bus-role \
  --assume-role-policy-document "$TRUST_POLICY" \
  2>/dev/null || true

aws iam put-role-policy \
  --role-name lab04-eventbridge-cross-bus-role \
  --policy-name put-events-to-central \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"events:PutEvents\",
      \"Resource\": \"$CENTRAL_BUS_ARN\"
    }]
  }"

ROLE_ARN=$(aws iam get-role \
  --role-name lab04-eventbridge-cross-bus-role \
  --query 'Role.Arn' --output text)

# Actualizar el target con el rol correcto
aws events put-targets \
  --rule lab04-forward-to-central \
  --event-bus-name lab04-workload-bus \
  --targets "[{
    \"Id\": \"forward-to-central\",
    \"Arn\": \"$CENTRAL_BUS_ARN\",
    \"RoleArn\": \"$ROLE_ARN\"
  }]" \
  --region eu-west-1
```

## Paso 5: Enviar eventos y verificar el flujo cross-bus

```bash
# Evento normal → NO se reenvía al central bus (source no coincide)
aws events put-events \
  --entries "[{
    \"Source\": \"com.miempresa.pedidos\",
    \"DetailType\": \"PedidoCreado\",
    \"Detail\": \"{\\\"pedido_id\\\": \\\"P001\\\"}\",
    \"EventBusName\": \"lab04-workload-bus\"
  }]" \
  --region eu-west-1

# Alerta de seguridad → SÍ se reenvía al central bus
aws events put-events \
  --entries "[{
    \"Source\": \"com.miempresa.security\",
    \"DetailType\": \"AlertaSeguridad\",
    \"Detail\": \"{\\\"tipo\\\": \\\"login-fallido\\\", \\\"usuario\\\": \\\"admin\\\", \\\"intentos\\\": 5}\",
    \"EventBusName\": \"lab04-workload-bus\"
  }]" \
  --region eu-west-1

sleep 5

# Ver en el log del bus central (debería verse la alerta de seguridad)
aws logs filter-log-events \
  --log-group-name /aws/events/lab04-central-bus \
  --region eu-west-1 \
  --query 'events[*].message' \
  --output text
```

## Limpieza

```bash
aws events remove-targets --rule lab04-forward-to-central --event-bus-name lab04-workload-bus --ids forward-to-central --region eu-west-1
aws events remove-targets --rule lab04-central-catch-all --event-bus-name lab04-central-bus --ids central-logs --region eu-west-1
aws events delete-rule --name lab04-forward-to-central --event-bus-name lab04-workload-bus --region eu-west-1
aws events delete-rule --name lab04-central-catch-all --event-bus-name lab04-central-bus --region eu-west-1
aws events delete-event-bus --name lab04-workload-bus --region eu-west-1
aws events delete-event-bus --name lab04-central-bus --region eu-west-1
aws iam delete-role-policy --role-name lab04-eventbridge-cross-bus-role --policy-name put-events-to-central
aws iam delete-role --role-name lab04-eventbridge-cross-bus-role
aws logs delete-log-group --log-group-name /aws/events/lab04-central-bus --region eu-west-1
```
