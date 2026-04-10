# Async Payment Processing

**Tipo:** Problem-First  
**Problema:** Una fintech necesita procesar pagos con exactly-once semantics, auditoría completa de cada estado, retry automático con backoff, y notificación al cliente en tiempo real. Máximo 5 segundos de latencia percibida. SLA 99.9%.

---

## Arquitectura

```
Cliente
  │
  ▼ POST /pagos
API Gateway (REST)
  │ valida formato, auth Cognito
  ▼
SQS FIFO Queue
  │ exactly-once, ordering por cliente
  ▼
Lambda (validador)
  │ verifica fondos, límites
  ▼
Step Functions (Standard)
  │
  ├─ ValidarPago (Lambda)
  ├─ ProcesarConBanco (Lambda → external API)
  │     retry: 3 intentos, backoff exponencial
  ├─ RegistrarAuditoria (DynamoDB put)
  └─ NotificarCliente (SNS → email + push)
         │
         ▼
DynamoDB (estado + auditoría completa)
SNS (notificación al cliente)
CloudWatch (métricas + alarmas)
```

---

## Por qué esta arquitectura

El problema requiere tres garantías simultáneas que ningún servicio individual ofrece:

1. **Exactly-once:** SQS FIFO + deduplication ID = el mismo pago no se procesa dos veces aunque el cliente haga doble click
2. **Auditoría:** Step Functions Standard guarda el historial completo de cada transición (qué ocurrió, cuándo, con qué resultado)
3. **Notificación <5s:** la latencia percibida es baja porque la API responde 202 inmediatamente; el procesamiento es asíncrono

---

## Módulos Terraform

| Módulo | Recursos | Descripción |
|--------|----------|-------------|
| [modules/queue/](modules/queue/) | SQS FIFO + DLQ + alarma | Buffer con exactly-once |
| [modules/processor/](modules/processor/) | Lambda + Step Functions + IAM | Lógica de procesamiento |
| [modules/storage/](modules/storage/) | DynamoDB + SNS + KMS | Persistencia y notificaciones |

## Entornos Terragrunt

```bash
# Dev — sin reserved concurrency, DynamoDB on-demand, sin alarmas costosas
cd dev/ && terragrunt apply

# Prod — reserved concurrency, DynamoDB provisioned + auto-scaling, alertas
cd prod/ && terragrunt apply
```

---

## Recursos relacionados

- [design/architecture.md](design/architecture.md) — flujo detallado + decisiones técnicas
- [design/options/](design/options/) — comparación con 3 alternativas
- [scenarios/](scenarios/) — variantes: pagos internacionales, refunds, chargebacks
- [cost-analysis.md](cost-analysis.md) — estimación dev vs prod
