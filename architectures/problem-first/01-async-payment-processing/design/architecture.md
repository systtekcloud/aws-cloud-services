# Diseño: Async Payment Processing

## Flujo detallado

```
1. Cliente → POST /pagos
   Headers: Authorization: Bearer <jwt>
   Body: { "monto": 149.99, "moneda": "EUR", "destino": "ES12..." }

2. API Gateway (REST)
   - Authorizer: Cognito JWT → extrae cliente_id
   - Request validation: JSON Schema (monto > 0, IBAN válido)
   - Responde: 202 Accepted + { "pago_id": "PAY-uuid", "status": "procesando" }

3. API GW → SQS FIFO
   - MessageGroupId = cliente_id (ordering por cliente)
   - MessageDeduplicationId = hash(cliente_id + monto + timestamp_truncado_a_5min)
   - Visibility timeout: 90s (> Lambda timeout de 30s × 3)

4. Lambda (ESM de SQS)
   - ReportBatchItemFailures: fallos individuales no bloquean el batch
   - Valida: cliente activo, fondos suficientes (DynamoDB check)
   - Escribe registro inicial en DynamoDB: { pago_id, status: "validado", ts }
   - Inicia Step Functions execution con el payload del pago

5. Step Functions (Standard)

   ValidarConBanco (Task, Lambda)
   ├─ Llama a API del banco via HTTPS
   ├─ Retry: Lambda.TooManyRequests + BancoTimeout
   │   IntervalSeconds: 2, MaxAttempts: 3, BackoffRate: 2, Jitter: FULL
   └─ Catch: BancoRechazado → NotificarRechazo

   RegistrarTransaccion (Task, DynamoDB PutItem directo)
   ├─ sdk integration: arn:aws:states:::dynamodb:putItem
   ├─ Condition: attribute_not_exists(pago_id)  ← idempotency
   └─ Guarda: { pago_id, status: "completado", banco_ref, ts_completado }

   NotificarCliente (Task, SNS Publish)
   ├─ sdk integration: arn:aws:states:::sns:publish
   ├─ Topic: pagos-notificaciones
   └─ Message: { pago_id, status, monto, ts }

   NotificarRechazo (Task, SNS Publish)
   └─ Topic: pagos-notificaciones con detalle del rechazo

6. DynamoDB
   - PK: pago_id (UUID)
   - GSI: cliente_id + fecha (queries por cliente)
   - TTL: 2 años (auditoría legal)
   - Point-in-time recovery: habilitado en prod

7. SNS → Email (SES) + Mobile Push (FCM/APNS) + Webhook del cliente
```

## Decisiones de diseño

### ¿Por qué SQS FIFO y no Standard?

Los pagos del mismo cliente deben procesarse en orden. Si el cliente hace un pago A y luego cancela con pago B, el orden importa. Standard queue no garantiza esto. La penalización de throughput (300 TPS vs ilimitado) es aceptable — una fintech media no supera 300 pagos/segundo por cliente.

### ¿Por qué Step Functions y no Lambda directa?

Lambda directa procesando el pago no proporciona:
- Historial de auditoría (¿cuándo exactamente se llamó al banco?)
- Retry declarativo con estado entre reintentos
- Visibilidad del estado actual de cada pago

Con Step Functions, el equipo de soporte puede ver en consola en qué estado está cualquier pago.

### ¿Por qué DynamoDB y no RDS?

- Escala automáticamente con el volumen de pagos
- Lecturas de ítem por pago_id son O(1)
- GSI para queries por cliente sin hot partition
- Point-in-time recovery para auditoría legal
- Sin connection pool management (Lambda + DynamoDB = sin fricción)

RDS sería más apropiado si necesitáramos joins complejos entre tablas (reporting), pero eso va a un data warehouse (Redshift/Athena), no a la base transaccional.

### ¿Por qué API GW responde 202 y no 200?

Procesar el pago tarda 2-8 segundos (llamada al banco + Step Functions). El cliente no debe esperar. La API responde inmediatamente con el pago_id. El cliente hace polling o recibe notificación push cuando termina.

Alternativamente: WebSocket API para notificación en tiempo real sin polling.

## Idempotency — el detalle crítico

```python
# El MessageDeduplicationId en SQS FIFO previene doble publicación
# Pero también necesitamos idempotency en DynamoDB:

# DynamoDB PutItem con condition expression:
ConditionExpression="attribute_not_exists(pago_id)"

# Si el mismo pago llega dos veces (retry de Step Functions):
#   Primera vez: escribe OK
#   Segunda vez: ConditionalCheckFailedException → capturado, skip
# El pago solo se registra UNA vez
```

## SLA 99.9% — cómo se garantiza

```
Componente         Disponibilidad AWS  Contribución al SLA
API Gateway        99.95%              Crítico
SQS                99.9%               Buffer — absorbe fallos downstream
Lambda             99.95%              Stateless, recupera solo
Step Functions     99.9%               Reintentos automáticos
DynamoDB           99.999%             Muy alta
SNS                99.9%               Notificaciones best-effort

Disponibilidad en serie ≠ producto de individuales
SQS actúa como buffer desacoplando el frontend del backend
→ Si Step Functions cae, los mensajes esperan en SQS hasta que vuelve
→ El cliente ya recibió 202, no le afecta la caída del backend
```
