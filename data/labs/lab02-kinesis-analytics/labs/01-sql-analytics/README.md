# Lab 01 — KDA SQL Analytics: agregaciones en tiempo real

> **Duración estimada:** 30 minutos | **Coste estimado:** ~$0.22 (2 KPU × $0.11/h)

---

## Objetivo

Crear una aplicación KDA con SQL que calcule el promedio de temperatura por sensor en ventanas de 1 minuto. Source: KDS con datos de sensores simulados. Sink: Firehose → S3.

---

## Prerequisitos

```bash
aws sts get-caller-identity
aws --version   # AWS CLI v2
jq --version
```

---

## Paso 1: Crear los recursos de soporte (KDS + S3 + Firehose)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab02-kda-analytics-${ACCOUNT_ID}"

# KDS source
aws kinesis create-stream \
  --stream-name lab02-sensor-data \
  --shard-count 2 \
  --region "$REGION"

aws kinesis wait stream-exists \
  --stream-name lab02-sensor-data \
  --region "$REGION"

# S3 bucket destino
aws s3 mb "s3://$BUCKET" --region "$REGION"
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

echo "KDS y S3 listos."
```

---

## Paso 2: Crear rol IAM para KDA

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

cat > /tmp/kda-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "kinesisanalytics.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lab02-kda-role \
  --assume-role-policy-document file:///tmp/kda-trust.json

KDS_ARN=$(aws kinesis describe-stream-summary \
  --stream-name lab02-sensor-data \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.StreamARN' \
  --output text)

BUCKET="lab02-kda-analytics-${ACCOUNT_ID}"

cat > /tmp/kda-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kinesis:GetRecords",
        "kinesis:GetShardIterator",
        "kinesis:DescribeStream",
        "kinesis:ListShards"
      ],
      "Resource": "$KDS_ARN"
    },
    {
      "Effect": "Allow",
      "Action": [
        "firehose:PutRecord",
        "firehose:PutRecordBatch",
        "firehose:DescribeDeliveryStream"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$BUCKET",
        "arn:aws:s3:::$BUCKET/*"
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
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name lab02-kda-role \
  --policy-name lab02-kda-policy \
  --policy-document file:///tmp/kda-policy.json

ROLE_ARN=$(aws iam get-role --role-name lab02-kda-role --query 'Role.Arn' --output text)
echo "Role ARN: $ROLE_ARN"
sleep 10
```

---

## Paso 3: Crear aplicación KDA con SQL

La aplicación KDA SQL define un **input stream** (mapeado desde KDS), queries SQL sobre él, y un **output stream** (hacia Firehose o KDS).

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
KDS_ARN=$(aws kinesis describe-stream-summary \
  --stream-name lab02-sensor-data \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.StreamARN' \
  --output text)
ROLE_ARN=$(aws iam get-role --role-name lab02-kda-role --query 'Role.Arn' --output text)
BUCKET="lab02-kda-analytics-${ACCOUNT_ID}"

# El SQL que calcula promedio de temperatura por sensor en ventana de 1 minuto
SQL_CODE='
CREATE OR REPLACE STREAM "DESTINATION_SQL_STREAM" (
    sensor_id VARCHAR(32),
    avg_temp  DOUBLE,
    min_temp  DOUBLE,
    max_temp  DOUBLE,
    record_count BIGINT,
    window_end TIMESTAMP
);

CREATE OR REPLACE PUMP "STREAM_PUMP" AS INSERT INTO "DESTINATION_SQL_STREAM"
SELECT STREAM
    sensor_id,
    AVG(temperature)   AS avg_temp,
    MIN(temperature)   AS min_temp,
    MAX(temperature)   AS max_temp,
    COUNT(*)           AS record_count,
    STEP("SOURCE_SQL_STREAM_001".ROWTIME BY INTERVAL '"'"'1'"'"' MINUTE) AS window_end
FROM "SOURCE_SQL_STREAM_001"
GROUP BY
    sensor_id,
    STEP("SOURCE_SQL_STREAM_001".ROWTIME BY INTERVAL '"'"'1'"'"' MINUTE);
'

aws kinesisanalytics create-application \
  --application-name lab02-sensor-analytics \
  --inputs "[{
    \"NamePrefix\": \"SOURCE_SQL_STREAM\",
    \"KinesisStreamsInput\": {
      \"ResourceARN\": \"$KDS_ARN\",
      \"RoleARN\": \"$ROLE_ARN\"
    },
    \"InputSchema\": {
      \"RecordFormat\": {
        \"RecordFormatType\": \"JSON\",
        \"MappingParameters\": {
          \"JSONMappingParameters\": {
            \"RecordRowPath\": \"\$\"
          }
        }
      },
      \"RecordColumns\": [
        {\"Name\": \"sensor_id\", \"SqlType\": \"VARCHAR(32)\", \"Mapping\": \"\$.sensor_id\"},
        {\"Name\": \"temperature\", \"SqlType\": \"DOUBLE\", \"Mapping\": \"\$.temperature\"},
        {\"Name\": \"ts\", \"SqlType\": \"VARCHAR(32)\", \"Mapping\": \"\$.ts\"}
      ]
    }
  }]" \
  --application-code "$SQL_CODE" \
  --region "$REGION"

echo "Aplicación KDA creada."
```

---

## Paso 4: Añadir output hacia S3 directo (simplificado)

Para el lab, usamos S3 output via referencia a Firehose. KDA SQL soporta output hacia KDS, Firehose, o Lambda.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab02-kda-analytics-${ACCOUNT_ID}"
ROLE_ARN=$(aws iam get-role --role-name lab02-kda-role --query 'Role.Arn' --output text)

# Crear Firehose que recibe el output de KDA y lo escribe en S3
cat > /tmp/firehose-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "firehose.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lab02-firehose-role \
  --assume-role-policy-document file:///tmp/firehose-trust.json

aws iam attach-role-policy \
  --role-name lab02-firehose-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

FIREHOSE_ROLE=$(aws iam get-role --role-name lab02-firehose-role --query 'Role.Arn' --output text)
sleep 10

aws firehose create-delivery-stream \
  --delivery-stream-name lab02-kda-output \
  --delivery-stream-type DirectPut \
  --s3-destination-configuration "{
    \"RoleARN\": \"$FIREHOSE_ROLE\",
    \"BucketARN\": \"arn:aws:s3:::$BUCKET\",
    \"Prefix\": \"aggregations/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/\",
    \"BufferingHints\": {\"SizeInMBs\": 1, \"IntervalInSeconds\": 60},
    \"CompressionFormat\": \"GZIP\"
  }" \
  --region "$REGION"

FIREHOSE_ARN="arn:aws:firehose:$REGION:${ACCOUNT_ID}:deliverystream/lab02-kda-output"

# Obtener el input ID de la aplicación para el output
INPUT_ID=$(aws kinesisanalytics describe-application \
  --application-name lab02-sensor-analytics \
  --region "$REGION" \
  --query 'ApplicationDetail.InputDescriptions[0].InputId' \
  --output text)

CURRENT_VERSION=$(aws kinesisanalytics describe-application \
  --application-name lab02-sensor-analytics \
  --region "$REGION" \
  --query 'ApplicationDetail.ApplicationVersionId' \
  --output text)

aws kinesisanalytics add-application-output \
  --application-name lab02-sensor-analytics \
  --current-application-version-id "$CURRENT_VERSION" \
  --output "{
    \"Name\": \"DESTINATION_SQL_STREAM\",
    \"KinesisFirehoseOutput\": {
      \"ResourceARN\": \"$FIREHOSE_ARN\",
      \"RoleARN\": \"$ROLE_ARN\"
    },
    \"DestinationSchema\": {
      \"RecordFormatType\": \"JSON\"
    }
  }" \
  --region "$REGION"

echo "Output hacia Firehose → S3 configurado."
```

---

## Paso 5: Iniciar la aplicación y enviar datos

```bash
REGION="eu-west-1"

# Iniciar la aplicación
aws kinesisanalytics start-application \
  --application-name lab02-sensor-analytics \
  --input-configurations "[{
    \"Id\": \"1.1\",
    \"InputStartingPositionConfiguration\": {
      \"InputStartingPosition\": \"NOW\"
    }
  }]" \
  --region "$REGION"

echo "Esperando que la aplicación arranque (30-60 segundos)..."
sleep 60

# Verificar estado
aws kinesisanalytics describe-application \
  --application-name lab02-sensor-analytics \
  --region "$REGION" \
  --query 'ApplicationDetail.ApplicationStatus'

# Enviar datos de sensores simulados (durante 2 minutos para ver al menos 2 ventanas)
echo "Enviando datos de sensores durante 2 minutos..."
for round in $(seq 1 24); do
  for sensor in sensor-A sensor-B sensor-C; do
    BASE_TEMP=$(case $sensor in sensor-A) echo 22;; sensor-B) echo 35;; sensor-C) echo 18;; esac)
    VARIATION=$(( (RANDOM % 40) - 20 ))
    TEMP=$(echo "scale=1; $BASE_TEMP + $VARIATION / 10" | bc)
    aws kinesis put-record \
      --stream-name lab02-sensor-data \
      --partition-key "$sensor" \
      --data "$(echo -n "{\"sensor_id\":\"$sensor\",\"temperature\":$TEMP,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | base64)" \
      --region "$REGION" > /dev/null
  done
  echo "Ronda $round/24 enviada ($(date -u +%H:%M:%S))"
  sleep 5
done

echo "Esperando que KDA procese y Firehose vacíe el buffer (90 segundos)..."
sleep 90

# Verificar resultados en S3
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab02-kda-analytics-${ACCOUNT_ID}"
aws s3 ls "s3://$BUCKET/aggregations/" --recursive
```

---

## Paso 6: Leer y verificar las agregaciones

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab02-kda-analytics-${ACCOUNT_ID}"

# Descargar y leer el último archivo
KEY=$(aws s3 ls "s3://$BUCKET/aggregations/" --recursive | sort | tail -1 | awk '{print $4}')
aws s3 cp "s3://$BUCKET/$KEY" /tmp/kda-output.gz
echo "=== Agregaciones por sensor (promedio de temperatura por minuto) ==="
zcat /tmp/kda-output.gz | jq '{sensor: .sensor_id, avg: .avg_temp, min: .min_temp, max: .max_temp, count: .record_count}'
```

Deberías ver una fila por sensor por ventana de 1 minuto, con `avg_temp`, `min_temp`, `max_temp`, y `record_count`.

---

## Validación

```bash
./validate.sh
```

---

## Limpieza

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Parar y eliminar aplicación KDA
aws kinesisanalytics stop-application \
  --application-name lab02-sensor-analytics \
  --region "$REGION" 2>/dev/null || true
sleep 30

aws kinesisanalytics delete-application \
  --application-name lab02-sensor-analytics \
  --create-timestamp "$(aws kinesisanalytics describe-application \
    --application-name lab02-sensor-analytics \
    --region "$REGION" \
    --query 'ApplicationDetail.CreateTimestamp' \
    --output text 2>/dev/null)" \
  --region "$REGION" 2>/dev/null || true

# Firehose, KDS, S3, IAM
aws firehose delete-delivery-stream --delivery-stream-name lab02-kda-output --region "$REGION" 2>/dev/null || true
aws kinesis delete-stream --stream-name lab02-sensor-data --region "$REGION" 2>/dev/null || true
aws s3 rm "s3://lab02-kda-analytics-${ACCOUNT_ID}" --recursive 2>/dev/null || true
aws s3 rb "s3://lab02-kda-analytics-${ACCOUNT_ID}" 2>/dev/null || true
aws iam delete-role-policy --role-name lab02-kda-role --policy-name lab02-kda-policy 2>/dev/null || true
aws iam delete-role --role-name lab02-kda-role 2>/dev/null || true
aws iam detach-role-policy --role-name lab02-firehose-role --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true
aws iam delete-role --role-name lab02-firehose-role 2>/dev/null || true
```

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| Tumbling window de 1 minuto | SQL: `STEP(ROWTIME BY INTERVAL '1' MINUTE)` |
| Aggregación por grupo | `GROUP BY sensor_id, STEP(...)` |
| Input schema desde KDS | Paso 3: `RecordColumns` mapeadas desde JSON |
| Output hacia Firehose | Paso 4: `KinesisFirehoseOutput` |
| Datos de múltiples sensores | Paso 5: sensor-A (22°C), sensor-B (35°C), sensor-C (18°C) |
