# Lab 05.03 — Security Standards y Controls

> **Coste:** GRATIS (free trial) | **Prerrequisito:** lab 05.01 completado

---

## Objetivo

Explorar los controles fallidos del CIS Benchmark, remediar un control específico, verificar que el Security Score mejora, y aprender a deshabilitar controles con justificación.

---

## Paso 1 — Ver controles fallidos del CIS Benchmark

```bash
export AWS_REGION="eu-west-1"

# Ver controles del CIS Benchmark que están fallando
aws securityhub get-findings \
  --filters '{
    "GeneratorId": [{"Value": "cis-aws-foundations-benchmark", "Comparison": "PREFIX"}],
    "ComplianceStatus": [{"Value": "FAILED", "Comparison": "EQUALS"}],
    "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]
  }' \
  --sort-criteria '[{"Field": "Severity.Normalized", "SortOrder": "desc"}]' \
  --max-items 20 \
  --region "$AWS_REGION" \
  --query 'Findings[].{Control:Title,Severidad:Severity.Label,Recurso:Resources[0].Id}' \
  --output table
```

```bash
# Ver controles del AWS FSBP que están fallando
aws securityhub get-findings \
  --filters '{
    "GeneratorId": [{"Value": "aws-foundational-security-best-practices", "Comparison": "PREFIX"}],
    "ComplianceStatus": [{"Value": "FAILED", "Comparison": "EQUALS"}]
  }' \
  --max-items 20 \
  --region "$AWS_REGION" \
  --query 'Findings[].{Control:Title,Severidad:Severity.Label,Recurso:Resources[0].Type}' \
  --output table
```

---

## Paso 2 — Remediar un control fallido (ejemplo: S3 block public access)

Vamos a remediar el control `S3.1 - S3 Block Public Access setting should be enabled` si está fallando.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Verificar si el control de S3 Block Public Access está fallando
aws securityhub get-findings \
  --filters '{
    "Title": [{"Value": "S3 Block Public Access", "Comparison": "CONTAINS"}],
    "ComplianceStatus": [{"Value": "FAILED", "Comparison": "EQUALS"}]
  }' \
  --region "$AWS_REGION" \
  --query 'Findings[].{Control:Title,Recurso:Resources[0].Id,Severidad:Severity.Label}' \
  --output table
```

```bash
# Remediar: habilitar S3 Block Public Access a nivel de cuenta
aws s3control put-public-access-block \
  --account-id "$ACCOUNT_ID" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "S3 Block Public Access habilitado a nivel de cuenta"
echo "Security Hub re-evaluará este control en los próximos minutos..."
```

```bash
# Esperar y verificar que el control pasa a PASSED
sleep 60

aws securityhub get-findings \
  --filters '{
    "Title": [{"Value": "S3 Block Public Access", "Comparison": "CONTAINS"}],
    "ComplianceStatus": [{"Value": "PASSED", "Comparison": "EQUALS"}]
  }' \
  --region "$AWS_REGION" \
  --query 'Findings[].{Control:Title,Estado:Compliance.Status}' \
  --output table
```

---

## Paso 3 — Ver el Security Score

```bash
# Obtener el score actual via describe-hub
# (el score detallado está en la consola; via CLI se obtiene indirectamente)

# Contar controles PASSED vs FAILED
PASSED=$(aws securityhub get-findings \
  --filters '{"ComplianceStatus": [{"Value": "PASSED", "Comparison": "EQUALS"}], "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]}' \
  --region "$AWS_REGION" \
  --query 'length(Findings)' --output text)

FAILED=$(aws securityhub get-findings \
  --filters '{"ComplianceStatus": [{"Value": "FAILED", "Comparison": "EQUALS"}], "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]}' \
  --region "$AWS_REGION" \
  --query 'length(Findings)' --output text)

TOTAL=$((PASSED + FAILED))
if [[ $TOTAL -gt 0 ]]; then
  SCORE=$(echo "scale=1; $PASSED * 100 / $TOTAL" | bc)
  echo "Security Score aproximado: ${SCORE}% ($PASSED PASSED / $TOTAL total)"
else
  echo "Aún no hay suficientes findings para calcular el score"
fi
```

---

## Paso 4 — Deshabilitar un control específico

Caso de uso: tu empresa usa un tercero para gestionar access keys (no las gestiona en IAM nativo), por lo que el control `IAM.3 - IAM users' access keys should be rotated every 90 days` no aplica a tu entorno.

```bash
# Ver el ID del control a deshabilitar
aws securityhub describe-standards-controls \
  --standards-subscription-arn "$(aws securityhub get-enabled-standards \
    --region "$AWS_REGION" \
    --query 'StandardsSubscriptions[?contains(StandardsArn, `cis`)].StandardsSubscriptionArn' \
    --output text)" \
  --region "$AWS_REGION" \
  --query 'Controls[?contains(Title, `access key`)].{Titulo:Title,ID:ControlId,Estado:ControlStatus}' \
  --output table
```

```bash
# Deshabilitar el control con justificación documentada
CONTROL_ARN=$(aws securityhub describe-standards-controls \
  --standards-subscription-arn "$(aws securityhub get-enabled-standards \
    --region "$AWS_REGION" \
    --query 'StandardsSubscriptions[?contains(StandardsArn, `cis`)].StandardsSubscriptionArn' \
    --output text)" \
  --region "$AWS_REGION" \
  --query 'Controls[?contains(Title, `access key`)].StandardsControlArn' \
  --output text | head -1)

if [[ -n "$CONTROL_ARN" ]]; then
  aws securityhub update-standards-control \
    --standards-control-arn "$CONTROL_ARN" \
    --control-status DISABLED \
    --disabled-reason "Gestión de credenciales delegada a tercero con SLA propio. Auditado trimestralmente." \
    --region "$AWS_REGION"

  echo "Control deshabilitado: $CONTROL_ARN"
fi
```

---

## Deshabilitar control vs Suppression Rule

```
┌─────────────────────────────────────────────────────────────────────────┐
│              ¿Cuándo usar cada opción?                                   │
│                                                                          │
│  Deshabilitar control                Suppression Rule                   │
│  ────────────────────────            ───────────────────────────────    │
│  El control NO se evalúa            El finding SE crea pero              │
│  en absoluto                        se archiva automáticamente          │
│                                                                          │
│  Cuándo:                            Cuándo:                             │
│  - El control no aplica a           - El control aplica pero hay        │
│    tu entorno (arquitectura          un caso específico conocido        │
│    diferente, compensating           que no requiere acción             │
│    controls, exención legal)         (ej: bucket de logs público)      │
│                                                                          │
│  Efecto en el score:                Efecto en el score:                 │
│  - El control NO cuenta en          - El finding existe pero            │
│    el denominador del score           archivado; no impacta el score   │
│                                                                          │
│  Auditoría:                         Auditoría:                          │
│  - Requiere justificación           - Requiere criterio documentado     │
│    (campo DisabledReason)            (descripción de la regla)         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Qué hace mejorar el Security Score? | Remediar controles fallidos o deshabilitar controles no aplicables |
| ¿Diferencia deshabilitar control vs Suppression Rule? | Deshabilitar = no se evalúa. Suppression = se evalúa pero se archiva |
| ¿Para qué sirven los estándares CIS/FSBP? | Comparar tu configuración contra best practices del sector |
| ¿Se puede deshabilitar un control sin justificación? | Técnicamente sí, pero es best practice documentar el `disabled-reason` |
