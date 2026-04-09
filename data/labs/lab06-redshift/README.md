# Lab 06 — Amazon Redshift

> **Coste:** Redshift Serverless cobra aunque no haya queries activas | **Región:** eu-west-1

---

## Objetivo

Dominar Amazon Redshift como data warehouse analítico a escala de petabytes: cargar datos con COPY, optimizar con columnar storage y distribution keys, y ampliar con Redshift Spectrum para queries sobre S3. Contenido clave para SAA-C03.

---

## Arquitectura

```
Fuentes de datos          Redshift                      Consumers
─────────────────         ──────────────────────────    ─────────────────────
S3 (CSV/Parquet) ──────► COPY command                  SQL clients
Kinesis Firehose          Columnar storage         ────► QuickSight
DMS (CDC)                 Compressed data               Jupyter notebooks
                          MPP (Massively Parallel)      APIs via Data API

                          Redshift Spectrum ─────────► S3 (external tables)
                          (query S3 from Redshift)       Glue Data Catalog
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — Redshift Basics](labs/01-redshift-basics/README.md) | Crear Serverless, cargar datos con COPY, queries SQL | Serverless RPU |
| [02 — Redshift Spectrum](labs/02-redshift-spectrum/README.md) | External tables sobre S3 + Glue Catalog | Serverless RPU |

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- Redshift vs RDS vs Athena — cuándo usar cada uno
- Distribution keys y sort keys
- Columnar storage vs row storage
- Redshift Spectrum vs Athena — diferencia crítica
- COPY vs INSERT performance

---

## Terraform

```bash
cd terraform/
terraform init
terraform apply
# ⚠️ Destruir después — Serverless cobra en reposo
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para escenarios data warehouse vs data lake.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Data warehouse SQL analítico a escala? | **Redshift** |
| ¿Queries SQL sobre S3 sin cargar datos en Redshift? | **Redshift Spectrum** (o Athena) |
| ¿Redshift vs Athena? | Redshift = datos en el warehouse, performance predecible. Athena = datos en S3, pago por query |
| ¿Cómo cargar datos en Redshift eficientemente? | **COPY** desde S3 (más rápido que INSERT fila a fila) |
