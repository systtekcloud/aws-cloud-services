# SQS — Concept Map

## ¿Qué es SQS?

Amazon SQS (Simple Queue Service) es un servicio de **cola de mensajes gestionado**. Desacopla productores (que envían mensajes) de consumidores (que los procesan). El productor no espera al consumidor — deposita el mensaje en la queue y continúa.

**Analogía DevOps:** SQS ≈ una cola de tareas (Celery/Redis Queue/RabbitMQ) pero serverless, sin gestionar brokers, con durabilidad garantizada por AWS.

---

## Standard Queue vs FIFO Queue

| Característica | Standard | FIFO |
|----------------|----------|------|
| Ordering | Best-effort (NO garantizado) | Estricto (First-In-First-Out) |
| Delivery | At-least-once (puede duplicarse) | Exactly-once (deduplicación) |
| Throughput | Ilimitado | 300 TPS (3000 con batching) |
| Precio/M mensajes | $0.40 | $0.50 |
| Nombre | `mi-queue` | `mi-queue.fifo` (sufijo obligatorio) |
| Deduplicación | No | Content-based o MessageDeduplicationId |
| Message Group | No | Sí (permite paralelismo dentro de FIFO) |

**Cuándo usar FIFO:**
- Transacciones financieras que deben procesarse en orden
- Comunicación entre microservicios donde el orden importa
- Evitar duplicados es un requisito de negocio

**Cuándo Standard es suficiente:**
- Procesamiento de imágenes, emails, notificaciones
- Tareas idempotentes (procesar 2 veces = mismo resultado)
- Necesitas throughput masivo

---

## Anatomía de un mensaje SQS

```
Mensaje SQS
├── MessageId           — ID único asignado por SQS
├── ReceiptHandle       — token temporal para borrar el mensaje
├── Body                — tu contenido (hasta 256 KB)
├── MessageAttributes   — metadatos estructurados (tipo, valor)
├── MD5OfBody           — checksum para verificar integridad
└── Attributes
    ├── ApproximateReceiveCount     — cuántas veces se ha recibido
    ├── SentTimestamp               — cuándo fue enviado
    └── ApproximateFirstReceiveTimestamp
```

---

## Visibility Timeout

El mecanismo más importante de SQS para entender:

```
Productor envía mensaje
         │
         ▼
   [Mensaje en queue] ← visible
         │
         ▼ (Consumer llama ReceiveMessage)
   [Mensaje en queue] ← INVISIBLE (visibility timeout: 30s default)
         │
    ┌────┴────┐
  Consumer    Consumer
  procesa     falla / timeout
  con éxito       │
    │         [Mensaje vuelve a ser visible]
    ▼              │
  DeleteMessage    ▼
  (lo borra)  Otro consumer lo recibe
```

**Configurar correctamente:**
```
visibility_timeout >= max(lambda_timeout, processing_time) × 6

Si tu Lambda tarda hasta 10s:
  visibility_timeout = 60s (mínimo recomendado)
```

**Si el timeout expira sin DeleteMessage:**
- El mensaje vuelve a la queue → otro consumer lo recibe
- `ApproximateReceiveCount` aumenta
- Cuando `ApproximateReceiveCount` > `maxReceiveCount` → va a la DLQ

---

## Long Polling vs Short Polling

| Aspecto | Short Polling (default) | Long Polling |
|---------|------------------------|--------------|
| Comportamiento | Responde inmediatamente aunque esté vacía | Espera hasta `WaitTimeSeconds` (max 20s) |
| Mensajes vacíos | Frecuentes | Raros |
| Coste | Mayor (más API calls) | Menor |
| Configurar | `ReceiveMessageWaitTimeSeconds=0` | `ReceiveMessageWaitTimeSeconds=20` |

**Usa siempre Long Polling** a menos que necesites respuesta inmediata garantizada.

---

## Dead Letter Queue (DLQ)

```
Queue principal
  ├── maxReceiveCount: 3   (reintentos antes de DLQ)
  └── deadLetterTargetArn: arn:...dlq

Flujo:
  Mensaje → Consumer falla → retry 1
          → Consumer falla → retry 2
          → Consumer falla → retry 3 (maxReceiveCount)
          → Mensaje movido a DLQ automáticamente
```

**DLQ no es de tipo diferente** — es simplemente otra queue SQS. Configuras el redrive policy en la queue principal.

**Monitorizar DLQ:** una alarma CloudWatch en `ApproximateNumberOfMessagesVisible > 0` en la DLQ es esencial en producción. Mensajes en DLQ = fallos que requieren investigación.

---

## Queue-based Load Leveling Pattern

```
Sin SQS (acoplamiento directo):
  Tráfico pico ──→ Servicio procesador ──→ Se satura / falla

Con SQS (load leveling):
  Tráfico pico ──→ [SQS Queue] ──→ Procesador consume a su ritmo
                   (buffer infinito)   (escala independientemente)
```

**Ejemplo real:** Una tienda online recibe 10.000 pedidos en Black Friday en 1 minuto. Sin SQS, el servicio de facturas colapsa. Con SQS, los 10.000 mensajes se encolan y el servicio los procesa a un ritmo sostenible durante los siguientes 10 minutos.

---

## SQS vs SNS vs EventBridge

| Necesidad | Servicio |
|-----------|----------|
| 1 productor → 1 consumidor, buffer, retry | **SQS** |
| 1 productor → N consumidores simultáneos | **SNS** (fan-out) |
| Routing complejo por atributos del evento | **EventBridge** |
| Retry automático con backoff | **SQS** (vía redelivery) |
| Exactamente una vez | **SQS FIFO** |
| Integración con SaaS (Stripe, Shopify) | **EventBridge** |

---

## Pricing

```
Standard:  $0.40 por millón de requests (primeros 1M gratuitos/mes)
FIFO:      $0.50 por millón de requests

Cada API call = 1 request (ReceiveMessage, SendMessage, DeleteMessage)
Cada batch de hasta 10 mensajes = 1 request (usar siempre batching)

Ejemplo: 10M mensajes/mes procesados en batch de 10:
  = 1M API calls × $0.40 = $0.40/mes
```
