# Lab 01 — EMR Serverless: job Spark de contar palabras

> **Duración estimada:** 30 minutos | **Coste estimado:** ~$0.10–0.20 (vCPU-hora de job)
> ⚠️ **Cleanup inmediato** al terminar — ver sección de limpieza.

---

## Objetivo

Crear una aplicación EMR Serverless, enviar un job Spark sencillo (word count sobre un dataset S3), verificar el output, y explorar los logs en CloudWatch. Entender el ciclo submit → running → succeeded sin gestionar ningún cluster EC2.

---

## Paso 1: Crear S3 buckets

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
INPUT_BUCKET="lab05-emr-input-${ACCOUNT_ID}"
OUTPUT_BUCKET="lab05-emr-output-${ACCOUNT_ID}"
LOGS_BUCKET="lab05-emr-logs-${ACCOUNT_ID}"

for BUCKET in "$INPUT_BUCKET" "$OUTPUT_BUCKET" "$LOGS_BUCKET"; do
  aws s3 mb "s3://$BUCKET" --region "$REGION"
  echo "Bucket creado: $BUCKET"
done
```

---

## Paso 2: Subir dataset de entrada y script Spark

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
INPUT_BUCKET="lab05-emr-input-${ACCOUNT_ID}"

# Dataset: texto de prueba
cat > /tmp/input_text.txt << 'EOF'
amazon web services cloud computing infrastructure platform
elastic compute cloud ec2 s3 simple storage service
apache spark distributed computing data processing framework
amazon emr elastic mapreduce hadoop spark hive presto
data lake s3 glue catalog athena redshift analytics
kinesis data streams firehose analytics real time streaming
lambda serverless functions event driven architecture
container kubernetes eks docker fargate microservices
devops infrastructure as code terraform cloudformation
machine learning sagemaker model training inference deployment
amazon web services cloud computing elastic compute
apache spark data processing distributed cluster
emr hadoop spark hive data lake analytics
EOF

aws s3 cp /tmp/input_text.txt "s3://$INPUT_BUCKET/input/text.txt"

# Script Spark para word count
cat > /tmp/wordcount.py << 'EOF'
import sys
from pyspark.sql import SparkSession

def main():
    if len(sys.argv) != 3:
        print("Uso: wordcount.py <input_path> <output_path>")
        sys.exit(1)

    input_path  = sys.argv[1]
    output_path = sys.argv[2]

    spark = SparkSession.builder \
        .appName("WordCount") \
        .getOrCreate()

    # Leer texto
    lines = spark.sparkContext.textFile(input_path)

    # Word count
    counts = (
        lines
        .flatMap(lambda line: line.lower().split())
        .map(lambda word: (word, 1))
        .reduceByKey(lambda a, b: a + b)
        .sortBy(lambda x: x[1], ascending=False)
    )

    # Guardar como CSV
    counts \
        .map(lambda x: f"{x[0]},{x[1]}") \
        .saveAsTextFile(output_path)

    print(f"Word count completado. Palabras únicas: {counts.count()}")
    spark.stop()

if __name__ == "__main__":
    main()
EOF

aws s3 cp /tmp/wordcount.py "s3://$INPUT_BUCKET/scripts/wordcount.py"
echo "Dataset y script subidos."
```

---

## Paso 3: Crear rol IAM para EMR Serverless

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
INPUT_BUCKET="lab05-emr-input-${ACCOUNT_ID}"
OUTPUT_BUCKET="lab05-emr-output-${ACCOUNT_ID}"
LOGS_BUCKET="lab05-emr-logs-${ACCOUNT_ID}"

cat > /tmp/emr-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "emr-serverless.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lab05-emr-serverless-role \
  --assume-role-policy-document file:///tmp/emr-trust.json

cat > /tmp/emr-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$INPUT_BUCKET",
        "arn:aws:s3:::$INPUT_BUCKET/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$OUTPUT_BUCKET",
        "arn:aws:s3:::$OUTPUT_BUCKET/*",
        "arn:aws:s3:::$LOGS_BUCKET",
        "arn:aws:s3:::$LOGS_BUCKET/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:$REGION:${ACCOUNT_ID}:log-group:/aws/emr-serverless/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name lab05-emr-serverless-role \
  --policy-name lab05-emr-policy \
  --policy-document file:///tmp/emr-policy.json

ROLE_ARN=$(aws iam get-role \
  --role-name lab05-emr-serverless-role \
  --query 'Role.Arn' --output text)

echo "Role ARN: $ROLE_ARN"
sleep 10
```

---

## Paso 4: Crear aplicación EMR Serverless

```bash
REGION="eu-west-1"

APP_ID=$(aws emr-serverless create-application \
  --name lab05-spark-app \
  --release-label emr-7.1.0 \
  --type SPARK \
  --region "$REGION" \
  --query 'applicationId' \
  --output text)

echo "Application ID: $APP_ID"
echo "Esperando estado CREATED..."

while true; do
  STATE=$(aws emr-serverless get-application \
    --application-id "$APP_ID" \
    --region "$REGION" \
    --query 'application.state' \
    --output text)
  echo "  Estado: $STATE"
  [[ "$STATE" == "CREATED" || "$STATE" == "STARTED" ]] && break
  sleep 5
done

echo "Aplicación lista: $APP_ID"
```

> **EMR Serverless vs EMR Cluster:** No hay instancias EC2 creadas aquí. AWS reserva capacidad cuando llega el job y la libera al terminar. Pagas solo durante la ejecución del job.

---

## Paso 5: Enviar el job Spark

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

ROLE_ARN=$(aws iam get-role \
  --role-name lab05-emr-serverless-role \
  --query 'Role.Arn' --output text)

JOB_RUN_ID=$(aws emr-serverless start-job-run \
  --application-id "$APP_ID" \
  --execution-role-arn "$ROLE_ARN" \
  --name "wordcount-job" \
  --job-driver "{
    \"sparkSubmit\": {
      \"entryPoint\": \"s3://$INPUT_BUCKET/scripts/wordcount.py\",
      \"entryPointArguments\": [
        \"s3://$INPUT_BUCKET/input/\",
        \"s3://$OUTPUT_BUCKET/wordcount-output/\"
      ],
      \"sparkSubmitParameters\": \"--conf spark.executor.cores=2 --conf spark.executor.memory=4g --conf spark.driver.cores=1 --conf spark.driver.memory=2g\"
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
echo "Siguiendo estado..."

while true; do
  STATE=$(aws emr-serverless get-job-run \
    --application-id "$APP_ID" \
    --job-run-id "$JOB_RUN_ID" \
    --region "$REGION" \
    --query 'jobRun.state' \
    --output text)
  echo "$(date -u +%H:%M:%S) Estado: $STATE"
  [[ "$STATE" == "SUCCESS" || "$STATE" == "FAILED" || "$STATE" == "CANCELLED" ]] && break
  sleep 15
done

echo ""
if [[ "$STATE" == "SUCCESS" ]]; then
  echo "Job completado con éxito."
else
  echo "Job terminó con estado: $STATE"
  aws emr-serverless get-job-run \
    --application-id "$APP_ID" \
    --job-run-id "$JOB_RUN_ID" \
    --region "$REGION" \
    --query 'jobRun.stateDetails'
fi
```

---

## Paso 6: Verificar output en S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OUTPUT_BUCKET="lab05-emr-output-${ACCOUNT_ID}"

echo "=== Archivos de output ==="
aws s3 ls "s3://$OUTPUT_BUCKET/wordcount-output/" --recursive

echo ""
echo "=== Top 20 palabras más frecuentes ==="
# Descargar y mostrar resultados
aws s3 cp "s3://$OUTPUT_BUCKET/wordcount-output/" /tmp/wc-output/ \
  --recursive --exclude "_SUCCESS" 2>/dev/null

if ls /tmp/wc-output/part-* 2>/dev/null; then
  cat /tmp/wc-output/part-* | sort -t',' -k2 -rn | head -20 \
    | awk -F',' '{printf "  %-20s %s\n", $1, $2}'
fi
```

---

## Paso 7: Explorar logs en CloudWatch y S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
LOGS_BUCKET="lab05-emr-logs-${ACCOUNT_ID}"

APP_ID=$(aws emr-serverless list-applications \
  --region "$REGION" \
  --query 'applications[?name==`lab05-spark-app`].id' \
  --output text)

JOB_RUN_ID=$(aws emr-serverless list-job-runs \
  --application-id "$APP_ID" \
  --region "$REGION" \
  --query 'jobRuns[0].id' \
  --output text)

# Logs en S3 (driver stdout)
echo "=== Logs del driver en S3 ==="
aws s3 ls "s3://$LOGS_BUCKET/emr-logs/applications/$APP_ID/jobs/$JOB_RUN_ID/" --recursive | head -10

# Descargar stdout del driver
STDOUT_KEY=$(aws s3 ls \
  "s3://$LOGS_BUCKET/emr-logs/applications/$APP_ID/jobs/$JOB_RUN_ID/SPARK_DRIVER/stdout.gz" \
  2>/dev/null && echo "exists" || echo "")

if [[ -n "$STDOUT_KEY" ]]; then
  aws s3 cp \
    "s3://$LOGS_BUCKET/emr-logs/applications/$APP_ID/jobs/$JOB_RUN_ID/SPARK_DRIVER/stdout.gz" \
    /tmp/driver-stdout.gz 2>/dev/null
  zcat /tmp/driver-stdout.gz 2>/dev/null | tail -20
fi

# Métricas del job
echo ""
echo "=== Métricas del job ==="
aws emr-serverless get-job-run \
  --application-id "$APP_ID" \
  --job-run-id "$JOB_RUN_ID" \
  --region "$REGION" \
  --query 'jobRun.{State:state,Duration:totalExecutionDurationSeconds,vCPUHour:billedResourceUtilization.vCPUHour,memoryGBHour:billedResourceUtilization.memoryGBHour}'
```

---

## Validación

```bash
./validate.sh
```

---

## ⚠️ Cleanup inmediato

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

APP_ID=$(aws emr-serverless list-applications \
  --region "$REGION" \
  --query 'applications[?name==`lab05-spark-app`].id' \
  --output text)

# Parar la aplicación (libera capacidad pre-inicializada si existe)
aws emr-serverless stop-application \
  --application-id "$APP_ID" \
  --region "$REGION" 2>/dev/null || true

sleep 30

# Eliminar aplicación
aws emr-serverless delete-application \
  --application-id "$APP_ID" \
  --region "$REGION" 2>/dev/null && echo "Aplicación EMR eliminada" || true

# S3 (ver cleanup.md para eliminar todos)
for BUCKET in \
  "lab05-emr-input-${ACCOUNT_ID}" \
  "lab05-emr-output-${ACCOUNT_ID}" \
  "lab05-emr-logs-${ACCOUNT_ID}"; do
  aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
  aws s3 rb "s3://$BUCKET" 2>/dev/null && echo "Bucket eliminado: $BUCKET" || true
done

echo "✓ Recursos del lab eliminados"
```

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| EMR Serverless sin cluster EC2 | Paso 4: `create-application` — no hay instancias creadas |
| Job Spark con `entryPoint` en S3 | Paso 5: `sparkSubmit.entryPoint` |
| Parámetros Spark: executor cores/memory | Paso 5: `--conf spark.executor.cores=2` |
| Output a S3 (no HDFS) | Paso 6: `saveAsTextFile("s3://...")` |
| Logs del driver en S3 + CloudWatch | Paso 7: `monitoringConfiguration` |
| Coste por vCPU-hora del job | Paso 7: `billedResourceUtilization` |
