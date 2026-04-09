# Lab 02 — Kinesis Data Firehose: delivery managed hacia S3

> **Duración estimada:** 30 minutos | **Coste estimado:** < $0.10

---

## Objetivo

Crear un pipeline KDS → Firehose → S3, entender la diferencia con consumir KDS directamente, y experimentar con transformación Lambda inline.

---

## Prerequisitos

```bash
aws sts get-caller-identity
# El lab01 puede estar destruido — Firehose puede recibir datos directamente o desde KDS
```

---

## Paso 1: Crear bucket S3 destino

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab01-kinesis-firehose-${ACCOUNT_ID}"

aws s3 mb "s3://$BUCKET" --region eu-west-1

# Habilitar versionado (buena práctica para data lake)
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled \
  --region eu-west-1

echo "Bucket: $BUCKET"
```

---

## Paso 2: Crear rol IAM para Firehose

```bash
# Trust policy
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
  --role-name lab01-kinesis-firehose-role \
  --assume-role-policy-document file:///tmp/firehose-trust.json

# Permisos: S3 + CloudWatch Logs
aws iam attach-role-policy \
  --role-name lab01-kinesis-firehose-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-role-policy \
  --role-name lab01-kinesis-firehose-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

ROLE_ARN=$(aws iam get-role \
  --role-name lab01-kinesis-firehose-role \
  --query 'Role.Arn' \
  --output text)

echo "Role ARN: $ROLE_ARN"
sleep 10  # esperar propagación IAM
```

---

## Paso 3: Crear Delivery Stream (Direct PUT)

Firehose puede recibir datos directamente (Direct PUT) o desde KDS. Empezamos con Direct PUT para entender el delivery.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab01-kinesis-firehose-${ACCOUNT_ID}"
ROLE_ARN=$(aws iam get-role --role-name lab01-kinesis-firehose-role --query 'Role.Arn' --output text)

aws firehose create-delivery-stream \
  --delivery-stream-name lab01-firehose-direct \
  --delivery-stream-type DirectPut \
  --s3-destination-configuration "{
    \"RoleARN\": \"$ROLE_ARN\",
    \"BucketARN\": \"arn:aws:s3:::$BUCKET\",
    \"Prefix\": \"data/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/\",
    \"ErrorOutputPrefix\": \"errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/\",
    \"BufferingHints\": {
      \"SizeInMBs\": 1,
      \"IntervalInSeconds\": 60
    },
    \"CompressionFormat\": \"GZIP\"
  }" \
  --region eu-west-1

# Esperar a que esté ACTIVE
aws firehose describe-delivery-stream \
  --delivery-stream-name lab01-firehose-direct \
  --region eu-west-1 \
  --query 'DeliveryStreamDescription.DeliveryStreamStatus'
```

**Clave del buffer:** `60 segundos o 1 MB`, lo que ocurra primero. Firehose NO es tiempo real — espera hasta acumular suficientes datos. Mínimo buffer: 60 segundos.

El prefijo `!{timestamp:yyyy}` usa la fecha de ingesta de Firehose, no la del evento.

---

## Paso 4: Enviar datos y verificar en S3

```bash
# Enviar 10 records
for i in $(seq 1 10); do
  DATA=$(echo -n "{\"sensor\":\"s$i\",\"value\":$((RANDOM % 100)),\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | base64)
  aws firehose put-record \
    --delivery-stream-name lab01-firehose-direct \
    --record "Data=$DATA" \
    --region eu-west-1 > /dev/null
  echo "Record $i enviado"
done

echo "Esperando buffer (60-90 segundos)..."
sleep 90

# Verificar en S3
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab01-kinesis-firehose-${ACCOUNT_ID}"

aws s3 ls "s3://$BUCKET/data/" --recursive
```

Si no aparecen archivos, espera otros 30 segundos. El buffer se vacía cuando se cumple la condición de tamaño O tiempo.

```bash
# Leer el archivo (está comprimido con GZIP)
KEY=$(aws s3 ls "s3://$BUCKET/data/" --recursive | sort | tail -1 | awk '{print $4}')
aws s3 cp "s3://$BUCKET/$KEY" /tmp/firehose-output.gz
zcat /tmp/firehose-output.gz
```

---

## Paso 5: KDS → Firehose (stream como fuente)

```bash
# Crear KDS primero
aws kinesis create-stream \
  --stream-name lab01-kds-source \
  --shard-count 1 \
  --region eu-west-1

aws kinesis wait stream-exists \
  --stream-name lab01-kds-source \
  --region eu-west-1

KDS_ARN=$(aws kinesis describe-stream-summary \
  --stream-name lab01-kds-source \
  --region eu-west-1 \
  --query 'StreamDescriptionSummary.StreamARN' \
  --output text)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab01-kinesis-firehose-${ACCOUNT_ID}"
ROLE_ARN=$(aws iam get-role --role-name lab01-kinesis-firehose-role --query 'Role.Arn' --output text)

# Firehose que lee desde KDS
aws firehose create-delivery-stream \
  --delivery-stream-name lab01-firehose-from-kds \
  --delivery-stream-type KinesisStreamAsSource \
  --kinesis-stream-source-configuration "{
    \"KinesisStreamARN\": \"$KDS_ARN\",
    \"RoleARN\": \"$ROLE_ARN\"
  }" \
  --s3-destination-configuration "{
    \"RoleARN\": \"$ROLE_ARN\",
    \"BucketARN\": \"arn:aws:s3:::$BUCKET\",
    \"Prefix\": \"from-kds/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/\",
    \"BufferingHints\": {\"SizeInMBs\": 1, \"IntervalInSeconds\": 60},
    \"CompressionFormat\": \"GZIP\"
  }" \
  --region eu-west-1

# Enviar a KDS — Firehose lo consume automáticamente
for i in $(seq 1 5); do
  aws kinesis put-record \
    --stream-name lab01-kds-source \
    --partition-key "key-$i" \
    --data "$(echo -n "{\"from\":\"kds\",\"record\":$i}" | base64)" \
    --region eu-west-1 > /dev/null
done

echo "Records en KDS. Firehose los recoge en ~60 segundos."
sleep 90
aws s3 ls "s3://$BUCKET/from-kds/" --recursive
```

---

## Paso 6: Transformación Lambda inline

Con Firehose puedes transformar records antes de que lleguen a S3 usando una Lambda. Firehose envía batches a la Lambda, que devuelve los records transformados o dropeados.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Crear rol para la Lambda
cat > /tmp/lambda-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lab01-kinesis-lambda-role \
  --assume-role-policy-document file:///tmp/lambda-trust.json

aws iam attach-role-policy \
  --role-name lab01-kinesis-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

LAMBDA_ROLE=$(aws iam get-role --role-name lab01-kinesis-lambda-role --query 'Role.Arn' --output text)
sleep 10

# Lambda de transformación — añade campo procesado y filtra registros con value < 10
cat > /tmp/transform.py << 'EOF'
import json
import base64

def handler(event, context):
    output = []
    for record in event['records']:
        payload = json.loads(base64.b64decode(record['data']))

        # Filtrar registros con value < 10
        if payload.get('value', 100) < 10:
            output.append({
                'recordId': record['recordId'],
                'result': 'Dropped',
                'data': record['data']
            })
            continue

        # Transformar: añadir campo y newline (Firehose lo necesita)
        payload['processed'] = True
        payload['env'] = 'lab01'
        transformed = json.dumps(payload) + '\n'

        output.append({
            'recordId': record['recordId'],
            'result': 'Ok',
            'data': base64.b64encode(transformed.encode()).decode()
        })

    return {'records': output}
EOF

cd /tmp && zip transform.zip transform.py

aws lambda create-function \
  --function-name lab01-firehose-transform \
  --runtime python3.12 \
  --role "$LAMBDA_ROLE" \
  --handler transform.handler \
  --zip-file fileb:///tmp/transform.zip \
  --timeout 60 \
  --region eu-west-1

LAMBDA_ARN="arn:aws:lambda:eu-west-1:${ACCOUNT_ID}:function:lab01-firehose-transform"
echo "Lambda: $LAMBDA_ARN"
```

---

## Firehose vs KDS directo — cuándo cada uno

| Situación | Recomendación |
|---|---|
| Solo necesitas datos en S3/Redshift | **Firehose** — cero gestión de consumers |
| Múltiples sistemas procesan el mismo evento | **KDS directo** — cada consumer independiente |
| Near real-time es suficiente (>60 seg) | **Firehose** |
| Latencia milisegundos requerida | **KDS** con Lambda trigger |
| Transformación simple antes de S3 | **Firehose + Lambda** |
| Analytics complejos en tiempo real | **KDS → Kinesis Data Analytics** |
| Equipo sin experiencia en streaming | **Firehose** — curva de aprendizaje mínima |

**Regla:** Si el destino final es S3, Redshift u OpenSearch y near-real-time es suficiente → Firehose. Si necesitas múltiples consumers o latencia sub-segundo → KDS.

---

## Limpieza

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab01-kinesis-firehose-${ACCOUNT_ID}"

aws firehose delete-delivery-stream --delivery-stream-name lab01-firehose-direct --region eu-west-1
aws firehose delete-delivery-stream --delivery-stream-name lab01-firehose-from-kds --region eu-west-1
aws kinesis delete-stream --stream-name lab01-kds-source --region eu-west-1
aws lambda delete-function --function-name lab01-firehose-transform --region eu-west-1
aws s3 rm "s3://$BUCKET" --recursive
aws s3 rb "s3://$BUCKET"
aws iam detach-role-policy --role-name lab01-kinesis-firehose-role --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam detach-role-policy --role-name lab01-kinesis-firehose-role --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
aws iam delete-role --role-name lab01-kinesis-firehose-role
aws iam detach-role-policy --role-name lab01-kinesis-lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name lab01-kinesis-lambda-role
```
