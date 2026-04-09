# Lab 03 — Amazon MSK (Managed Apache Kafka)

> **Coste:** Bajo pero acumulativo (partition-hours + GB) | **Región:** eu-west-1

---

## Objetivo

Dominar Amazon MSK como Kafka gestionado en AWS: crear un cluster Serverless, producir y consumir mensajes con la Kafka CLI, y conectar con MSK Connect para integración con S3. Contenido relevante para SAA-C03.

---

## Arquitectura

```
Productores                MSK (Kafka)                 Consumidores
────────────               ───────────────────────     ─────────────────────
Aplicaciones     ────────► Topics / Partitions  ──────► Aplicaciones Java
Microservicios              Retention: 7 días           Lambda (trigger)
IoT / logs                  Replication: 3x             MSK Connect → S3
                            TLS in-transit              Flink (KDA)
                            At-rest encryption
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — MSK Cluster](labs/01-msk-cluster/README.md) | Crear cluster Serverless, topics, producir/consumir | partition-hours |
| [02 — MSK Connect](labs/02-msk-connect/README.md) | S3 Sink Connector — entregar mensajes Kafka a S3 | + conector |

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- MSK vs Kinesis Data Streams — cuándo usar Kafka vs Kinesis
- Partitions vs Shards
- Consumer groups y offset management
- MSK Connect vs Kinesis Firehose

---

## Terraform

```bash
cd terraform/
terraform init
terraform apply
# Limpiar al terminar
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para escenarios MSK vs KDS.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Ecosistema Kafka existente → migrar a AWS? | **MSK** |
| ¿Nuevo proyecto streaming en AWS nativo? | **Kinesis Data Streams** |
| ¿MSK Connect para qué? | Conectores managed (S3, JDBC, OpenSearch) sin código |
| ¿MSK vs KDS para múltiples consumer groups? | Ambos soportan múltiples consumers; MSK usa consumer groups Kafka |
