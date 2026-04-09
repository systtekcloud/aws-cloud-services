# Cleanup — Lab 08: Data Lake Integrador con Terragrunt

> ⚠️ **CRÍTICO:** Destruir en orden inverso a la creación para evitar errores de dependencias.
> Redshift Serverless cobra aunque no haya queries activas. EMR Serverless para automáticamente, pero el bucket S3 acumula costes si tiene datos.

---

## Opción A: Destruir todo con Terragrunt (recomendado)

```bash
cd data/labs/lab08-data-lake-terragrunt/dev

# Terragrunt resuelve el orden inverso de dependencias automáticamente:
# serving → processing → ingestion → governance → storage
terragrunt run-all destroy

# Confirmar con "yes" cuando lo pida
```

El `run-all destroy` tarda ~10-15 minutos. Verificar que no quedan recursos con la sección de verificación al final.

---

## Opción B: Destruir módulo a módulo (más control)

```bash
BASE="data/labs/lab08-data-lake-terragrunt"

# Orden: de las capas más altas a las más bajas
cd "${BASE}/dev/serving"
terragrunt destroy

cd "${BASE}/dev/processing"
terragrunt destroy

cd "${BASE}/dev/ingestion"
terragrunt destroy

cd "${BASE}/dev/governance"
terragrunt destroy

cd "${BASE}/dev/storage"
terragrunt destroy
```

---

## Opción C: Destruir manualmente

Si Terraform/Terragrunt fallan (por ejemplo, si el state S3 fue eliminado), destruir manualmente en este orden:

### 1. Redshift Serverless

```bash
REGION="eu-west-1"
NAME_PREFIX="lab08-data-lake-dev"

# Eliminar workgroup primero, luego namespace
aws redshift-serverless delete-workgroup \
  --workgroup-name "${NAME_PREFIX}-wg" \
  --region "$REGION" 2>/dev/null && echo "Workgroup eliminado" || true

# Esperar a que el workgroup se elimine (~2-3 min)
echo "Esperando eliminación del workgroup..."
sleep 30

aws redshift-serverless delete-namespace \
  --namespace-name "${NAME_PREFIX}-ns" \
  --region "$REGION" 2>/dev/null && echo "Namespace eliminado" || true
```

### 2. EMR Serverless

```bash
# Listar aplicaciones del lab
APP_IDS=$(aws emr-serverless list-applications \
  --region "$REGION" \
  --query 'applications[?contains(name, `lab08`)].id' \
  --output text)

for APP_ID in $APP_IDS; do
  # Detener la aplicación antes de eliminarla
  aws emr-serverless stop-application \
    --application-id "$APP_ID" \
    --region "$REGION" 2>/dev/null || true

  sleep 10

  aws emr-serverless delete-application \
    --application-id "$APP_ID" \
    --region "$REGION" 2>/dev/null && echo "EMR App $APP_ID eliminada" || true
done
```

### 3. Glue (Jobs, Crawlers, Database)

```bash
GLUE_DB="lab08_data_lake_dev_catalog"

# Eliminar tablas del catálogo
for TABLE in $(aws glue get-tables \
  --database-name "$GLUE_DB" \
  --region "$REGION" \
  --query 'TableList[].Name' \
  --output text 2>/dev/null); do
  aws glue delete-table \
    --database-name "$GLUE_DB" \
    --name "$TABLE" \
    --region "$REGION" 2>/dev/null && echo "Tabla eliminada: $TABLE" || true
done

# Eliminar Jobs
aws glue delete-job \
  --job-name "${NAME_PREFIX}-raw-to-processed" \
  --region "$REGION" 2>/dev/null && echo "Glue Job eliminado" || true

# Eliminar Crawler
aws glue delete-crawler \
  --name "${NAME_PREFIX}-raw-crawler" \
  --region "$REGION" 2>/dev/null && echo "Glue Crawler eliminado" || true

# Eliminar base de datos del catálogo
aws glue delete-database \
  --name "$GLUE_DB" \
  --region "$REGION" 2>/dev/null && echo "Glue Database eliminada" || true
```

### 4. Kinesis (Firehose + KDS)

```bash
# Eliminar Firehose primero
aws firehose delete-delivery-stream \
  --delivery-stream-name "${NAME_PREFIX}-raw-delivery" \
  --region "$REGION" 2>/dev/null && echo "Firehose eliminado" || true

# Eliminar KDS
aws kinesis delete-stream \
  --stream-name "${NAME_PREFIX}-events" \
  --region "$REGION" 2>/dev/null && echo "KDS eliminado" || true
```

### 5. S3 (vaciar y eliminar)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${NAME_PREFIX}-data-lake"
LOGS_BUCKET="${NAME_PREFIX}-access-logs"

for B in "$BUCKET" "$LOGS_BUCKET"; do
  # Eliminar todas las versiones (bucket tiene versioning habilitado)
  aws s3api list-object-versions \
    --bucket "$B" \
    --query '[Versions[*].{Key:Key,VersionId:VersionId}, DeleteMarkers[*].{Key:Key,VersionId:VersionId}]' \
    --output json 2>/dev/null | \
    python3 -c "
import sys, json, subprocess
data = json.load(sys.stdin)
for group in data:
  if group:
    for obj in group:
      subprocess.run(['aws', 's3api', 'delete-object',
        '--bucket', '${B}', '--key', obj['Key'],
        '--version-id', obj['VersionId'],
        '--region', '${REGION}'], capture_output=True)
print('Versiones eliminadas de ${B}')
" 2>/dev/null || true

  # Eliminar objetos corrientes
  aws s3 rm "s3://${B}" --recursive --region "$REGION" 2>/dev/null || true

  # Eliminar el bucket
  aws s3 rb "s3://${B}" --region "$REGION" 2>/dev/null && echo "Bucket eliminado: $B" || true
done
```

### 6. IAM Roles

```bash
for ROLE in \
  "${NAME_PREFIX}-glue-role" \
  "${NAME_PREFIX}-athena-role" \
  "${NAME_PREFIX}-firehose-role" \
  "${NAME_PREFIX}-emr-serverless-role" \
  "${NAME_PREFIX}-redshift-role"; do

  # Desadjuntar políticas managed
  for ARN in $(aws iam list-attached-role-policies \
    --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$ARN" 2>/dev/null || true
  done

  # Eliminar políticas inline
  for POLICY in $(aws iam list-role-policies \
    --role-name "$ROLE" \
    --query 'PolicyNames[]' \
    --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY" 2>/dev/null || true
  done

  aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "Rol eliminado: $ROLE" || true
done
```

### 7. SSM Parameters

```bash
aws ssm delete-parameter \
  --name "/${NAME_PREFIX}/redshift/spectrum-setup-sql" \
  --region "$REGION" 2>/dev/null && echo "SSM Parameter eliminado" || true
```

### 8. Athena Workgroup

```bash
aws athena delete-work-group \
  --work-group "${NAME_PREFIX}-workgroup" \
  --recursive-delete-option \
  --region "$REGION" 2>/dev/null && echo "Athena workgroup eliminado" || true
```

### 9. Lake Formation — desregistrar el bucket

```bash
BUCKET_ARN="arn:aws:s3:::${NAME_PREFIX}-data-lake"
aws lakeformation deregister-resource \
  --resource-arn "$BUCKET_ARN" \
  --region "$REGION" 2>/dev/null && echo "LF resource desregistrado" || true
```

### 10. Remote State (eliminar al final)

```bash
# Vaciar y eliminar el bucket de tfstate
TFSTATE_BUCKET="lab08-data-lake-tfstate-${ACCOUNT_ID}"
aws s3 rm "s3://${TFSTATE_BUCKET}" --recursive --region "$REGION" 2>/dev/null || true
aws s3 rb "s3://${TFSTATE_BUCKET}" --region "$REGION" 2>/dev/null && echo "tfstate bucket eliminado" || true

# Eliminar tabla DynamoDB de locking
aws dynamodb delete-table \
  --table-name "lab08-data-lake-tfstate-lock" \
  --region "$REGION" 2>/dev/null && echo "DynamoDB lock table eliminada" || true
```

---

## Verificación final

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
NAME_PREFIX="lab08-data-lake-dev"

echo "=== Redshift Serverless ==="
aws redshift-serverless list-workgroups --region "$REGION" \
  --query 'workgroups[?contains(workgroupName, `lab08`)].workgroupName'

echo "=== EMR Serverless Applications ==="
aws emr-serverless list-applications --region "$REGION" \
  --query 'applications[?contains(name, `lab08`)].{id:id, name:name, state:state}'

echo "=== Glue Jobs ==="
aws glue get-jobs --region "$REGION" \
  --query 'Jobs[?contains(Name, `lab08`)].Name' 2>/dev/null

echo "=== Glue Crawlers ==="
aws glue list-crawlers --region "$REGION" \
  --query 'CrawlerNames[?contains(@, `lab08`) == `true`]'

echo "=== Kinesis Streams ==="
aws kinesis list-streams --region "$REGION" \
  --query 'StreamNames[?contains(@, `lab08`) == `true`]'

echo "=== Firehose ==="
aws firehose list-delivery-streams --region "$REGION" \
  --query 'DeliveryStreamNames[?contains(@, `lab08`) == `true`]'

echo "=== S3 Buckets ==="
aws s3 ls | grep lab08

echo "=== IAM Roles ==="
aws iam list-roles --query 'Roles[?contains(RoleName, `lab08`)].RoleName' --output text

echo "=== SSM Parameters ==="
aws ssm describe-parameters --region "$REGION" \
  --query 'Parameters[?contains(Name, `lab08`)].Name' 2>/dev/null
```

Todas las listas deben estar vacías.

---

## CloudWatch Log Groups (opcional)

```bash
REGION="eu-west-1"

for LG in \
  "/aws/glue/jobs/lab08-data-lake-dev-raw-to-processed" \
  "/aws/kinesisfirehose/lab08-data-lake-dev-raw-delivery" \
  "/aws-glue/crawlers"; do
  aws logs delete-log-group \
    --log-group-name "$LG" \
    --region "$REGION" 2>/dev/null || true
done

echo "Log groups eliminados."
```
