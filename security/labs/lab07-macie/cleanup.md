# Lab 07 — Limpieza y costes

## Coste residual

| Recurso | Coste residual |
|---------|---------------|
| Macie habilitado | **GRATIS 30 días**, luego basado en GB escaneados |
| S3 buckets | ~$0.023/GB/mes (mínimo en el lab) |
| Discovery Jobs completados | $0.00 (solo se cobra el escaneo activo) |

**IMPORTANTE:** Deshabilitar Macie y eliminar buckets después del lab.

---

## Limpieza completa

### 1. Eliminar objetos y buckets S3

```bash
export AWS_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

for BUCKET in \
  "lab07-macie-demo-${ACCOUNT_ID}" \
  "lab07-macie-public-${ACCOUNT_ID}" \
  "lab07-macie-unencrypted-${ACCOUNT_ID}"; do

  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    # Vaciar bucket
    aws s3 rm "s3://$BUCKET" --recursive --region "$AWS_REGION" 2>/dev/null || true
    # Eliminar versiones si tiene versionado
    aws s3api delete-objects \
      --bucket "$BUCKET" \
      --delete "$(aws s3api list-object-versions \
        --bucket "$BUCKET" \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null)" \
      --region "$AWS_REGION" 2>/dev/null || true
    # Eliminar bucket
    aws s3api delete-bucket --bucket "$BUCKET" --region "$AWS_REGION" 2>/dev/null && \
      echo "Bucket eliminado: $BUCKET" || true
  fi
done
```

### 2. Deshabilitar Macie

```bash
aws macie2 disable-macie \
  --region "$AWS_REGION"

echo "Macie deshabilitado"
```

### Alternativa: Terraform destroy

```bash
cd terraform/
terraform destroy -auto-approve
```

---

## Verificar limpieza

```bash
aws macie2 get-macie-session \
  --region "$AWS_REGION" \
  --query 'status' --output text 2>/dev/null && \
  echo "Macie AÚN activo" || echo "Macie deshabilitado (correcto)"
```
