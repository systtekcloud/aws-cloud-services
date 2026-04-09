# AWS Integration Services — Módulo de Labs

Módulo centrado en los servicios de **pegamento** de AWS: los que conectan, desacoplan y orquestan el resto de servicios. Estos servicios son la diferencia entre una arquitectura monolítica acoplada y una arquitectura event-driven escalable.

---

## ¿Qué cubre este módulo?

| Lab | Servicio | Sub-labs | Coste estimado | Cuándo usarlo |
|-----|----------|----------|----------------|---------------|
| [lab01-lambda](labs/lab01-lambda/) | AWS Lambda | 4 | ~$0 (free tier) | Código sin servidor, event-driven, <15 min, <10 GB RAM |
| [lab02-sqs](labs/lab02-sqs/) | Amazon SQS | 2 | ~$0 (free tier) | Desacoplar productor/consumidor, buffer, retry automático |
| [lab03-sns](labs/lab03-sns/) | Amazon SNS | 2 | ~$0 (free tier) | Fan-out, notificaciones push, pub/sub |
| [lab04-eventbridge](labs/lab04-eventbridge/) | Amazon EventBridge | 2 | ~$1/millón eventos | Event routing, integración SaaS, cron jobs |
| [lab05-step-functions](labs/lab05-step-functions/) | AWS Step Functions | 4 | Standard: $0.025/1K; Express: $0.00001/ejecución | Orquestación de workflows, saga pattern, batch |
| [lab06-api-gateway](labs/lab06-api-gateway/) | Amazon API Gateway | 2 | REST: $3.50/M; HTTP: $1.00/M | API pública/privada, auth, rate limiting, WebSocket |

**Total sub-labs:** 16

---

## Árbol de decisión: ¿Qué servicio usar?

### Para procesar eventos en background

```
¿Necesitas garantía de orden estricto?
  ├─ Sí → SQS FIFO
  └─ No → SQS Standard

¿El productor no sabe quién consume?
  ├─ Múltiples consumidores → SNS (fan-out) o EventBridge
  └─ Un consumidor → SQS directamente

¿El evento viene de otro servicio AWS o SaaS?
  └─ EventBridge (schema registry, pipes, integración nativa)
```

### Para ejecutar código

```
¿Duración < 15 min y RAM < 10 GB?
  ├─ Sí → Lambda
  └─ No → ECS Fargate / EKS

¿Necesitas coordinar múltiples pasos con retry y estado?
  └─ Step Functions (orquestación) vs EventBridge (coreografía)
```

### Para exponer una API

```
¿Necesitas WebSocket o bidireccional?
  └─ API Gateway WebSocket

¿Necesitas caching, request validation, usage plans?
  └─ API Gateway REST

¿Quieres lo más barato y rápido con JWT nativo?
  └─ API Gateway HTTP
```

---

## SQS vs SNS vs EventBridge

| Característica | SQS | SNS | EventBridge |
|----------------|-----|-----|-------------|
| Modelo | Queue (pull) | Topic (push) | Event bus (push) |
| Consumidores | 1 (compete) | N (fan-out) | N (con reglas) |
| Ordering | Standard: best-effort / FIFO: estricto | No garantizado | No garantizado |
| Exactly-once | Solo FIFO | No | No |
| Filtrado | No (en queue) | Sí (filter policy) | Sí (event patterns) |
| Retención | 14 días | No retiene | Retry limitado |
| Schema Registry | No | No | Sí |
| Integración SaaS | No | No | Sí (Shopify, Stripe, etc.) |
| Precio/M eventos | $0.40 | $0.50 | $1.00 |

**Regla rápida:**
- Cola de trabajo entre dos servicios → **SQS**
- Un evento, múltiples receptores → **SNS** 
- Evento de negocio con routing complejo o fuente externa → **EventBridge**

---

## Lambda vs Step Functions: Orquestación

| Aspecto | Lambda + SQS/SNS | Step Functions |
|---------|------------------|----------------|
| Visibilidad del flujo | Ninguna (logs dispersos) | Visual, centralizada |
| Retry | Manual en código | Declarativo en ASL |
| Estado entre pasos | Externo (DynamoDB) | Nativo |
| Máx. duración | 15 min por función | Standard: 1 año |
| Coste | Solo compute | Compute + transiciones ($0.025/1K) |
| Auditabilidad | CloudWatch Logs | Execution history completo |

**Usa Step Functions cuando:** el flujo tiene 3+ pasos, necesitas retry/timeout declarativo, o el negocio necesita auditar cada transición.

---

## Prereqs recomendados

- Módulo [networking/](../networking/) — VPC, subnets, security groups
- Módulo [security/](../security/) — IAM roles, políticas de mínimo privilegio
- [lab04-guardduty](../security/labs/lab04-guardduty/) — Familiaridad con el patrón de labs

---

## Patrón de cada lab

```
labXX-servicio/
├── concept-map/     # Teoría: cómo funciona el servicio
├── labs/            # Pasos prácticos con AWS CLI
│   ├── 01-*/
│   └── 02-*/
├── terraform/       # Infrastructure as Code
├── scenarios/       # Cuándo usar este servicio vs alternativas
├── cleanup.md       # Cómo destruir todos los recursos
└── README.md        # Resumen + quickstart
```

---

## Relación con otros módulos

- **[architectures/](../architectures/)** — Combina estos servicios en arquitecturas end-to-end reales. Prereq: labs 01-06 de este módulo.
- **[eks/](../eks/)** — EKS usa Lambda (IRSA webhooks), SQS (KEDA), EventBridge (eventos de cluster).
- **[data/](../data/)** — Kinesis + Lambda es un patrón central en pipelines de datos.
