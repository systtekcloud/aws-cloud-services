# Cleanup — Lab 02: Kinesis Data Analytics

> Eliminar todos los recursos en orden correcto.
> **Coste si se olvida destruir:** ~$0.50/hora (2 KPU × $0.11/h + KDS).

---

## Opción A: Destruir con Terraform

```bash
cd data/labs/lab02-kinesis-analytics/terraform
terraform destroy -auto-approve
```

---

## Opción B: Destruir manualmente

Orden: parar aplicación KDA → eliminar KDA → Lambda → SNS → Firehose → KDS → S3 → IAM.

### 1. Parar y eliminar aplicaciones KDA

```bash
REGION="eu-west-1"

for APP in lab02-sensor-analytics lab02-anomaly-detection; do
  # Parar si está RUNNING
  STATUS=$(aws kinesisanalytics describe-application \
    --application-name "$APP" --region "$REGION" \
    --query 'ApplicationDetail.ApplicationStatus' --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$STATUS" == "RUNNING" ]]; then
    echo "Parando $APP..."
    aws kinesisanalytics stop-application \
      --application-name "$APP" --region "$REGION" 2>/dev/null || true
    sleep 30
  fi

  # Eliminar
  CREATE_TS=$(aws kinesisanalytics describe-application \
    --application-name "$APP" --region "$REGION" \
    --query 'ApplicationDetail.CreateTimestamp' --output text 2>/dev/null || echo "")

  if [[ -n "$CREATE_TS" && "$CREATE_TS" != "None" ]]; then
    aws kinesisanalytics delete-application \
      --application-name "$APP" \
      --create-timestamp "$CREATE_TS" \
      --region "$REGION" 2>/dev/null && echo "Eliminado: $APP" || true
  fi
done
```

### 2. Eliminar Lambda y event source mappings

```bash
REGION="eu-west-1"

for FUNC in lab02-anomaly-alert; do
  # Eliminar event source mappings primero
  for UUID in $(aws lambda list-event-source-mappings \
    --function-name "$FUNC" --region "$REGION" \
    --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
    aws lambda delete-event-source-mapping --uuid "$UUID" --region "$REGION" 2>/dev/null || true
  done
  sleep 5
  aws lambda delete-function --function-name "$FUNC" --region "$REGION" 2>/dev/null && echo "Lambda eliminada: $FUNC" || true
done
```

### 3. Eliminar SNS

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

aws sns delete-topic \
  --topic-arn "arn:aws:sns:$REGION:${ACCOUNT_ID}:lab02-anomaly-alerts" \
  --region "$REGION" 2>/dev/null || true
```

### 4. Eliminar Firehose

```bash
REGION="eu-west-1"

for STREAM in lab02-kda-output; do
  aws firehose delete-delivery-stream \
    --delivery-stream-name "$STREAM" \
    --region "$REGION" 2>/dev/null && echo "Firehose eliminado: $STREAM" || true
done
```

### 5. Eliminar KDS

```bash
REGION="eu-west-1"

for STREAM in lab02-sensor-data lab02-app-metrics lab02-anomaly-alerts lab02-kda-output; do
  aws kinesis delete-stream \
    --stream-name "$STREAM" \
    --region "$REGION" 2>/dev/null && echo "KDS eliminado: $STREAM" || true
done
```

### 6. Vaciar y eliminar S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab02-kda-analytics-${ACCOUNT_ID}"

aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
aws s3 rb "s3://$BUCKET" 2>/dev/null || true
```

### 7. Eliminar roles IAM

```bash
for ROLE in lab02-kda-role lab02-firehose-role lab02-anomaly-lambda-role; do
  # Eliminar políticas inline
  for POLICY in $(aws iam list-role-policies --role-name "$ROLE" \
    --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY" 2>/dev/null || true
  done
  # Desadjuntar políticas managed
  for POLICY_ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "Rol eliminado: $ROLE" || true
done
```

---

## Verificación final

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== KDA Applications ==="
aws kinesisanalytics list-applications --region "$REGION" \
  --query 'ApplicationSummaries[?contains(ApplicationName, `lab02`)].ApplicationName'

echo "=== KDS Streams ==="
aws kinesis list-streams --region "$REGION" \
  --query 'StreamNames[?contains(@, `lab02`) == `true`]'

echo "=== Lambda Functions ==="
aws lambda list-functions --region "$REGION" \
  --query 'Functions[?contains(FunctionName, `lab02`)].FunctionName'

echo "=== Firehose Streams ==="
aws firehose list-delivery-streams --region "$REGION" \
  --query 'DeliveryStreamNames[?contains(@, `lab02`) == `true`]'

echo "=== S3 Buckets ==="
aws s3 ls | grep lab02-kda

echo "=== IAM Roles ==="
aws iam list-roles \
  --query 'Roles[?contains(RoleName, `lab02`)].RoleName'
```

Si todas las listas están vacías, el lab está limpio.

---

## CloudWatch Logs (opcionales)

```bash
REGION="eu-west-1"

for LOG_GROUP in \
  "/aws/lambda/lab02-anomaly-alert" \
  "/aws/kinesisanalytics/lab02-sensor-analytics" \
  "/aws/kinesisanalytics/lab02-anomaly-detection"; do
  aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$REGION" 2>/dev/null || true
done
```
