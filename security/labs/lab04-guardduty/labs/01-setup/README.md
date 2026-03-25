# Lab 04.01 — Habilitar Amazon GuardDuty

> **Coste:** GRATIS durante 30 días de free trial | **Región:** eu-west-1 | **Duración:** ~20 minutos

> ⚠️ **IMPORTANTE:** GuardDuty tiene 30 días de free trial por región. Actívalo solo cuando vayas a ejecutar el lab. Este lab es **prerequisito** para lab05-security-hub y lab08-detective.

---

## Objetivo

Habilitar GuardDuty, generar sample findings para explorar la estructura de un finding, y entender los datos que GuardDuty analiza continuamente.

---

## Paso 1 — Habilitar GuardDuty

```bash
export AWS_REGION="eu-west-1"

# Habilitar GuardDuty
DETECTOR_ID=$(aws guardduty create-detector \
  --enable \
  --finding-publishing-frequency FIFTEEN_MINUTES \
  --region "$AWS_REGION" \
  --query 'DetectorId' --output text)

echo "GuardDuty habilitado. Detector ID: $DETECTOR_ID"
```

### Verificar que está activo

```bash
aws guardduty get-detector \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --query '{Estado:Status,Frecuencia:FindingPublishingFrequency,Trial:ServiceRole}' \
  --output table
```

Output esperado:
```
------------------------------------------------
|              GetDetector                      |
+----------+------------------------------------+
|  Estado  |  ENABLED                           |
+----------+------------------------------------+
```

---

## Paso 2 — Generar sample findings

GuardDuty puede generar findings de muestra que cubren todos los tipos de findings disponibles. Útil para explorar la estructura sin necesidad de actividad real.

```bash
# Generar sample findings (uno de cada tipo)
aws guardduty create-sample-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-types \
    "UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.B" \
    "Recon:EC2/Portscan" \
    "CryptoCurrency:EC2/BitcoinTool.B" \
    "Backdoor:EC2/C&CActivity.B!DNS" \
    "PenTest:IAMUser/KaliLinux" \
  --region "$AWS_REGION"

echo "Sample findings generados"
sleep 10
```

---

## Paso 3 — Explorar los findings

```bash
# Listar todos los findings del detector
aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --query 'FindingIds' \
  --output table
```

```bash
# Guardar IDs de los findings
FINDING_IDS=$(aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --query 'FindingIds' \
  --output json)

# Ver el detalle de todos los findings
aws guardduty get-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-ids $(echo $FINDING_IDS | jq -r '.[]' | head -5 | tr '\n' ' ') \
  --region "$AWS_REGION" \
  --query 'Findings[].{Tipo:Type,Severidad:Severity,Recurso:Resource.ResourceType,Cuenta:AccountId}' \
  --output table
```

---

## Paso 4 — Explorar la estructura de un finding

```bash
# Obtener el primer finding con todos sus detalles
FIRST_FINDING=$(aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --query 'FindingIds[0]' --output text)

# Ver estructura completa del finding
aws guardduty get-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-ids "$FIRST_FINDING" \
  --region "$AWS_REGION" \
  --output json | jq '.Findings[0] | {
    id: .Id,
    tipo: .Type,
    titulo: .Title,
    descripcion: .Description,
    severidad: .Severity,
    region: .Region,
    cuenta: .AccountId,
    recurso_tipo: .Resource.ResourceType,
    actualizado: .UpdatedAt
  }'
```

### Estructura de un finding (campos clave)

```
Finding
├── Id               — Identificador único del finding
├── Type             — ThreatPurpose:ResourceType/ThreatFamilyName
│                      Ejemplo: "CryptoCurrency:EC2/BitcoinTool.B"
├── Title            — Descripción corta
├── Description      — Descripción detallada
├── Severity         — 0.0-10.0 (LOW <4, MEDIUM <7, HIGH <9, CRITICAL ≤10)
├── CreatedAt        — Cuándo se detectó la primera vez
├── UpdatedAt        — Cuándo se actualizó (GuardDuty agrega eventos)
├── Service
│   ├── Count        — Número de veces que se detectó esta actividad
│   ├── EventFirstSeen
│   └── EventLastSeen
└── Resource
    ├── ResourceType — "Instance", "S3Bucket", "AccessKey", etc.
    └── [datos específicos del recurso]
```

---

## Paso 5 — Filtrar findings por severidad

```bash
# Ver solo findings HIGH y CRITICAL (severidad >= 7)
aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-criteria '{
    "Criterion": {
      "severity": {
        "Gte": 7
      }
    }
  }' \
  --region "$AWS_REGION" \
  --query 'FindingIds' \
  --output table

echo "Findings de severidad HIGH o CRITICAL"
```

```bash
# Filtrar por tipo de finding
aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-criteria '{
    "Criterion": {
      "type": {
        "Equals": ["CryptoCurrency:EC2/BitcoinTool.B"]
      }
    }
  }' \
  --region "$AWS_REGION" \
  --query 'FindingIds' \
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

echo "=== Lab 04.01 — GuardDuty Setup ==="

# Verificar que GuardDuty está habilitado
DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$REGION" \
  --query 'DetectorIds[0]' --output text 2>/dev/null || echo "NONE")

if [[ "$DETECTOR_ID" == "NONE" || -z "$DETECTOR_ID" ]]; then
  fail "GuardDuty no está habilitado (no hay detector)"
fi

STATUS=$(aws guardduty get-detector \
  --detector-id "$DETECTOR_ID" \
  --region "$REGION" \
  --query 'Status' --output text 2>/dev/null || echo "DISABLED")

if [[ "$STATUS" == "ENABLED" ]]; then
  pass "GuardDuty habilitado (Detector: $DETECTOR_ID)"
else
  fail "GuardDuty está en estado: $STATUS"
fi

# Verificar que hay findings
FINDING_COUNT=$(aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --region "$REGION" \
  --query 'length(FindingIds)' --output text 2>/dev/null || echo "0")

if [[ "$FINDING_COUNT" -gt 0 ]]; then
  pass "GuardDuty tiene $FINDING_COUNT findings (sample findings generados)"
else
  fail "No hay findings — ejecutar create-sample-findings del Paso 2"
fi

echo "GuardDuty activo y con findings. Free trial: 30 días desde activación."
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Necesita GuardDuty que Flow Logs estén habilitados? | **No** — GuardDuty los analiza directamente |
| ¿GuardDuty bloquea el tráfico malicioso? | **No** — solo detecta, la respuesta va via EventBridge |
| ¿Qué es un sample finding? | Finding sintético para pruebas, sin actividad real detrás |
| ¿Cuánto dura el free trial? | 30 días por región por cuenta |
