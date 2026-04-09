# Lab 02 — EMR + Glue Catalog: Spark lee tablas del metastore

> **Duración estimada:** 25 minutos | **Coste estimado:** ~$0.10–0.20
> ⚠️ **Cleanup inmediato** al terminar.

---

## Objetivo

Configurar EMR Serverless para que use el Glue Data Catalog como metastore Hive. Un job Spark lee la tabla del Catalog (creada en Lab 04), procesa los datos, y escribe el resultado en S3. Comparar este enfoque con Glue ETL Job para el mismo procesamiento.

---

## Prerequisitos

- Lab 04 completado: base de datos `lab04_ecommerce` con tabla `sales` en Glue Catalog
- Si no tienes Lab 04, ejecuta primero los Pasos 1–4 de `lab04/labs/01-glue-catalog/README.md`
- Buckets del lab05 creados (Paso 1 del Lab 01)

---

## Paso 1: Verificar que el Glue Catalog tiene datos

```bash
REGION="eu-west-1"

# Verificar base de datos y tabla
aws glue get-database --name lab04_ecommerce --region "$REGION" \
  --query 'Database.Name' --output text 2>/dev/null || \
  echo "⚠️  Base de datos no encontrada — ejecuta Lab 04 Lab 01 primero"

aws glue get-tables \
  --database-name lab04_ecommerce \
  --region "$REGION" \
  --query 'TableList[].{Name:Name,Location:StorageDescriptor.Location}'
```

---

## Paso 2: Añadir permisos Glue al rol EMR

```bash
REGION="eu-west-1"

# El rol del lab01 necesita permisos para leer el Glue Catalog
cat > /tmp/emr-glue-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase",
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetPartitions",
        "glue:GetPartition",
        "glue:BatchGetPartition"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "lakeformation:GetDataAccess"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name lab05-emr-serverless-role \
  --policy-name lab05-emr-glue-policy \
  --policy-document file:///tmp/emr-glue-policy.json

echo "Permisos Glue añadidos al rol EMR."
```

---

## Paso 3: Crear script Spark que lee desde Glue Catalog

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
INPUT_BUCKET="lab05-emr-input-${ACCOUNT_ID}"
OUTPUT_BUCKET="lab05-emr-output-${ACCOUNT_ID}"

cat > /tmp/glue_catalog_job.py << EOF
import sys
from pyspark.sql import SparkSession

def main():
    output_path = sys.argv[1] if len(sys.argv) > 1 else "s3://$OUTPUT_BUCKET/catalog-output/"

    # EMR configura automáticamente el Glue Catalog como metastore Hive
    # cuando se usa --conf spark.hadoop.hive.metastore.client.factory.class=...
    spark = SparkSession.builder \\
        .appName("EMRGlueCatalogJob") \\
        .config("spark.sql.catalogImplementation", "hive") \\
        .enableHiveSupport() \\
        .getOrCreate()

    spark.sparkContext.setLogLevel("WARN")

    # Listar bases de datos disponibles en el Glue Catalog
    print("=== Bases de datos en Glue Catalog ===")
    spark.sql("SHOW DATABASES").show()

    # Listar tablas
    print("=== Tablas en lab04_ecommerce ===")
    spark.sql("SHOW TABLES IN lab04_ecommerce").show()

    # Leer la tabla sales directamente desde el Catalog
    print("=== Schema de la tabla sales ===")
    spark.sql("DESCRIBE lab04_ecommerce.sales").show()

    # Query de analytics: top categorías por revenue
    print("=== Top categorías por revenue ===")
    result = spark.sql("""
        SELECT
            category,
            COUNT(*) as num_orders,
            ROUND(SUM(CAST(total AS DOUBLE)), 2) as total_revenue,
            ROUND(AVG(CAST(total AS DOUBLE)), 2) as avg_order_value,
            SUM(CAST(quantity AS INT)) as units_sold
        FROM lab04_ecommerce.sales
        GROUP BY category
        ORDER BY total_revenue DESC
    """)

    result.show()

    # Query: top clientes
    print("=== Top clientes ===")
    top_customers = spark.sql("""
        SELECT
            customer_id,
            COUNT(*) as orders,
            ROUND(SUM(CAST(total AS DOUBLE)), 2) as total_spent
        FROM lab04_ecommerce.sales
        GROUP BY customer_id
        ORDER BY total_spent DESC
        LIMIT 5
    """)
    top_customers.show()

    # Guardar resultado en S3 como Parquet
    result.write \\
        .mode("overwrite") \\
        .parquet(output_path)

    print(f"Resultado guardado en: {output_path}")
    spark.stop()

if __name__ == "__main__":
    main()
EOF

aws s3 cp /tmp/glue_catalog_job.py "s3://$INPUT_BUCKET/scripts/glue_catalog_job.py"
echo "Script subido."
```

---

## Paso 4: Enviar job con Glue Catalog habilitado

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
INPUT_BUCKET="lab05-emr-input-${ACCOUNT_ID}"
OUTPUT_BUCKET="lab05-emr-output-${ACCOUNT_ID}"
LOGS_BUCKET="lab05-emr-logs-${ACCOUNT_ID}"

APP_ID=$(aws emr-serverless list-applications \
  --region "$REGION" \
  --query 'applications[?name==`lab05-spark-app`].id' \
  --output text)

# Si la app fue eliminada, recrearla
if [[ -z "$APP_ID" || "$APP_ID" == "None" ]]; then
  APP_ID=$(aws emr-serverless create-application \
    --name lab05-spark-app \
    --release-label emr-7.1.0 \
    --type SPARK \
    --region "$REGION" \
    --query 'applicationId' \
    --output text)
  echo "Aplicación creada: $APP_ID"
  sleep 15
fi

ROLE_ARN=$(aws iam get-role \
  --role-name lab05-emr-serverless-role \
  --query 'Role.Arn' --output text)

JOB_RUN_ID=$(aws emr-serverless start-job-run \
  --application-id "$APP_ID" \
  --execution-role-arn "$ROLE_ARN" \
  --name "glue-catalog-job" \
  --job-driver "{
    \"sparkSubmit\": {
      \"entryPoint\": \"s3://$INPUT_BUCKET/scripts/glue_catalog_job.py\",
      \"entryPointArguments\": [\"s3://$OUTPUT_BUCKET/catalog-output/\"],
      \"sparkSubmitParameters\": \"--conf spark.executor.cores=2 --conf spark.executor.memory=4g --conf spark.driver.memory=2g --conf spark.hadoop.hive.metastore.client.factory.class=com.amazonaws.glue.catalog.metastore.AWSGlueDataCatalogHiveClientFactory\"
    }
  }" \
  --configuration-overrides "{
    \"monitoringConfiguration\": {
      \"s3MonitoringConfiguration\": {
        \"logUri\": \"s3://$LOGS_BUCKET/emr-logs/\"
      }
    }
  }" \
  --region "$REGION" \
  --query 'jobRunId' \
  --output text)

echo "Job enviado: $JOB_RUN_ID"

while true; do
  STATE=$(aws emr-serverless get-job-run \
    --application-id "$APP_ID" \
    --job-run-id "$JOB_RUN_ID" \
    --region "$REGION" \
    --query 'jobRun.state' \
    --output text)
  echo "$(date -u +%H:%M:%S) $STATE"
  [[ "$STATE" == "SUCCESS" || "$STATE" == "FAILED" ]] && break
  sleep 15
done

echo "Job: $STATE"
```

> **Clave:** El flag `spark.hadoop.hive.metastore.client.factory.class=com.amazonaws.glue.catalog.metastore.AWSGlueDataCatalogHiveClientFactory` hace que Spark use el Glue Catalog en lugar de un Hive Metastore propio. El código Spark usa `spark.sql("SELECT * FROM lab04_ecommerce.sales")` como si fuera una tabla Hive normal.

---

## Paso 5: Verificar resultados

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OUTPUT_BUCKET="lab05-emr-output-${ACCOUNT_ID}"

echo "=== Output en S3 ==="
aws s3 ls "s3://$OUTPUT_BUCKET/catalog-output/" --recursive

# Leer con Athena para verificar el Parquet generado
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RESULTS_BUCKET="lab04-glue-results-${ACCOUNT_ID}"

if aws s3 ls "s3://$RESULTS_BUCKET" &>/dev/null; then
  QUERY_ID=$(aws athena start-query-execution \
    --query-string "SELECT * FROM \"s3scan\".\"lab05_output\" LIMIT 10" \
    --result-configuration "OutputLocation=s3://$RESULTS_BUCKET/athena/" \
    --region eu-west-1 \
    --query 'QueryExecutionId' --output text 2>/dev/null || echo "")
  echo "Usa Athena para leer s3://$OUTPUT_BUCKET/catalog-output/ directamente"
fi
```

---

## Comparación: EMR Spark vs Glue ETL para el mismo job

```
Job: leer tabla Glue Catalog, agregar por categoría, escribir Parquet en S3

┌─────────────────────────────────────────────────────────────────┐
│                    Glue ETL Job                                 │
│  ✓ Serverless — sin configuración de workers                    │
│  ✓ DynamicFrame API más simple                                  │
│  ✓ Glue Studio: visual ETL sin código                          │
│  ✗ Sin enableHiveSupport() ni SparkSQL sobre Catalog            │
│  ✗ Sin control de particionado de Spark                         │
│  Coste: 2 DPU × $0.44/DPU-h × 5 min ≈ $0.07                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    EMR Serverless                               │
│  ✓ SparkSQL completo — enableHiveSupport(), Glue Catalog nativo │
│  ✓ Control total: executor sizing, particiones, shuffle          │
│  ✓ MLlib, GraphX, Streaming, Delta Lake, Hudi                  │
│  ✓ Reutiliza código Spark existente sin cambios                 │
│  ✗ Tiempo de arranque mayor (1–3 min)                           │
│  ✗ Más configuración necesaria                                  │
│  Coste: similar a Glue para jobs pequeños                      │
└─────────────────────────────────────────────────────────────────┘

Conclusión para este job:
  → Glue ETL es suficiente y más simple
  → EMR se justifica si: código Spark existente, MLlib, tuning avanzado,
    joins complejos con >100GB, o frameworks no-Spark (Hive, Presto)
```

---

## ⚠️ Cleanup inmediato

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

APP_ID=$(aws emr-serverless list-applications \
  --region "$REGION" \
  --query 'applications[?name==`lab05-spark-app`].id' \
  --output text 2>/dev/null || echo "")

if [[ -n "$APP_ID" && "$APP_ID" != "None" ]]; then
  aws emr-serverless stop-application --application-id "$APP_ID" --region "$REGION" 2>/dev/null || true
  sleep 30
  aws emr-serverless delete-application --application-id "$APP_ID" --region "$REGION"
  echo "Aplicación EMR eliminada."
fi
```

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| EMR usa Glue Catalog como metastore | Paso 4: `AWSGlueDataCatalogHiveClientFactory` |
| SparkSQL con `SHOW DATABASES`, `SHOW TABLES` | Paso 3: código Spark |
| Leer tabla Glue con `spark.sql("FROM catalog.db.table")` | Paso 3: `lab04_ecommerce.sales` |
| Escribir Parquet en S3 desde Spark | Paso 3: `.write.parquet(output_path)` |
| EMR vs Glue: misma tarea, distinta complejidad | Paso 5: tabla comparativa |
