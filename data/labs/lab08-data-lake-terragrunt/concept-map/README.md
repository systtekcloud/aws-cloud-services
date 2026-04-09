# Data Lake Architecture — Mapa Conceptual

> **Módulo:** `data/labs/lab08-data-lake-terragrunt` | **Región:** eu-west-1
> ⚠️ **Coste:** ~$5-10 por lab completo. Destruir con `terragrunt run-all destroy`.

---

## Lambda Pattern (patrón de arquitectura de datos, no AWS Lambda)

El **Lambda Pattern** (Marz, 2011) propone dividir el procesamiento de datos en dos capas paralelas para equilibrar latencia y completitud:

```
                    ┌─────────────────────────────────────────────────────┐
  Producers         │              Lambda Pattern                         │
  (app, IoT,        │                                                     │
   eventos)         │  Batch Layer (Glue/EMR):                            │
      │             │    Reprocessa datos históricos completos             │
      │─────────────►    S3 raw → ETL → S3 processed → views exactas     │
      │             │                                        │            │
      │             │  Speed Layer (Kinesis):                │            │
      └─────────────►    Procesa datos en tiempo real         │            │
                    │    Solo datos recientes (bajo lag)      │            │
                    │                            │            │            │
                    │                            ▼            ▼            │
                    │                    Serving Layer (Athena / Redshift)│
                    │                    Combina batch views + speed views │
                    └─────────────────────────────────────────────────────┘

Problema: dos codebases distintos (batch + streaming) para la misma lógica → difícil de mantener.
```

---

## Kappa Architecture — simplificación

El **Kappa Pattern** (Kreps, 2014) elimina el batch layer completamente. Todo es streaming. Para recalcular historial, se reproduce el stream desde el principio:

```
  Producers
      │
      ▼
  Kinesis / MSK (stream completo, retención larga)
      │
      ├──► Consumer en tiempo real → serving layer (resultados inmediatos)
      │
      └──► Re-procesamiento del stream completo → recalcula si cambia la lógica
           (sin pipeline batch separado)

Ventaja: un único codebase para batch y streaming.
Cuándo usarlo: cuando el streaming puede reproducir todo el historial
               y el volumen no requiere compresión masiva de datos históricos.
```

---

## Data Lake vs Data Warehouse

```
Data Lake (S3 + Glue + Athena):               Data Warehouse (Redshift):
  ┌──────────────────────────────┐               ┌──────────────────────────────┐
  │ Schema-on-read               │               │ Schema-on-write              │
  │ Datos raw + procesados       │               │ Datos estructurados y limpios│
  │ CSV, Parquet, JSON, ORC...   │               │ Solo tablas relacionales      │
  │ Exploración, ML, ad-hoc      │               │ BI, dashboards, JOINs SQL    │
  │ Barato ($0.023/GB S3)        │               │ Más caro (compute siempre)   │
  │ Escalado ilimitado           │               │ Escalado por nodo            │
  └──────────────────────────────┘               └──────────────────────────────┘

Los mejores sistemas combinan ambos:
  Raw data    → S3 (data lake, barato, flexible)
  Hot data    → Redshift (rápido, para dashboards BI)
  Cold data   → S3 via Redshift Spectrum (sin mover datos)
```

---

## Arquitectura del Lab 08 — capas y servicios

```
CAPA INGESTION:
  App / IoT → Kinesis Data Streams (lab01)
                   └──► Firehose → S3 raw (lab01)
                   └──► Lambda (alertas tiempo real)

CAPA STORAGE (S3 — 3 zonas):
  raw/       → datos sin procesar (CSV, JSON, Avro)
  processed/ → datos transformados (Parquet, particionados)
  curated/   → datos agregados listos para BI

CAPA PROCESSING:
  Glue Crawler → descubre schemas en raw/
  Glue ETL Job → raw/ → processed/ (CSV → Parquet)
  EMR Serverless → jobs Spark complejos sobre processed/

CAPA SERVING:
  Athena → SQL ad-hoc sobre processed/ (Glue Catalog)
  Redshift Serverless → BI dashboards sobre curated/
  Redshift Spectrum → combina Redshift + processed/ S3

CAPA GOVERNANCE:
  Glue Data Catalog → metastore centralizado (schemas, particiones)
  Lake Formation    → permisos tabla/columna/fila por rol

OBSERVABILIDAD:
  OpenSearch → logs de aplicación y pipeline (opcional en dev)
```

---

## Cuándo usar cada capa

| Pregunta de negocio | Capa | Servicio |
|---|---|---|
| "¿Cuántos eventos recibimos en tiempo real?" | Speed | KDS + Lambda |
| "¿Qué datos tenemos crudos sin procesar?" | Storage raw | S3 + Athena ad-hoc |
| "¿Cuántas ventas hubo el mes pasado?" (ad-hoc) | Batch serving | Athena sobre processed/ |
| "Dashboard diario de revenue" (recurrente) | Serving | Redshift Serverless |
| "Datos de los últimos 5 años" (histórico) | Cold | Redshift Spectrum sobre S3 |
| "Usuarios del data lake sin acceso a PII" | Governance | Lake Formation column-level |
| "Buscar logs de error 'connection refused'" | Observabilidad | OpenSearch |

---

## Estructura Terragrunt del lab

```
lab08-data-lake-terragrunt/
├── terragrunt.hcl          ← root: remote state S3+DynamoDB, provider AWS
├── dev/
│   ├── env.hcl             ← variables de entorno (account_id, region, tags)
│   ├── storage/            ← S3 buckets (raw, processed, curated)
│   ├── governance/         ← Glue Catalog DB + Lake Formation
│   ├── ingestion/          ← KDS + Firehose → S3 raw
│   ├── processing/         ← Glue Crawler + ETL Job + EMR Serverless
│   └── serving/            ← Redshift Serverless + Athena workgroup
└── modules/
    ├── storage/            ← módulo reutilizable S3 + lifecycle policies
    ├── governance/         ← módulo reutilizable Glue Catalog + Lake Formation
    ├── ingestion/          ← módulo reutilizable KDS + Firehose
    ├── processing/         ← módulo reutilizable Glue + EMR
    └── serving/            ← módulo reutilizable Redshift + Athena
```

**Dependencias entre capas:**
```
storage → (base para todos)
governance → depende de storage (registra los buckets en Lake Formation)
ingestion  → depende de storage (escribe en raw/)
processing → depende de storage + governance (lee Catalog, escribe processed/)
serving    → depende de storage + governance (lee Catalog, carga en Redshift)
```

Terragrunt gestiona estas dependencias con `dependency {}` blocks — aplica en el orden correcto automáticamente.
