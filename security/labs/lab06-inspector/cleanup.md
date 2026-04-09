# Lab 06 — Limpieza y costes

## Coste residual

| Recurso | Coste residual |
|---------|---------------|
| Inspector habilitado | **GRATIS 30 días**, luego ~$0.0014/instancia EC2/hora |
| ECR Enhanced Scanning | Incluido en Inspector |
| Lambda | $0.00 (free tier) |
| SNS Topic | $0.00 (sin mensajes) |
| ECR repositorios | ~$0.10/GB/mes (mínimo) |

**IMPORTANTE:** Deshabilitar Inspector después del lab para evitar costes post-trial.

---

## Limpieza completa

### 1. Eliminar recursos de Lambda y EventBridge

```bash
export AWS_REGION="eu-west-1"

# Eliminar EventBridge rule (primero eliminar targets)
aws events remove-targets \
  --rule lab06-inspector-critical-ecr \
  --ids lambda-pipeline-blocker sns-team-notification \
  --region "$AWS_REGION" 2>/dev/null || true

aws events delete-rule \
  --name lab06-inspector-critical-ecr \
  --region "$AWS_REGION" 2>/dev/null || true

# Eliminar Lambda
aws lambda delete-function \
  --function-name lab06-inspector-pipeline-blocker \
  --region "$AWS_REGION" 2>/dev/null || true

# Eliminar SNS topic
SNS_ARN=$(aws sns list-topics \
  --region "$AWS_REGION" \
  --query 'Topics[?contains(TopicArn, `lab06-inspector-alerts`)].TopicArn' \
  --output text 2>/dev/null)
[[ -n "$SNS_ARN" ]] && aws sns delete-topic --topic-arn "$SNS_ARN" --region "$AWS_REGION"

echo "Lambda, EventBridge y SNS eliminados"
```

### 2. Eliminar imágenes y repositorios ECR

```bash
# Eliminar imágenes del repositorio
IMAGE_IDS=$(aws ecr list-images \
  --repository-name lab06-inspector-demo \
  --region "$AWS_REGION" \
  --query 'imageIds' --output json 2>/dev/null || echo "[]")

if [[ "$IMAGE_IDS" != "[]" && -n "$IMAGE_IDS" ]]; then
  aws ecr batch-delete-image \
    --repository-name lab06-inspector-demo \
    --image-ids "$IMAGE_IDS" \
    --region "$AWS_REGION"
fi

# Eliminar repositorios
for REPO in lab06-inspector-demo lab06-basic-scan-demo; do
  aws ecr delete-repository \
    --repository-name "$REPO" \
    --force \
    --region "$AWS_REGION" 2>/dev/null && echo "ECR repo eliminado: $REPO" || true
done
```

### 3. Eliminar instancias EC2

```bash
# Terminar instancias del lab
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Lab,Values=lab06-inspector" \
    "Name=instance-state-name,Values=running,stopped" \
  --region "$AWS_REGION" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text 2>/dev/null)

if [[ -n "$INSTANCE_IDS" ]]; then
  aws ec2 terminate-instances \
    --instance-ids $INSTANCE_IDS \
    --region "$AWS_REGION"
  echo "Instancias terminadas: $INSTANCE_IDS"
fi
```

### 4. Deshabilitar Inspector

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws inspector2 disable \
  --account-ids "$ACCOUNT_ID" \
  --resource-types EC2 ECR \
  --region "$AWS_REGION"

echo "Inspector deshabilitado"
```

### 5. Eliminar IAM Roles

```bash
for ROLE in lab06-ec2-inspector-role lab06-lambda-inspector-role; do
  # Detach policies
  for POLICY_ARN in $(aws iam list-attached-role-policies \
    --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" 2>/dev/null
  done

  # Remove from instance profile
  aws iam remove-role-from-instance-profile \
    --instance-profile-name lab06-ec2-inspector-profile \
    --role-name "$ROLE" 2>/dev/null || true

  aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "Role eliminado: $ROLE" || true
done

aws iam delete-instance-profile \
  --instance-profile-name lab06-ec2-inspector-profile 2>/dev/null || true
```

### Alternativa: Terraform destroy

```bash
cd terraform/
terraform destroy -auto-approve
```

---

## Verificar limpieza

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws inspector2 batch-get-account-status \
  --account-ids "$ACCOUNT_ID" \
  --region "$AWS_REGION" \
  --query 'accounts[0].state' --output text 2>/dev/null && \
  echo "Inspector AÚN activo" || echo "Inspector deshabilitado (correcto)"
```
