# Lab 02.03 — Bucket S3 público: finding y remediación

> **Coste:** GRATIS | **Prerrequisito:** lab 02.01 completado (analyzer activo)

---

## Objetivo

Crear un bucket S3 con `Block Public Access` desactivado y una policy que permite `s3:GetObject` a `Principal: *` (internet). Verificar que Access Analyzer genera un finding de tipo público, remediarlo, y comparar con lo que detectaría Macie.

---

## Paso 1 — Crear bucket con BPA desactivado

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ANALYZER_NAME="lab02-account-analyzer"
export ANALYZER_ARN="arn:aws:access-analyzer:${AWS_REGION}:${ACCOUNT_ID}:analyzer/${ANALYZER_NAME}"
export PUBLIC_BUCKET="lab02-public-test-${ACCOUNT_ID}"

# Crear bucket
aws s3api create-bucket \
  --bucket "$PUBLIC_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# Desactivar Block Public Access (necesario para que la policy pública funcione)
aws s3api put-public-access-block \
  --bucket "$PUBLIC_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

echo "Block Public Access desactivado en $PUBLIC_BUCKET"
```

---

## Paso 2 — Aplicar policy que permite acceso desde internet

```bash
cat > /tmp/public-bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${PUBLIC_BUCKET}/*"
    }
  ]
}
EOF

aws s3api put-bucket-policy \
  --bucket "$PUBLIC_BUCKET" \
  --policy file:///tmp/public-bucket-policy.json

echo "Policy pública aplicada"
```

---

## Paso 3 — Forzar análisis y verificar finding

```bash
aws accessanalyzer start-resource-scan \
  --analyzer-arn "$ANALYZER_ARN" \
  --resource-arn "arn:aws:s3:::${PUBLIC_BUCKET}" \
  --region "$AWS_REGION"

sleep 30

# Buscar finding del bucket público
FINDING_ID=$(aws accessanalyzer list-findings \
  --analyzer-arn "$ANALYZER_ARN" \
  --filter "{\"resource\": {\"contains\": [\"${PUBLIC_BUCKET}\"]}, \"status\": {\"eq\": [\"ACTIVE\"]}}" \
  --region "$AWS_REGION" \
  --query 'findings[0].id' \
  --output text)

echo "Finding ID: $FINDING_ID"

# Ver detalle — especialmente el campo isPublic
aws accessanalyzer get-finding \
  --analyzer-arn "$ANALYZER_ARN" \
  --id "$FINDING_ID" \
  --region "$AWS_REGION" \
  --query 'finding.{ID:id,Publico:isPublic,Principal:principal,Accion:action,Estado:status}'
```

Output esperado:
```json
{
    "ID": "a1b2c3d4-...",
    "Publico": true,
    "Principal": {"AWS": "*"},
    "Accion": ["s3:GetObject"],
    "Estado": "ACTIVE"
}
```

El campo `"isPublic": true` indica que el acceso es desde internet (Principal: *), no solo cross-account.

---

## Paso 4 — Remediar: habilitar BPA y eliminar la policy

```bash
# 1. Habilitar Block Public Access
aws s3api put-public-access-block \
  --bucket "$PUBLIC_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 2. Eliminar la bucket policy pública
aws s3api delete-bucket-policy --bucket "$PUBLIC_BUCKET"

# 3. Forzar re-análisis
aws accessanalyzer start-resource-scan \
  --analyzer-arn "$ANALYZER_ARN" \
  --resource-arn "arn:aws:s3:::${PUBLIC_BUCKET}" \
  --region "$AWS_REGION"

sleep 30

# 4. Verificar que el finding está Resolved
aws accessanalyzer get-finding \
  --analyzer-arn "$ANALYZER_ARN" \
  --id "$FINDING_ID" \
  --region "$AWS_REGION" \
  --query 'finding.status' \
  --output text
```

Output esperado: `RESOLVED`

---

## Paso 5 — Limpiar

```bash
aws s3 rb "s3://${PUBLIC_BUCKET}" --force
```

---

## Comparación: Access Analyzer vs Macie para buckets públicos

Ambos servicios pueden detectar un bucket S3 público, pero de formas distintas:

| Aspecto | Access Analyzer | Macie |
|---------|----------------|-------|
| **Qué analiza** | La bucket policy (configuración) | Configuración + contenido del bucket |
| **Tipo de finding** | Finding de acceso externo | `Policy:IAMUser/S3BucketPubliclyAccessible` |
| **Coste** | GRATIS | 30 días free trial, luego de pago |
| **Profundidad** | Solo configuración de acceso | Configuración + clasifica contenido (PII, etc.) |
| **Velocidad** | Minutos tras el cambio | Horas (scan del contenido) |
| **Cuándo usar** | Auditoría de políticas de acceso | Cumplimiento GDPR/PII + configuración |

**Regla SAA-C03:** Si te preguntan "detectar bucket público" → cualquiera de los dos. Si te preguntan "detectar datos sensibles en buckets públicos" → Macie.

---

## Nota sobre `isPublic` vs cross-account

Access Analyzer distingue entre:
- `"isPublic": true` → Principal: * (acceso desde cualquier entidad de internet)
- `"isPublic": false` + principal externo → acceso cross-account específico

Ambos generan findings activos, pero el nivel de urgencia es diferente.
