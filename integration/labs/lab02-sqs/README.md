# Lab 02: Amazon SQS

Amazon SQS es el servicio de **colas de mensajes** de AWS. Desacopla productores de consumidores, actúa como buffer ante picos, y garantiza que los mensajes no se pierdan aunque el consumer esté caído.

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-standard-vs-fifo](labs/01-standard-vs-fifo/) | Crear ambas queues, comparar ordering, deduplicación FIFO, MessageGroupId | 30 min |
| [02-dlq-visibility](labs/02-dlq-visibility/) | Visibility timeout, DLQ con redrive policy, alarma CloudWatch, redrive | 40 min |

---

## Conceptos clave

| Concepto | Resumen |
|----------|---------|
| Standard | At-least-once, best-effort ordering, throughput ilimitado |
| FIFO | Exactly-once, orden estricto, 300 TPS (3000 con batch) |
| Visibility Timeout | Ventana de invisibilidad tras receive. Si expira sin DeleteMessage → el mensaje vuelve |
| Long Polling | `WaitTimeSeconds=20` — reduce costes y falsos vacíos |
| DLQ | Destino de mensajes que fallan N veces. Requiere alarma + proceso de revisión |
| Redrive | `start-message-move-task` — reenvía mensajes de DLQ a la queue original |

---

## Terraform quickstart

```bash
cd terraform/
terraform init && terraform apply
```

---

## Recursos

- [concept-map/](concept-map/) — Standard vs FIFO, visibility timeout, DLQ, pricing
- [scenarios/](scenarios/) — Cuándo Standard vs FIFO, dimensionar timeout, DLQ como safety net
- [terraform/](terraform/) — Standard + FIFO queues con DLQ y alarmas
- [cleanup.md](cleanup.md)
- [SQS Developer Guide](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/)
