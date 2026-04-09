# Cleanup — Lab 06: Amazon Redshift

> ⚠️ **CRÍTICO:** Redshift Serverless cobra **$0.36/RPU-hora** mientras el workgroup está activo.
> Con 8 RPU base: $0.36 × 8 = $2.88/hora. **Eliminar inmediatamente tras el lab.**
> El auto-pause ocurre tras ~30 minutos de inactividad, pero la eliminación manual es más segura.

---

## Opción A: Destruir con Terraform

```bash
cd data/labs/lab06-redshift/terraform
terraform destroy -auto-approve
```

---

## Opción B: Destruir manualmente

Orden: external schemas (SQL) → Workgroup → Namespace → S3 → IAM → SG.

### 1. Eliminar external schemas (en Redshift Query Editor v2)

Antes de eliminar el namespace, elimina los schemas externos para evitar referencias huérfanas:

```sql
-- Conectarse al Query Editor v2 y ejecutar:
DROP SCHEMA IF EXISTS spectrum_lab04;

-- Verificar que no quedan external schemas
SELECT schemaname FROM svv_external_schemas;
```

### 2. Eliminar Workgroup

```bash
REGION="eu-west-1"

WG_STATE=$(aws redshift-serverless get-workgroup \
  --workgroup-name lab06-workgroup \
  --region "$REGION" \
  --query 'workgroup.status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$WG_STATE" != "NOT_FOUND" ]]; then
  echo "Eliminando workgroup lab06-workgroup (estado: $WG_STATE)..."
  aws redshift-serverless delete-workgroup \
    --workgroup-name lab06-workgroup \
    --region "$REGION"

  echo "Esperando eliminación del workgroup..."
  while true; do
    WG=$(aws redshift-serverless get-workgroup \
      --workgroup-name lab06-workgroup --region "$REGION" \
      --query 'workgroup.status' --output text 2>/dev/null || echo "DELETED")
    echo "  Estado: $WG"
    [[ "$WG" == "DELETED" ]] && break
    sleep 20
  done
  echo "Workgroup eliminado."
fi
```

### 3. Eliminar Namespace

```bash
REGION="eu-west-1"

NS_STATE=$(aws redshift-serverless get-namespace \
  --namespace-name lab06-namespace \
  --region "$REGION" \
  --query 'namespace.status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$NS_STATE" != "NOT_FOUND" ]]; then
  aws redshift-serverless delete-namespace \
    --namespace-name lab06-namespace \
    --region "$REGION"

  echo "Esperando eliminación del namespace..."
  while true; do
    NS=$(aws redshift-serverless get-namespace \
      --namespace-name lab06-namespace --region "$REGION" \
      --query 'namespace.status' --output text 2>/dev/null || echo "DELETED")
    echo "  Estado: $NS"
    [[ "$NS" == "DELETED" ]] && break
    sleep 15
  done
  echo "Namespace eliminado."
fi
```

### 4. Vaciar y eliminar S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab06-redshift-${ACCOUNT_ID}"

aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
aws s3 rb "s3://$BUCKET" 2>/dev/null && echo "Bucket eliminado: $BUCKET" || true
```

### 5. Eliminar IAM roles

```bash
for ROLE in lab06-redshift-role; do
  for POLICY in $(aws iam list-role-policies --role-name "$ROLE" \
    --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY" 2>/dev/null || true
  done
  for ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$ARN" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "Rol eliminado: $ROLE" || true
done
```

### 6. Eliminar Security Group

```bash
REGION="eu-west-1"

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lab06-redshift-sg" \
  --region "$REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

[[ -n "$SG_ID" && "$SG_ID" != "None" ]] && \
  aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" \
  && echo "Security Group eliminado" || true
```

---

## Verificación final

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Redshift Serverless Workgroups ==="
aws redshift-serverless list-workgroups --region "$REGION" \
  --query 'workgroups[?contains(workgroupName, `lab06`)].{Name:workgroupName,Status:status}'

echo "=== Redshift Serverless Namespaces ==="
aws redshift-serverless list-namespaces --region "$REGION" \
  --query 'namespaces[?contains(namespaceName, `lab06`)].{Name:namespaceName,Status:status}'

echo "=== S3 Buckets ==="
aws s3 ls | grep lab06-redshift

echo "=== IAM Roles ==="
aws iam list-roles --query 'Roles[?contains(RoleName, `lab06`)].RoleName'
```

Todas las listas deben estar vacías.

---

## Athena workgroup del lab (si se creó)

```bash
REGION="eu-west-1"

aws athena delete-work-group \
  --work-group lab06-athena-compare \
  --recursive-delete-option \
  --region "$REGION" 2>/dev/null || true
```
