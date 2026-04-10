# Lab 01 — Cleanup

Elimina todos los recursos creados en lab01-lambda para evitar costes no deseados.

> **Coste residual de este lab:** Las funciones Lambda no tienen coste en idle. El único coste continuo es Provisioned Concurrency si la dejaste activa (sub-lab 02). Verifica con `aws lambda list-provisioned-concurrency-configs`.

---

## Opción A: Terraform (si usaste terraform/)

```bash
cd integration/labs/lab01-lambda/terraform/
terraform destroy -auto-approve
```

---

## Opción B: AWS CLI (si creaste recursos manualmente)

### Funciones Lambda

```bash
for fn in lab01-fundamentos lab01-concurrency-test lab01-provisioned-test lab01-with-layer lab01-destinations lab01-custom-runtime; do
  aws lambda delete-function --function-name "$fn" --region eu-west-1 2>/dev/null && echo "Deleted: $fn" || echo "Not found: $fn"
done
```

### Provisioned Concurrency (si quedó activa)

```bash
# Listar
aws lambda list-provisioned-concurrency-configs \
  --function-name lab01-provisioned-test \
  --region eu-west-1

# Eliminar
aws lambda delete-provisioned-concurrency-config \
  --function-name lab01-provisioned-test \
  --qualifier live \
  --region eu-west-1 2>/dev/null || true
```

### Lambda Layers

```bash
# Listar versiones del layer
aws lambda list-layer-versions \
  --layer-name lab01-requests-layer \
  --region eu-west-1 \
  --query 'LayerVersions[*].Version' \
  --output text | tr '\t' '\n' | while read VERSION; do
    aws lambda delete-layer-version \
      --layer-name lab01-requests-layer \
      --version-number "$VERSION" \
      --region eu-west-1
    echo "Deleted layer version: $VERSION"
  done
```

### SQS Queues

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

for queue in lab01-destinations-success lab01-destinations-failure lab01-dlq lab01-esm-queue lab01-lambda-trigger lab01-lambda-trigger-dlq lab01-lambda-success lab01-lambda-failure; do
  URL="https://sqs.$REGION.amazonaws.com/$ACCOUNT_ID/$queue"
  aws sqs delete-queue --queue-url "$URL" --region "$REGION" 2>/dev/null && echo "Deleted: $queue" || echo "Not found: $queue"
done
```

### S3 Bucket del trigger S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab01-lambda-trigger-$ACCOUNT_ID"

# Vaciar antes de borrar
aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
aws s3api delete-bucket --bucket "$BUCKET" --region eu-west-1 2>/dev/null && echo "Deleted bucket: $BUCKET" || echo "Not found: $BUCKET"
```

### IAM

```bash
# Detach policies
aws iam detach-role-policy \
  --role-name lab01-lambda-basic-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

aws iam detach-role-policy \
  --role-name lab01-lambda-basic-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole 2>/dev/null || true

# Eliminar inline policies
aws iam list-role-policies --role-name lab01-lambda-basic-role --query 'PolicyNames' --output text | \
  tr '\t' '\n' | while read pol; do
    aws iam delete-role-policy --role-name lab01-lambda-basic-role --policy-name "$pol"
  done

# Eliminar rol
aws iam delete-role --role-name lab01-lambda-basic-role 2>/dev/null && echo "Deleted IAM role" || echo "Role not found"
```

### CloudWatch Logs (opcional — se eliminan solos según retención)

```bash
for fn in lab01-fundamentos lab01-concurrency-test lab01-provisioned-test lab01-with-layer lab01-destinations; do
  aws logs delete-log-group \
    --log-group-name "/aws/lambda/$fn" \
    --region eu-west-1 2>/dev/null && echo "Deleted log group: $fn" || true
done
```

---

## Verificación

```bash
# Confirmar que no quedan funciones de lab01
aws lambda list-functions \
  --region eu-west-1 \
  --query 'Functions[?starts_with(FunctionName, `lab01`)].FunctionName' \
  --output text

# Confirmar que no quedan queues de lab01
aws sqs list-queues \
  --region eu-west-1 \
  --queue-name-prefix lab01 \
  --query 'QueueUrls' \
  --output text
```

Si ambos comandos devuelven vacío, la limpieza está completa.
