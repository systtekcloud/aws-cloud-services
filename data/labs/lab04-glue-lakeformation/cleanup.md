# Cleanup — Lab 04: Glue + Lake Formation

> Eliminar en orden correcto.
> **Coste si se olvida:** Glue Jobs y Crawlers no generan coste en reposo. Los buckets S3 generan coste mínimo por almacenamiento.

---

## Opción A: Destruir con Terraform

```bash
cd data/labs/lab04-glue-lakeformation/terraform
terraform destroy -auto-approve
```

---

## Opción B: Destruir manualmente

Orden: Lake Formation → Glue Jobs → Crawlers → Glue Catalog → Athena → S3 → IAM.

### 1. Revocar permisos y deregistrar recursos Lake Formation

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROCESSED_BUCKET="lab04-glue-processed-${ACCOUNT_ID}"
ANALYST_ARN=$(aws iam get-user --user-name lab04-analyst-user \
  --query 'User.Arn' --output text 2>/dev/null || echo "")

# Revocar permisos del analista
if [[ -n "$ANALYST_ARN" && "$ANALYST_ARN" != "None" ]]; then
  # Listar y revocar todos los permisos del analista
  aws lakeformation list-permissions \
    --principal "DataLakePrincipalIdentifier=$ANALYST_ARN" \
    --region "$REGION" \
    --query 'PrincipalResourcePermissions[]' \
    --output json 2>/dev/null | \
  jq -c '.[]' | while read -r perm; do
    RESOURCE=$(echo "$perm" | jq -c '.Resource')
    PERMS=$(echo "$perm" | jq -r '[.Permissions[]] | join(",")' | tr ',' '\n' | jq -R . | jq -s .)
    aws lakeformation revoke-permissions \
      --principal "DataLakePrincipalIdentifier=$ANALYST_ARN" \
      --resource "$RESOURCE" \
      --permissions $(echo "$perm" | jq -r '.Permissions[]') \
      --region "$REGION" 2>/dev/null || true
  done
fi

# Deregistrar S3
aws lakeformation deregister-resource \
  --resource-arn "arn:aws:s3:::$PROCESSED_BUCKET" \
  --region "$REGION" 2>/dev/null && echo "S3 deregistrado de Lake Formation" || true
```

### 2. Eliminar usuario IAM analista

```bash
ANALYST_NAME="lab04-analyst-user"

for KEY in $(aws iam list-access-keys --user-name "$ANALYST_NAME" \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
  aws iam delete-access-key --user-name "$ANALYST_NAME" --access-key-id "$KEY"
done

for POLICY in $(aws iam list-user-policies --user-name "$ANALYST_NAME" \
  --query 'PolicyNames[]' --output text 2>/dev/null); do
  aws iam delete-user-policy --user-name "$ANALYST_NAME" --policy-name "$POLICY"
done

aws iam delete-user --user-name "$ANALYST_NAME" 2>/dev/null && echo "Usuario eliminado" || true
```

### 3. Eliminar Glue Jobs

```bash
REGION="eu-west-1"

for JOB in lab04-csv-to-parquet; do
  aws glue delete-job --job-name "$JOB" --region "$REGION" 2>/dev/null && echo "Job eliminado: $JOB" || true
done
```

### 4. Eliminar Crawlers

```bash
REGION="eu-west-1"

for CRAWLER in lab04-sales-crawler lab04-parquet-crawler; do
  # Parar si está corriendo
  aws glue stop-crawler --name "$CRAWLER" --region "$REGION" 2>/dev/null || true
  sleep 5
  aws glue delete-crawler --name "$CRAWLER" --region "$REGION" 2>/dev/null && echo "Crawler eliminado: $CRAWLER" || true
done
```

### 5. Eliminar tablas y base de datos en Glue Catalog

```bash
REGION="eu-west-1"

# Eliminar todas las tablas primero
for TABLE in $(aws glue get-tables --database-name lab04_ecommerce --region "$REGION" \
  --query 'TableList[].Name' --output text 2>/dev/null); do
  aws glue delete-table --database-name lab04_ecommerce --name "$TABLE" \
    --region "$REGION" 2>/dev/null && echo "Tabla eliminada: $TABLE" || true
done

aws glue delete-database --name lab04_ecommerce --region "$REGION" 2>/dev/null && echo "Base de datos eliminada" || true
```

### 6. Eliminar Athena workgroup

```bash
REGION="eu-west-1"

# Mover las queries del workgroup al primario antes de eliminar
aws athena delete-work-group \
  --work-group lab04-workgroup \
  --recursive-delete-option \
  --region "$REGION" 2>/dev/null && echo "Athena workgroup eliminado" || true
```

### 7. Vaciar y eliminar buckets S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

for BUCKET in \
  "lab04-glue-raw-${ACCOUNT_ID}" \
  "lab04-glue-processed-${ACCOUNT_ID}" \
  "lab04-glue-results-${ACCOUNT_ID}"; do
  aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
  aws s3 rb "s3://$BUCKET" 2>/dev/null && echo "Bucket eliminado: $BUCKET" || true
done
```

### 8. Eliminar roles IAM

```bash
for ROLE in lab04-glue-crawler-role lab04-lakeformation-service-role; do
  # Desadjuntar políticas managed
  for POLICY_ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  done
  # Eliminar políticas inline
  for POLICY_NAME in $(aws iam list-role-policies --role-name "$ROLE" \
    --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY_NAME" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "Rol eliminado: $ROLE" || true
done
```

---

## Verificación final

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Glue Databases ==="
aws glue get-databases --region "$REGION" \
  --query 'DatabaseList[?contains(Name, `lab04`)].Name'

echo "=== Glue Crawlers ==="
aws glue list-crawlers --region "$REGION" \
  --query 'CrawlerNames[?contains(@, `lab04`) == `true`]'

echo "=== Glue Jobs ==="
aws glue list-jobs --region "$REGION" \
  --query 'JobNames[?contains(@, `lab04`) == `true`]'

echo "=== S3 Buckets ==="
aws s3 ls | grep lab04-glue

echo "=== IAM Roles ==="
aws iam list-roles --query 'Roles[?contains(RoleName, `lab04`)].RoleName'

echo "=== IAM Users ==="
aws iam list-users --query 'Users[?contains(UserName, `lab04`)].UserName'

echo "=== Athena Workgroups ==="
aws athena list-work-groups --region "$REGION" \
  --query 'WorkGroups[?contains(Name, `lab04`)].Name'
```

Todas las listas deben estar vacías.
