# Lab 02 — Pipeline de logs: CloudWatch → Firehose → OpenSearch

> **Duración estimada:** 25 minutos | **Coste estimado:** ~$0.10 adicional al Lab 01
> ⚠️ **Prerequisito:** Dominio lab07-opensearch del Lab 01 activo

---

## Objetivo

Construir el pipeline estándar de log analytics en AWS: una Lambda genera logs → CloudWatch Logs → Subscription Filter → Firehose → OpenSearch. Crear un dashboard operacional en OpenSearch Dashboards con errores/hora, latencia promedio y top endpoints.

---

## Arquitectura

```
Lambda Function
  └──► CloudWatch Log Group
              │
              └──► Subscription Filter
                          │
                          ▼
                  Kinesis Firehose
                  (buffer 60s/1MB)
                          │
                          ▼
                  OpenSearch Index
                  "lambda-logs-*"
                          │
                          ▼
               OpenSearch Dashboards
               (dashboard operacional)
```

---

## Paso 1: Crear Lambda que genera logs estructurados

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

cat > /tmp/log_generator.py << 'EOF'
import json
import logging
import random
import time
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ENDPOINTS = ["/api/products", "/api/orders", "/api/users", "/api/payment", "/api/search"]
SERVICES  = ["product-service", "order-service", "user-service", "payment-service"]
ERRORS    = [
    "Database connection timeout",
    "Cache miss: key not found",
    "External API unavailable",
    "Validation failed: invalid payload",
    "Rate limit exceeded",
]

def handler(event, context):
    """Genera logs de aplicación simulados en formato JSON estructurado."""
    num_logs = event.get("num_logs", 20)

    for _ in range(num_logs):
        endpoint = random.choice(ENDPOINTS)
        service  = random.choice(SERVICES)
        duration = random.randint(10, 5000)
        is_error = random.random() < 0.2  # 20% error rate

        if is_error:
            status_code = random.choice([400, 401, 429, 500, 502, 503])
            level       = "ERROR"
            message     = random.choice(ERRORS)
        else:
            status_code = 200
            level       = "INFO" if duration < 1000 else "WARN"
            message     = f"Request processed successfully"

        log_entry = {
            "timestamp":   datetime.utcnow().isoformat() + "Z",
            "level":       level,
            "service":     service,
            "endpoint":    endpoint,
            "duration_ms": duration,
            "status_code": status_code,
            "message":     message,
            "request_id":  context.aws_request_id,
        }
        logger.info(json.dumps(log_entry))

    return {"statusCode": 200, "logs_generated": num_logs}
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
  --role-name lab07-lambda-role \
  --assume-role-policy-document file:///tmp/lambda-trust.json 2>/dev/null || true

aws iam attach-role-policy \
  --role-name lab07-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

LAMBDA_ROLE=$(aws iam get-role --role-name lab07-lambda-role --query 'Role.Arn' --output text)
sleep 10

cd /tmp && zip log_generator.zip log_generator.py

LAMBDA_ARN=$(aws lambda create-function \
  --function-name lab07-log-generator \
  --runtime python3.12 \
  --role "$LAMBDA_ROLE" \
  --handler log_generator.handler \
  --zip-file fileb:///tmp/log_generator.zip \
  --timeout 30 \
  --region "$REGION" \
  --query 'FunctionArn' \
  --output text)

echo "Lambda creada: $LAMBDA_ARN"
```

---

## Paso 2: Invocar Lambda para generar logs

```bash
REGION="eu-west-1"

# Invocar varias veces para generar suficientes logs
for i in $(seq 1 5); do
  aws lambda invoke \
    --function-name lab07-log-generator \
    --payload '{"num_logs": 20}' \
    --region "$REGION" \
    /tmp/lambda-response.json > /dev/null
  echo "Invocación $i/5 — 20 logs generados"
  sleep 2
done

echo ""
echo "100 logs generados en CloudWatch."
echo "Verificando en CloudWatch Logs..."

sleep 5
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/lab07-log-generator" \
  --region "$REGION" \
  --query 'logGroups[].{Group:logGroupName,Bytes:storedBytes}'
```

---

## Paso 3: Crear rol IAM para Firehose → OpenSearch

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

DOMAIN_ARN=$(aws opensearch describe-domain \
  --domain-name lab07-opensearch --region "$REGION" \
  --query 'DomainStatus.ARN' --output text)

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
  --role-name lab07-firehose-role \
  --assume-role-policy-document file:///tmp/firehose-trust.json 2>/dev/null || true

# S3 bucket para errores de Firehose (backup de registros que fallaron al indexar)
BUCKET="lab07-firehose-backup-${ACCOUNT_ID}"
aws s3 mb "s3://$BUCKET" --region "$REGION" 2>/dev/null || true

cat > /tmp/firehose-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "es:DescribeElasticsearchDomain",
        "es:DescribeElasticsearchDomains",
        "es:DescribeElasticsearchDomainConfig",
        "es:ESHttpPost",
        "es:ESHttpPut"
      ],
      "Resource": [
        "$DOMAIN_ARN",
        "$DOMAIN_ARN/*"
      ]
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
        "logs:PutLogEvents",
        "logs:CreateLogGroup",
        "logs:CreateLogStream"
      ],
      "Resource": "arn:aws:logs:$REGION:${ACCOUNT_ID}:log-group:/aws/kinesisfirehose/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name lab07-firehose-role \
  --policy-name lab07-firehose-policy \
  --policy-document file:///tmp/firehose-policy.json

FIREHOSE_ROLE=$(aws iam get-role --role-name lab07-firehose-role --query 'Role.Arn' --output text)
echo "Rol Firehose: $FIREHOSE_ROLE"
sleep 10
```

---

## Paso 4: Crear Firehose → OpenSearch

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab07-firehose-backup-${ACCOUNT_ID}"
FIREHOSE_ROLE=$(aws iam get-role --role-name lab07-firehose-role --query 'Role.Arn' --output text)

DOMAIN_ENDPOINT=$(aws opensearch describe-domain \
  --domain-name lab07-opensearch --region "$REGION" \
  --query 'DomainStatus.Endpoint' --output text)

DOMAIN_ARN=$(aws opensearch describe-domain \
  --domain-name lab07-opensearch --region "$REGION" \
  --query 'DomainStatus.ARN' --output text)

aws firehose create-delivery-stream \
  --delivery-stream-name lab07-logs-to-opensearch \
  --delivery-stream-type DirectPut \
  --amazon-open-search-service-destination-configuration "{
    \"RoleARN\": \"$FIREHOSE_ROLE\",
    \"DomainARN\": \"$DOMAIN_ARN\",
    \"IndexName\": \"lambda-logs\",
    \"IndexRotationPeriod\": \"OneDay\",
    \"TypeName\": \"\",
    \"BufferingHints\": {
      \"IntervalInSeconds\": 60,
      \"SizeInMBs\": 1
    },
    \"RetryOptions\": {\"DurationInSeconds\": 300},
    \"S3BackupMode\": \"FailedDocumentsOnly\",
    \"S3Configuration\": {
      \"RoleARN\": \"$FIREHOSE_ROLE\",
      \"BucketARN\": \"arn:aws:s3:::$BUCKET\",
      \"Prefix\": \"failed-docs/\",
      \"BufferingHints\": {\"IntervalInSeconds\": 300, \"SizeInMBs\": 5},
      \"CompressionFormat\": \"GZIP\"
    }
  }" \
  --region "$REGION"

echo "Firehose creado."

# Esperar a ACTIVE
while true; do
  STATE=$(aws firehose describe-delivery-stream \
    --delivery-stream-name lab07-logs-to-opensearch --region "$REGION" \
    --query 'DeliveryStreamDescription.DeliveryStreamStatus' --output text)
  echo "  Firehose: $STATE"
  [[ "$STATE" == "ACTIVE" ]] && break
  sleep 10
done
```

---

## Paso 5: Crear Subscription Filter en CloudWatch Logs

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

FIREHOSE_ARN="arn:aws:firehose:$REGION:${ACCOUNT_ID}:deliverystream/lab07-logs-to-opensearch"

# Rol para que CloudWatch Logs pueda escribir en Firehose
cat > /tmp/cwlogs-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "logs.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lab07-cwlogs-role \
  --assume-role-policy-document file:///tmp/cwlogs-trust.json 2>/dev/null || true

aws iam put-role-policy \
  --role-name lab07-cwlogs-role \
  --policy-name lab07-cwlogs-firehose \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"firehose:PutRecord\", \"firehose:PutRecordBatch\"],
      \"Resource\": \"$FIREHOSE_ARN\"
    }]
  }" 2>/dev/null || true

CWLOGS_ROLE=$(aws iam get-role --role-name lab07-cwlogs-role --query 'Role.Arn' --output text)
sleep 10

# Crear subscription filter en el log group de la Lambda
aws logs put-subscription-filter \
  --log-group-name "/aws/lambda/lab07-log-generator" \
  --filter-name "lab07-to-firehose" \
  --filter-pattern "" \
  --destination-arn "$FIREHOSE_ARN" \
  --distribution "Random" \
  --region "$REGION"

echo "Subscription Filter creado."
echo ""
echo "Pipeline activo: Lambda → CloudWatch → Firehose → OpenSearch"
```

---

## Paso 6: Generar más logs y verificar en OpenSearch

```bash
REGION="eu-west-1"

# Generar logs adicionales para que lleguen a OpenSearch
echo "Generando logs durante 2 minutos..."
for i in $(seq 1 6); do
  aws lambda invoke \
    --function-name lab07-log-generator \
    --payload '{"num_logs": 30}' \
    --region "$REGION" \
    /tmp/lambda-response.json > /dev/null
  echo "  Batch $i/6 enviado"
  sleep 20
done

echo ""
echo "Esperando que Firehose vacíe el buffer (60 segundos)..."
sleep 70

# Verificar en OpenSearch
OS_ENDPOINT=$(aws opensearch describe-domain \
  --domain-name lab07-opensearch --region "$REGION" \
  --query 'DomainStatus.Endpoint' --output text)
AUTH="admin:Lab07Admin#2024"

echo "=== Índices en OpenSearch ==="
curl -s -u "$AUTH" "https://$OS_ENDPOINT/_cat/indices?v" | grep lambda-logs

echo ""
echo "=== Count de logs Lambda ==="
curl -s -u "$AUTH" "https://$OS_ENDPOINT/lambda-logs*/_count" | jq '{total: .count}'

echo ""
echo "=== Distribución por level ==="
curl -s -u "$AUTH" -X GET "https://$OS_ENDPOINT/lambda-logs*/_search" \
  -H "Content-Type: application/json" \
  -d '{"size":0,"aggs":{"by_level":{"terms":{"field":"level"}}}}' \
  | jq '[.aggregations.by_level.buckets[] | {level: .key, count: .doc_count}]'
```

---

## Paso 7: Crear dashboard en OpenSearch Dashboards

```bash
REGION="eu-west-1"
ENDPOINT=$(aws opensearch describe-domain \
  --domain-name lab07-opensearch --region "$REGION" \
  --query 'DomainStatus.Endpoint' --output text)
echo "Abre: https://$ENDPOINT/_dashboards"
```

**En OpenSearch Dashboards:**

1. **Index Pattern:** Management → Index Patterns → `lambda-logs*` → Time field: `timestamp`

2. **Visualización 1 — Errores por nivel:**
   - Visualize → Vertical Bar → `lambda-logs*`
   - Y-axis: Count | X-axis: Terms → field: `level`
   - Guarda: "Logs por nivel"

3. **Visualización 2 — Latencia promedio por servicio:**
   - Visualize → Horizontal Bar → `lambda-logs*`
   - Y-axis: Average → `duration_ms` | X-axis: Terms → `service`
   - Guarda: "Latencia por servicio"

4. **Visualización 3 — Top endpoints con errores:**
   - Visualize → Data Table → `lambda-logs*`
   - Add filter: `level: ERROR`
   - Split rows: Terms → `endpoint`
   - Guarda: "Endpoints con errores"

5. **Dashboard:**
   - Dashboard → New → Add las 3 visualizaciones
   - Guarda: "Operations Dashboard"

---

## CloudWatch Logs Insights vs OpenSearch — comparación directa

```bash
REGION="eu-west-1"

# La misma query en CloudWatch Logs Insights
LOG_GROUP="/aws/lambda/lab07-log-generator"

QUERY_ID=$(aws logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time "$(date -u -d '1 hour ago' +%s 2>/dev/null || date -u -v-1H +%s)" \
  --end-time "$(date -u +%s)" \
  --query-string '
    fields @timestamp, level, service, duration_ms
    | filter ispresent(level)
    | stats count(*) as total, avg(duration_ms) as avg_ms by level
    | sort total desc
  ' \
  --region "$REGION" \
  --query 'queryId' --output text)

sleep 5

aws logs get-query-results \
  --query-id "$QUERY_ID" \
  --region "$REGION" \
  --query 'results[]'
```

```
Comparación directa:

CloudWatch Logs Insights:
  ✓ Sin infraestructura extra — los logs ya están en CW
  ✓ Syntax simple: filter, stats, sort
  ✓ Sin coste fijo ($0.005/GB + $0.005/GB escaneado en query)
  ✗ Sin dashboards persistentes (solo widgets en CW Dashboard)
  ✗ Sin búsqueda full-text de alto rendimiento
  ✗ Solo logs en CloudWatch

OpenSearch:
  ✓ OpenSearch Dashboards rico (Kibana-like), dashboards persistentes
  ✓ Full-text search, fuzzy, agregaciones avanzadas
  ✓ Correlación multi-fuente (logs + métricas + trazas APM)
  ✗ Coste fijo ($0.036/hora para t3.small)
  ✗ Requiere pipeline (Firehose/Lambda) para ingerir datos

Cuándo usar cada uno:
  CW Logs Insights → análisis puntual de logs AWS nativos, sin infraestructura
  OpenSearch       → dashboards operacionales 24/7, aplicaciones con logs propios
```

---

## Cleanup (solo este lab, mantener el dominio para cleanup.md)

```bash
REGION="eu-west-1"

# Eliminar subscription filter
aws logs delete-subscription-filter \
  --log-group-name "/aws/lambda/lab07-log-generator" \
  --filter-name "lab07-to-firehose" \
  --region "$REGION" 2>/dev/null || true

# Eliminar Firehose
aws firehose delete-delivery-stream \
  --delivery-stream-name lab07-logs-to-opensearch \
  --region "$REGION" 2>/dev/null || true

# Eliminar Lambda
aws lambda delete-function --function-name lab07-log-generator --region "$REGION" 2>/dev/null || true

echo "Recursos del Lab 02 eliminados. Ver cleanup.md para eliminar el dominio OpenSearch."
```
