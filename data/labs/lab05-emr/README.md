# Lab 05 — Amazon EMR (Elastic MapReduce)

> **Coste:** Solo durante jobs (EMR Serverless = $0 en reposo) | **Región:** eu-west-1

---

## Objetivo

Dominar Amazon EMR Serverless para procesamiento Spark a gran escala: ejecutar jobs sin gestionar clusters, integrar con Glue Data Catalog, y entender cuándo elegir EMR vs Glue para procesamiento batch. Contenido relevante para SAA-C03.

---

## Arquitectura

```
Datos de entrada          EMR Serverless                Salida
─────────────────         ──────────────────────────    ─────────────────────
S3 (raw data)    ──────► Application                   S3 (processed)
                          (Spark / Hive / Presto)  ────►
                          - Auto-scaling               Glue Data Catalog
                          - $0 en reposo               (metadatos actualizados)
                          - Sin cluster management

                          Glue Data Catalog ──────────► Athena / Redshift
                          (metadatos compartidos)        Spectrum
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — EMR Serverless](labs/01-emr-serverless/README.md) | Crear application, submit Spark job, ver resultados en S3 | Solo job duration |
| [02 — EMR + Glue Integration](labs/02-emr-glue-integration/README.md) | Usar Glue Data Catalog como metastore en EMR | Solo job duration |

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- EMR Serverless vs EMR on EC2 vs EMR on EKS
- EMR vs Glue — cuándo usar cada uno
- Spark en EMR: jobs, stages, tasks
- S3 como HDFS sustituto (S3A connector)

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

Ver [scenarios/README.md](scenarios/README.md) para escenarios EMR vs Glue vs Athena.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Procesamiento Spark masivo con control total? | **EMR** |
| ¿ETL serverless simple sin gestionar clusters? | **Glue ETL** |
| ¿EMR Serverless vs EMR on EC2? | Serverless = sin gestionar workers. EC2 = control total de instancias |
| ¿EMR + Glue Catalog? | EMR puede usar el Glue Data Catalog como Hive metastore |
