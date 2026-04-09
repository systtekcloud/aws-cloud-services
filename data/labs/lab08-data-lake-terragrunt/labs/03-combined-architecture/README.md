# Lab 03 — Arquitectura Combinada: EMR Serverless + Redshift Spectrum

> **Objetivo:** Ejecutar un job Spark en EMR Serverless sobre los datos procesados del Lab 01, cargar resultados en Redshift Serverless (curated/), y hacer un JOIN entre tablas Redshift y datos S3 con Redshift Spectrum.
> **Prerequisito:** Labs 01 y 02 completados. Datos en processed/ disponibles.
> **Coste estimado:** ~$2-4 (EMR Serverless cobra por vCPU-hora y GB-hora; Redshift Serverless por RPU-hora).

---

## Paso 1: Desplegar la capa serving

```bash
cd data/labs/lab08-data-lake-terragrunt/dev/serving
terragrunt apply
```

Obtener endpoints:

```bash
REGION="eu-west-1"
NAME_PREFIX="lab08-data-lake-dev"

BUCKET=$(terragrunt output -raw data_lake_bucket_id --terragrunt-working-dir ../storage 2>/dev/null \
        || echo "${NAME_PREFIX}-data-lake")

GLUE_DB=$(terragrunt output -raw glue_database_name --terragrunt-working-dir ../governance 2>/dev/null \
         || echo "lab08_data_lake_dev_catalog")

EMR_APP_ID=$(terragrunt output -raw emr_application_id --terragrunt-working-dir ../processing 2>/dev/null)
EMR_ROLE=$(terragrunt output -raw emr_role_arn --terragrunt-working-dir ../processing 2>/dev/null)

RS_WG=$(terragrunt output -raw redshift_workgroup_name --terragrunt-working-dir ../serving 2>/dev/null \
       || echo "${NAME_PREFIX}-wg")

RS_ROLE=$(terragrunt output -raw redshift_role_arn --terragrunt-working-dir ../serving 2>/dev/null)

echo "EMR App ID: $EMR_APP_ID"
echo "EMR Role:   $EMR_ROLE"
echo "RS WG:      $RS_WG"
echo "RS Role:    $RS_ROLE"
```

---

## Paso 2: Job Spark en EMR Serverless — agregar datos processed/

Crear el script PySpark de agregación:

```bash
cat > /tmp/aggregate_events.py << 'PYTHON'
"""
aggregate_events.py — EMR Serverless Spark job
Lee los eventos procesados (Parquet) desde el Glue Catalog,
calcula métricas de negocio y escribe en curated/ (Parquet particionado).
"""
from pyspark.sql import SparkSession
from pyspark.sql.functions import count, countDistinct, sum as spark_sum, avg, col, round as spark_round

import sys
source_db = sys.argv[1]
target_path = sys.argv[2]

spark = SparkSession.builder \
    .appName("AggregateEvents") \
    .config("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog") \
    .config("hive.metastore.client.factory.class",
            "com.amazonaws.glue.catalog.metastore.AWSGlueDataCatalogHiveClientFactory") \
    .enableHiveSupport() \
    .getOrCreate()

spark.sparkContext.setLogLevel("WARN")

# Leer desde el Glue Catalog — usa el metastore de Glue como Hive metastore
events = spark.sql(f"SELECT * FROM {source_db}.raw")

print(f"Total de eventos: {events.count()}")
events.printSchema()

# Agregación 1: conteo por tipo de evento y día
by_type_day = events.groupBy("event_type", "year", "month", "day") \
    .agg(
        count("*").alias("event_count"),
        countDistinct("user_id").alias("unique_users")
    )

# Agregación 2: sesiones de usuario (simplificado: eventos por usuario por día)
user_activity = events.groupBy("user_id", "year", "month", "day") \
    .agg(
        count("*").alias("total_events"),
        count(col("event_type") == "purchase").alias("purchases")
    )

# Escribir en curated/ particionado
by_type_day.write \
    .mode("overwrite") \
    .partitionBy("year", "month", "day") \
    .parquet(f"{target_path}/event_type_daily/")

user_activity.write \
    .mode("overwrite") \
    .partitionBy("year", "month", "day") \
    .parquet(f"{target_path}/user_activity_daily/")

print(f"Datos curated escritos en: {target_path}")
spark.stop()
PYTHON

# Subir el script a S3
aws s3 cp /tmp/aggregate_events.py \
  "s3://${BUCKET}/scripts/aggregate_events.py" \
  --region "$REGION"

echo "Script subido a S3."
```

Lanzar el job en EMR Serverless:

```bash
JOB_RUN_ID=$(aws emr-serverless start-job-run \
  --application-id "$EMR_APP_ID" \
  --execution-role-arn "$EMR_ROLE" \
  --region "$REGION" \
  --name "aggregate-events-$(date +%Y%m%d%H%M%S)" \
  --job-driver '{
    "sparkSubmit": {
      "entryPoint": "s3://'"${BUCKET}"'/scripts/aggregate_events.py",
      "entryPointArguments": ["'"${GLUE_DB}"'", "s3://'"${BUCKET}"'/curated/"],
      "sparkSubmitParameters": "--conf spark.executor.cores=2 --conf spark.executor.memory=4g --conf spark.driver.cores=1 --conf spark.driver.memory=2g"
    }
  }' \
  --configuration-overrides '{
    "monitoringConfiguration": {
      "s3MonitoringConfiguration": {
        "logUri": "s3://'"${BUCKET}"'/emr-logs/"
      }
    }
  }' \
  --query 'jobRunId' \
  --output text)

echo "Job Run ID: $JOB_RUN_ID"

# Monitorizar el job
while true; do
  STATUS=$(aws emr-serverless get-job-run \
    --application-id "$EMR_APP_ID" \
    --job-run-id "$JOB_RUN_ID" \
    --region "$REGION" \
    --query 'jobRun.state' \
    --output text)
  echo "Estado: $STATUS"
  [[ "$STATUS" == "SUCCESS" || "$STATUS" == "FAILED" || "$STATUS" == "CANCELLED" ]] && break
  sleep 20
done
```

---

## Paso 3: Cargar datos curated en Redshift con COPY

```bash
# Conectar a Redshift con el Query Editor v2 en la consola, o usar psql:
# psql -h <endpoint> -U admin -d datalake -p 5439

# SQL para ejecutar en Redshift Query Editor v2:
cat << SQL
-- 1. Configurar Redshift Spectrum (ejecutar una sola vez)
CREATE EXTERNAL SCHEMA IF NOT EXISTS spectrum_processed
FROM DATA CATALOG
DATABASE '${GLUE_DB}'
IAM_ROLE '${RS_ROLE}'
REGION 'eu-west-1';

-- 2. Ver tablas externas disponibles (datos en S3 processed/)
SELECT schemaname, tablename, location
FROM SVV_EXTERNAL_TABLES
WHERE schemaname = 'spectrum_processed';

-- 3. Crear tabla interna para datos curated (event_type_daily)
CREATE TABLE IF NOT EXISTS public.event_type_daily (
  event_type  VARCHAR(32),
  event_count BIGINT,
  unique_users BIGINT,
  year        SMALLINT,
  month       SMALLINT,
  day         SMALLINT
)
DISTSTYLE AUTO
SORTKEY (year, month, day, event_type);

-- 4. Cargar datos desde curated/ con COPY
COPY public.event_type_daily
FROM 's3://${BUCKET}/curated/event_type_daily/'
IAM_ROLE '${RS_ROLE}'
FORMAT AS PARQUET;

-- 5. Verificar carga
SELECT COUNT(*) FROM public.event_type_daily;

-- 6. Query de negocio: top event types esta semana
SELECT event_type, SUM(event_count) as total_events, SUM(unique_users) as total_users
FROM public.event_type_daily
WHERE year = 2024 AND month = 3
GROUP BY event_type
ORDER BY total_events DESC;
SQL
```

---

## Paso 4: Redshift Spectrum — JOIN entre Redshift y S3

El poder de Spectrum: hacer JOINs entre tablas Redshift (datos calientes, procesados) y tablas externas en S3 (histórico, sin mover datos):

```sql
-- En Redshift Query Editor v2:

-- Datos de los últimos 7 días en Redshift (curated, cargados con COPY)
-- vs histórico en S3 (processed/, accedido vía Spectrum)

SELECT
  r.event_type,
  r.event_count                           AS redshift_count_7d,
  s.total_events_historical                AS s3_count_30d,
  ROUND(r.event_count * 100.0 / NULLIF(s.total_events_historical, 0), 1) AS pct_recent
FROM public.event_type_daily r
JOIN (
  SELECT event_type, COUNT(*) AS total_events_historical
  FROM spectrum_processed.raw          -- tabla en S3 processed/
  GROUP BY event_type
) s ON r.event_type = s.event_type
WHERE r.year = 2024 AND r.month = 3
ORDER BY redshift_count_7d DESC;

-- Ver el plan de ejecución — confirmar que Spectrum hace partition pruning
EXPLAIN
SELECT * FROM spectrum_processed.raw
WHERE year = 2024 AND month = 3;
-- Buscar en el plan: "S3 Seq Scan" con "Filter: ..." → pruning correcto
```

---

## Paso 5: Consultas Athena vs Redshift — comparación

```bash
ATHENA_WG=$(terragrunt output -raw athena_workgroup_name --terragrunt-working-dir ../governance 2>/dev/null \
           || echo "${NAME_PREFIX}-workgroup")

# Misma query en Athena (schema-on-read, procesa directamente el Parquet en S3)
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT event_type, COUNT(*) as total FROM \"${GLUE_DB}\".raw WHERE year=2024 AND month=3 GROUP BY event_type ORDER BY total DESC;" \
  --work-group "$ATHENA_WG" \
  --region "$REGION" \
  --query 'QueryExecutionId' \
  --output text)

sleep 8

aws athena get-query-execution \
  --query-execution-id "$QUERY_ID" \
  --region "$REGION" \
  --query '{DataScannedGB: QueryExecution.Statistics.DataScannedInBytes, EngineTime: QueryExecution.Statistics.EngineExecutionTimeInMillis}'
```

```
Athena sobre processed/ (Parquet):
  DataScannedInBytes: ~50KB para 5 eventos
  EngineTime: ~2-3 segundos (cold start incluido)
  Coste: $5 × 50KB/1TB ≈ $0.000000025

Redshift Serverless:
  DataScannedInBytes: ~2MB (minimum charge = 1s a 8 RPU)
  EngineTime: < 500ms (data en memoria si recién cargado)
  Coste: 8 RPU × $0.36/hora × (1s/3600s) ≈ $0.0008

Conclusión: para queries ad-hoc poco frecuentes → Athena más barato.
Para dashboards BI con queries recurrentes → Redshift más rápido y predecible.
```

---

## Qué aprendiste

| Concepto | Detalle |
|---|---|
| `AWSGlueDataCatalogHiveClientFactory` | Config Spark para usar Glue como Hive metastore en EMR |
| EMR Serverless auto-stop | `idle_timeout_minutes = 15` — para el cluster cuando no hay jobs |
| Redshift `COPY` | Carga masiva desde S3; mucho más rápido que INSERT fila a fila |
| Redshift Spectrum | `CREATE EXTERNAL SCHEMA FROM DATA CATALOG` — JOIN S3 + Redshift sin COPY |
| `SVV_EXTERNAL_TABLES` | Vista de sistema en Redshift que lista las tablas externas de Spectrum |
| `EXPLAIN` en Redshift | Verificar que Spectrum aplica partition pruning en la query |
