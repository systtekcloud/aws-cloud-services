# Lab 01 — Batch Pipeline: S3 raw/ → Glue ETL → processed/ → Athena

> **Objetivo:** Desplegar la infraestructura completa con Terragrunt, cargar datos de ejemplo en raw/, transformarlos a Parquet con Glue, y consultarlos con Athena.
> **Prerequisitos:** AWS CLI v2 configurado, Terraform >= 1.7, Terragrunt instalado.
> **Coste estimado:** ~$1-2 (Glue cobra por DPU-hora; Athena por TB escaneado).

---

## Paso 1: Desplegar la infraestructura

```bash
cd data/labs/lab08-data-lake-terragrunt

# Desplegar todo en orden (storage → governance → processing)
# Terragrunt resuelve las dependencias automáticamente
terragrunt run-all apply --terragrunt-include-dir dev/storage \
                          --terragrunt-include-dir dev/governance \
                          --terragrunt-include-dir dev/processing

# Alternativa: desplegar todo el entorno dev de una vez
cd dev
terragrunt run-all apply
```

Confirmar con `yes` cuando lo pida. El despliegue tarda ~3-5 minutos.

---

## Paso 2: Obtener outputs de Terragrunt

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
NAME_PREFIX="lab08-data-lake-dev"

# Obtener nombre del bucket
BUCKET=$(terragrunt output -raw data_lake_bucket_id --terragrunt-working-dir dev/storage 2>/dev/null \
         || echo "${NAME_PREFIX}-data-lake")

# Obtener nombre del Glue Job y Crawler
GLUE_CRAWLER=$(terragrunt output -raw glue_crawler_name --terragrunt-working-dir dev/processing 2>/dev/null \
              || echo "${NAME_PREFIX}-raw-crawler")

GLUE_JOB=$(terragrunt output -raw glue_job_name --terragrunt-working-dir dev/processing 2>/dev/null \
          || echo "${NAME_PREFIX}-raw-to-processed")

# Obtener nombre del workgroup Athena
ATHENA_WG=$(terragrunt output -raw athena_workgroup_name --terragrunt-working-dir dev/governance 2>/dev/null \
           || echo "${NAME_PREFIX}-workgroup")

echo "Bucket:    $BUCKET"
echo "Crawler:   $GLUE_CRAWLER"
echo "Glue Job:  $GLUE_JOB"
echo "Athena WG: $ATHENA_WG"
```

---

## Paso 3: Cargar datos de ejemplo en raw/

```bash
# Crear CSV de ejemplo (eventos de e-commerce)
cat > /tmp/events_sample.json << 'EOF'
{"event_id":"evt-001","timestamp":"2024-03-15T10:00:00Z","user_id":"user-123","event_type":"page_view","payload":"{\"page\":\"/products/laptop\",\"duration\":45}"}
{"event_id":"evt-002","timestamp":"2024-03-15T10:01:30Z","user_id":"user-456","event_type":"add_to_cart","payload":"{\"product_id\":\"prod-789\",\"price\":1299.99}"}
{"event_id":"evt-003","timestamp":"2024-03-15T10:02:00Z","user_id":"user-123","event_type":"purchase","payload":"{\"order_id\":\"ord-001\",\"total\":1299.99}"}
{"event_id":"evt-004","timestamp":"2024-03-15T10:05:00Z","user_id":"user-789","event_type":"search","payload":"{\"query\":\"auriculares bluetooth\",\"results\":42}"}
{"event_id":"evt-005","timestamp":"2024-03-15T10:06:00Z","user_id":"user-789","event_type":"page_view","payload":"{\"page\":\"/products/headphones\",\"duration\":120}"}
EOF

# Subir al prefijo raw/ con la estructura de partición esperada por el Crawler
aws s3 cp /tmp/events_sample.json \
  "s3://${BUCKET}/raw/year=2024/month=03/day=15/events_001.json" \
  --region "$REGION"

echo "Datos cargados. Verificar:"
aws s3 ls "s3://${BUCKET}/raw/" --recursive --region "$REGION"
```

---

## Paso 4: Ejecutar el Glue Crawler

El Crawler inspecciona raw/ y registra el schema en el Glue Data Catalog.

```bash
# Iniciar el Crawler
aws glue start-crawler \
  --name "$GLUE_CRAWLER" \
  --region "$REGION"

echo "Crawler iniciado. Esperando que termine..."

# Esperar hasta que el Crawler esté READY (puede tardar 2-5 minutos)
while true; do
  STATE=$(aws glue get-crawler \
    --name "$GLUE_CRAWLER" \
    --region "$REGION" \
    --query 'Crawler.State' \
    --output text)
  echo "Estado: $STATE"
  [[ "$STATE" == "READY" ]] && break
  sleep 15
done

echo "Crawler completado."
```

Verificar la tabla creada en el Catalog:

```bash
GLUE_DB=$(terragrunt output -raw glue_database_name --terragrunt-working-dir dev/governance 2>/dev/null \
         || echo "lab08_data_lake_dev_catalog")

aws glue get-tables \
  --database-name "$GLUE_DB" \
  --region "$REGION" \
  --query 'TableList[].{Name:Name, Location:StorageDescriptor.Location}'
```

---

## Paso 5: Ejecutar el Glue ETL Job

El ETL lee la tabla del Catalog, convierte a Parquet Snappy y particiona por fecha.

```bash
# Lanzar el job
JOB_RUN_ID=$(aws glue start-job-run \
  --job-name "$GLUE_JOB" \
  --region "$REGION" \
  --arguments '{
    "--SOURCE_PATH": "s3://'"${BUCKET}"'/raw/",
    "--TARGET_PATH": "s3://'"${BUCKET}"'/processed/",
    "--DATABASE": "'"${GLUE_DB}"'",
    "--TABLE": "raw"
  }' \
  --query 'JobRunId' \
  --output text)

echo "Job Run ID: $JOB_RUN_ID"

# Monitorizar el job
while true; do
  STATUS=$(aws glue get-job-run \
    --job-name "$GLUE_JOB" \
    --run-id "$JOB_RUN_ID" \
    --region "$REGION" \
    --query 'JobRun.JobRunState' \
    --output text)
  echo "Estado: $STATUS"
  [[ "$STATUS" == "SUCCEEDED" || "$STATUS" == "FAILED" ]] && break
  sleep 20
done

[[ "$STATUS" == "SUCCEEDED" ]] && echo "ETL completado con éxito." || echo "ETL fallido — revisar logs en CloudWatch."
```

Verificar datos Parquet en processed/:

```bash
aws s3 ls "s3://${BUCKET}/processed/" --recursive --region "$REGION" | head -20
```

---

## Paso 6: Consultar con Athena

```bash
# Verificar que el workgroup existe
aws athena get-work-group \
  --work-group "$ATHENA_WG" \
  --region "$REGION" \
  --query 'WorkGroup.Status'

# Lanzar query de conteo
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT event_type, COUNT(*) as total FROM \"${GLUE_DB}\".raw GROUP BY event_type ORDER BY total DESC;" \
  --query-execution-context "Database=${GLUE_DB}" \
  --work-group "$ATHENA_WG" \
  --region "$REGION" \
  --query 'QueryExecutionId' \
  --output text)

echo "Query ID: $QUERY_ID"

# Esperar resultado
sleep 5
aws athena get-query-results \
  --query-execution-id "$QUERY_ID" \
  --region "$REGION" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue'
```

Comparar coste de Athena entre raw (JSON sin comprimir) y processed (Parquet Snappy):

```bash
# Query sobre raw/ (JSON — escanea más datos)
Q1=$(aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM \"${GLUE_DB}\".raw;" \
  --work-group "$ATHENA_WG" --region "$REGION" \
  --query 'QueryExecutionId' --output text)

sleep 5

aws athena get-query-execution \
  --query-execution-id "$Q1" \
  --region "$REGION" \
  --query 'QueryExecution.Statistics.DataScannedInBytes'
```

> **Resultado esperado:** Parquet Snappy escanea 5-10x menos datos que JSON sin comprimir. A $5/TB, el ahorro es directo.

---

## Qué aprendiste

| Concepto | Detalle |
|---|---|
| Terragrunt `dependency {}` | Resolve el orden storage → governance → processing automáticamente |
| Glue Crawler | Inspecciona S3, infiere schema, registra tabla en el Catalog |
| Glue ETL DynamicFrame | API de alto nivel sobre Spark; más fácil que DataFrames para ETL |
| Parquet + Snappy | Columnar + compresión = 5-10x menos datos escaneados por Athena |
| Particionado Hive | `year=.../month=.../day=...` — Athena aplica partition pruning |
| Athena workgroup | Controla costes (límite por query), almacena resultados en S3 |
