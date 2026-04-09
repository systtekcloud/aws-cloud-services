# Lab 03 — Lake Formation: gobierno del data lake

> **Duración estimada:** 25 minutos | **Coste estimado:** ~$0 (Lake Formation no tiene coste propio)

---

## Objetivo

Habilitar Lake Formation, registrar el S3 bucket como data lake location, configurar permisos granulares por usuario, y verificar que Athena respeta esos permisos.

---

## Prerequisitos

- Labs 01 y 02 completados (base de datos `lab04_ecommerce` + tablas en Glue Catalog)
- Usuario IAM con permisos de administrador de Lake Formation

---

## Paso 1: Habilitar Lake Formation y configurar el admin

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
USER_ARN=$(aws sts get-caller-identity --query Arn --output text)

# Registrar el usuario actual como Lake Formation admin
aws lakeformation put-data-lake-settings \
  --data-lake-settings "{
    \"DataLakeAdmins\": [{\"DataLakePrincipalIdentifier\": \"$USER_ARN\"}],
    \"CreateDatabaseDefaultPermissions\": [],
    \"CreateTableDefaultPermissions\": []
  }" \
  --region "$REGION"

echo "Lake Formation admin configurado: $USER_ARN"

# Verificar
aws lakeformation get-data-lake-settings \
  --region "$REGION" \
  --query 'DataLakeSettings.DataLakeAdmins[].DataLakePrincipalIdentifier'
```

> **Importante:** Al vaciar `CreateDatabaseDefaultPermissions` y `CreateTableDefaultPermissions`, deshabilitas los permisos IAM implícitos sobre el Catalog. Desde este momento, Lake Formation es el único punto de control de acceso para los recursos registrados.

---

## Paso 2: Registrar S3 bucket como data lake location

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
PROCESSED_BUCKET="lab04-glue-processed-${ACCOUNT_ID}"

# Crear rol de servicio para Lake Formation
cat > /tmp/lf-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lakeformation.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lab04-lakeformation-service-role \
  --assume-role-policy-document file:///tmp/lf-trust.json 2>/dev/null || true

aws iam attach-role-policy \
  --role-name lab04-lakeformation-service-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true

LF_ROLE=$(aws iam get-role \
  --role-name lab04-lakeformation-service-role \
  --query 'Role.Arn' --output text)

# Registrar el bucket procesado como data lake location
aws lakeformation register-resource \
  --resource-arn "arn:aws:s3:::$PROCESSED_BUCKET" \
  --use-service-linked-role \
  --region "$REGION" 2>/dev/null || \
aws lakeformation register-resource \
  --resource-arn "arn:aws:s3:::$PROCESSED_BUCKET" \
  --role-arn "$LF_ROLE" \
  --region "$REGION"

echo "Bucket registrado en Lake Formation: $PROCESSED_BUCKET"

# Verificar recursos registrados
aws lakeformation list-resources \
  --region "$REGION" \
  --query 'ResourceInfoList[].{Resource:ResourceArn,Role:RoleArn}'
```

---

## Paso 3: Crear usuarios IAM de prueba

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

# Usuario A: analista — solo puede ver tablas procesadas (no raw)
aws iam create-user --user-name lab04-analyst-user 2>/dev/null || true

cat > /tmp/analyst-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase",
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetPartitions",
        "lakeformation:GetDataAccess"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "athena:StartQueryExecution",
        "athena:GetQueryExecution",
        "athena:GetQueryResults",
        "athena:StopQueryExecution"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket", "s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::lab04-glue-results-$ACCOUNT_ID",
        "arn:aws:s3:::lab04-glue-results-$ACCOUNT_ID/*"
      ]
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name lab04-analyst-user \
  --policy-name lab04-analyst-policy \
  --policy-document file:///tmp/analyst-policy.json

ANALYST_ARN=$(aws iam get-user \
  --user-name lab04-analyst-user \
  --query 'User.Arn' --output text)

echo "Analista ARN: $ANALYST_ARN"
```

---

## Paso 4: Configurar permisos Lake Formation por usuario

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

ANALYST_ARN=$(aws iam get-user \
  --user-name lab04-analyst-user \
  --query 'User.Arn' --output text)

# Obtener el nombre de la tabla Parquet
PARQUET_TABLE=$(aws glue get-tables \
  --database-name lab04_ecommerce --region "$REGION" \
  --query "TableList[?contains(StorageDescriptor.Location, 'processed')].Name" \
  --output text 2>/dev/null || echo "sales")

echo "Tabla Parquet: $PARQUET_TABLE"

# Permisos del analista: SELECT sobre tabla procesada, SIN acceso a columna unit_price (precio de coste)
aws lakeformation grant-permissions \
  --principal "DataLakePrincipalIdentifier=$ANALYST_ARN" \
  --resource "{
    \"TableWithColumns\": {
      \"DatabaseName\": \"lab04_ecommerce\",
      \"Name\": \"$PARQUET_TABLE\",
      \"ColumnWildcard\": {
        \"ExcludedColumnNames\": [\"unit_price\"]
      }
    }
  }" \
  --permissions SELECT \
  --region "$REGION"

# El analista NO tiene permisos sobre la tabla CSV raw
# (no se le otorga nada para 'sales' raw)

echo "Permisos configurados:"
aws lakeformation list-permissions \
  --principal "DataLakePrincipalIdentifier=$ANALYST_ARN" \
  --region "$REGION" \
  --query 'PrincipalResourcePermissions[].{Resource:Resource,Permissions:Permissions}'
```

---

## Paso 5: Verificar que Athena respeta los permisos

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
PARQUET_TABLE=$(aws glue get-tables \
  --database-name lab04_ecommerce --region "$REGION" \
  --query "TableList[?contains(StorageDescriptor.Location, 'processed')].Name" \
  --output text 2>/dev/null || echo "sales")

# Con tu usuario actual (admin) — funciona todo
echo "=== Query como admin (todas las columnas) ==="
ADMIN_QUERY=$(aws athena start-query-execution \
  --query-string "SELECT order_id, category, unit_price, total FROM lab04_ecommerce.$PARQUET_TABLE LIMIT 3" \
  --work-group lab04-workgroup \
  --region "$REGION" \
  --query 'QueryExecutionId' --output text)
sleep 5
aws athena get-query-results \
  --query-execution-id "$ADMIN_QUERY" --region "$REGION" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' --output table

# Verificar que unit_price está visible para el admin
echo ""
echo "El admin ve 'unit_price'. El analista (lab04-analyst-user) tendría"
echo "acceso denegado a esa columna si ejecutara la misma query."
echo ""
echo "Para simular el acceso del analista, crea credenciales temporales:"
echo "  aws iam create-access-key --user-name lab04-analyst-user"
echo "  AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... aws athena start-query-execution \\"
echo "    --query-string \"SELECT order_id, unit_price FROM lab04_ecommerce.$PARQUET_TABLE LIMIT 1\" \\"
echo "    --work-group lab04-workgroup --region $REGION"
echo "  → Debería devolver error de permisos en 'unit_price'"
```

---

## Lake Formation vs S3 Bucket Policies — diferencia clave

```
S3 Bucket Policy:
  Controla ACCESO AL OBJETO S3.
  Si tienes s3:GetObject sobre el bucket → puedes leer el archivo físico.
  No sabe qué tabla, qué columna, qué fila estás leyendo.

Lake Formation:
  Controla ACCESO LÓGICO a través de servicios analíticos (Athena, EMR, Glue).
  Puede denegar acceso a una columna específica sin bloquear el archivo en S3.
  Registra en CloudTrail qué tabla/columna se accedió y por quién.

Ejemplo:
  - Con S3 policy puedes bloquear el bucket entero.
  - Con Lake Formation puedes decir "el analista puede ver sales pero no la columna unit_price".

Para datos PII (emails, tarjetas de crédito, salarios):
  → Lake Formation column-level security es la solución correcta en AWS.
```

---

## Limpieza

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROCESSED_BUCKET="lab04-glue-processed-${ACCOUNT_ID}"
ANALYST_ARN=$(aws iam get-user --user-name lab04-analyst-user --query 'User.Arn' --output text 2>/dev/null || echo "")

# Revocar permisos Lake Formation
[[ -n "$ANALYST_ARN" ]] && aws lakeformation revoke-permissions \
  --principal "DataLakePrincipalIdentifier=$ANALYST_ARN" \
  --resource "{\"Database\":{\"Name\":\"lab04_ecommerce\"}}" \
  --permissions ALL \
  --region "$REGION" 2>/dev/null || true

# Deregistrar recurso S3
aws lakeformation deregister-resource \
  --resource-arn "arn:aws:s3:::$PROCESSED_BUCKET" \
  --region "$REGION" 2>/dev/null || true

# Eliminar usuario IAM
for KEY in $(aws iam list-access-keys --user-name lab04-analyst-user \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
  aws iam delete-access-key --user-name lab04-analyst-user --access-key-id "$KEY"
done
aws iam delete-user-policy --user-name lab04-analyst-user --policy-name lab04-analyst-policy 2>/dev/null || true
aws iam delete-user --user-name lab04-analyst-user 2>/dev/null || true
```
