# Lab 02.01 — Crear IAM Access Analyzer

> **Coste:** GRATIS siempre | **Región:** eu-west-1 | **Duración:** ~15 minutos

---

## Objetivo

Crear un IAM Access Analyzer a nivel de cuenta y verificar que está activo y analizando recursos.

---

## Paso 1 — Variables de entorno

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ANALYZER_NAME="lab02-account-analyzer"

echo "Account ID: $ACCOUNT_ID"
echo "Región: $AWS_REGION"
```

Output esperado:
```
Account ID: 123456789012
Región: eu-west-1
```

---

## Paso 2 — Crear el Access Analyzer

```bash
aws accessanalyzer create-analyzer \
  --analyzer-name "$ANALYZER_NAME" \
  --type ACCOUNT \
  --region "$AWS_REGION"
```

Output esperado:
```json
{
    "arn": "arn:aws:access-analyzer:eu-west-1:123456789012:analyzer/lab02-account-analyzer"
}
```

**Parámetro `--type`:**
- `ACCOUNT` → zona de confianza = tu cuenta AWS (usamos este en el lab)
- `ORGANIZATION` → zona de confianza = toda la organización (requiere AWS Organizations)

---

## Paso 3 — Verificar que el analyzer está activo

```bash
aws accessanalyzer get-analyzer \
  --analyzer-name "$ANALYZER_NAME" \
  --region "$AWS_REGION"
```

Output esperado:
```json
{
    "analyzer": {
        "arn": "arn:aws:access-analyzer:eu-west-1:123456789012:analyzer/lab02-account-analyzer",
        "name": "lab02-account-analyzer",
        "status": "ACTIVE",
        "type": "ACCOUNT",
        "createdAt": "2026-03-24T10:00:00Z"
    }
}
```

Verificar que `"status": "ACTIVE"`.

---

## Paso 4 — Ver los findings iniciales

Tras crear el analyzer, AWS analiza todos los recursos existentes automáticamente. Puede tardar 1-2 minutos.

```bash
# Listar todos los findings activos
aws accessanalyzer list-findings \
  --analyzer-arn "arn:aws:access-analyzer:${AWS_REGION}:${ACCOUNT_ID}:analyzer/${ANALYZER_NAME}" \
  --filter '{"status": {"eq": ["ACTIVE"]}}' \
  --region "$AWS_REGION" \
  --query 'findings[].{ID:id,Tipo:resourceType,Recurso:resource,Estado:status}' \
  --output table
```

Es normal encontrar findings si tienes recursos con acceso cross-account ya configurado. Si no tienes nada, la tabla saldrá vacía — eso está bien.

---

## Paso 5 — Listar todos los analyzers de la cuenta

```bash
aws accessanalyzer list-analyzers \
  --region "$AWS_REGION" \
  --query 'analyzers[].{Nombre:name,Tipo:type,Estado:status}' \
  --output table
```

Output esperado:
```
-----------------------------------------------------------
|                     ListAnalyzers                       |
+----------------------------+----------+---------+-------+
|         Nombre             |   Tipo   | Estado  |
+----------------------------+----------+---------+-------+
|  lab02-account-analyzer    | ACCOUNT  | ACTIVE  |
+----------------------------+----------+---------+-------+
```

---

## validate.sh

```bash
#!/usr/bin/env bash
# validate.sh — Lab 02.01: IAM Access Analyzer setup

set -euo pipefail

REGION="eu-west-1"
ANALYZER_NAME="lab02-account-analyzer"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ANALYZER_ARN="arn:aws:access-analyzer:${REGION}:${ACCOUNT_ID}:analyzer/${ANALYZER_NAME}"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "=== Lab 02.01 — IAM Access Analyzer Setup ==="

# Verificar que el analyzer existe y está activo
STATUS=$(aws accessanalyzer get-analyzer \
  --analyzer-name "$ANALYZER_NAME" \
  --region "$REGION" \
  --query 'analyzer.status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$STATUS" == "ACTIVE" ]]; then
  pass "Analyzer '$ANALYZER_NAME' existe y está ACTIVE"
else
  fail "Analyzer no encontrado o no está activo (status: $STATUS)"
fi

# Contar findings activos
FINDING_COUNT=$(aws accessanalyzer list-findings \
  --analyzer-arn "$ANALYZER_ARN" \
  --filter '{"status": {"eq": ["ACTIVE"]}}' \
  --region "$REGION" \
  --query 'length(findings)' \
  --output text)

pass "Findings activos encontrados: $FINDING_COUNT"
echo ""
echo "Coste: GRATIS — IAM Access Analyzer no tiene coste adicional"
echo "Para eliminar: aws accessanalyzer delete-analyzer --analyzer-name $ANALYZER_NAME --region $REGION"
```

Guardar como `labs/01-setup/validate.sh` y ejecutar:

```bash
chmod +x validate.sh
./validate.sh
```

---

## Notas

- Access Analyzer es **gratuito** — no hay coste por número de findings, recursos analizados ni tiempo activo
- Solo puede haber **un analyzer por tipo por región** — si intentas crear un segundo de tipo `ACCOUNT` en la misma región, obtendrás error
- El análisis inicial puede tardar hasta 30 minutos para cuentas con muchos recursos
