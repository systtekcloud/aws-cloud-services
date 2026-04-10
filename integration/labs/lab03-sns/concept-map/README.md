# SNS — Concept Map

## ¿Qué es SNS?

Amazon SNS (Simple Notification Service) es un servicio de **pub/sub** (publicar/suscribir). Un publicador envía un mensaje a un Topic y SNS lo entrega a todos los suscriptores registrados simultáneamente.

**La diferencia clave con SQS:** En SQS, un solo consumidor procesa cada mensaje. En SNS, N suscriptores reciben el mismo mensaje al mismo tiempo.

---

## Modelo pub/sub

```
Publicador (Producer)
        │
        ▼  publish()
   [SNS Topic]
        │
   ┌────┼────┐────────┐
   ▼    ▼    ▼        ▼
 SQS  Lambda HTTP   Email
Queue  fn   endpt   addr

(todos reciben el mismo mensaje)
```

---

## Topics: Standard vs FIFO

| Característica | Standard | FIFO |
|----------------|----------|------|
| Ordering | No garantizado | Estricto (por MessageGroupId) |
| Deduplicación | No | Sí |
| Throughput | Ilimitado | 300 pub/s (3000 con batch) |
| Suscriptores | SQS, Lambda, HTTP, Email, SMS, móvil | Solo SQS FIFO |
| Uso típico | Fan-out general | Fan-out que requiere orden |

---

## Protocolos de suscripción

| Protocolo | Uso | Confirmación requerida |
|-----------|-----|------------------------|
| `sqs` | Queue SQS como buffer | No (automática) |
| `lambda` | Invocar función Lambda | No (automática) |
| `https` | Webhook a endpoint HTTP | Sí (confirm subscription) |
| `http` | Igual pero sin TLS (no recomendado) | Sí |
| `email` | Notificación por email | Sí (el usuario confirma) |
| `email-json` | Email con payload JSON | Sí |
| `sms` | SMS vía SNS Mobile | No |
| `application` | Push móvil (FCM, APNS) | No |

---

## Fan-out Pattern

El patrón más importante de SNS. Un evento → múltiples sistemas reaccionan de forma independiente y desacoplada.

```
Evento: "pedido creado"
         │
    [SNS Topic: pedidos]
         │
    ┌────┼────┬────────┐
    ▼    ▼    ▼        ▼
  SQS  SQS  SQS     Lambda
  │    │    │          │
  ▼    ▼    ▼          ▼
Inv. Fact. Email    Analytics
Service Service Service  fn

(cada servicio procesa de forma independiente)
```

**Ventaja sobre llamadas directas:**
- Si el servicio de Facturación cae, el de Inventario sigue funcionando
- Añadir un nuevo subscriber no requiere cambiar el publicador
- Cada subscriber tiene su propia DLQ y retry policy (vía SQS)

---

## SNS + SQS: el patrón recomendado

SNS es push (no retiene mensajes). Si un subscriber cae, el mensaje se pierde. La solución es usar SQS como buffer entre SNS y el consumer:

```
[SNS Topic]
     │
     ▼ (push síncrono)
  [SQS Queue]  ← retiene el mensaje si el consumer cae
     │
     ▼ (pull asíncrono)
  Consumer
```

Este patrón da lo mejor de ambos: fan-out de SNS + durabilidad y retry de SQS.

---

## Message Filtering

Sin filtering: todos los suscriptores reciben todos los mensajes.  
Con filtering: cada suscriptor declara qué mensajes quiere recibir mediante una **filter policy**.

```
Publicador envía:
  {
    "default": "Nuevo pedido",
    "MessageAttributes": {
      "order_type": {"Type": "String", "Value": "international"},
      "amount":     {"Type": "Number", "Value": "1500"}
    }
  }

Suscriptor A — filter policy: {"order_type": ["domestic"]}
  → NO recibe este mensaje

Suscriptor B — filter policy: {"order_type": ["international"]}
  → SÍ recibe este mensaje

Suscriptor C — filter policy: {"amount": [{"numeric": [">=", 1000]}]}
  → SÍ recibe este mensaje (amount = 1500)
```

**Filter policy operators:**
- String: exact match, prefix, suffix, contains
- Numeric: =, <, <=, >, >=, between
- Exists / not exists
- Anything-but

---

## SNS vs SQS vs EventBridge

| Necesidad | Servicio |
|-----------|----------|
| 1 mensaje → N consumidores simultáneos | **SNS** |
| Desacoplar con buffer y retry | **SQS** |
| Fan-out con SQS como buffer | **SNS + SQS** |
| Routing complejo por contenido del evento | **EventBridge** |
| Integración SaaS (Stripe, GitHub) | **EventBridge** |
| Schema Registry y validación | **EventBridge** |
| Retención de mensajes | **SQS** (14 días) |

---

## SNS FIFO — cuándo usarlo

```
Caso: sistema bancario
  Evento 1: "cuenta creada"       → group: cuenta-123
  Evento 2: "fondos añadidos"     → group: cuenta-123
  Evento 3: "transferencia"       → group: cuenta-123

Sin FIFO: los 3 eventos podrían llegar en cualquier orden a los subscribers
Con FIFO: garantiza que todos los subscribers ven los eventos en orden

Solo disponible con suscriptores SQS FIFO.
```

---

## Pricing

```
Standard: $0.50 por millón de publicaciones
          + coste por protocolo de entrega:
            SQS:    incluido en precio SQS
            Lambda: incluido en precio Lambda
            HTTP:   $0.06 por millón de entregas
            Email:  $2.00 por 100.000 emails
            SMS:    varía por país (~$0.01–0.10 por SMS)

FIFO: $0.50 por millón de publicaciones
      $0.50 por millón de subscriptions API calls
```
