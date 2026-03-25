# Lab 05.02 — Gestión de Findings

> **Coste:** GRATIS (free trial) | **Prerrequisito:** lab 05.01 completado

---

## Objetivo

Explorar los findings agregados de múltiples servicios, filtrarlos por distintos criterios, gestionar su estado (Suppressed/Resolved), y crear una Suppression Rule automática.

---

## Paso 1 — Explorar findings por fuente

```bash
export AWS_REGION="eu-west-1"

# Ver findings agrupados por producto (fuente)
aws securityhub get-findings \
  --filters '{"RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]}' \
  --max-items 50 \
  --region "$AWS_REGION" \
  --query 'Findings[].{Servicio:ProductName,Tipo:Types[0],Severidad:Severity.Label}' \
  --output table
```

```bash
# Ver solo findings de GuardDuty
aws securityhub get-findings \
  --filters '{
    "ProductName": [{"Value": "GuardDuty", "Comparison": "EQUALS"}],
    "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]
  }' \
  --region "$AWS_REGION" \
  --query 'Findings[].{Tipo:Types[0],Severidad:Severity.Label,Recurso:Resources[0].Id}' \
  --output table
```

```bash
# Ver findings de Config (controles fallidos)
aws securityhub get-findings \
  --filters '{
    "ProductName": [{"Value": "Config", "Comparison": "EQUALS"}],
    "ComplianceStatus": [{"Value": "FAILED", "Comparison": "EQUALS"}]
  }' \
  --region "$AWS_REGION" \
  --query 'Findings[].{Control:Title,Recurso:Resources[0].Id,Severidad:Severity.Label}' \
  --output table
```

---

## Paso 2 — Filtrar por severidad

```bash
# Ver solo findings CRITICAL y HIGH
aws securityhub get-findings \
  --filters '{
    "SeverityLabel": [
      {"Value": "CRITICAL", "Comparison": "EQUALS"},
      {"Value": "HIGH", "Comparison": "EQUALS"}
    ],
    "WorkflowStatus": [{"Value": "NEW", "Comparison": "EQUALS"}]
  }' \
  --sort-criteria '[{"Field": "Severity.Normalized", "SortOrder": "desc"}]' \
  --region "$AWS_REGION" \
  --query 'Findings[].{Titulo:Title,Severidad:Severity.Label,Servicio:ProductName,Recurso:Resources[0].Id}' \
  --output table
```

---

## Paso 3 — Suprimir un finding (SUPPRESSED)

Caso de uso: equipo de seguridad decide que un finding es un known issue que no requiere acción inmediata.

```bash
# Obtener el ID de un finding para gestionarlo
FINDING_ID=$(aws securityhub get-findings \
  --filters '{"RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]}' \
  --region "$AWS_REGION" \
  --query 'Findings[0].Id' --output text)

PRODUCT_ARN=$(aws securityhub get-findings \
  --filters '{"RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]}' \
  --region "$AWS_REGION" \
  --query 'Findings[0].ProductArn' --output text)

echo "Finding ID: $FINDING_ID"
echo "Product ARN: $PRODUCT_ARN"
```

```bash
# Suprimir el finding (marcar como SUPPRESSED con razón documentada)
aws securityhub batch-update-findings \
  --finding-identifiers "[{\"Id\": \"${FINDING_ID}\", \"ProductArn\": \"${PRODUCT_ARN}\"}]" \
  --workflow '{"Status": "SUPPRESSED"}' \
  --note '{
    "Text": "Known issue — verificado por equipo de seguridad el 2026-03-25. No requiere acción.",
    "UpdatedBy": "security-team"
  }' \
  --region "$AWS_REGION"

echo "Finding marcado como SUPPRESSED"
```

```bash
# Verificar el cambio
aws securityhub get-findings \
  --filters "{\"Id\": [{\"Value\": \"${FINDING_ID}\", \"Comparison\": \"EQUALS\"}]}" \
  --region "$AWS_REGION" \
  --query 'Findings[0].{Estado:Workflow.Status,Nota:Note.Text}' \
  --output table
```

---

## Paso 4 — Resolver un finding (RESOLVED)

Caso de uso: se remedia el recurso que causaba el finding.

```bash
# Obtener un finding diferente para resolverlo
FINDING_ID_2=$(aws securityhub get-findings \
  --filters '{
    "WorkflowStatus": [{"Value": "NEW", "Comparison": "EQUALS"}],
    "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]
  }' \
  --region "$AWS_REGION" \
  --query 'Findings[1].Id' --output text)

PRODUCT_ARN_2=$(aws securityhub get-findings \
  --filters '{
    "WorkflowStatus": [{"Value": "NEW", "Comparison": "EQUALS"}],
    "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]
  }' \
  --region "$AWS_REGION" \
  --query 'Findings[1].ProductArn' --output text)

# Marcar como RESOLVED tras remediar el recurso
aws securityhub batch-update-findings \
  --finding-identifiers "[{\"Id\": \"${FINDING_ID_2}\", \"ProductArn\": \"${PRODUCT_ARN_2}\"}]" \
  --workflow '{"Status": "RESOLVED"}' \
  --note '{
    "Text": "Remediado — recurso corregido el 2026-03-25. Config Rule en COMPLIANT.",
    "UpdatedBy": "security-team"
  }' \
  --region "$AWS_REGION"

echo "Finding marcado como RESOLVED"
```

---

## Paso 5 — Crear una Suppression Rule automática

Las Automation Rules (antes Suppression Rules) se aplican automáticamente a findings futuros que cumplan los criterios.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Crear Automation Rule: suprimir automáticamente findings LOW de GuardDuty
aws securityhub create-automation-rule \
  --rule-name "suppress-guardduty-low-dev" \
  --description "Suprime automáticamente findings GuardDuty LOW en entornos dev" \
  --rule-order 1 \
  --is-terminal \
  --criteria '{
    "ProductName": [{"Value": "GuardDuty", "Comparison": "EQUALS"}],
    "SeverityLabel": [{"Value": "LOW", "Comparison": "EQUALS"}]
  }' \
  --actions '[{
    "Type": "FINDING_FIELDS_UPDATE",
    "FindingFieldsUpdate": {
      "Workflow": {"Status": "SUPPRESSED"},
      "Note": {
        "Text": "Auto-suprimido: GuardDuty LOW — nivel de riesgo aceptado",
        "UpdatedBy": "automation-rule"
      }
    }
  }]' \
  --region "$AWS_REGION" 2>/dev/null || echo "NOTA: Automation Rules requiere Security Hub con versión actualizada — usar batch-update-findings manualmente"
```

---

## Diferencia: SUPPRESSED vs RESOLVED

```
┌────────────────────────────────────────────────────────────────────────┐
│                    ¿Cuándo usar cada estado?                            │
│                                                                         │
│  SUPPRESSED                          RESOLVED                           │
│  ─────────────────────────           ─────────────────────────────      │
│  "Lo sé y acepto el riesgo"          "Lo arreglé"                      │
│                                                                         │
│  Casos de uso:                       Casos de uso:                      │
│  - Control que no aplica a          - Recurso fue corregido             │
│    tu entorno                       - SG ya no tiene puerto 22          │
│  - Comportamiento intencional       - Bucket S3 ya tiene cifrado        │
│  - Finding de pentest conocido      - MFA ya está habilitado            │
│                                                                         │
│  Efecto:                            Efecto:                             │
│  - Finding existe pero archivado    - Finding marcado como resuelto     │
│  - No cuenta en el Security Score   - Security Score puede mejorar      │
│  - Auditable (queda el registro)    - Se re-abre si el problema vuelve  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Diferencia SUPPRESSED vs RESOLVED? | SUPPRESSED = aceptado conscientemente. RESOLVED = remediado |
| ¿Las Suppression Rules aplican a findings futuros? | **Sí** — automáticamente |
| ¿Cómo filtrar findings por severidad? | `--filters SeverityLabel EQUALS CRITICAL` |
| ¿Se puede añadir nota al gestionar un finding? | **Sí** — `--note` con texto y autor |
