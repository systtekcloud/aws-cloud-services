# Lab 02 — MSK Connect: S3 Sink Connector

> **Duración estimada:** 25 minutos | **Coste estimado:** ~$0.15 (MSK Connect MCU-hora)

---

## Objetivo

Configurar un S3 Sink Connector en MSK Connect que mueve mensajes del topic `lab03-events` a S3 automáticamente. Sin código consumer — MSK Connect gestiona los workers Kafka Connect.

---

## Prerequisitos

- Cluster MSK Serverless `lab03-msk-serverless` del Lab 01 en estado ACTIVE
- Topic `lab03-events` creado con mensajes
- `MSK_BOOTSTRAP` exportado

---

## Paso 1: Crear bucket S3 destino

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab03-msk-connect-${ACCOUNT_ID}"

aws s3 mb "s3://$BUCKET" --region "$REGION"
echo "Bucket: $BUCKET"
```

---

## Paso 2: Crear rol IAM para MSK Connect

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab03-msk-connect-${ACCOUNT_ID}"

cat > /tmp/msk-connect-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "kafkaconnect.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lab03-msk-connect-role \
  --assume-role-policy-document file:///tmp/msk-connect-trust.json

CLUSTER_ARN=$(aws kafka list-clusters-v2 \
  --region "$REGION" \
  --query 'ClusterInfoList[?ClusterName==`lab03-msk-serverless`].ClusterArn' \
  --output text)

cat > /tmp/msk-connect-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:AbortMultipartUpload",
        "s3:ListBucketMultipartUploads",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::$BUCKET",
        "arn:aws:s3:::$BUCKET/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "kafka-cluster:Connect",
        "kafka-cluster:DescribeCluster"
      ],
      "Resource": "$CLUSTER_ARN"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kafka-cluster:ReadData",
        "kafka-cluster:DescribeTopic"
      ],
      "Resource": "arn:aws:kafka:$REGION:${ACCOUNT_ID}:topic/lab03-msk-serverless/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kafka-cluster:AlterGroup",
        "kafka-cluster:DescribeGroup"
      ],
      "Resource": "arn:aws:kafka:$REGION:${ACCOUNT_ID}:group/lab03-msk-serverless/*"
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
  --role-name lab03-msk-connect-role \
  --policy-name lab03-msk-connect-policy \
  --policy-document file:///tmp/msk-connect-policy.json

ROLE_ARN=$(aws iam get-role \
  --role-name lab03-msk-connect-role \
  --query 'Role.Arn' --output text)

echo "Role ARN: $ROLE_ARN"
sleep 10
```

---

## Paso 3: Crear Custom Plugin (Confluent S3 Sink Connector)

MSK Connect necesita el JAR del conector subido a S3.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab03-msk-connect-${ACCOUNT_ID}"

# Descargar el Confluent S3 Sink Connector
curl -L \
  "https://d1i4a15mxbxib1.cloudfront.net/api/plugins/confluentinc/kafka-connect-s3/versions/10.5.7/confluentinc-kafka-connect-s3-10.5.7.zip" \
  -o /tmp/kafka-connect-s3.zip

# Subir a S3
aws s3 cp /tmp/kafka-connect-s3.zip "s3://$BUCKET/plugins/kafka-connect-s3.zip"

# Crear Custom Plugin en MSK Connect
PLUGIN_ARN=$(aws kafkaconnect create-custom-plugin \
  --name lab03-s3-sink-plugin \
  --content-type ZIP \
  --location "{
    \"s3Location\": {
      \"bucketArn\": \"arn:aws:s3:::$BUCKET\",
      \"fileKey\": \"plugins/kafka-connect-s3.zip\"
    }
  }" \
  --region "$REGION" \
  --query 'customPluginArn' \
  --output text)

echo "Plugin ARN: $PLUGIN_ARN"
echo "Esperando que el plugin esté ACTIVE..."

# Esperar al plugin
while true; do
  STATE=$(aws kafkaconnect describe-custom-plugin \
    --custom-plugin-arn "$PLUGIN_ARN" \
    --region "$REGION" \
    --query 'customPluginState' \
    --output text)
  echo "  Plugin state: $STATE"
  [[ "$STATE" == "ACTIVE" ]] && break
  sleep 15
done
```

---

## Paso 4: Crear el Connector

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab03-msk-connect-${ACCOUNT_ID}"

CLUSTER_ARN=$(aws kafka list-clusters-v2 \
  --region "$REGION" \
  --query 'ClusterInfoList[?ClusterName==`lab03-msk-serverless`].ClusterArn' \
  --output text)

PLUGIN_ARN=$(aws kafkaconnect list-custom-plugins \
  --region "$REGION" \
  --query 'customPlugins[?name==`lab03-s3-sink-plugin`].customPluginArn' \
  --output text)

ROLE_ARN=$(aws iam get-role \
  --role-name lab03-msk-connect-role \
  --query 'Role.Arn' --output text)

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --region "$REGION" \
  --query 'Vpcs[0].VpcId' --output text)

SUBNETS_ARRAY=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query 'Subnets[:2].SubnetId' \
  --output json)

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lab03-msk-sg" \
  --region "$REGION" \
  --query 'SecurityGroups[0].GroupId' --output text)

BOOTSTRAP=$(aws kafka get-bootstrap-brokers \
  --cluster-arn "$CLUSTER_ARN" \
  --region "$REGION" \
  --query 'BootstrapBrokerStringSaslIam' \
  --output text)

aws kafkaconnect create-connector \
  --connector-name lab03-s3-sink \
  --kafka-cluster "{
    \"apacheKafkaCluster\": {
      \"bootstrapServers\": \"$BOOTSTRAP\",
      \"vpc\": {
        \"subnets\": $SUBNETS_ARRAY,
        \"securityGroups\": [\"$SG_ID\"]
      }
    }
  }" \
  --kafka-cluster-client-authentication '{"authenticationType": "IAM"}' \
  --kafka-cluster-encryption-in-transit '{"encryptionType": "TLS"}' \
  --connector-configuration "{
    \"connector.class\": \"io.confluent.connect.s3.S3SinkConnector\",
    \"tasks.max\": \"2\",
    \"topics\": \"lab03-events\",
    \"s3.region\": \"$REGION\",
    \"s3.bucket.name\": \"$BUCKET\",
    \"s3.part.size\": \"5242880\",
    \"flush.size\": \"10\",
    \"storage.class\": \"io.confluent.connect.s3.storage.S3Storage\",
    \"format.class\": \"io.confluent.connect.s3.format.json.JsonFormat\",
    \"schema.compatibility\": \"NONE\",
    \"locale\": \"en_US\",
    \"timezone\": \"UTC\",
    \"timestamp.extractor\": \"Wallclock\",
    \"partitioner.class\": \"io.confluent.connect.storage.partitioner.TimeBasedPartitioner\",
    \"path.format\": \"'year'=YYYY/'month'=MM/'day'=dd/'hour'=HH\",
    \"partition.duration.ms\": \"3600000\",
    \"rotate.interval.ms\": \"60000\"
  }" \
  --plugins "[{
    \"customPlugin\": {
      \"customPluginArn\": \"$PLUGIN_ARN\",
      \"revision\": 1
    }
  }]" \
  --service-execution-role-arn "$ROLE_ARN" \
  --capacity "{
    \"provisionedCapacity\": {
      \"mcuCount\": 1,
      \"workerCount\": 1
    }
  }" \
  --region "$REGION"

echo "Connector creado. Esperando estado RUNNING (~3-5 minutos)..."
```

---

## Paso 5: Producir mensajes y verificar en S3

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab03-msk-connect-${ACCOUNT_ID}"

# Verificar estado del connector
aws kafkaconnect list-connectors \
  --region "$REGION" \
  --query 'connectors[?connectorName==`lab03-s3-sink`].{Name:connectorName,State:connectorState}'

# Producir más mensajes (el connector necesita al menos 10 para hacer flush)
export CLASSPATH="/tmp/aws-msk-iam-auth.jar:$CLASSPATH"
CLUSTER_ARN=$(aws kafka list-clusters-v2 \
  --region "$REGION" \
  --query 'ClusterInfoList[?ClusterName==`lab03-msk-serverless`].ClusterArn' \
  --output text)
export MSK_BOOTSTRAP=$(aws kafka get-bootstrap-brokers \
  --cluster-arn "$CLUSTER_ARN" --region "$REGION" \
  --query 'BootstrapBrokerStringSaslIam' --output text)

for i in $(seq 1 15); do
  echo "sensor-00${i}:{\"device\":\"sensor-00${i}\",\"temp\":$(( 20 + RANDOM % 15 )),\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
  | kafka-console-producer.sh \
    --bootstrap-server "$MSK_BOOTSTRAP" \
    --producer.config /tmp/kafka-iam.properties \
    --topic lab03-events \
    --property "parse.key=true" \
    --property "key.separator=:" 2>/dev/null
  sleep 1
done

echo "Esperando flush a S3 (rotate.interval.ms=60s)..."
sleep 90

# Verificar objetos en S3
echo "=== Objetos en S3 ==="
aws s3 ls "s3://$BUCKET/" --recursive | grep -v plugins

# Descargar y leer el último archivo
KEY=$(aws s3 ls "s3://$BUCKET/" --recursive | grep -v plugins | sort | tail -1 | awk '{print $4}')
if [[ -n "$KEY" ]]; then
  aws s3 cp "s3://$BUCKET/$KEY" /tmp/msk-connect-output.json
  echo "=== Muestra de mensajes en S3 ==="
  head -5 /tmp/msk-connect-output.json | jq '.' 2>/dev/null || head -5 /tmp/msk-connect-output.json
fi
```

---

## MSK Connect vs Lambda consumer — cuándo usar cada uno

| | MSK Connect | Lambda trigger MSK |
|---|---|---|
| **Objetivo** | Mover datos entre Kafka y otro sistema | Procesar mensajes con lógica de negocio |
| **Throughput** | Alto — workers dedicados, batch nativo | Limitado por concurrencia Lambda (1000/región por defecto) |
| **Configuración** | Declarativa — JSON de configuración | Código Python/Node/Java |
| **Latencia** | Segundos (buffer + flush) | Milisegundos |
| **Transformaciones** | SMT simples (rename, filter, cast) | Lógica arbitraria |
| **Destinos soportados** | S3, DynamoDB, OpenSearch, JDBC, Elasticsearch | Cualquier servicio AWS |
| **Cuándo usar** | Pipeline de datos: Kafka → S3/Redshift sin código | Alertas, enriquecimiento, routing condicional |

**Combinación habitual:**
```
MSK topic
  ├──► MSK Connect → S3 (archivado — sin código)
  └──► Lambda → SNS (alertas — lógica de negocio)
```

---

## Limpieza

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab03-msk-connect-${ACCOUNT_ID}"

# Eliminar connector
CONNECTOR_ARN=$(aws kafkaconnect list-connectors \
  --region "$REGION" \
  --query 'connectors[?connectorName==`lab03-s3-sink`].connectorArn' \
  --output text 2>/dev/null || echo "")
[[ -n "$CONNECTOR_ARN" ]] && \
  aws kafkaconnect delete-connector --connector-arn "$CONNECTOR_ARN" --region "$REGION" 2>/dev/null || true

# Eliminar plugin
PLUGIN_ARN=$(aws kafkaconnect list-custom-plugins \
  --region "$REGION" \
  --query 'customPlugins[?name==`lab03-s3-sink-plugin`].customPluginArn' \
  --output text 2>/dev/null || echo "")
[[ -n "$PLUGIN_ARN" ]] && \
  aws kafkaconnect delete-custom-plugin --custom-plugin-arn "$PLUGIN_ARN" --region "$REGION" 2>/dev/null || true

# S3
aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
aws s3 rb "s3://$BUCKET" 2>/dev/null || true

# IAM
aws iam delete-role-policy \
  --role-name lab03-msk-connect-role \
  --policy-name lab03-msk-connect-policy 2>/dev/null || true
aws iam delete-role --role-name lab03-msk-connect-role 2>/dev/null || true
```
