# IoT Data Pipeline

**Tipo:** Problem-First  
**Problema:** Una empresa de infraestructura industrial tiene 10.000 sensores IoT enviando métricas cada 10 segundos. Necesitan: alertas en tiempo real (<10s latencia), histórico de 2 años para análisis, y coste <$500/mes.

---

## Arquitectura

```
Sensores IoT (10K dispositivos)
  │
  ▼ MQTT / HTTPS
AWS IoT Core
  │ Rules Engine
  ├─────────────────────────────────────────────────────┐
  ▼ (todos los mensajes)                                 ▼ (si temp > 85°C)
Kinesis Data Streams                              Lambda (alertas)
  │ (1MB/s por shard)                                    │
  ▼                                                      ▼
Lambda (procesador)                               SNS → email/SMS/PagerDuty
  │
  ├─── Kinesis Data Firehose ──→ S3 (raw data, Parquet)
  │                                    │
  │                              AWS Glue Crawler
  │                                    │
  │                              Athena (queries ad-hoc)
  │
  └─── DynamoDB (últimas lecturas por sensor)
             │
        API Gateway → Dashboard en tiempo real
```

---

## Por qué esta arquitectura

El problema tiene dos rutas de datos con requisitos opuestos:

**Ruta caliente (alertas <10s):**
- IoT Core Rule → Lambda directa: la regla SQL evalúa cada mensaje sin buffering
- Lambda invoca SNS inmediatamente: latencia total ~2-3s
- No pasa por Kinesis: evita el overhead de batch

**Ruta fría (histórico 2 años):**
- Kinesis → Firehose → S3 (Parquet, Snappy): compresión 10:1 reduce costes de almacenamiento
- Athena queries sobre S3: serverless, pago por query, sin base de datos que mantener
- Glue Catalog: schema management para Athena

**Por qué Kinesis y no SQS:**
- 10K sensores × 1 mensaje/10s = 1.000 mensajes/segundo
- Kinesis admite múltiples consumers del mismo stream (Lambda + Firehose simultáneamente)
- SQS: un mensaje solo puede ser consumido por un consumer (borrado tras lectura)
- Kinesis retiene 7-365 días para replay si falla un consumer

---

## Módulos Terraform

| Módulo | Recursos | Descripción |
|--------|----------|-------------|
| [modules/ingestion/](modules/ingestion/) | IoT Core Policy + Rules | Entrada de datos MQTT/HTTPS |
| [modules/streaming/](modules/streaming/) | Kinesis Data Streams + Lambda | Procesamiento en tiempo real |
| [modules/storage/](modules/storage/) | S3 + Firehose + Glue + DynamoDB | Persistencia y analytics |

## Entornos Terragrunt

```bash
# Dev — 1 shard Kinesis, S3 standard, sin alarmas costosas
cd dev/ && terragrunt apply

# Prod — shards dinámicos, S3 Intelligent-Tiering, alarmas + presupuesto
cd prod/ && terragrunt apply
```

---

## Recursos relacionados

- [design/architecture.md](design/architecture.md) — flujo detallado + decisiones técnicas
- [design/options/](design/options/) — Kinesis vs MSK vs SQS+SNS
- [scenarios/](scenarios/) — anomaly detection, backfill histórico, multi-región
- [cost-analysis.md](cost-analysis.md) — estimación con 10K sensores
