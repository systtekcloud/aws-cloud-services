# Cleanup — Lab 02: IAM Access Analyzer

> ℹ️ **IAM Access Analyzer es GRATIS** — no hay coste residual por dejarlo activo.
> Aun así, eliminar los recursos de prueba mantiene la cuenta limpia.

---

## Recursos creados en este lab

| Recurso | Nombre | Coste |
|---------|--------|-------|
| IAM Access Analyzer | lab02-account-analyzer | GRATIS |
| S3 Bucket (cross-account) | lab02-access-analyzer-\<ACCOUNT_ID\> | GRATIS si está vacío |
| S3 Bucket (público, opcional) | lab02-public-test-\<ACCOUNT_ID\> | GRATIS si está vacío |
| IAM Role (opcional) | lab02-cross-account-role | GRATIS |

---

## Variables

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ANALYZER_NAME="lab02-account-analyzer"
```

---

## PASO 1 — Eliminar recursos de prueba del Lab 02.02 (si existen)

```bash
# Bucket cross-account
aws s3 rb "s3://lab02-access-analyzer-${ACCOUNT_ID}" --force 2>/dev/null \
  && echo "Bucket cross-account eliminado" \
  || echo "Bucket no existía o ya eliminado"
```

---

## PASO 2 — Eliminar recursos de prueba del Lab 02.03 (si existen)

```bash
# Bucket público
aws s3 rb "s3://lab02-public-test-${ACCOUNT_ID}" --force 2>/dev/null \
  && echo "Bucket público eliminado" \
  || echo "Bucket no existía o ya eliminado"
```

---

## PASO 3 — Eliminar IAM Role del Lab 02.04 (si existe)

```bash
# Eliminar políticas adjuntas primero (si las hubiera)
aws iam list-attached-role-policies \
  --role-name "lab02-cross-account-role" 2>/dev/null \
  --query 'AttachedPolicies[].PolicyArn' \
  --output text | tr '\t' '\n' | while read arn; do
    aws iam detach-role-policy --role-name "lab02-cross-account-role" --policy-arn "$arn"
done

# Eliminar el rol
aws iam delete-role --role-name "lab02-cross-account-role" 2>/dev/null \
  && echo "IAM Role eliminado" \
  || echo "Rol no existía o ya eliminado"
```

---

## PASO 4 — Eliminar el Access Analyzer

```bash
aws accessanalyzer delete-analyzer \
  --analyzer-name "$ANALYZER_NAME" \
  --region "$AWS_REGION" \
  && echo "Access Analyzer eliminado" \
  || echo "Analyzer no existía o ya eliminado"
```

---

## PASO 5 — Verificar que no quedan recursos

```bash
echo "=== Verificación post-cleanup ==="

# Comprobar analyzer
ANALYZER_STATUS=$(aws accessanalyzer get-analyzer \
  --analyzer-name "$ANALYZER_NAME" \
  --region "$AWS_REGION" \
  --query 'analyzer.status' \
  --output text 2>/dev/null || echo "ELIMINADO")
echo "Analyzer: $ANALYZER_STATUS"

# Comprobar buckets
aws s3 ls | grep "lab02-" && echo "ATENCIÓN: quedan buckets lab02-*" || echo "Buckets: ninguno"

# Comprobar roles
aws iam get-role --role-name "lab02-cross-account-role" 2>/dev/null \
  && echo "ATENCIÓN: IAM Role aún existe" \
  || echo "IAM Role: eliminado"

echo "=== Cleanup completado ==="
```

---

## Cleanup con Terraform (si usaste terraform/)

```bash
cd terraform/
terraform destroy -auto-approve
```

---

## Coste residual

| Situación | Coste mensual |
|-----------|---------------|
| Access Analyzer activo (sin recursos de prueba) | **$0.00** |
| Buckets S3 vacíos (< 1 KB) | < $0.01 |
| IAM Role sin políticas | **$0.00** |
| **Total** | **~$0.00** |

IAM Access Analyzer no tiene ningún coste asociado.
