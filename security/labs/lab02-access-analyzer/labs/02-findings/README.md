# Lab 02.02 — Generar y gestionar findings

> **Coste:** GRATIS | **Prerrequisito:** lab 02.01 completado (analyzer activo)

---

## Objetivo

Crear un S3 bucket con una bucket policy que permite acceso desde otra cuenta AWS, verificar que Access Analyzer genera un finding, y gestionar ese finding (archive + remediation).

---

## Paso 1 — Crear bucket S3 con acceso cross-account

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET_NAME="lab02-access-analyzer-test-${ACCOUNT_ID}"
export EXTERNAL_ACCOUNT="111122223333"  # cuenta externa ficticia

# Crear el bucket
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
```

Output esperado:
```json
{
    "Location": "http://lab02-access-analyzer-test-123456789012.s3.amazonaws.com/"
}
```

---

## Paso 2 — Aplicar bucket policy con acceso cross-account

```bash
# Crear bucket policy que permite acceso desde cuenta externa
cat > /tmp/bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CrossAccountRead",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${EXTERNAL_ACCOUNT}:root"
      },
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ]
    }
  ]
}
EOF

aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy file:///tmp/bucket-policy.json
```

---

## Paso 3 — Forzar re-análisis y esperar el finding

Access Analyzer analiza recursos cuando detecta cambios de política. Puedes forzar un análisis:

```bash
ANALYZER_NAME="lab02-account-analyzer"
ANALYZER_ARN="arn:aws:access-analyzer:${AWS_REGION}:${ACCOUNT_ID}:analyzer/${ANALYZER_NAME}"

# Forzar análisis del bucket
aws accessanalyzer start-resource-scan \
  --analyzer-arn "$ANALYZER_ARN" \
  --resource-arn "arn:aws:s3:::${BUCKET_NAME}" \
  --region "$AWS_REGION"

echo "Esperando 30 segundos para que el análisis complete..."
sleep 30
```

---

## Paso 4 — Ver el finding generado

```bash
# Listar findings del bucket
aws accessanalyzer list-findings \
  --analyzer-arn "$ANALYZER_ARN" \
  --filter "{\"resourceType\": {\"eq\": [\"AWS::S3::Bucket\"]}, \"status\": {\"eq\": [\"ACTIVE\"]}}" \
  --region "$AWS_REGION" \
  --query 'findings[].{ID:id,Recurso:resource,Principal:principal,Accion:action,Estado:status}' \
  --output table
```

Output esperado (finding activo):
```
-----------------------------------------------------------------------
|                           ListFindings                              |
+--------------------------------------+-----------------------------+
| ID     | a1b2c3d4-...               |                             |
| Recurso| arn:aws:s3:::lab02-...      |                             |
| Estado | ACTIVE                     |                             |
-----------------------------------------------------------------------
```

Obtener el ID del finding para los siguientes pasos:

```bash
FINDING_ID=$(aws accessanalyzer list-findings \
  --analyzer-arn "$ANALYZER_ARN" \
  --filter "{\"resourceType\": {\"eq\": [\"AWS::S3::Bucket\"]}, \"status\": {\"eq\": [\"ACTIVE\"]}}" \
  --region "$AWS_REGION" \
  --query 'findings[0].id' \
  --output text)

echo "Finding ID: $FINDING_ID"
```

---

## Paso 5 — Ver el detalle del finding

```bash
aws accessanalyzer get-finding \
  --analyzer-arn "$ANALYZER_ARN" \
  --id "$FINDING_ID" \
  --region "$AWS_REGION"
```

Output esperado:
```json
{
    "finding": {
        "id": "a1b2c3d4-...",
        "principal": {
            "AWS": "arn:aws:iam::111122223333:root"
        },
        "action": ["s3:GetObject", "s3:ListBucket"],
        "resource": "arn:aws:s3:::lab02-access-analyzer-test-123456789012",
        "resourceType": "AWS::S3::Bucket",
        "status": "ACTIVE",
        "isPublic": false
    }
}
```

El finding muestra exactamente:
- **quién** tiene acceso (`principal`)
- **qué puede hacer** (`action`)
- **sobre qué recurso** (`resource`)

---

## Paso 6 — Archivar el finding (acceso intencionado)

Supongamos que este acceso es legítimo (ej: cuenta de un partner autorizado):

```bash
aws accessanalyzer update-findings \
  --analyzer-arn "$ANALYZER_ARN" \
  --ids "$FINDING_ID" \
  --status ARCHIVED \
  --region "$AWS_REGION"

echo "Finding archivado. Verificando..."

aws accessanalyzer get-finding \
  --analyzer-arn "$ANALYZER_ARN" \
  --id "$FINDING_ID" \
  --region "$AWS_REGION" \
  --query 'finding.status' \
  --output text
```

Output esperado: `ARCHIVED`

---

## Paso 7 — Remediar (eliminar el acceso externo)

Si el acceso era un error, eliminamos la bucket policy:

```bash
# Eliminar la bucket policy que daba acceso externo
aws s3api delete-bucket-policy --bucket "$BUCKET_NAME"

# Forzar re-análisis
aws accessanalyzer start-resource-scan \
  --analyzer-arn "$ANALYZER_ARN" \
  --resource-arn "arn:aws:s3:::${BUCKET_NAME}" \
  --region "$AWS_REGION"

sleep 30

# Verificar que el finding pasó a Resolved automáticamente
aws accessanalyzer get-finding \
  --analyzer-arn "$ANALYZER_ARN" \
  --id "$FINDING_ID" \
  --region "$AWS_REGION" \
  --query 'finding.status' \
  --output text
```

Output esperado: `RESOLVED`

Access Analyzer actualiza el estado automáticamente cuando detecta que el acceso externo fue eliminado.

---

## Paso 8 — Limpiar el bucket

```bash
aws s3 rb "s3://${BUCKET_NAME}" --force
```

---

## Resumen: Archive vs Resolved

| Acción | Cuándo | Cómo |
|--------|--------|------|
| **Archive** | Acceso intencionado y documentado | `update-findings --status ARCHIVED` |
| **Resolved** | Acceso eliminado (automático) | Eliminar la política → Access Analyzer lo detecta |

No puedes marcar manualmente un finding como `RESOLVED` — solo se resuelve automáticamente cuando el acceso externo desaparece.
