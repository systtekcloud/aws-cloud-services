# Cleanup — Lab 01: Kinesis

> Eliminar todos los recursos en orden correcto para evitar errores de dependencia.
> **Coste si se olvida destruir:** ~$0.50/hora (KDS + Firehose activos).

---

## Opción A: Destruir con Terraform (si usaste terraform/)

```bash
cd data/labs/lab01-kinesis/terraform
terraform destroy -auto-approve
```

Terraform elimina los recursos en el orden correcto (Lambda → Firehose → KDS → S3 → IAM).

---

## Opción B: Destruir manualmente (si usaste los labs CLI)

Orden correcto: primero los consumers (Firehose), luego el stream fuente (KDS), luego S3, luego IAM.

### 1. Eliminar Firehose Delivery Streams

```bash
# Listar streams activos
aws firehose list-delivery-streams --region eu-west-1

# Eliminar los del lab (ajustar nombres según los que hayas creado)
aws firehose delete-delivery-stream \
  --delivery-stream-name lab01-firehose-direct \
  --region eu-west-1 2>/dev/null || true

aws firehose delete-delivery-stream \
  --delivery-stream-name lab01-firehose-from-kds \
  --region eu-west-1 2>/dev/null || true
```

### 2. Eliminar Kinesis Data Streams

```bash
# Listar streams activos
aws kinesis list-streams --region eu-west-1

# Eliminar los del lab
for STREAM in lab01-kds lab01-kds-source iot-sensors app-metrics; do
  aws kinesis delete-stream \
    --stream-name "$STREAM" \
    --region eu-west-1 2>/dev/null && echo "Eliminado: $STREAM" || true
done
```

### 3. Eliminar Lambda

```bash
aws lambda delete-function \
  --function-name lab01-firehose-transform \
  --region eu-west-1 2>/dev/null || true
```

### 4. Vaciar y eliminar S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab01-kinesis-firehose-${ACCOUNT_ID}"

# Eliminar todas las versiones (bucket versionado)
aws s3api delete-objects \
  --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null)" \
  --region eu-west-1 2>/dev/null || true

# Eliminar delete markers
aws s3api delete-objects \
  --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null)" \
  --region eu-west-1 2>/dev/null || true

aws s3 rb "s3://$BUCKET" --force 2>/dev/null || true
```

### 5. Eliminar roles IAM

```bash
# Firehose role
aws iam detach-role-policy \
  --role-name lab01-kinesis-firehose-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true

aws iam detach-role-policy \
  --role-name lab01-kinesis-firehose-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess 2>/dev/null || true

# Eliminar políticas inline
for POLICY in $(aws iam list-role-policies --role-name lab01-kinesis-firehose-role --query 'PolicyNames[]' --output text 2>/dev/null); do
  aws iam delete-role-policy \
    --role-name lab01-kinesis-firehose-role \
    --policy-name "$POLICY" 2>/dev/null || true
done

aws iam delete-role \
  --role-name lab01-kinesis-firehose-role 2>/dev/null || true

# Lambda role
aws iam detach-role-policy \
  --role-name lab01-kinesis-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

aws iam delete-role \
  --role-name lab01-kinesis-lambda-role 2>/dev/null || true
```

---

## Verificación final

```bash
echo "=== Kinesis Streams ==="
aws kinesis list-streams --region eu-west-1 \
  --query 'StreamNames[?contains(@, `lab01`) == `true`]'

echo "=== Firehose Streams ==="
aws firehose list-delivery-streams --region eu-west-1 \
  --query 'DeliveryStreamNames[?contains(@, `lab01`) == `true`]'

echo "=== Lambda Functions ==="
aws lambda list-functions --region eu-west-1 \
  --query 'Functions[?contains(FunctionName, `lab01`)].FunctionName'

echo "=== S3 Buckets ==="
aws s3 ls | grep lab01-kinesis

echo "=== IAM Roles ==="
aws iam list-roles \
  --query 'Roles[?contains(RoleName, `lab01-kinesis`)].RoleName'
```

Si todos los comandos devuelven listas vacías, el lab está limpio.

---

## Recursos de CloudWatch (opcionales)

CloudWatch Logs genera grupos automáticamente al ejecutar Lambdas. Si quieres eliminarlos:

```bash
aws logs delete-log-group \
  --log-group-name "/aws/lambda/lab01-firehose-transform" \
  --region eu-west-1 2>/dev/null || true
```
