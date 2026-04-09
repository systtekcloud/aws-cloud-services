# Cleanup — Lab 05: Amazon EMR

> ⚠️ **CRÍTICO:** EMR Serverless no genera coste en reposo (solo durante jobs), pero elimínalo igualmente para mantener el entorno limpio.
> Los buckets S3 generan coste mínimo por almacenamiento.

---

## Opción A: Destruir con Terraform

```bash
cd data/labs/lab05-emr/terraform
terraform destroy -auto-approve
```

---

## Opción B: Destruir manualmente

Orden: Jobs activos → Aplicación EMR → S3 → IAM.

### 1. Cancelar jobs en ejecución

```bash
REGION="eu-west-1"

APP_ID=$(aws emr-serverless list-applications \
  --region "$REGION" \
  --query 'applications[?name==`lab05-spark-app`].id' \
  --output text 2>/dev/null || echo "")

if [[ -n "$APP_ID" && "$APP_ID" != "None" ]]; then
  echo "Aplicación encontrada: $APP_ID"

  # Cancelar jobs en ejecución
  for JOB_ID in $(aws emr-serverless list-job-runs \
    --application-id "$APP_ID" \
    --region "$REGION" \
    --states RUNNING PENDING SCHEDULED \
    --query 'jobRuns[].id' \
    --output text 2>/dev/null); do
    aws emr-serverless cancel-job-run \
      --application-id "$APP_ID" \
      --job-run-id "$JOB_ID" \
      --region "$REGION" 2>/dev/null && echo "Job cancelado: $JOB_ID" || true
  done

  sleep 10
fi
```

### 2. Parar y eliminar aplicación EMR Serverless

```bash
REGION="eu-west-1"

APP_ID=$(aws emr-serverless list-applications \
  --region "$REGION" \
  --query 'applications[?name==`lab05-spark-app`].id' \
  --output text 2>/dev/null || echo "")

if [[ -n "$APP_ID" && "$APP_ID" != "None" ]]; then
  # Parar la aplicación
  aws emr-serverless stop-application \
    --application-id "$APP_ID" \
    --region "$REGION" 2>/dev/null || true

  echo "Esperando que la aplicación se detenga..."
  while true; do
    STATE=$(aws emr-serverless get-application \
      --application-id "$APP_ID" --region "$REGION" \
      --query 'application.state' --output text 2>/dev/null || echo "STOPPED")
    echo "  Estado: $STATE"
    [[ "$STATE" == "STOPPED" || "$STATE" == "TERMINATED" ]] && break
    sleep 10
  done

  # Eliminar
  aws emr-serverless delete-application \
    --application-id "$APP_ID" \
    --region "$REGION" && echo "Aplicación EMR eliminada." || true
fi
```

### 3. Vaciar y eliminar buckets S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

for BUCKET in \
  "lab05-emr-input-${ACCOUNT_ID}" \
  "lab05-emr-output-${ACCOUNT_ID}" \
  "lab05-emr-logs-${ACCOUNT_ID}"; do
  echo "Vaciando $BUCKET..."
  aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
  aws s3 rb "s3://$BUCKET" 2>/dev/null && echo "Bucket eliminado: $BUCKET" || true
done
```

### 4. Eliminar rol IAM

```bash
ROLE="lab05-emr-serverless-role"

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
```

---

## Verificación final

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== EMR Serverless Applications ==="
aws emr-serverless list-applications --region "$REGION" \
  --query 'applications[?contains(name, `lab05`)].{Name:name,State:state,Id:id}'

echo "=== S3 Buckets ==="
aws s3 ls | grep lab05-emr

echo "=== IAM Roles ==="
aws iam list-roles --query 'Roles[?contains(RoleName, `lab05`)].RoleName'
```

Todas las listas deben estar vacías.

---

## CloudWatch Logs (opcional)

```bash
REGION="eu-west-1"

aws logs delete-log-group \
  --log-group-name "/aws/emr-serverless/lab05-spark-app" \
  --region "$REGION" 2>/dev/null || true
```
