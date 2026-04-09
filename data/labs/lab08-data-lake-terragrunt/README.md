# Lab 08 — Data Lake con Terragrunt

> **Coste:** Redshift Serverless cobra en reposo — destruir al terminar | **Región:** eu-west-1

---

## Objetivo

Construir un data lake completo usando Terragrunt para gestionar múltiples capas (ingesta, almacenamiento, procesamiento, serving, gobernanza) de forma DRY. Integra todos los servicios de los labs anteriores en una arquitectura cohesiva.

---

## Arquitectura

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Data Lake — Capas Terragrunt                                            │
│                                                                          │
│  ingestion/              storage/              processing/               │
│  ─────────────           ────────────────      ────────────────          │
│  Kinesis Firehose  ────► S3 (raw/)        ───► Glue ETL          ──────►│
│  MSK Connect             S3 (curated/)         EMR Serverless            │
│                          S3 (serving/)                                   │
│                                                                          │
│  serving/                governance/                                     │
│  ─────────────────       ─────────────────────────────────               │
│  Redshift Serverless ◄── Lake Formation (column-level security)          │
│  Athena                  Glue Data Catalog (metadatos unificados)        │
│  OpenSearch                                                              │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Estructura Terragrunt

```
lab08-data-lake-terragrunt/
├── terragrunt.hcl          ← root: S3 backend + provider
├── dev/
│   ├── env.hcl             ← variables por entorno
│   ├── ingestion/          ← Kinesis Firehose + MSK
│   ├── storage/            ← S3 buckets por capa
│   ├── processing/         ← Glue + EMR Serverless
│   ├── serving/            ← Redshift Serverless + Athena
│   └── governance/         ← Lake Formation + Glue Catalog
└── modules/
    ├── ingestion/
    ├── storage/
    ├── processing/
    ├── serving/
    └── governance/
```

---

## Labs

| Lab | Objetivo |
|-----|---------|
| [01 — Batch Pipeline](labs/01-batch-pipeline/README.md) | S3 → Glue ETL → S3 curated → Athena |
| [02 — Streaming Pipeline](labs/02-streaming-pipeline/README.md) | Kinesis Firehose → S3 → Glue Catalog → Redshift Spectrum |
| [03 — Combined Architecture](labs/03-combined-architecture/README.md) | Lambda architecture: batch + streaming |
| [04 — Governance](labs/04-governance/README.md) | Lake Formation: column-level security + fine-grained access |

---

## Despliegue

```bash
# Desplegar capa a capa (en orden de dependencias)
cd dev/storage/ && terragrunt apply
cd dev/governance/ && terragrunt apply
cd dev/ingestion/ && terragrunt apply
cd dev/processing/ && terragrunt apply
cd dev/serving/ && terragrunt apply

# O desplegar todo
terragrunt run-all apply

# Limpiar (⚠️ Redshift cobra en reposo)
terragrunt run-all destroy
```

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para la arquitectura completa del data lake y las decisiones de diseño por capa.

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para escenarios de arquitectura data lake end-to-end.
