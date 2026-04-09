# Lab 08 — Limpieza y costes

## Coste residual

| Recurso | Coste residual |
|---------|---------------|
| Detective habilitado | **GRATIS 30 días**, luego basado en GB ingestados |
| Behavior graph | Incluido en el coste de Detective |

**IMPORTANTE:** Deshabilitar Detective después del lab para evitar costes post-trial.

---

## Orden de teardown recomendado

Detective depende de GuardDuty para ser útil. Si también tienes Security Hub activo:

```
Teardown recomendado (inverso al orden de activación):
  1. Detective        ← este lab
  2. Security Hub     ← lab05
  3. GuardDuty        ← lab04 (último — prerrequisito de los otros dos)
```

---

## Limpieza completa

### 1. Eliminar el behavior graph

```bash
export AWS_REGION="eu-west-1"

GRAPH_ARN=$(aws detective list-graphs \
  --region "$AWS_REGION" \
  --query 'GraphList[0].Arn' --output text 2>/dev/null)

if [[ -n "$GRAPH_ARN" && "$GRAPH_ARN" != "None" ]]; then
  aws detective delete-graph \
    --graph-arn "$GRAPH_ARN" \
    --region "$AWS_REGION"
  echo "Detective graph eliminado: $GRAPH_ARN"
else
  echo "No hay Detective graph activo"
fi
```

### Alternativa: Terraform destroy

```bash
cd terraform/
terraform destroy -auto-approve
```

---

## Verificar limpieza

```bash
export AWS_REGION="eu-west-1"

GRAPHS=$(aws detective list-graphs \
  --region "$AWS_REGION" \
  --query 'length(GraphList)' --output text 2>/dev/null || echo "0")

if [[ "$GRAPHS" -eq 0 ]]; then
  echo "Detective deshabilitado (correcto)"
else
  echo "Detective AÚN activo ($GRAPHS graphs)"
fi
```

---

## Teardown completo de todos los labs de seguridad

```bash
export AWS_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Teardown completo Security Labs ==="

# 1. Detective
GRAPH_ARN=$(aws detective list-graphs --region "$AWS_REGION" --query 'GraphList[0].Arn' --output text 2>/dev/null)
[[ -n "$GRAPH_ARN" && "$GRAPH_ARN" != "None" ]] && \
  aws detective delete-graph --graph-arn "$GRAPH_ARN" --region "$AWS_REGION" && \
  echo "[OK] Detective deshabilitado"

# 2. Security Hub
aws securityhub disable-security-hub --region "$AWS_REGION" 2>/dev/null && \
  echo "[OK] Security Hub deshabilitado" || true

# 3. Inspector
aws inspector2 disable \
  --account-ids "$ACCOUNT_ID" \
  --resource-types EC2 ECR \
  --region "$AWS_REGION" 2>/dev/null && \
  echo "[OK] Inspector deshabilitado" || true

# 4. Macie
aws macie2 disable-macie --region "$AWS_REGION" 2>/dev/null && \
  echo "[OK] Macie deshabilitado" || true

# 5. GuardDuty (último)
DETECTOR_ID=$(aws guardduty list-detectors --region "$AWS_REGION" --query 'DetectorIds[0]' --output text 2>/dev/null)
[[ -n "$DETECTOR_ID" && "$DETECTOR_ID" != "None" ]] && \
  aws guardduty delete-detector --detector-id "$DETECTOR_ID" --region "$AWS_REGION" && \
  echo "[OK] GuardDuty deshabilitado"

echo "=== Teardown completado ==="
```
