# Lab 01 — MSK Serverless: crear cluster, topic y producir/consumir mensajes

> **Duración estimada:** 35 minutos | **Coste estimado:** ~$0.10 (pay-per-use)

---

## Objetivo

Crear un cluster MSK Serverless, conectarte via Kafka CLI, crear un topic, producir mensajes y consumirlos — exactamente igual que con Kafka on-prem, solo cambia el endpoint.

---

## Prerequisitos

```bash
# Verificar AWS CLI v2
aws --version && aws sts get-caller-identity

# Instalar Kafka CLI (necesario para kafka-topics.sh, kafka-console-producer.sh)
# Opción 1 — Homebrew (Mac)
# brew install kafka

# Opción 2 — Descarga directa (Linux/Mac)
wget https://downloads.apache.org/kafka/3.7.0/kafka_2.13-3.7.0.tgz
tar -xzf kafka_2.13-3.7.0.tgz
export PATH="$PATH:$(pwd)/kafka_2.13-3.7.0/bin"

# Verificar
kafka-topics.sh --version
```

---

## Paso 1: Crear la VPC y subnets para MSK

MSK Serverless requiere estar en una VPC. Usamos la VPC default o creamos una dedicada.

```bash
REGION="eu-west-1"

# Obtener VPC default
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --region "$REGION" \
  --query 'Vpcs[0].VpcId' \
  --output text)

# Obtener subnets en 3 AZs (MSK requiere mínimo 2, serverless soporta hasta 3)
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query 'Subnets[:3].SubnetId' \
  --output text | tr '\t' ',')

echo "VPC: $VPC_ID"
echo "Subnets: $SUBNET_IDS"
```

---

## Paso 2: Crear Security Group para MSK

```bash
REGION="eu-west-1"
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --region "$REGION" \
  --query 'Vpcs[0].VpcId' \
  --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name lab03-msk-sg \
  --description "Lab03 MSK Security Group" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --query 'GroupId' \
  --output text)

# Kafka TLS (9098 = IAM auth), Kafka plaintext (9092), ZooKeeper (2181)
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 9098 \
  --cidr 0.0.0.0/0 \
  --region "$REGION"

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 9092 \
  --cidr 0.0.0.0/0 \
  --region "$REGION"

echo "Security Group: $SG_ID"
```

> **Nota:** En producción limita el CIDR a tu rango de IPs. Para el lab, `0.0.0.0/0` facilita el acceso.

---

## Paso 3: Crear cluster MSK Serverless

```bash
REGION="eu-west-1"
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --region "$REGION" \
  --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lab03-msk-sg" \
  --region "$REGION" \
  --query 'SecurityGroups[0].GroupId' --output text)

# Obtener las 3 primeras subnets como array JSON
SUBNETS_JSON=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query 'Subnets[:3].SubnetId' \
  --output json)

CLUSTER_ARN=$(aws kafka create-cluster-v2 \
  --cluster-name lab03-msk-serverless \
  --serverless "{
    \"VpcConfigs\": [{
      \"SubnetIds\": $SUBNETS_JSON,
      \"SecurityGroupIds\": [\"$SG_ID\"]
    }],
    \"ClientAuthentication\": {
      \"Sasl\": {
        \"Iam\": {\"Enabled\": true}
      }
    }
  }" \
  --region "$REGION" \
  --query 'ClusterArn' \
  --output text)

echo "Cluster ARN: $CLUSTER_ARN"
echo "Esperando que el cluster esté ACTIVE (puede tardar 5-10 minutos)..."
```

---

## Paso 4: Esperar y obtener el bootstrap endpoint

```bash
REGION="eu-west-1"
CLUSTER_ARN=$(aws kafka list-clusters-v2 \
  --region "$REGION" \
  --query 'ClusterInfoList[?ClusterName==`lab03-msk-serverless`].ClusterArn' \
  --output text)

# Esperar hasta ACTIVE
while true; do
  STATE=$(aws kafka describe-cluster-v2 \
    --cluster-arn "$CLUSTER_ARN" \
    --region "$REGION" \
    --query 'ClusterInfo.State' \
    --output text)
  echo "$(date -u +%H:%M:%S) Estado: $STATE"
  [[ "$STATE" == "ACTIVE" ]] && break
  sleep 30
done

echo "Cluster ACTIVE."

# Obtener bootstrap broker endpoint
BOOTSTRAP=$(aws kafka get-bootstrap-brokers \
  --cluster-arn "$CLUSTER_ARN" \
  --region "$REGION" \
  --query 'BootstrapBrokerStringSaslIam' \
  --output text)

echo "Bootstrap Brokers: $BOOTSTRAP"
# Exportar para los siguientes pasos
export MSK_BOOTSTRAP="$BOOTSTRAP"
```

---

## Paso 5: Configurar autenticación IAM para Kafka CLI

MSK Serverless solo soporta autenticación IAM (no PLAINTEXT). Necesitas el MSK IAM Auth plugin.

```bash
# Descargar el JAR del plugin de autenticación IAM
curl -L \
  "https://github.com/aws/aws-msk-iam-auth/releases/download/v2.0.3/aws-msk-iam-auth-2.0.3-all.jar" \
  -o /tmp/aws-msk-iam-auth.jar

# Crear archivo de configuración para Kafka CLI
cat > /tmp/kafka-iam.properties << 'EOF'
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF

# Añadir el JAR al classpath
export CLASSPATH="/tmp/aws-msk-iam-auth.jar:$CLASSPATH"

echo "Configuración IAM lista."
```

---

## Paso 6: Crear topic vía Kafka CLI

```bash
# Asegúrate de que MSK_BOOTSTRAP está exportado del paso 4
echo "Bootstrap: $MSK_BOOTSTRAP"

# Crear topic 'lab03-events' con 3 particiones y replicación 2
kafka-topics.sh \
  --bootstrap-server "$MSK_BOOTSTRAP" \
  --command-config /tmp/kafka-iam.properties \
  --create \
  --topic lab03-events \
  --partitions 3 \
  --replication-factor 2

# Verificar
kafka-topics.sh \
  --bootstrap-server "$MSK_BOOTSTRAP" \
  --command-config /tmp/kafka-iam.properties \
  --describe \
  --topic lab03-events
```

Observa en la salida: `Partition`, `Leader`, `Replicas`, `Isr` — igual que Kafka on-prem.

---

## Paso 7: Producir mensajes

Abre una nueva terminal:

```bash
export CLASSPATH="/tmp/aws-msk-iam-auth.jar:$CLASSPATH"
export MSK_BOOTSTRAP="<tu-bootstrap-endpoint>"

kafka-console-producer.sh \
  --bootstrap-server "$MSK_BOOTSTRAP" \
  --producer.config /tmp/kafka-iam.properties \
  --topic lab03-events \
  --property "parse.key=true" \
  --property "key.separator=:"
```

Escribe mensajes en formato `clave:valor`:
```
sensor-001:{"device":"sensor-001","temp":22.5,"ts":"2024-01-15T10:00:00Z"}
sensor-002:{"device":"sensor-002","temp":19.8,"ts":"2024-01-15T10:00:01Z"}
sensor-001:{"device":"sensor-001","temp":23.1,"ts":"2024-01-15T10:00:02Z"}
```
`Ctrl+C` para salir.

---

## Paso 8: Consumir mensajes

Abre otra terminal:

```bash
export CLASSPATH="/tmp/aws-msk-iam-auth.jar:$CLASSPATH"
export MSK_BOOTSTRAP="<tu-bootstrap-endpoint>"

# Consumir desde el principio con consumer group 'lab03-cg'
kafka-console-consumer.sh \
  --bootstrap-server "$MSK_BOOTSTRAP" \
  --consumer.config /tmp/kafka-iam.properties \
  --topic lab03-events \
  --from-beginning \
  --group lab03-cg \
  --property "print.key=true" \
  --property "key.separator=:"
```

Observa: los mensajes con la misma clave (`sensor-001`) siempre van a la misma partición — orden garantizado por clave.

---

## Paso 9: Verificar consumer groups y métricas

```bash
# Ver consumer groups y sus offsets
kafka-consumer-groups.sh \
  --bootstrap-server "$MSK_BOOTSTRAP" \
  --command-config /tmp/kafka-iam.properties \
  --describe \
  --group lab03-cg

# Ver métricas del cluster en CloudWatch
CLUSTER_ARN=$(aws kafka list-clusters-v2 \
  --region eu-west-1 \
  --query 'ClusterInfoList[?ClusterName==`lab03-msk-serverless`].ClusterArn' \
  --output text)

aws cloudwatch get-metric-statistics \
  --namespace "AWS/Kafka" \
  --metric-name "BytesInPerSec" \
  --dimensions "Name=Cluster Name,Value=lab03-msk-serverless" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Sum \
  --region eu-west-1
```

---

## Validación

```bash
./validate.sh
```

---

## Limpieza

```bash
REGION="eu-west-1"
CLUSTER_ARN=$(aws kafka list-clusters-v2 \
  --region "$REGION" \
  --query 'ClusterInfoList[?ClusterName==`lab03-msk-serverless`].ClusterArn' \
  --output text)

aws kafka delete-cluster \
  --cluster-arn "$CLUSTER_ARN" \
  --region "$REGION"

# Security Group (esperar a que el cluster esté eliminado primero)
sleep 60
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lab03-msk-sg" \
  --region "$REGION" \
  --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION"
```

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| MSK Serverless — sin gestión de brokers | Paso 3: create-cluster-v2 serverless |
| Autenticación IAM (no PLAINTEXT) | Paso 5: kafka-iam.properties |
| Topic con particiones y replicación | Paso 6: --partitions 3 --replication-factor 2 |
| Partition Key garantiza orden | Paso 7: misma clave → misma partición |
| Consumer group con offsets | Paso 8 + 9: consumer-groups describe |
| Métricas en CloudWatch | Paso 9: BytesInPerSec |
