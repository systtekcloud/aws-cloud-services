# Lab 07.03 — Findings de tipo Policy

> **Coste:** GRATIS (free trial) | **Prerrequisito:** lab 07.01 completado

---

## Objetivo

Crear un bucket S3 con Block Public Access deshabilitado y política `Allow Principal: *`, verificar el finding `Policy:IAMUser/S3BucketPubliclyAccessible`, documentar la diferencia crítica con `SensitiveData:`, y remediar la configuración.

---

## Paso 1 — Crear bucket público (configuración insegura intencional)

```bash
export AWS_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PUBLIC_BUCKET="lab07-macie-public-${ACCOUNT_ID}"

# Crear bucket
aws s3api create-bucket \
  --bucket "$PUBLIC_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

echo "Bucket creado: $PUBLIC_BUCKET"
```

```bash
# DESHABILITAR Block Public Access (necesario para el finding)
aws s3api put-public-access-block \
  --bucket "$PUBLIC_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

echo "Block Public Access deshabilitado (configuración insegura intencional para el lab)"
```

```bash
# Aplicar bucket policy que permite acceso público a s3:GetObject
aws s3api put-bucket-policy \
  --bucket "$PUBLIC_BUCKET" \
  --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"PublicReadGetObject\",
      \"Effect\": \"Allow\",
      \"Principal\": \"*\",
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::${PUBLIC_BUCKET}/*\"
    }]
  }"

echo "Bucket policy aplicada: Principal=* puede leer objetos"
echo "Macie detectará esto como Policy:IAMUser/S3BucketPubliclyAccessible en los próximos minutos"
```

---

## Paso 2 — Verificar el finding de Macie

```bash
# Macie chequea periódicamente la configuración de buckets
# Puede tardar hasta 15 minutos en generar el finding

echo "Esperando finding de Macie (puede tardar 5-15 min)..."
echo "Ejecuta este comando para verificar:"
echo ""
echo "aws macie2 list-findings \\"
echo "  --finding-criteria '{\"criterion\": {\"type\": {\"eq\": [\"Policy:IAMUser/S3BucketPubliclyAccessible\"]}}}' \\"
echo "  --region $AWS_REGION --query 'findingIds' --output table"
```

```bash
# Cuando aparezca el finding, ver el detalle
FINDING_ID=$(aws macie2 list-findings \
  --finding-criteria '{
    "criterion": {
      "type": {"eq": ["Policy:IAMUser/S3BucketPubliclyAccessible"]}
    }
  }' \
  --region "$AWS_REGION" \
  --query 'findingIds[0]' --output text 2>/dev/null)

if [[ -n "$FINDING_ID" && "$FINDING_ID" != "None" ]]; then
  aws macie2 get-findings \
    --finding-ids "$FINDING_ID" \
    --region "$AWS_REGION" \
    --query 'findings[0].{
      Tipo:type,
      Categoria:category,
      Severidad:severity.description,
      Bucket:resourcesAffected.s3Bucket.name,
      BucketPublico:resourcesAffected.s3Bucket.publicAccess.effectivePermission
    }' \
    --output json
fi
```

---

## La diferencia clave: Policy: vs SensitiveData:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Tienes DOS problemas en un bucket:                                          │
│                                                                              │
│  PROBLEMA 1:                           PROBLEMA 2:                           │
│  El bucket está PÚBLICAMENTE           El bucket CONTIENE datos PII          │
│  ACCESIBLE                                                                   │
│                                                                              │
│  Finding que genera Macie:            Finding que genera Macie:              │
│  Policy:IAMUser/                      SensitiveData:S3Object/Personal        │
│  S3BucketPubliclyAccessible                                                  │
│                                                                              │
│  Categoría: POLICY                    Categoría: SENSITIVE_INFORMATION       │
│                                                                              │
│  ¿Qué debes remediar?                 ¿Qué debes remediar?                  │
│  → La CONFIGURACIÓN del bucket        → El CONTENIDO del objeto              │
│    · Habilitar Block Public Access      · Cifrar el objeto                   │
│    · Eliminar política pública          · Restringir acceso                  │
│    · Revisar ACLs                       · Mover a bucket privado             │
│                                         · Eliminar si no es necesario        │
│                                                                              │
│  Macie puede generar AMBOS findings   Fixing uno NO arregla el otro          │
│  para el mismo bucket si tiene los    Si habilitas BPA pero el objeto sigue  │
│  dos problemas a la vez               teniendo PII → sigue habiendo          │
│                                       SensitiveData finding                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Paso 3 — Remediar la configuración del bucket

```bash
# REMEDIAR: habilitar Block Public Access
aws s3api put-public-access-block \
  --bucket "$PUBLIC_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "Block Public Access habilitado"
```

```bash
# REMEDIAR: eliminar la bucket policy pública
aws s3api delete-bucket-policy --bucket "$PUBLIC_BUCKET"

echo "Bucket policy eliminada"
echo "El finding Policy:IAMUser/S3BucketPubliclyAccessible se resolverá en los próximos minutos"
```

```bash
# Verificar que el finding se resuelve automáticamente
# (Macie re-evalúa y cierra el finding cuando la configuración se corrige)
aws macie2 list-findings \
  --finding-criteria '{
    "criterion": {
      "type": {"eq": ["Policy:IAMUser/S3BucketPubliclyAccessible"]},
      "resourcesAffected.s3Bucket.name": {"eq": ["'"$PUBLIC_BUCKET"'"]}
    }
  }' \
  --region "$AWS_REGION" \
  --query 'findingIds' \
  --output table
```

---

## Paso 4 — Finding Policy: de cifrado deshabilitado

```bash
# Crear bucket sin cifrado por defecto para generar otro tipo de Policy: finding
UNENCRYPTED_BUCKET="lab07-macie-unencrypted-${ACCOUNT_ID}"

aws s3api create-bucket \
  --bucket "$UNENCRYPTED_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

echo "Bucket creado sin cifrado: $UNENCRYPTED_BUCKET"
echo "Macie generará: Policy:IAMUser/S3BucketEncryptionDisabled"
echo "(puede tardar 5-15 minutos)"
```

```bash
# Remediar: habilitar cifrado SSE-S3
aws s3api put-bucket-encryption \
  --bucket "$UNENCRYPTED_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

echo "Cifrado habilitado: SSE-S3 (AES256)"
```

---

## Resumen: todos los tipos de findings Policy:

| Finding | Causa | Remediación |
|---------|-------|------------|
| `Policy:IAMUser/S3BucketPubliclyAccessible` | BPA off + policy pública | Habilitar BPA + eliminar policy pública |
| `Policy:IAMUser/S3BucketEncryptionDisabled` | Sin SSE configurado | Habilitar SSE-S3 o SSE-KMS |
| `Policy:IAMUser/S3BucketSharedExternally` | Acceso desde otra cuenta AWS | Revisar bucket policy cross-account |
| `Policy:IAMUser/S3BucketReplicatedExternally` | Replicación a cuenta externa | Verificar si la replicación es intencional |

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| Finding `Policy:` → ¿qué remediar? | La **CONFIGURACIÓN** del bucket (BPA, cifrado, policy) |
| ¿Macie puede generar dos findings para el mismo bucket? | **Sí** — uno `Policy:` y uno `SensitiveData:` son independientes |
| ¿Se resuelve automáticamente al remediar? | **Sí** — Macie re-evalúa y cierra el finding |
| ¿`Policy:` es lo mismo que Access Analyzer? | No — Access Analyzer analiza permisos efectivos IAM, Macie analiza configuración del bucket |
