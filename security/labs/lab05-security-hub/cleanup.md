# Lab 05 — Limpieza y costes

## Coste residual

| Recurso | Coste residual |
|---------|---------------|
| Security Hub activo | **GRATIS 30 días**, luego ~$0.001 por finding/control evaluado |
| Estándares activos | Incluido en el coste de Security Hub |
| Insights | $0.00 |

**IMPORTANTE:** El coste post-trial es bajo pero acumulable. Deshabilitar Security Hub cuando termines los labs.

---

## Limpieza completa

### 1. Deshabilitar estándares (primero, para evitar errores)

```bash
export AWS_REGION="eu-west-1"

# Listar y deshabilitar todos los estándares activos
for ARN in $(aws securityhub get-enabled-standards \
  --region "$AWS_REGION" \
  --query 'StandardsSubscriptions[].StandardsSubscriptionArn' \
  --output text 2>/dev/null); do
  aws securityhub batch-disable-standards \
    --standards-subscription-arns "$ARN" \
    --region "$AWS_REGION"
  echo "Estándar deshabilitado: $ARN"
done
```

### 2. Eliminar Insights personalizados

```bash
for ARN in $(aws securityhub get-insights \
  --region "$AWS_REGION" \
  --query 'Insights[?contains(Name, `lab05`)].InsightArn' \
  --output text 2>/dev/null); do
  aws securityhub delete-insight \
    --insight-arn "$ARN" \
    --region "$AWS_REGION"
  echo "Insight eliminado: $ARN"
done
```

### 3. Deshabilitar Security Hub

```bash
aws securityhub disable-security-hub \
  --region "$AWS_REGION"

echo "Security Hub deshabilitado"
```

### Alternativa: Terraform destroy

```bash
cd terraform/
terraform destroy -auto-approve
```

---

## Verificar que todo está limpio

```bash
export AWS_REGION="eu-west-1"

aws securityhub describe-hub \
  --region "$AWS_REGION" 2>/dev/null && echo "Security Hub AÚN activo" || echo "Security Hub deshabilitado (correcto)"
```

---

## ⚠️ Nota sobre prerequisitos

Si tienes previsto hacer **lab08-detective**, recuerda que también necesita GuardDuty activo.

**Orden recomendado de teardown:**
1. lab08-detective (último — necesita más tiempo de maduración)
2. lab05-security-hub
3. lab04-guardduty (último en desactivar — prerequisito de ambos)
