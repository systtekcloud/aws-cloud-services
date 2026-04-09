# Lab 02 — Glue ETL Job: CSV → Parquet

> **Duración estimada:** 25 minutos | **Coste estimado:** ~$0.44 (2 DPU × $0.44/DPU-hora × ~30 min)

---

## Objetivo

Crear un Glue ETL Job que convierta el dataset CSV del Lab 01 a formato Parquet comprimido en S3. Comparar el rendimiento y coste de Athena antes y después de la conversión.

---

## Por qué Parquet > CSV para analytics

```
CSV:
  - Sin compresión nativa
  - Row-oriented: Athena lee TODAS las columnas para responder queries de columnas específicas
  - Sin estadísticas de columna (min/max) → full scan siempre
  - Tamaño: ~1x

Parquet:
  - Columnar: Athena lee SOLO las columnas que necesita la query
  - Compresión nativa por columna (Snappy, GZIP)
  - Estadísticas por row group (min/max/count) → skip de bloques
  - Tamaño: 0.1–0.3x del CSV equivalente
  
Resultado típico:
  - Athena lee 10–100x menos bytes → 10–100x menos coste
  - Queries 2–10x más rápidas
```

---

## Paso 1: Crear bucket procesado

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
PROCESSED_BUCKET="lab04-glue-processed-${ACCOUNT_ID}"

aws s3 mb "s3://$PROCESSED_BUCKET" --region "$REGION"
echo "Bucket procesado: $PROCESSED_BUCKET"
```

---

## Paso 2: Crear el script del ETL Job

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RAW_BUCKET="lab04-glue-raw-${ACCOUNT_ID}"
PROCESSED_BUCKET="lab04-glue-processed-${ACCOUNT_ID}"

cat > /tmp/glue_etl_job.py << EOF
import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.dynamicframe import DynamicFrame

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'source_bucket', 'dest_bucket'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Leer desde Glue Catalog (tabla creada por el Crawler)
source = glueContext.create_dynamic_frame.from_catalog(
    database="lab04_ecommerce",
    table_name="sales",
    transformation_ctx="source"
)

print(f"Registros leídos: {source.count()}")
source.printSchema()

# Transformación: castear tipos correctamente
from awsglue.transforms import ApplyMapping
mapped = ApplyMapping.apply(
    frame=source,
    mappings=[
        ("order_id",    "string", "order_id",    "int"),
        ("customer_id", "string", "customer_id", "string"),
        ("product_id",  "string", "product_id",  "string"),
        ("category",    "string", "category",    "string"),
        ("quantity",    "string", "quantity",    "int"),
        ("unit_price",  "string", "unit_price",  "double"),
        ("total",       "string", "total",       "double"),
        ("country",     "string", "country",     "string"),
        ("order_date",  "string", "order_date",  "date"),
        ("year",        "string", "year",        "string"),
        ("month",       "string", "month",       "string"),
    ],
    transformation_ctx="mapped"
)

# Escribir como Parquet comprimido con Snappy, particionado
glueContext.write_dynamic_frame.from_options(
    frame=mapped,
    connection_type="s3",
    connection_options={
        "path": f"s3://{args['dest_bucket']}/sales/",
        "partitionKeys": ["year", "month"]
    },
    format="parquet",
    format_options={"compression": "snappy"},
    transformation_ctx="sink"
)

print("Job completado. Datos escritos en Parquet.")
job.commit()
EOF

# Subir el script a S3
aws s3 cp /tmp/glue_etl_job.py "s3://${RAW_BUCKET}/scripts/glue_etl_job.py"
echo "Script subido a s3://${RAW_BUCKET}/scripts/glue_etl_job.py"
```

---

## Paso 3: Crear y ejecutar el ETL Job

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
RAW_BUCKET="lab04-glue-raw-${ACCOUNT_ID}"
PROCESSED_BUCKET="lab04-glue-processed-${ACCOUNT_ID}"
ROLE_ARN=$(aws iam get-role --role-name lab04-glue-crawler-role --query 'Role.Arn' --output text)

# Añadir permisos al rol para escribir en el bucket procesado
cat > /tmp/glue-processed-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"],
    "Resource": [
      "arn:aws:s3:::$PROCESSED_BUCKET",
      "arn:aws:s3:::$PROCESSED_BUCKET/*",
      "arn:aws:s3:::$RAW_BUCKET",
      "arn:aws:s3:::$RAW_BUCKET/*"
    ]
  }]
}
EOF

aws iam put-role-policy \
  --role-name lab04-glue-crawler-role \
  --policy-name lab04-glue-processed-access \
  --policy-document file:///tmp/glue-processed-policy.json

# Crear el Job
aws glue create-job \
  --name lab04-csv-to-parquet \
  --role "$ROLE_ARN" \
  --command "{
    \"Name\": \"glueetl\",
    \"ScriptLocation\": \"s3://$RAW_BUCKET/scripts/glue_etl_job.py\",
    \"PythonVersion\": \"3\"
  }" \
  --default-arguments "{
    \"--source_bucket\": \"$RAW_BUCKET\",
    \"--dest_bucket\": \"$PROCESSED_BUCKET\",
    \"--job-language\": \"python\",
    \"--enable-continuous-cloudwatch-log\": \"true\"
  }" \
  --glue-version "4.0" \
  --number-of-workers 2 \
  --worker-type "G.1X" \
  --region "$REGION"

# Ejecutar
RUN_ID=$(aws glue start-job-run \
  --job-name lab04-csv-to-parquet \
  --region "$REGION" \
  --query 'JobRunId' \
  --output text)

echo "Job iniciado: $RUN_ID"
echo "Siguiendo estado..."

while true; do
  STATE=$(aws glue get-job-run \
    --job-name lab04-csv-to-parquet \
    --run-id "$RUN_ID" \
    --region "$REGION" \
    --query 'JobRun.JobRunState' \
    --output text)
  echo "$(date -u +%H:%M:%S) Estado: $STATE"
  [[ "$STATE" == "SUCCEEDED" || "$STATE" == "FAILED" || "$STATE" == "ERROR" ]] && break
  sleep 15
done

echo "Job finalizado: $STATE"
```

---

## Paso 4: Verificar Parquet en S3 y crear tabla en Catalog

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
PROCESSED_BUCKET="lab04-glue-processed-${ACCOUNT_ID}"

# Ver archivos generados
aws s3 ls "s3://$PROCESSED_BUCKET/sales/" --recursive

# Crear Crawler para los datos procesados (Parquet)
ROLE_ARN=$(aws iam get-role --role-name lab04-glue-crawler-role --query 'Role.Arn' --output text)

aws glue create-crawler \
  --name lab04-parquet-crawler \
  --role "$ROLE_ARN" \
  --database-name lab04_ecommerce \
  --targets "{\"S3Targets\": [{\"Path\": \"s3://$PROCESSED_BUCKET/sales/\"}]}" \
  --region "$REGION"

aws glue start-crawler --name lab04-parquet-crawler --region "$REGION"

while true; do
  STATE=$(aws glue get-crawler --name lab04-parquet-crawler --region "$REGION" \
    --query 'Crawler.State' --output text)
  echo "Crawler: $STATE"
  [[ "$STATE" == "READY" ]] && break
  sleep 10
done

# Ver la nueva tabla creada (sales desde processed bucket)
aws glue get-tables \
  --database-name lab04_ecommerce \
  --region "$REGION" \
  --query 'TableList[].{Name:Name,Location:StorageDescriptor.Location,Format:StorageDescriptor.SerdeInfo.SerializationLibrary}'
```

---

## Paso 5: Comparar Athena CSV vs Parquet

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

# Query sobre CSV
CSV_QUERY=$(aws athena start-query-execution \
  --query-string "SELECT category, SUM(total) as revenue FROM lab04_ecommerce.sales GROUP BY category ORDER BY revenue DESC" \
  --work-group lab04-workgroup \
  --region "$REGION" \
  --query 'QueryExecutionId' --output text)

sleep 5

CSV_BYTES=$(aws athena get-query-execution \
  --query-execution-id "$CSV_QUERY" --region "$REGION" \
  --query 'QueryExecution.Statistics.DataScannedInBytes' --output text)

# Obtener nombre de la tabla Parquet (la que apunta al processed bucket)
PARQUET_TABLE=$(aws glue get-tables \
  --database-name lab04_ecommerce --region "$REGION" \
  --query "TableList[?contains(StorageDescriptor.Location, 'processed')].Name" \
  --output text)

# Query sobre Parquet
PARQUET_QUERY=$(aws athena start-query-execution \
  --query-string "SELECT category, SUM(total) as revenue FROM lab04_ecommerce.${PARQUET_TABLE:-sales} GROUP BY category ORDER BY revenue DESC" \
  --work-group lab04-workgroup \
  --region "$REGION" \
  --query 'QueryExecutionId' --output text)

sleep 5

PARQUET_BYTES=$(aws athena get-query-execution \
  --query-execution-id "$PARQUET_QUERY" --region "$REGION" \
  --query 'QueryExecution.Statistics.DataScannedInBytes' --output text)

echo "=== Comparación Athena ==="
echo "Bytes escaneados (CSV):    $CSV_BYTES bytes"
echo "Bytes escaneados (Parquet): $PARQUET_BYTES bytes"
if [[ -n "$CSV_BYTES" && -n "$PARQUET_BYTES" && "$CSV_BYTES" -gt 0 ]]; then
  RATIO=$(echo "scale=1; $CSV_BYTES / $PARQUET_BYTES" | bc 2>/dev/null || echo "N/A")
  echo "Reducción: ${RATIO}x menos bytes con Parquet"
fi
echo ""
echo "Coste estimado (CSV):    \$$(echo "scale=6; $CSV_BYTES / 1099511627776 * 5" | bc 2>/dev/null || echo "N/A")"
echo "Coste estimado (Parquet): \$$(echo "scale=6; $PARQUET_BYTES / 1099511627776 * 5" | bc 2>/dev/null || echo "N/A")"
```

Con datasets pequeños la diferencia es mínima, pero en producción con TBs de datos Parquet puede reducir el coste de Athena en 10–100x.

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| Glue ETL Job serverless (sin cluster) | Paso 3: `number-of-workers 2 G.1X` gestionados por AWS |
| Conversión CSV → Parquet columnar | Paso 2: `format="parquet", compression="snappy"` |
| Tipos correctos (int, double, date) | Paso 2: `ApplyMapping` en el script |
| Particionado por año/mes | Paso 3: `partitionKeys: ["year", "month"]` |
| Athena escanea menos bytes con Parquet | Paso 5: comparación `DataScannedInBytes` |
