# Lab 03 — Limpieza y costes

## Coste residual

| Recurso | Coste residual |
|---------|---------------|
| Config Recorder activo | **~$0.003 por item** registrado (mínimo ~$2-5/mes si hay actividad) |
| Config Rules | $0.001 por evaluación |
| S3 bucket (delivery) | ~$0.023/GB/mes (mínimo) |
| Lambda custom rule | $0.00 (capa gratuita) |
| Config Aggregator | $0.003 por item agregado |

**IMPORTANTE:** El Config Recorder es el componente de mayor coste. Detenerlo elimina el coste recurrente.

---

## Limpieza completa (orden recomendado)

### 1. Detener el recorder (lo más importante)

```bash
export AWS_REGION="eu-west-1"

aws configservice stop-configuration-recorder \
  --configuration-recorder-name default \
  --region "$AWS_REGION"

echo "Recorder detenido — coste recurrente eliminado"
```

### 2. Eliminar reglas Config

```bash
# Eliminar reglas managed
aws configservice delete-config-rule \
  --config-rule-name "restricted-ssh" \
  --region "$AWS_REGION"

aws configservice delete-config-rule \
  --config-rule-name "s3-bucket-public-read-prohibited" \
  --region "$AWS_REGION"

# Eliminar custom rule (si se creó en lab04)
aws configservice delete-config-rule \
  --config-rule-name "ec2-required-tag-environment" \
  --region "$AWS_REGION" 2>/dev/null || echo "Custom rule no existe, OK"
```

### 3. Eliminar remediation configuration (si se configuró en lab03)

```bash
aws configservice delete-remediation-configuration \
  --config-rule-name "restricted-ssh" \
  --region "$AWS_REGION" 2>/dev/null || echo "No hay remediation config, OK"
```

### 4. Eliminar aggregator (si se creó en lab05)

```bash
aws configservice delete-configuration-aggregator \
  --configuration-aggregator-name "lab03-aggregator" \
  --region "$AWS_REGION" 2>/dev/null || echo "No hay aggregator, OK"
```

### 5. Eliminar Lambdas (si se crearon en lab04)

```bash
aws lambda delete-function \
  --function-name "lab03-ec2-tag-check" \
  --region "$AWS_REGION" 2>/dev/null || echo "Lambda check no existe, OK"

aws lambda delete-function \
  --function-name "lab03-ec2-tag-remediation" \
  --region "$AWS_REGION" 2>/dev/null || echo "Lambda remediation no existe, OK"
```

### 6. Eliminar IAM Roles

```bash
# Rol del recorder
aws iam detach-role-policy \
  --role-name "lab03-config-recorder-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole" 2>/dev/null

aws iam delete-role \
  --role-name "lab03-config-recorder-role" 2>/dev/null || echo "Rol recorder no existe, OK"

# Rol de remediation SSM
aws iam delete-role-policy \
  --role-name "lab03-config-remediation-role" \
  --policy-name "lab03-remediation-sg-policy" 2>/dev/null

aws iam delete-role \
  --role-name "lab03-config-remediation-role" 2>/dev/null || echo "Rol remediation no existe, OK"

# Rol de Lambda custom rule
aws iam delete-role-policy \
  --role-name "lab03-custom-rule-lambda-role" \
  --policy-name "lab03-config-eval-policy" 2>/dev/null

aws iam delete-role-policy \
  --role-name "lab03-custom-rule-lambda-role" \
  --policy-name "lab03-ec2-tag-policy" 2>/dev/null

aws iam detach-role-policy \
  --role-name "lab03-custom-rule-lambda-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null

aws iam delete-role \
  --role-name "lab03-custom-rule-lambda-role" 2>/dev/null || echo "Rol Lambda no existe, OK"
```

### 7. Eliminar delivery channel y recorder

```bash
aws configservice delete-delivery-channel \
  --delivery-channel-name default \
  --region "$AWS_REGION" 2>/dev/null || echo "No hay delivery channel, OK"

aws configservice delete-configuration-recorder \
  --configuration-recorder-name default \
  --region "$AWS_REGION" 2>/dev/null || echo "No hay recorder, OK"
```

### 8. Vaciar y eliminar bucket S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CONFIG_BUCKET="lab03-config-delivery-${ACCOUNT_ID}"

# Vaciar todas las versiones del bucket
aws s3api list-object-versions \
  --bucket "$CONFIG_BUCKET" \
  --query 'Versions[].{Key:Key,VersionId:VersionId}' \
  --output json 2>/dev/null | \
  jq -r '.[] | "\(.Key) \(.VersionId)"' | \
  while read key version; do
    aws s3api delete-object --bucket "$CONFIG_BUCKET" --key "$key" --version-id "$version"
  done 2>/dev/null

# Eliminar marcadores de borrado
aws s3api list-object-versions \
  --bucket "$CONFIG_BUCKET" \
  --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
  --output json 2>/dev/null | \
  jq -r '.[] | "\(.Key) \(.VersionId)"' | \
  while read key version; do
    aws s3api delete-object --bucket "$CONFIG_BUCKET" --key "$key" --version-id "$version"
  done 2>/dev/null

# Eliminar bucket
aws s3 rb "s3://${CONFIG_BUCKET}" --force 2>/dev/null || echo "Bucket no existe, OK"
echo "Limpieza completa"
```

### Alternativa: Terraform destroy

Si se desplegó con Terraform:

```bash
cd terraform/
terraform destroy -auto-approve
```

---

## Verificar que todo está limpio

```bash
export AWS_REGION="eu-west-1"

echo "=== Estado del recorder ==="
aws configservice describe-configuration-recorder-status \
  --region "$AWS_REGION" \
  --query 'ConfigurationRecordersStatus[].{Nombre:name,Grabando:recording}' \
  --output table 2>/dev/null || echo "No hay recorder"

echo "=== Reglas activas ==="
aws configservice describe-config-rules \
  --region "$AWS_REGION" \
  --query 'ConfigRules[].ConfigRuleName' \
  --output table 2>/dev/null || echo "No hay reglas"

echo "=== Lambdas del lab ==="
aws lambda list-functions \
  --region "$AWS_REGION" \
  --query 'Functions[?starts_with(FunctionName, `lab03`)].FunctionName' \
  --output table 2>/dev/null || echo "No hay Lambdas"
```
