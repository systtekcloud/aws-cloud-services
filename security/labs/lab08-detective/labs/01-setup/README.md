# Lab 08.01 — Habilitar Amazon Detective

> **Coste:** GRATIS durante 30 días de free trial
> **Prerrequisito OBLIGATORIO:** GuardDuty habilitado (lab04) con findings generados
> **NOTA:** Detective necesita 24-48h para construir el behavior graph inicial

---

## Objetivo

Habilitar Amazon Detective, verificar que ingiere datos de GuardDuty, y explorar el behavior graph inicial.

---

## Prerrequisito: verificar GuardDuty activo

```bash
export AWS_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Verificar GuardDuty activo
DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$AWS_REGION" \
  --query 'DetectorIds[0]' --output text 2>/dev/null)

if [[ -z "$DETECTOR_ID" || "$DETECTOR_ID" == "None" ]]; then
  echo "ERROR: GuardDuty no está habilitado. Completa lab04 primero."
  exit 1
fi

DETECTOR_STATUS=$(aws guardduty get-detector \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --query 'Status' --output text)

echo "GuardDuty Detector ID: $DETECTOR_ID"
echo "Estado: $DETECTOR_STATUS"

# Verificar que hay findings para que Detective tenga datos
FINDINGS_COUNT=$(aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --query 'length(FindingIds)' --output text)

echo "Findings en GuardDuty: $FINDINGS_COUNT"
[[ "$FINDINGS_COUNT" -eq 0 ]] && \
  echo "AVISO: Sin findings. Ejecuta 'aws guardduty create-sample-findings --detector-id $DETECTOR_ID --region $AWS_REGION' antes de continuar."
```

---

## Paso 1 — Habilitar Detective

```bash
# Habilitar Detective (crea el behavior graph)
GRAPH_ARN=$(aws detective create-graph \
  --tags '{"Lab": "lab08-detective"}' \
  --region "$AWS_REGION" \
  --query 'GraphArn' --output text 2>/dev/null || \
  aws detective list-graphs \
    --region "$AWS_REGION" \
    --query 'GraphList[0].Arn' --output text)

echo "Detective Graph ARN: $GRAPH_ARN"
```

```bash
# Verificar que el grafo está activo
aws detective list-graphs \
  --region "$AWS_REGION" \
  --query 'GraphList[].{ARN:Arn,Creado:CreatedTime}' \
  --output table
```

---

## Paso 2 — Verificar ingestión de datos

```bash
# Ver las fuentes de datos que Detective está ingiriendo
aws detective list-datasource-packages \
  --graph-arn "$GRAPH_ARN" \
  --region "$AWS_REGION" \
  --query 'DatasourcePackages' \
  --output json 2>/dev/null || \
  echo "INFO: Detective ingiere CloudTrail + VPC Flow Logs + GuardDuty automáticamente"
```

```bash
# Ver los miembros del grafo (en lab de una sola cuenta: solo la cuenta actual)
aws detective list-members \
  --graph-arn "$GRAPH_ARN" \
  --region "$AWS_REGION" \
  --query 'MemberDetails[].{Cuenta:AccountId,Email:EmailAddress,Estado:Status}' \
  --output table
```

---

## Paso 3 — Generar sample findings en GuardDuty

Para que Detective tenga entidades interesantes para investigar, generamos sample findings en GuardDuty:

```bash
# Generar sample findings de varios tipos
aws guardduty create-sample-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-types \
    "UnauthorizedAccess:EC2/SSHBruteForce" \
    "Recon:IAMUser/UserPermissions" \
    "PrivilegeEscalation:IAMUser/AdministrativePermissions" \
  --region "$AWS_REGION"

echo "Sample findings creados en GuardDuty"
echo "Detective correlacionará estos eventos en su grafo"
echo ""
echo "IMPORTANTE: Esperar 24-48h antes de hacer el lab 02 (investigación)"
echo "El behavior graph necesita tiempo para construir el baseline de comportamiento normal"
```

```bash
# Verificar que los findings aparecen en GuardDuty
aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-criteria '{"Criterion": {"type": {"Neq": []}}}' \
  --region "$AWS_REGION" \
  --query 'length(FindingIds)' --output text | \
  xargs -I {} echo "{} findings en GuardDuty"
```

---

## validate.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
warn() { echo -e "${YELLOW}[WAIT]${NC} $*"; }

echo "=== Lab 08.01 — Detective Setup ==="

# Verificar GuardDuty activo (prerrequisito)
DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$REGION" \
  --query 'DetectorIds[0]' --output text 2>/dev/null || echo "NONE")

if [[ "$DETECTOR_ID" == "NONE" || -z "$DETECTOR_ID" ]]; then
  fail "GuardDuty no activo — prerrequisito obligatorio para Detective"
fi
pass "GuardDuty activo: $DETECTOR_ID"

# Verificar Detective habilitado
GRAPH_ARN=$(aws detective list-graphs \
  --region "$REGION" \
  --query 'GraphList[0].Arn' --output text 2>/dev/null || echo "NONE")

if [[ "$GRAPH_ARN" == "NONE" || -z "$GRAPH_ARN" ]]; then
  fail "Detective no habilitado"
fi
pass "Detective habilitado: $GRAPH_ARN"

# Verificar findings en GuardDuty
FINDINGS=$(aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --region "$REGION" \
  --query 'length(FindingIds)' --output text 2>/dev/null || echo "0")

if [[ "$FINDINGS" -gt 0 ]]; then
  pass "$FINDINGS findings en GuardDuty (datos para Detective)"
else
  warn "Sin findings en GuardDuty. Genera sample findings para el lab 02"
fi

echo ""
warn "Esperar 24-48h antes del lab 02 para que el behavior graph madure"
echo "Detective free trial: 30 días desde activación"
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Prerrequisito para Detective? | GuardDuty activo con findings |
| ¿Qué datos ingiere Detective automáticamente? | CloudTrail + VPC Flow Logs + GuardDuty findings |
| ¿Cuánto tarda el behavior graph en madurar? | 24-48h para el baseline inicial |
| ¿Qué es el behavior graph? | Modelo del comportamiento normal de entidades en tu cuenta |
