# Lab 01 — Amazon Kinesis

> **Coste:** ~$0.50/h si se olvida destruir | **Región:** eu-west-1

---

## Objetivo

Dominar Amazon Kinesis como plataforma de streaming en tiempo real: Data Streams para ingesta con múltiples consumers, Firehose para entrega managed a destinos, y patrones de arquitectura de decisión entre ambos. Contenido clave para SAA-C03.

---

## Arquitectura

```
Productores                 Kinesis                    Consumidores
────────────                ───────────────────        ─────────────────────
IoT devices                 Data Streams               Lambda (real-time)
Aplicaciones     ─────────► (shards, 24h-365d)  ────► Kinesis Analytics
Logs/eventos                                           KCL applications
                            Firehose           ────► S3 (data lake)
                            (managed)          ────► Redshift
                                               ────► OpenSearch
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — Kinesis Data Streams](labs/01-kinesis-data-streams/README.md) | Crear stream, producir y consumir mensajes | ~$0.015/h |
| [02 — Kinesis Firehose](labs/02-kinesis-firehose/README.md) | Delivery stream a S3 con transformación Lambda | ~$0.029/GB |
| [03 — Architecture Patterns](labs/03-architecture-patterns/README.md) | KDS vs Firehose — cuándo usar cada uno | $0 (solo teoría) |

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- KDS vs Firehose vs SQS — tabla comparativa
- Shards, partitions y retención de datos
- Exactly-once vs at-least-once semantics
- Enhanced Fan-Out vs polling estándar

---

## Terraform

```bash
cd terraform/
terraform init
terraform apply
# Limpiar al terminar (evita ~$0.50/h)
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para escenarios de examen sobre KDS vs Firehose vs SQS.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Múltiples consumers del mismo stream? | **KDS** (Firehose solo entrega a destinos fijos) |
| ¿Ingesta managed a S3 sin código? | **Firehose** |
| ¿Retención configurable de mensajes? | **KDS** (24h a 365 días) |
| ¿KDS vs SQS? | KDS = ordering + múltiples consumers. SQS = desacoplamiento + fan-out |
