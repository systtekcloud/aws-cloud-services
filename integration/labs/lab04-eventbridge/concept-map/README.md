# EventBridge — Concept Map

## ¿Qué es EventBridge?

Amazon EventBridge es un **event bus serverless** que conecta aplicaciones mediante eventos. Recibe eventos de servicios AWS, aplicaciones propias y SaaS de terceros, y los enruta a targets según reglas declarativas.

**La diferencia clave vs SNS:** EventBridge tiene Schema Registry, puede filtrar por contenido del evento JSON (no solo atributos), integra con +200 fuentes SaaS, y permite Pipes (transformaciones sin Lambda).

---

## Tipos de Event Bus

```
┌─────────────────────────────────────────────────────────┐
│  Default Event Bus                                       │
│  • Recibe eventos de servicios AWS automáticamente       │
│  • EC2 state change, RDS events, ECS task changes, etc.  │
│  • No se puede borrar                                    │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Custom Event Bus                                        │
│  • Para tus propios eventos de aplicación                │
│  • Aislamiento entre dominios/equipos                    │
│  • Resource policy para cross-account                    │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Partner Event Bus                                       │
│  • Eventos de SaaS externos: Stripe, GitHub, Shopify,   │
│    Zendesk, PagerDuty, Datadog, etc.                     │
│  • El SaaS publica directamente en tu bus                │
└─────────────────────────────────────────────────────────┘
```

---

## Anatomía de un evento

```json
{
  "version": "0",
  "id": "12345678-1234-1234-1234-111122223333",
  "source": "com.miempresa.pagos",
  "account": "123456789012",
  "time": "2026-04-09T12:00:00Z",
  "region": "eu-west-1",
  "detail-type": "PagoCompletado",
  "detail": {
    "pedido_id": "PED-001",
    "monto": 149.99,
    "moneda": "EUR",
    "cliente_id": "cli-789"
  }
}
```

Los campos `source` y `detail-type` son los más importantes para las reglas de routing.

---

## Rules y Event Patterns

Una regla tiene dos partes: el **event pattern** (qué eventos captura) y los **targets** (adónde los envía).

```json
// Event pattern — captura pagos completados de más de 100€
{
  "source": ["com.miempresa.pagos"],
  "detail-type": ["PagoCompletado"],
  "detail": {
    "monto": [{"numeric": [">", 100]}],
    "moneda": ["EUR"]
  }
}
```

### Operadores de matching

| Operador | Ejemplo | Descripción |
|----------|---------|-------------|
| Exact | `["EU"]` | Valor exacto |
| Prefix | `[{"prefix": "EU"}]` | Empieza por |
| Suffix | `[{"suffix": ".pdf"}]` | Termina en |
| Anything-but | `[{"anything-but": ["test"]}]` | Todo menos |
| Numeric | `[{"numeric": [">=", 100]}]` | Comparación numérica |
| Exists | `[{"exists": true}]` | El campo existe |
| Null | `[null]` | Valor null |

---

## Targets disponibles

EventBridge puede enviar a más de 20 targets AWS:

```
Lambda           — invocar función
SQS              — encolar mensaje
SNS              — publicar en topic
Step Functions   — iniciar ejecución
ECS Task         — lanzar tarea Fargate
Kinesis Streams  — poner registro
Firehose         — entregar a S3/Redshift
API Gateway      — llamar endpoint REST/HTTP
EventBridge Bus  — reenviar a otro bus (cross-account)
CloudWatch Logs  — escribir log
EC2 API          — acciones (stop, reboot)
SSM Run Command  — ejecutar comando en instancias
```

**Input transformers:** puedes transformar el evento antes de enviarlo al target (extraer campos, añadir constantes, cambiar estructura) sin necesidad de una Lambda intermedia.

---

## EventBridge Pipes

Pipes conecta una **fuente** (SQS, Kinesis, DynamoDB Streams, Kafka) directamente a un **target** con filtrado y enriquecimiento opcionales — sin Lambda como middleware.

```
[Fuente]
  SQS / Kinesis / DDB Streams
      │
      ▼ (filtrado opcional)
  [Filter]
      │
      ▼ (enriquecimiento opcional)
  [Enrichment: Lambda / API GW]
      │
      ▼
  [Target]
  Lambda / Step Functions / EventBridge / SQS / ...
```

**Caso de uso:** DynamoDB Stream → filtrar solo INSERT → enriquecer con datos adicionales → Step Functions. Sin Pipes necesitarías una Lambda "glue" que no hace nada útil más que reenviar.

---

## Schema Registry

EventBridge puede descubrir y registrar automáticamente el esquema de todos los eventos que pasan por el bus. Genera código SDK en Python, Java, TypeScript para deserializar eventos con tipos.

```bash
# Habilitar schema discovery en un bus
aws schemas create-discoverer \
  --source-arn "arn:aws:events:eu-west-1:ACCOUNT:event-bus/mi-bus" \
  --description "Auto-discover schemas"
```

---

## Cross-account Event Routing

```
Cuenta A (workload)           Cuenta B (Security/Observability)
┌────────────────────┐        ┌──────────────────────────────┐
│  Custom Event Bus  │──────→ │  Custom Event Bus (central)  │
│  (put-events)      │        │  (resource policy abierta)   │
└────────────────────┘        │  → Lambda (alertas)          │
                              │  → CloudWatch Logs           │
                              └──────────────────────────────┘
```

El bus destino necesita una **resource policy** que permita al bus fuente enviar eventos.

---

## EventBridge vs SNS vs SQS

| Característica | EventBridge | SNS | SQS |
|----------------|-------------|-----|-----|
| Modelo | Event bus con reglas | Pub/sub | Cola |
| Filtrado | Por contenido JSON | Por atributos | No |
| Schema Registry | Sí | No | No |
| SaaS integration | Sí (+200 fuentes) | No | No |
| Event replay | Sí (Archive) | No | No |
| Retención | No (no persiste) | No | 14 días |
| Precio/M eventos | $1.00 | $0.50 | $0.40 |
| Targets | 20+ AWS services | SQS, Lambda, HTTP, email | 1 consumer |

---

## Pricing

```
Custom events:     $1.00 por millón de eventos
Default bus:       Gratuito (eventos de servicios AWS)
Schema Registry:   $0.10 por millón de eventos descubiertos
EventBridge Pipes: $0.40 por millón de eventos procesados
Archive/Replay:    $0.023 por GB/mes almacenado
```
