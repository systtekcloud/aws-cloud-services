# Lab 04 — Limpieza y costes

## Coste residual

| Recurso | Coste residual |
|---------|---------------|
| GuardDuty Detector | **GRATIS 30 días** desde activación, luego ~$1-4/mes según uso |
| S3 bucket (IP lists) | ~$0.00 (archivos mínimos) |
| Lambda | $0.00 (capa gratuita) |
| SNS Topic | $0.00 sin mensajes |
| EventBridge Rule | $0.00 sin eventos |

**IMPORTANTE:** El coste recurrente principal es el **GuardDuty Detector**. Después del free trial de 30 días, deshabilitarlo elimina el coste.

---

## Limpieza completa (orden recomendado)

### 1. Eliminar recursos de remediación (si se crearon en lab04)

```bash
export AWS_REGION="eu-west-1"

# Eliminar targets EventBridge
aws events remove-targets \
  --rule "lab04-guardduty-high-severity" \
  --ids "lambda-target" "sns-target" \
  --region "$AWS_REGION" 2>/dev/null || echo "Targets no existen, OK"

# Eliminar regla EventBridge
aws events delete-rule \
  --name "lab04-guardduty-high-severity" \
  --region "$AWS_REGION" 2>/dev/null || echo "Regla no existe, OK"

# Eliminar Lambda
aws lambda delete-function \
  --function-name "lab04-guardduty-isolate" \
  --region "$AWS_REGION" 2>/dev/null || echo "Lambda no existe, OK"

# Eliminar SNS Topic
SNS_ARN=$(aws sns list-topics \
  --region "$AWS_REGION" \
  --query "Topics[?contains(TopicArn,'lab04-guardduty-alerts')].TopicArn" \
  --output text 2>/dev/null)

[[ -n "$SNS_ARN" ]] && aws sns delete-topic --topic-arn "$SNS_ARN" --region "$AWS_REGION" || echo "SNS no existe, OK"

# Eliminar SG de cuarentena
QUARANTINE_SG=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=lab04-quarantine-sg \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

[[ -n "$QUARANTINE_SG" && "$QUARANTINE_SG" != "None" ]] && \
  aws ec2 delete-security-group --group-id "$QUARANTINE_SG" || echo "Quarantine SG no existe, OK"
```

### 2. Eliminar IAM Role

```bash
aws iam delete-role-policy \
  --role-name "lab04-guardduty-remediation-role" \
  --policy-name "lab04-ec2-isolate-policy" 2>/dev/null

aws iam detach-role-policy \
  --role-name "lab04-guardduty-remediation-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null

aws iam delete-role \
  --role-name "lab04-guardduty-remediation-role" 2>/dev/null || echo "Rol no existe, OK"
```

### 3. Eliminar IP Lists y Suppression Rules

```bash
DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$AWS_REGION" \
  --query 'DetectorIds[0]' --output text 2>/dev/null)

if [[ -n "$DETECTOR_ID" && "$DETECTOR_ID" != "None" ]]; then
  # Eliminar Trusted IP Set
  for IPSET_ID in $(aws guardduty list-ip-sets \
    --detector-id "$DETECTOR_ID" \
    --region "$AWS_REGION" \
    --query 'IpSetIds' --output text 2>/dev/null); do
    aws guardduty delete-ip-set \
      --detector-id "$DETECTOR_ID" \
      --ip-set-id "$IPSET_ID" \
      --region "$AWS_REGION"
  done

  # Eliminar Threat Intel Sets
  for THREATSET_ID in $(aws guardduty list-threat-intel-sets \
    --detector-id "$DETECTOR_ID" \
    --region "$AWS_REGION" \
    --query 'ThreatIntelSetIds' --output text 2>/dev/null); do
    aws guardduty delete-threat-intel-set \
      --detector-id "$DETECTOR_ID" \
      --threat-intel-set-id "$THREATSET_ID" \
      --region "$AWS_REGION"
  done

  # Eliminar Suppression Rules (Filters)
  for FILTER_NAME in $(aws guardduty list-filters \
    --detector-id "$DETECTOR_ID" \
    --region "$AWS_REGION" \
    --query 'FilterNames' --output text 2>/dev/null); do
    aws guardduty delete-filter \
      --detector-id "$DETECTOR_ID" \
      --filter-name "$FILTER_NAME" \
      --region "$AWS_REGION"
  done

  echo "IP Lists y Suppression Rules eliminadas"
fi
```

### 4. Eliminar bucket S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LISTS_BUCKET="lab04-guardduty-lists-${ACCOUNT_ID}"

aws s3 rb "s3://${LISTS_BUCKET}" --force 2>/dev/null || echo "Bucket no existe, OK"
```

### 5. Deshabilitar GuardDuty (¡IMPORTANTE para evitar costes!)

```bash
DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$AWS_REGION" \
  --query 'DetectorIds[0]' --output text 2>/dev/null)

if [[ -n "$DETECTOR_ID" && "$DETECTOR_ID" != "None" ]]; then
  # Primero deshabilitar
  aws guardduty update-detector \
    --detector-id "$DETECTOR_ID" \
    --no-enable \
    --region "$AWS_REGION"

  # Luego eliminar el detector
  aws guardduty delete-detector \
    --detector-id "$DETECTOR_ID" \
    --region "$AWS_REGION"

  echo "GuardDuty deshabilitado y detector eliminado"
else
  echo "GuardDuty ya estaba eliminado"
fi
```

### Alternativa: Terraform destroy

```bash
cd terraform/
terraform destroy -auto-approve
```

---

## Verificar que todo está limpio

```bash
export AWS_REGION="eu-west-1"

echo "=== Estado de GuardDuty ==="
aws guardduty list-detectors \
  --region "$AWS_REGION" \
  --query 'DetectorIds' \
  --output text 2>/dev/null || echo "Sin detectores (correcto)"

echo "=== Lambdas del lab ==="
aws lambda list-functions \
  --region "$AWS_REGION" \
  --query 'Functions[?starts_with(FunctionName, `lab04`)].FunctionName' \
  --output table 2>/dev/null

echo "=== Reglas EventBridge del lab ==="
aws events list-rules \
  --region "$AWS_REGION" \
  --query 'Rules[?starts_with(Name, `lab04`)].Name' \
  --output table 2>/dev/null
```

---

## ⚠️ Nota sobre prerequisitos

Si tienes previsto hacer **lab05-security-hub** o **lab08-detective**, NO elimines GuardDuty todavía:
- Security Hub necesita GuardDuty activo para tener findings útiles
- Detective necesita GuardDuty activo + 24-48h de datos

**Estrategia recomendada:** Activar GuardDuty (lab04) → lab05 (Security Hub) → lab08 (Detective) → luego deshabilitar todo.
