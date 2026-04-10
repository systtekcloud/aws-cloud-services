# Lab 03 — Scenarios: SNS en decisiones de arquitectura

## Scenario 1: SNS vs SQS — ¿cuál para cada caso?

| Caso | Servicio | Por qué |
|------|----------|---------|
| Enviar tarea a un worker | SQS | Un consumer, no fan-out |
| Notificar a 5 servicios de un evento | SNS | Fan-out simultáneo |
| Notificar + garantizar no pérdida | SNS + SQS | SNS no retiene; SQS sí |
| Orden estricto + un consumer | SQS FIFO | Ordering garantizado |
| Orden estricto + múltiples consumers | SNS FIFO → SQS FIFO | Fan-out ordenado |

## Scenario 2: Por qué SNS + SQS y no SNS directo a Lambda

```
Opción A: SNS → Lambda (directo)
  Riesgo: si Lambda está throttleada, SNS reintenta 3 veces y descarta
  → pérdida de mensajes bajo carga alta

Opción B: SNS → SQS → Lambda (recomendado)
  SQS retiene hasta 14 días
  Lambda procesa a su ritmo (Event Source Mapping)
  DLQ en SQS para fallos persistentes
  → sin pérdida de mensajes
```

## Scenario 3: Filtering para reducir procesamiento innecesario

**Sin filtering:** 100 servicios suscritos reciben 1M eventos/día aunque solo 10% les aplique → 100M invocaciones Lambda innecesarias.

**Con filtering:** cada subscriber declara qué necesita → solo recibe los relevantes → 90% menos invocaciones → 90% menos coste.

## Scenario 4: SNS vs EventBridge para routing de eventos

| Criterio | SNS | EventBridge |
|----------|-----|-------------|
| Filtering por atributo del mensaje | Sí | Sí (más expresivo) |
| Filtering por contenido del body | Sí (FilterPolicyScope=MessageBody) | Sí |
| Schema Registry | No | Sí |
| Integración con SaaS (Stripe, GitHub) | No | Sí (Event Sources) |
| Replay de eventos históricos | No | Sí (Event Archive) |
| Precio por evento | Más barato | Más caro |
| Targets | SQS, Lambda, HTTP, Email, SMS | 20+ AWS services |

**Regla:** SNS cuando necesitas pub/sub simple y barato. EventBridge cuando necesitas routing complejo, schema validation, o integración con SaaS.
