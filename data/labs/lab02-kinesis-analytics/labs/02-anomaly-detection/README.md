# Lab 02 — KDA Anomaly Detection: RANDOM_CUT_FOREST

> **Duración estimada:** 30 minutos | **Coste estimado:** ~$0.22

---

## Objetivo

Usar la función `RANDOM_CUT_FOREST` de KDA para detectar anomalías en métricas de aplicación sin definir umbrales fijos. Output: KDS → Lambda → SNS alerta.

---

## Por qué RANDOM_CUT_FOREST en lugar de thresholds fijos

Con thresholds fijos (`IF latency > 500ms`), necesitas saber de antemano qué es "anómalo". Con **Random Cut Forest**, el algoritmo aprende el comportamiento normal del stream y asigna una **anomaly score** a cada record. Cuanto mayor la score, más anómalo.

```
Métrica normal:   [cpu=45, cpu=47, cpu=44, cpu=46] → scores bajas (~0.2)
Spike anómalo:    [cpu=45, cpu=47, cpu=98, cpu=44] → score alta (>3.0)

No necesitas decir ">80% es anómalo" — el algoritmo lo detecta solo.
```

**Cuándo usarlo:**
- Métricas con comportamiento variable (carga de trabajo no uniforme)
- No conoces los valores "normales" de antemano
- Quieres detectar patrones multivariados (combinación de CPU + latencia + errores)

---

## Prerequisitos

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

# Usar los recursos del lab anterior si existen, o crear nuevos
aws kinesis create-stream \
  --stream-name lab02-app-metrics \
  --shard-count 1 \
  --region "$REGION" 2>/dev/null || true

aws kinesis wait stream-exists \
  --stream-name lab02-app-metrics \
  --region "$REGION"

echo "Stream listo."
```

---

## Paso 1: Crear KDS output para alertas

El pipeline es: **KDS input → KDA (RANDOM_CUT_FOREST) → KDS output → Lambda → SNS**.

```bash
REGION="eu-west-1"

aws kinesis create-stream \
  --stream-name lab02-anomaly-alerts \
  --shard-count 1 \
  --region "$REGION"

aws kinesis wait stream-exists \
  --stream-name lab02-anomaly-alerts \
  --region "$REGION"

echo "Stream de alertas creado."
```

---

## Paso 2: Crear SNS topic y Lambda para alertas

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

# SNS topic
SNS_ARN=$(aws sns create-topic \
  --name lab02-anomaly-alerts \
  --region "$REGION" \
  --query 'TopicArn' \
  --output text)

echo "SNS topic: $SNS_ARN"

# Suscribir email (opcional — requiere confirmación)
# aws sns subscribe --topic-arn "$SNS_ARN" --protocol email --notification-endpoint "tu@email.com"

# Lambda que lee el KDS output y publica en SNS
cat > /tmp/alert.py << EOF
import json
import base64
import boto3
import os

sns = boto3.client('sns', region_name='eu-west-1')
SNS_TOPIC = os.environ.get('SNS_TOPIC_ARN', '')
ANOMALY_THRESHOLD = float(os.environ.get('ANOMALY_THRESHOLD', '2.0'))

def handler(event, context):
    alerts = []
    for record in event['Records']:
        payload = json.loads(base64.b64decode(record['kinesis']['data']))
        score = float(payload.get('anomaly_score', 0))

        if score > ANOMALY_THRESHOLD:
            message = (
                f"ANOMALIA DETECTADA\\n"
                f"Servicio: {payload.get('service', 'unknown')}\\n"
                f"Anomaly Score: {score:.2f}\\n"
                f"CPU: {payload.get('cpu_percent', '-')}%\\n"
                f"Latencia: {payload.get('latency_ms', '-')}ms\\n"
                f"Timestamp: {payload.get('ts', '-')}"
            )
            sns.publish(TopicArn=SNS_TOPIC, Message=message, Subject=f'Anomalia: {payload.get("service")}')
            alerts.append({'service': payload.get('service'), 'score': score})

    if alerts:
        print(f"Alertas enviadas: {alerts}")
    return {'alerts': len(alerts)}
EOF

# Rol para Lambda
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
  --role-name lab02-anomaly-lambda-role \
  --assume-role-policy-document file:///tmp/lambda-trust.json

aws iam attach-role-policy \
  --role-name lab02-anomaly-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaKinesisExecutionRole

aws iam attach-role-policy \
  --role-name lab02-anomaly-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess

LAMBDA_ROLE=$(aws iam get-role --role-name lab02-anomaly-lambda-role --query 'Role.Arn' --output text)
sleep 10

cd /tmp && zip alert.zip alert.py

LAMBDA_ARN=$(aws lambda create-function \
  --function-name lab02-anomaly-alert \
  --runtime python3.12 \
  --role "$LAMBDA_ROLE" \
  --handler alert.handler \
  --zip-file fileb:///tmp/alert.zip \
  --timeout 30 \
  --environment "Variables={SNS_TOPIC_ARN=$SNS_ARN,ANOMALY_THRESHOLD=2.0}" \
  --region "$REGION" \
  --query 'FunctionArn' \
  --output text)

# Trigger: Lambda lee del KDS de alertas
ALERTS_ARN=$(aws kinesis describe-stream-summary \
  --stream-name lab02-anomaly-alerts \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.StreamARN' \
  --output text)

aws lambda create-event-source-mapping \
  --function-name lab02-anomaly-alert \
  --event-source-arn "$ALERTS_ARN" \
  --starting-position LATEST \
  --batch-size 10 \
  --region "$REGION"

echo "Lambda: $LAMBDA_ARN"
echo "SNS: $SNS_ARN"
```

---

## Paso 3: Crear aplicación KDA con RANDOM_CUT_FOREST

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
METRICS_ARN=$(aws kinesis describe-stream-summary \
  --stream-name lab02-app-metrics \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.StreamARN' \
  --output text)
ALERTS_ARN=$(aws kinesis describe-stream-summary \
  --stream-name lab02-anomaly-alerts \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.StreamARN' \
  --output text)
ROLE_ARN=$(aws iam get-role --role-name lab02-kda-role --query 'Role.Arn' --output text 2>/dev/null || echo "")

# Si no existe el rol del lab anterior, crear uno nuevo
if [[ -z "$ROLE_ARN" ]]; then
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
  aws iam create-role --role-name lab02-kda-role --assume-role-policy-document file:///tmp/kda-trust.json
  aws iam attach-role-policy --role-name lab02-kda-role --policy-arn arn:aws:iam::aws:policy/AmazonKinesisFullAccess
  ROLE_ARN=$(aws iam get-role --role-name lab02-kda-role --query 'Role.Arn' --output text)
  sleep 10
fi

# SQL con RANDOM_CUT_FOREST
SQL_ANOMALY='
CREATE OR REPLACE STREAM "ANOMALY_SCORE_STREAM" (
    service         VARCHAR(64),
    cpu_percent     DOUBLE,
    latency_ms      DOUBLE,
    anomaly_score   DOUBLE,
    ts              VARCHAR(32)
);

CREATE OR REPLACE PUMP "ANOMALY_PUMP" AS INSERT INTO "ANOMALY_SCORE_STREAM"
SELECT STREAM
    service,
    cpu_percent,
    latency_ms,
    ANOMALY_SCORE(MDIFF(cpu_percent, latency_ms) OVER (PARTITION BY service ROWS 100 PRECEDING)) AS anomaly_score,
    ts
FROM "SOURCE_SQL_STREAM_001";
'

aws kinesisanalytics create-application \
  --application-name lab02-anomaly-detection \
  --inputs "[{
    \"NamePrefix\": \"SOURCE_SQL_STREAM\",
    \"KinesisStreamsInput\": {
      \"ResourceARN\": \"$METRICS_ARN\",
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
        {\"Name\": \"service\", \"SqlType\": \"VARCHAR(64)\", \"Mapping\": \"\$.service\"},
        {\"Name\": \"cpu_percent\", \"SqlType\": \"DOUBLE\", \"Mapping\": \"\$.cpu_percent\"},
        {\"Name\": \"latency_ms\", \"SqlType\": \"DOUBLE\", \"Mapping\": \"\$.latency_ms\"},
        {\"Name\": \"ts\", \"SqlType\": \"VARCHAR(32)\", \"Mapping\": \"\$.ts\"}
      ]
    }
  }]" \
  --application-code "$SQL_ANOMALY" \
  --region "$REGION"

# Añadir output hacia KDS de alertas
CURRENT_VERSION=$(aws kinesisanalytics describe-application \
  --application-name lab02-anomaly-detection \
  --region "$REGION" \
  --query 'ApplicationDetail.ApplicationVersionId' \
  --output text)

aws kinesisanalytics add-application-output \
  --application-name lab02-anomaly-detection \
  --current-application-version-id "$CURRENT_VERSION" \
  --output "{
    \"Name\": \"ANOMALY_SCORE_STREAM\",
    \"KinesisStreamsOutput\": {
      \"ResourceARN\": \"$ALERTS_ARN\",
      \"RoleARN\": \"$ROLE_ARN\"
    },
    \"DestinationSchema\": {\"RecordFormatType\": \"JSON\"}
  }" \
  --region "$REGION"

echo "Aplicación de detección de anomalías creada."
```

---

## Paso 4: Iniciar y enviar métricas normales + anomalías

```bash
REGION="eu-west-1"

# Iniciar aplicación
aws kinesisanalytics start-application \
  --application-name lab02-anomaly-detection \
  --input-configurations "[{
    \"Id\": \"1.1\",
    \"InputStartingPositionConfiguration\": {\"InputStartingPosition\": \"NOW\"}
  }]" \
  --region "$REGION"

sleep 60
echo "Aplicación iniciada."

# Enviar 20 métricas normales (el algoritmo aprende el baseline)
echo "Enviando métricas normales (baseline)..."
for i in $(seq 1 20); do
  CPU=$(( 40 + RANDOM % 20 ))
  LAT=$(( 100 + RANDOM % 50 ))
  aws kinesis put-record \
    --stream-name lab02-app-metrics \
    --partition-key "api-service" \
    --data "$(echo -n "{\"service\":\"api-service\",\"cpu_percent\":$CPU,\"latency_ms\":$LAT,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | base64)" \
    --region "$REGION" > /dev/null
done

echo "Esperando 30 segundos..."
sleep 30

# Inyectar anomalías (CPU spike + latencia alta)
echo "Inyectando anomalías..."
for i in $(seq 1 3); do
  aws kinesis put-record \
    --stream-name lab02-app-metrics \
    --partition-key "api-service" \
    --data "$(echo -n "{\"service\":\"api-service\",\"cpu_percent\":95,\"latency_ms\":2500,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | base64)" \
    --region "$REGION"
  echo "Anomalía $i inyectada: cpu=95%, latency=2500ms"
  sleep 2
done

echo "Monitorea CloudWatch Logs de la Lambda para ver las alertas SNS."
```

---

## KDA Anomaly Detection vs CloudWatch Anomaly Detection

| | KDA RANDOM_CUT_FOREST | CloudWatch Anomaly Detection |
|---|---|---|
| **Datos** | Streams (KDS/MSK) en tiempo real | Métricas CloudWatch |
| **Latencia detección** | Milisegundos | Minutos |
| **Variables** | Multivariado (CPU + latencia + errores juntos) | Una métrica a la vez |
| **Integración** | KDS, Lambda, Firehose | CloudWatch Alarms, SNS |
| **Configuración** | SQL + RANDOM_CUT_FOREST | Checkbox en CloudWatch |
| **Coste** | $0.11/KPU-hora (KDA) | Incluido en CloudWatch |

**Cuándo CloudWatch:** métricas estándar de AWS (CPU de EC2, requests de ALB), alertas simples, sin necesidad de stream processing.

**Cuándo KDA:** stream de eventos de aplicación, múltiples variables correlacionadas, latencia sub-segundo en la detección, datos que no pasan por CloudWatch.

---

## Limpieza

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws kinesisanalytics stop-application --application-name lab02-anomaly-detection --region "$REGION" 2>/dev/null || true
sleep 30

aws kinesisanalytics delete-application \
  --application-name lab02-anomaly-detection \
  --create-timestamp "$(aws kinesisanalytics describe-application \
    --application-name lab02-anomaly-detection --region "$REGION" \
    --query 'ApplicationDetail.CreateTimestamp' --output text 2>/dev/null)" \
  --region "$REGION" 2>/dev/null || true

# Eliminar event source mapping antes de la Lambda
MAPPING_UUID=$(aws lambda list-event-source-mappings \
  --function-name lab02-anomaly-alert \
  --region "$REGION" \
  --query 'EventSourceMappings[0].UUID' \
  --output text 2>/dev/null || echo "")
[[ -n "$MAPPING_UUID" && "$MAPPING_UUID" != "None" ]] && \
  aws lambda delete-event-source-mapping --uuid "$MAPPING_UUID" --region "$REGION" 2>/dev/null || true

aws lambda delete-function --function-name lab02-anomaly-alert --region "$REGION" 2>/dev/null || true
aws kinesis delete-stream --stream-name lab02-app-metrics --region "$REGION" 2>/dev/null || true
aws kinesis delete-stream --stream-name lab02-anomaly-alerts --region "$REGION" 2>/dev/null || true
aws sns delete-topic \
  --topic-arn "arn:aws:sns:$REGION:${ACCOUNT_ID}:lab02-anomaly-alerts" \
  --region "$REGION" 2>/dev/null || true
aws iam detach-role-policy --role-name lab02-anomaly-lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaKinesisExecutionRole 2>/dev/null || true
aws iam detach-role-policy --role-name lab02-anomaly-lambda-role --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess 2>/dev/null || true
aws iam delete-role --role-name lab02-anomaly-lambda-role 2>/dev/null || true
```
