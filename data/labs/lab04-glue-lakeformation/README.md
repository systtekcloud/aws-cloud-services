# Lab 04 — AWS Glue + Lake Formation

> **Coste:** Mínimo (S3 storage, Glue en reposo = $0) | **Región:** eu-west-1

---

## Objetivo

Dominar AWS Glue como plataforma ETL serverless y catálogo de metadatos, y Lake Formation como capa de gobierno del data lake. Contenido frecuente en SAA-C03.

---

## Arquitectura

```
Data Sources              Glue                          Data Lake
─────────────             ──────────────────────────    ─────────────────────
S3 (raw data)    ──────► Crawler → Data Catalog        S3 (curated/processed)
RDS / Redshift            ETL Jobs (Spark/Python)  ────►
On-premises               Workflows (orchestración)     Consumers:
                                                        Athena (SQL ad-hoc)
                          Lake Formation                Redshift Spectrum
                          (governance layer)            QuickSight
                          - Column-level security
                          - Row-level filters
                          - Fine-grained permissions
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — Glue Catalog](labs/01-glue-catalog/README.md) | Crawler + Data Catalog + Athena queries | ~$0 (Crawler = $0.44/DPU-h) |
| [02 — Glue ETL](labs/02-glue-etl/README.md) | Job ETL Spark: CSV → Parquet con transformaciones | ~$0.44/DPU-h |
| [03 — Lake Formation](labs/03-lake-formation/README.md) | Column-level security + fine-grained permissions | $0 |

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- Glue Catalog vs Hive Metastore
- ETL vs ELT — cuándo usar Glue vs Redshift COPY
- Lake Formation vs IAM + bucket policies — diferencia crítica
- DPU (Data Processing Unit) y escalado de Glue Jobs

---

## Terraform

```bash
cd terraform/
terraform init
terraform apply
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para escenarios ETL, catálogo y gobernanza.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Catálogo de metadatos centralizado para S3? | **Glue Data Catalog** |
| ¿ETL serverless sin gestionar infraestructura? | **AWS Glue ETL** |
| ¿Column-level security en data lake? | **Lake Formation** |
| ¿Glue vs EMR para ETL? | Glue = serverless/simple. EMR = clusters dedicados/complejo |
