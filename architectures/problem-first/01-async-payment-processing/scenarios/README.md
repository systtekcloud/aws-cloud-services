# Escenarios y variantes

## Escenario 1: Pagos internacionales (SWIFT/SEPA)

**Problema añadido:** El banco externo responde en 10-30 segundos (SWIFT) en vez de 1-3s.

**Impacto en la arquitectura:**

```
Step Functions waitForTaskToken
  ↓
Lambda → SWIFT gateway (async callback)
  ↓  (minutos después)
SWIFT gateway → Lambda callback → SendTaskSuccess/SendTaskFailure
```

**Cambios necesarios:**
- `ValidarConBanco` usa `waitForTaskToken` en vez de Lambda sincrónico
- Lambda envía `taskToken` al gateway SWIFT como referencia
- Gateway SWIFT llama a `SendTaskSuccess` cuando hay respuesta
- Timeout: `HeartbeatSeconds: 1800` (30 min) + `TimeoutSeconds: 86400` (24h)
- DLQ en Lambda callback para notificaciones fallidas

**ASL modificado:**
```json
"ValidarConBanco": {
  "Type": "Task",
  "Resource": "arn:aws:states:::lambda:invoke.waitForTaskToken",
  "Parameters": {
    "FunctionName": "pagos-swift-gateway",
    "Payload": {
      "pago_id.$": "$.pago_id",
      "taskToken.$": "$$.Task.Token"
    }
  },
  "HeartbeatSeconds": 1800,
  "TimeoutSeconds": 86400
}
```

---

## Escenario 2: Refunds

**Problema:** El cliente solicita devolución de un pago ya completado.

**Flujo:**
```
POST /refunds
  │ Body: { pago_id, motivo }
  │
  ▼
API Gateway → SQS FIFO (mismo grupo que el pago original)
  │ MessageGroupId = cliente_id (procesa refund DESPUÉS del pago)
  ▼
Lambda → verifica que pago existe + status=completado
  ▼
Step Functions (refund state machine)
  │
  ├─ RevertirConBanco (Lambda → banco API reversal)
  ├─ RegistrarRefund (DynamoDB: pago_id + "_refund")
  └─ NotificarRefund (SNS)
```

**Decisión clave:** mismo `MessageGroupId` que el pago garantiza que el refund no se procesa antes que el pago original si llegan casi simultáneos.

**Idempotency en refunds:**
```python
# DynamoDB condition: solo refund si pago completado y sin refund previo
ConditionExpression = "status = :completado AND attribute_not_exists(refund_id)"
```

---

## Escenario 3: Chargebacks (disputas del banco)

**Problema:** El banco inicia una disputa días después. No es una petición del cliente.

**Flujo (event-driven, no iniciado por cliente):**
```
Banco → webhook → API Gateway (endpoint dedicado)
  │ Autenticación: HMAC signature del banco
  ▼
Lambda → valida HMAC → publica a EventBridge
  │
  ▼
EventBridge rule: source=banco, type=chargeback
  │
  ├─ Lambda → actualiza DynamoDB (status=disputed)
  ├─ SNS → notifica al cliente
  └─ Lambda → notifica al equipo de fraude (Slack/email)
```

**Por qué EventBridge aquí y no SQS:**
- El chargeback dispara múltiples acciones en paralelo (fan-out)
- No necesita ordering (es un evento único por disputa)
- Los targets son distintos sistemas (cliente, fraude, auditoría)

---

## Escenario 4: Alto volumen (>300 TPS por cliente)

**Problema:** SQS FIFO tiene límite de 300 TPS (3000 con high throughput mode).

**Si un cliente supera ese límite (muy raro, pero existe en marketplaces):**

```
Opción A: FIFO High Throughput Mode
  - aws sqs create-queue --attributes FifoThroughputLimit=perMessageGroupId
  - Hasta 3000 TPS por MessageGroupId
  - Limitación: deduplication solo por contenido (no por ID)

Opción B: Sharding de colas FIFO
  - En vez de 1 cola FIFO, 10 colas FIFO
  - hash(cliente_id) % 10 → selecciona la cola
  - Throughput: 10 × 300 = 3000 TPS por cliente
  - Complejidad: Lambda necesita saber a qué cola consumir

Opción C: Kinesis Data Streams (si >3000 TPS)
  - API GW → Kinesis → Lambda (ESM)
  - Ordering por PartitionKey=cliente_id dentro del shard
  - 1 shard = 1000 records/s, 1MB/s
  - 10 shards = 10K records/s
  - Sin exactly-once nativo (hay que implementar en Lambda)
```

**Recomendación:** SQS FIFO High Throughput Mode cubre 99.9% de los casos. Kinesis solo para plataformas de pagos masivos (Stripe, Adyen escala).

---

## Anti-patrones a evitar

### Anti-patrón 1: Lambda procesando el pago directamente (sin SQS)

```
API GW → Lambda → [banco + DynamoDB + SNS]  ← MAL
```

**Por qué es un problema:**
- Si el banco tarda 10s y el cliente hace 100 pagos simultáneos: 100 Lambdas concurrentes
- Sin buffer: si Lambda falla, el cliente no recibe respuesta (timeout)
- Sin ordering: si falla y retry, puede procesar pagos fuera de orden

### Anti-patrón 2: SQS Standard para pagos

```
SQS Standard → Lambda → pago A procesado dos veces  ← MAL
```

**Por qué:** SQS Standard garantiza "at-least-once", no "exactly-once". Con pagos, doble procesamiento = doble cargo.

### Anti-patrón 3: Polling del cliente al API GW con estado en Lambda

```
Cliente → GET /pagos/{id}/status → Lambda → busca en memoria  ← MAL
```

**Por qué:** Lambda es stateless. El estado debe estar en DynamoDB. El cliente hace GET /pagos/{id} → Lambda → DynamoDB GetItem → devuelve status.
