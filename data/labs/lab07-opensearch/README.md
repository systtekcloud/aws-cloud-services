# Lab 07 — Amazon OpenSearch Service

> **Coste:** Instancias cobran por hora (destruir al terminar) | **Región:** eu-west-1

---

## Objetivo

Dominar Amazon OpenSearch Service para búsqueda full-text y analytics sobre logs y eventos: crear un dominio, indexar documentos, y construir un pipeline de logs con Firehose. Contenido relevante para SAA-C03.

---

## Arquitectura

```
Fuentes de logs           Pipeline                      OpenSearch
─────────────────         ──────────────────────────    ─────────────────────
CloudWatch Logs  ──────► Kinesis Firehose               Índices + Shards
VPC Flow Logs             (transformación Lambda)  ────► OpenSearch Dashboards
ALB logs                                                 (Kibana)
Aplicaciones     ──────► Logstash / Fluentd             Alerting
                          (directo a OpenSearch)        Anomaly Detection
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — OpenSearch Basics](labs/01-opensearch-basics/README.md) | Crear dominio, indexar docs, búsquedas full-text | instancia/h |
| [02 — Logs Pipeline](labs/02-logs-pipeline/README.md) | Firehose → OpenSearch con transformación Lambda | instancia/h |

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- OpenSearch vs CloudWatch Logs Insights vs Athena
- Índices, shards y réplicas
- Mapping types y analyzers
- Firehose → OpenSearch vs directo desde aplicación
- OpenSearch Serverless vs dominio gestionado

---

## Terraform

```bash
cd terraform/
terraform init
terraform apply
# ⚠️ Destruir después — cobran por hora
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para escenarios de búsqueda y analytics de logs.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Búsqueda full-text en documentos? | **OpenSearch** |
| ¿Analytics sobre logs con dashboard visual? | **OpenSearch** (con OpenSearch Dashboards) |
| ¿OpenSearch vs CloudWatch Logs Insights? | OpenSearch = búsqueda avanzada + retention personalizada. CW Logs = nativo AWS, simple |
| ¿Cómo entregar logs a OpenSearch desde múltiples fuentes? | **Kinesis Firehose** como pipeline centralizado |
