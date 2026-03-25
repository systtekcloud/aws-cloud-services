# Lab 05.01 — Habilitar AWS Security Hub

> **Coste:** GRATIS durante 30 días de free trial | **Prerrequisito:** lab04-guardduty activo

---

## Objetivo

Habilitar Security Hub, activar los estándares AWS FSBP y CIS Benchmark, y verificar que los findings de GuardDuty aparecen automáticamente.

---

## Paso 1 — Habilitar Security Hub

```bash
export AWS_REGION="eu-west-1"

# Habilitar Security Hub
aws securityhub enable-security-hub \
  --enable-default-standards \
  --region "$AWS_REGION"

echo "Security Hub habilitado"
```

> **Nota:** `--enable-default-standards` activa automáticamente AWS FSBP. CIS Benchmark se activa en el paso 2.

### Verificar que está activo

```bash
aws securityhub describe-hub \
  --region "$AWS_REGION" \
  --query '{ARN:HubArn,Suscrito:SubscribedAt}' \
  --output table
```

---

## Paso 2 — Activar estándares adicionales

```bash
# Ver estándares disponibles
aws securityhub describe-standards \
  --region "$AWS_REGION" \
  --query 'Standards[].{Nombre:Name,ARN:StandardsArn}' \
  --output table
```

```bash
# Activar CIS AWS Foundations Benchmark
CIS_ARN=$(aws securityhub describe-standards \
  --region "$AWS_REGION" \
  --query 'Standards[?contains(Name, `CIS`)].StandardsArn' \
  --output text | head -1)

aws securityhub batch-enable-standards \
  --standards-subscription-requests "[{\"StandardsArn\": \"${CIS_ARN}\"}]" \
  --region "$AWS_REGION"

echo "CIS Benchmark activado"
```

```bash
# Ver estándares activos y su estado
aws securityhub get-enabled-standards \
  --region "$AWS_REGION" \
  --query 'StandardsSubscriptions[].{Nombre:StandardsArn,Estado:StandardsStatus}' \
  --output table
```

Output esperado:
```
---------------------------------------------------------
|              GetEnabledStandards                       |
+---------------------------------------+---------------+
|  Nombre                               |  Estado       |
+---------------------------------------+---------------+
|  arn:aws:securityhub:...:fsbp/...    |  READY        |
|  arn:aws:securityhub:...:cis/...     |  READY        |
+---------------------------------------+---------------+
```

---

## Paso 3 — Verificar que GuardDuty envía findings

```bash
# Verificar que la integración con GuardDuty está activa
aws securityhub list-enabled-products-for-import \
  --region "$AWS_REGION" \
  --query 'ProductSubscriptions' \
  --output table
```

```bash
# Ver findings recientes (pueden tardar 5-15 min en aparecer)
aws securityhub get-findings \
  --filters '{
    "ProductName": [{"Value": "GuardDuty", "Comparison": "EQUALS"}]
  }' \
  --sort-criteria '[{"Field": "UpdatedAt", "SortOrder": "desc"}]' \
  --max-items 5 \
  --region "$AWS_REGION" \
  --query 'Findings[].{Tipo:Types[0],Severidad:Severity.Label,Recurso:Resources[0].Type,Estado:Workflow.Status}' \
  --output table
```

---

## Paso 4 — Explorar el Security Score inicial

```bash
# Ver el Security Score actual
aws securityhub get-findings \
  --filters '{
    "Type": [{"Value": "Software and Configuration Checks", "Comparison": "PREFIX"}],
    "WorkflowStatus": [{"Value": "NEW", "Comparison": "EQUALS"}]
  }' \
  --region "$AWS_REGION" \
  --query 'length(Findings)' \
  --output text

echo "findings NEW (sin gestionar)"
```

```bash
# Ver resumen de controles fallidos por estándar
aws securityhub get-findings \
  --filters '{
    "ComplianceStatus": [{"Value": "FAILED", "Comparison": "EQUALS"}],
    "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]
  }' \
  --max-items 10 \
  --region "$AWS_REGION" \
  --query 'Findings[].{Control:Title,Severidad:Severity.Label,Recurso:Resources[0].Id}' \
  --output table
```

---

## validate.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-1"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "=== Lab 05.01 — Security Hub Setup ==="

# Verificar que Security Hub está habilitado
HUB_ARN=$(aws securityhub describe-hub \
  --region "$REGION" \
  --query 'HubArn' --output text 2>/dev/null || echo "NONE")

if [[ "$HUB_ARN" == "NONE" || -z "$HUB_ARN" ]]; then
  fail "Security Hub no está habilitado"
fi
pass "Security Hub habilitado: $HUB_ARN"

# Verificar estándares activos
STANDARDS_COUNT=$(aws securityhub get-enabled-standards \
  --region "$REGION" \
  --query 'length(StandardsSubscriptions)' --output text 2>/dev/null || echo "0")

if [[ "$STANDARDS_COUNT" -ge 1 ]]; then
  pass "Estándares activos: $STANDARDS_COUNT"
else
  fail "No hay estándares activos"
fi

# Verificar que hay findings
FINDINGS_COUNT=$(aws securityhub get-findings \
  --region "$REGION" \
  --query 'length(Findings)' --output text 2>/dev/null || echo "0")

if [[ "$FINDINGS_COUNT" -gt 0 ]]; then
  pass "Security Hub tiene $FINDINGS_COUNT findings"
else
  echo "INFO: Aún no hay findings (puede tardar 5-15 min en aparecer)"
fi

echo "Security Hub activo. Free trial: 30 días desde activación."
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Security Hub detecta amenazas? | **No** — agrega findings de otros servicios |
| ¿Prerequisito para Security Hub? | GuardDuty activo (para tener findings útiles) |
| ¿Qué estándares incluye? | AWS FSBP, CIS, PCI-DSS, NIST SP 800-53 |
| ¿Qué mide el Security Score? | % de controles pasando |
