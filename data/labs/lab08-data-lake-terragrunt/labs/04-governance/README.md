# Lab 04 — Governance: Lake Formation — Column-level y Row-level Security

> **Objetivo:** Configurar permisos granulares con Lake Formation: un analista ve datos anonimizados (sin columna `user_id`), un data scientist ve todo; una query de Athena con un role "analista" no puede acceder a PII aunque tenga permisos S3.
> **Prerequisito:** Labs 01-03 completados. Datos en Glue Catalog disponibles.
> **Coste estimado:** < $0.50 (solo Athena queries).

---

## Conceptos clave

```
Sin Lake Formation:            Con Lake Formation:
  IAM role con s3:GetObject  →   Permisos tabla/columna/fila por identidad
  accede a TODO el bucket        Athena y Glue respetan los permisos LF
                                 aunque el IAM role tenga s3:GetObject

  Analogía: IAM = acceso a la sala del servidor (infraestructura)
            Lake Formation = acceso a filas/columnas específicas en la BD
```

---

## Paso 1: Verificar la configuración de Lake Formation

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Ver los data lake admins configurados
aws lakeformation get-data-lake-settings \
  --region "$REGION" \
  --query 'DataLakeSettings.DataLakeAdmins'

# Ver los recursos registrados (el bucket del data lake)
aws lakeformation list-resources \
  --region "$REGION" \
  --query 'ResourceInfoList[*].{ARN:ResourceArn, Role:RoleArn}'
```

---

## Paso 2: Crear un IAM role "analista" (acceso restringido)

```bash
# Role que simula un analista de negocio (sin acceso a PII)
aws iam create-role \
  --role-name "lab08-analyst-role" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "athena.amazonaws.com"},
      "Action": "sts:AssumeRole"
    },{
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::'"${ACCOUNT_ID}"':root"},
      "Action": "sts:AssumeRole"
    }]
  }' \
  --region "$REGION"

# Permisos básicos de Athena (sin permisos S3 directos — Lake Formation los gestiona)
aws iam attach-role-policy \
  --role-name "lab08-analyst-role" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonAthenaFullAccess"

aws iam put-role-policy \
  --role-name "lab08-analyst-role" \
  --policy-name "lakeformation-data-access" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["lakeformation:GetDataAccess"],
      "Resource": "*"
    },{
      "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:GetBucketLocation","s3:ListBucket"],
      "Resource": ["arn:aws:s3:::lab08-data-lake-dev-data-lake", "arn:aws:s3:::lab08-data-lake-dev-data-lake/*"]
    }]
  }'

ANALYST_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/lab08-analyst-role"
echo "Analyst role ARN: $ANALYST_ROLE_ARN"
```

---

## Paso 3: Otorgar permisos Lake Formation — columnas específicas

```bash
GLUE_DB=$(terragrunt output -raw glue_database_name --terragrunt-working-dir dev/governance 2>/dev/null \
         || echo "lab08_data_lake_dev_catalog")

# Permiso para el analista: acceso a la tabla "raw" pero SIN la columna user_id (PII)
aws lakeformation grant-permissions \
  --principal "DataLakePrincipalIdentifier=${ANALYST_ROLE_ARN}" \
  --permissions "SELECT" \
  --resource '{
    "TableWithColumns": {
      "DatabaseName": "'"${GLUE_DB}"'",
      "Name": "raw",
      "ColumnWildcard": {
        "ExcludedColumnNames": ["user_id"]
      }
    }
  }' \
  --region "$REGION"

echo "Permisos de columna otorgados. El analista NO verá user_id."

# Verificar los permisos otorgados
aws lakeformation list-permissions \
  --principal "DataLakePrincipalIdentifier=${ANALYST_ROLE_ARN}" \
  --region "$REGION" \
  --query 'PrincipalResourcePermissions[*].{Resource:Resource, Permissions:Permissions}'
```

---

## Paso 4: Otorgar permisos completos al data scientist

```bash
DATA_SCIENTIST_ROLE=$(terragrunt output -raw athena_role_arn --terragrunt-working-dir dev/governance 2>/dev/null \
                     || echo "arn:aws:iam::${ACCOUNT_ID}:role/lab08-data-lake-dev-athena-role")

# Permiso completo sobre la tabla (todas las columnas)
aws lakeformation grant-permissions \
  --principal "DataLakePrincipalIdentifier=${DATA_SCIENTIST_ROLE}" \
  --permissions "SELECT" "ALTER" "DESCRIBE" \
  --resource '{
    "Table": {
      "DatabaseName": "'"${GLUE_DB}"'",
      "Name": "raw"
    }
  }' \
  --region "$REGION"

echo "Data scientist tiene acceso completo a la tabla."
```

---

## Paso 5: Probar los permisos — query como "analista"

```bash
NAME_PREFIX="lab08-data-lake-dev"
ATHENA_WG="${NAME_PREFIX}-workgroup"

# Query que intenta acceder a user_id (debería fallar o no devolver la columna)
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT event_id, user_id, event_type FROM \"${GLUE_DB}\".raw LIMIT 5;" \
  --work-group "$ATHENA_WG" \
  --region "$REGION" \
  --query 'QueryExecutionId' \
  --output text)

sleep 8

aws athena get-query-execution \
  --query-execution-id "$QUERY_ID" \
  --region "$REGION" \
  --query '{Status: QueryExecution.Status.State, Error: QueryExecution.Status.StateChangeReason}'
```

Si Lake Formation está correctamente configurado, la query falla con:
```
"Insufficient Lake Formation permission(s) on raw (Service: Glue...)"
```

O devuelve la tabla sin la columna `user_id` si LF está en modo permissive.

---

## Paso 6: Row-level Security — filtrar por region

Lake Formation también soporta RLS mediante Data Filters:

```bash
# Crear un data filter que solo devuelve eventos del año 2024
aws lakeformation create-data-cells-filter \
  --table-data "DatabaseName=${GLUE_DB},Name=raw" \
  --name "only-2024-events" \
  --row-filter '{
    "FilterExpression": "year = 2024"
  }' \
  --column-wildcard '{}' \
  --region "$REGION" 2>/dev/null || echo "Data Cells Filter ya existe o no soportado en esta región"

# Aplicar el filtro al analista
aws lakeformation grant-permissions \
  --principal "DataLakePrincipalIdentifier=${ANALYST_ROLE_ARN}" \
  --permissions "SELECT" \
  --resource '{
    "DataCellsFilter": {
      "TableCatalogId": "'"${ACCOUNT_ID}"'",
      "DatabaseName": "'"${GLUE_DB}"'",
      "TableName": "raw",
      "Name": "only-2024-events"
    }
  }' \
  --region "$REGION" 2>/dev/null || echo "Grant con data filter requiere Lake Formation habilitado en modo Governor"
```

---

## Paso 7: Revocar permisos y auditar

```bash
# Ver historial de acceso (requiere CloudTrail habilitado)
aws logs filter-log-events \
  --log-group-name "aws-lakeformation-logs" \
  --region "$REGION" \
  --filter-pattern "analyst" 2>/dev/null || echo "Log group no disponible"

# Revocar permiso del analista
aws lakeformation revoke-permissions \
  --principal "DataLakePrincipalIdentifier=${ANALYST_ROLE_ARN}" \
  --permissions "SELECT" \
  --resource '{
    "TableWithColumns": {
      "DatabaseName": "'"${GLUE_DB}"'",
      "Name": "raw",
      "ColumnWildcard": {
        "ExcludedColumnNames": ["user_id"]
      }
    }
  }' \
  --region "$REGION"

echo "Permiso revocado."

# Limpiar el IAM role de analista
aws iam detach-role-policy \
  --role-name "lab08-analyst-role" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonAthenaFullAccess" 2>/dev/null || true

aws iam delete-role-policy \
  --role-name "lab08-analyst-role" \
  --policy-name "lakeformation-data-access" 2>/dev/null || true

aws iam delete-role \
  --role-name "lab08-analyst-role" 2>/dev/null || true

echo "Rol analista eliminado."
```

---

## Qué aprendiste

| Concepto | Detalle |
|---|---|
| Lake Formation vs S3 bucket policies | LF controla tabla/columna/fila; S3 solo controla el objeto completo |
| `ColumnWildcard.ExcludedColumnNames` | Excluir columnas PII para un rol; las columnas no aparecen en Athena |
| `Data Cells Filter` | Row-level security: filtrar filas por predicado (ej: `year = 2024`) |
| `lakeformation:GetDataAccess` | Permiso IAM que permite a Athena/Glue llamar a LF para obtener credenciales temporales de S3 |
| Auditoría | Lake Formation envía eventos a CloudTrail; buscar `GetDataAccess` para ver quién accedió a qué |
