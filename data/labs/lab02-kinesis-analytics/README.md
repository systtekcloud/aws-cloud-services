# Lab 02 — Kinesis Data Analytics (Managed Apache Flink)

> **Coste:** ~$0.50/h si se olvida destruir (2 KPU) | **Región:** eu-west-1

---

## Objetivo

Dominar Kinesis Data Analytics (Managed Apache Flink) para procesamiento de streams en tiempo real: SQL sobre streams, detección de anomalías y patrones de arquitectura lambda. Contenido clave para SAA-C03.

---

## Arquitectura

```
KDS / MSK                Kinesis Data Analytics           Destinos
──────────               ──────────────────────────       ──────────────
Stream de        ──────► Managed Apache Flink             KDS (resultados)
eventos                  (SQL / Java / Python)    ──────► S3 (analytics)
                         - Windowing                       OpenSearch
                         - Aggregations                    Lambda
                         - Anomaly detection
                         - JOINs entre streams
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — SQL Analytics](labs/01-sql-analytics/README.md) | Aggregations y windowing sobre stream en tiempo real | ~$0.22/h |
| [02 — Anomaly Detection](labs/02-anomaly-detection/README.md) | RANDOM_CUT_FOREST para detectar anomalías en métricas | ~$0.22/h |

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- KDA vs Spark Streaming vs Lambda — cuándo usar cada uno
- Tumbling vs Sliding vs Session windows
- KPU (Kinesis Processing Units) y escalado
- Patrón lambda architecture (batch + streaming)

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

Ver [scenarios/README.md](scenarios/README.md) para escenarios sobre procesamiento en tiempo real vs batch.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿SQL sobre streams en tiempo real? | **Kinesis Data Analytics** |
| ¿Detección de anomalías en streams? | **KDA** con RANDOM_CUT_FOREST |
| ¿KDA vs Lambda para transformar streams? | KDA = stateful, windowing, aggregations. Lambda = stateless, transformación simple |
| ¿Qué es un KPU? | Unidad de procesamiento = 1 vCPU + 4 GB RAM |
