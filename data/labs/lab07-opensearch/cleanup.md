# Cleanup — Lab 07: Amazon OpenSearch

> ⚠️ **CRÍTICO:** El dominio OpenSearch cobra por hora aunque no haya datos ni queries.
> t3.small.search = ~$0.036/hora. Eliminar inmediatamente tras el lab.

---

## Opción A: Destruir con Terraform

```bash
cd data/labs/lab07-opensearch/terraform
terraform destroy -auto-approve
```

---

## Opción B: Destruir manualmente

Orden: Subscription Filter → Firehose → Lambda → OpenSearch → S3 → IAM.

### 1. Eliminar Subscription Filter y recursos del Lab 02

```bash
REGION="eu-west-1"

aws logs delete-subscription-filter \
  --log-group-name "/aws/lambda/lab07-log-generator" \
  --filter-name "lab07-to-firehose" \
  --region "$REGION" 2>/dev/null && echo "Subscription Filter eliminado" || true

# Eliminar Lambda
MAPPING_UUID=$(aws lambda list-event-source-mappings \
  --function-name lab07-log-generator --region "$REGION" \
  --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || echo "")
[[ -n "$MAPPING_UUID" && "$MAPPING_UUID" != "None" ]] && \
  aws lambda delete-event-source-mapping --uuid "$MAPPING_UUID" --region "$REGION" 2>/dev/null || true

aws lambda delete-function \
  --function-name lab07-log-generator \
  --region "$REGION" 2>/dev/null && echo "Lambda eliminada" || true
```

### 2. Eliminar Firehose

```bash
REGION="eu-west-1"

aws firehose delete-delivery-stream \
  --delivery-stream-name lab07-logs-to-opensearch \
  --region "$REGION" 2>/dev/null && echo "Firehose eliminado" || true
```

### 3. Eliminar dominio OpenSearch

```bash
REGION="eu-west-1"

aws opensearch delete-domain \
  --domain-name lab07-opensearch \
  --region "$REGION" && echo "Dominio OpenSearch en eliminación (5-10 min, no genera más coste)"
```

### 4. Vaciar y eliminar S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab07-firehose-backup-${ACCOUNT_ID}"

aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
aws s3 rb "s3://$BUCKET" 2>/dev/null && echo "Bucket eliminado: $BUCKET" || true
```

### 5. Eliminar roles IAM

```bash
for ROLE in lab07-lambda-role lab07-firehose-role lab07-cwlogs-role; do
  # Desadjuntar políticas managed
  for ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$ARN" 2>/dev/null || true
  done
  # Eliminar políticas inline
  for POLICY in $(aws iam list-role-policies --role-name "$ROLE" \
    --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "Rol eliminado: $ROLE" || true
done
```

---

## Verificación final

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== OpenSearch Domains ==="
aws opensearch list-domain-names --region "$REGION" \
  --query 'DomainNames[?contains(DomainName, `lab07`)].DomainName'

echo "=== Firehose Streams ==="
aws firehose list-delivery-streams --region "$REGION" \
  --query 'DeliveryStreamNames[?contains(@, `lab07`) == `true`]'

echo "=== Lambda Functions ==="
aws lambda list-functions --region "$REGION" \
  --query 'Functions[?contains(FunctionName, `lab07`)].FunctionName'

echo "=== S3 Buckets ==="
aws s3 ls | grep lab07

echo "=== IAM Roles ==="
aws iam list-roles --query 'Roles[?contains(RoleName, `lab07`)].RoleName'
```

Todas las listas deben estar vacías.

---

## CloudWatch Log Groups (opcional)

```bash
REGION="eu-west-1"

aws logs delete-log-group \
  --log-group-name "/aws/lambda/lab07-log-generator" \
  --region "$REGION" 2>/dev/null || true
```
