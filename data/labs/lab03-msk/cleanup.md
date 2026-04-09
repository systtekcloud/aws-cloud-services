# Cleanup — Lab 03: Amazon MSK

> Eliminar todos los recursos en orden correcto.
> **Coste si se olvida:** MSK Serverless cobra por partition-hours y GB de datos — bajo pero acumulativo.

---

## Opción A: Destruir con Terraform

```bash
cd data/labs/lab03-msk/terraform
terraform destroy -auto-approve
```

---

## Opción B: Destruir manualmente

Orden: MSK Connect → Custom Plugin → MSK Cluster → S3 → IAM → Security Group.

### 1. Eliminar MSK Connect Connector

```bash
REGION="eu-west-1"

CONNECTOR_ARN=$(aws kafkaconnect list-connectors \
  --region "$REGION" \
  --query 'connectors[?connectorName==`lab03-s3-sink`].connectorArn' \
  --output text 2>/dev/null || echo "")

if [[ -n "$CONNECTOR_ARN" && "$CONNECTOR_ARN" != "None" ]]; then
  aws kafkaconnect delete-connector \
    --connector-arn "$CONNECTOR_ARN" \
    --region "$REGION" && echo "Connector eliminado" || true
  echo "Esperando eliminación del connector (30 seg)..."
  sleep 30
fi
```

### 2. Eliminar Custom Plugin

```bash
REGION="eu-west-1"

PLUGIN_ARN=$(aws kafkaconnect list-custom-plugins \
  --region "$REGION" \
  --query 'customPlugins[?name==`lab03-s3-sink-plugin`].customPluginArn' \
  --output text 2>/dev/null || echo "")

if [[ -n "$PLUGIN_ARN" && "$PLUGIN_ARN" != "None" ]]; then
  aws kafkaconnect delete-custom-plugin \
    --custom-plugin-arn "$PLUGIN_ARN" \
    --region "$REGION" && echo "Plugin eliminado" || true
fi
```

### 3. Eliminar cluster MSK

```bash
REGION="eu-west-1"

CLUSTER_ARN=$(aws kafka list-clusters-v2 \
  --region "$REGION" \
  --query 'ClusterInfoList[?ClusterName==`lab03-msk-serverless`].ClusterArn' \
  --output text 2>/dev/null || echo "")

if [[ -n "$CLUSTER_ARN" && "$CLUSTER_ARN" != "None" ]]; then
  aws kafka delete-cluster \
    --cluster-arn "$CLUSTER_ARN" \
    --region "$REGION" && echo "Cluster MSK eliminado"

  echo "Esperando eliminación del cluster..."
  while true; do
    STATE=$(aws kafka describe-cluster-v2 \
      --cluster-arn "$CLUSTER_ARN" --region "$REGION" \
      --query 'ClusterInfo.State' --output text 2>/dev/null || echo "DELETED")
    echo "  Estado: $STATE"
    [[ "$STATE" == "DELETED" || -z "$STATE" ]] && break
    sleep 30
  done
fi
```

### 4. Vaciar y eliminar S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab03-msk-connect-${ACCOUNT_ID}"

aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
aws s3 rb "s3://$BUCKET" 2>/dev/null && echo "Bucket eliminado" || true
```

### 5. Eliminar roles IAM

```bash
for ROLE in lab03-msk-connect-role; do
  for POLICY in $(aws iam list-role-policies --role-name "$ROLE" \
    --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY" 2>/dev/null || true
  done
  for POLICY_ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "Rol eliminado: $ROLE" || true
done
```

### 6. Eliminar Security Group

```bash
REGION="eu-west-1"

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lab03-msk-sg" \
  --region "$REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  aws ec2 delete-security-group \
    --group-id "$SG_ID" \
    --region "$REGION" && echo "Security Group eliminado" || true
fi
```

---

## Verificación final

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== MSK Clusters ==="
aws kafka list-clusters-v2 --region "$REGION" \
  --query 'ClusterInfoList[?contains(ClusterName, `lab03`)].{Name:ClusterName,State:State}'

echo "=== MSK Connect Connectors ==="
aws kafkaconnect list-connectors --region "$REGION" \
  --query 'connectors[?contains(connectorName, `lab03`)].connectorName'

echo "=== MSK Connect Plugins ==="
aws kafkaconnect list-custom-plugins --region "$REGION" \
  --query 'customPlugins[?contains(name, `lab03`)].name'

echo "=== S3 Buckets ==="
aws s3 ls | grep lab03-msk

echo "=== IAM Roles ==="
aws iam list-roles --query 'Roles[?contains(RoleName, `lab03`)].RoleName'

echo "=== Security Groups ==="
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lab03-msk-sg" \
  --region "$REGION" \
  --query 'SecurityGroups[].GroupId'
```

Todas las listas deben estar vacías.
