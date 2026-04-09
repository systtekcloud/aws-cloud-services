# Lab 07.01 — Habilitar Amazon Macie

> **Coste:** GRATIS durante 30 días de free trial | **Sin prerrequisitos**

---

## Objetivo

Habilitar Macie, explorar Automated Discovery, y crear un bucket S3 de prueba para los labs siguientes.

---

## Paso 1 — Habilitar Macie

```bash
export AWS_REGION="eu-west-1"

# Habilitar Macie
aws macie2 enable-macie \
  --finding-publishing-frequency FIFTEEN_MINUTES \
  --status ENABLED \
  --region "$AWS_REGION"

echo "Macie habilitado"
```

```bash
# Verificar estado
aws macie2 get-macie-session \
  --region "$AWS_REGION" \
  --query '{Estado:status,Frecuencia:findingPublishingFrequency,CreadoEn:createdAt}' \
  --output table
```

---

## Paso 2 — Crear bucket S3 de prueba

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="lab07-macie-demo-${ACCOUNT_ID}"

# Crear bucket
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# Habilitar cifrado por defecto
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Activar versionado
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

echo "Bucket creado: $BUCKET_NAME"
```

---

## Paso 3 — Explorar Automated Discovery

```bash
# Ver el estado de Automated Discovery
aws macie2 get-automated-discovery-configuration \
  --region "$AWS_REGION" \
  --query '{Estado:status,Actualizado:lastUpdatedAt}' \
  --output table 2>/dev/null || echo "Automated Discovery configurando..."
```

```bash
# Listar buckets que Macie está monitorizando
aws macie2 describe-buckets \
  --region "$AWS_REGION" \
  --query 'buckets[].{Bucket:bucketName,Objetos:objectCount,Sensible:sensitiveDataOccurrences}' \
  --output table 2>/dev/null || echo "Aún cargando el inventario de buckets (puede tardar 5-10 min)"
```

```bash
# Ver el inventario de datos sensibles (si existe tras Automated Discovery)
aws macie2 get-sensitive-data-occurrences-availability \
  --finding-id "dummy" \
  --region "$AWS_REGION" 2>/dev/null || \
  echo "INFO: Automated Discovery necesita tiempo para construir el inventario inicial"
```

---

## validate.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="lab07-macie-demo-${ACCOUNT_ID}"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "=== Lab 07.01 — Macie Setup ==="

# Verificar que Macie está habilitado
STATUS=$(aws macie2 get-macie-session \
  --region "$REGION" \
  --query 'status' --output text 2>/dev/null || echo "DISABLED")

if [[ "$STATUS" == "ENABLED" ]]; then
  pass "Macie habilitado"
else
  fail "Macie no está habilitado (estado: $STATUS)"
fi

# Verificar bucket de prueba
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
  pass "Bucket de prueba existe: $BUCKET_NAME"
else
  fail "Bucket de prueba no encontrado: $BUCKET_NAME"
fi

echo "Macie activo. Free trial: 30 días desde activación."
echo "Bucket de lab: s3://$BUCKET_NAME"
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Macie solo analiza S3? | **Sí** — no analiza RDS, EFS, DynamoDB |
| ¿Qué es Automated Discovery? | Escaneo continuo con sampling inteligente |
| ¿Diferencia con Discovery Jobs? | Jobs = exhaustivo/manual. Automated = continuo/sampling |
| ¿Cuánto cuesta Macie? | GRATIS 30 días de free trial |
