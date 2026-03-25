# Lab 04.03 — Suppression Rules

> **Coste:** GRATIS (free trial) | **Prerrequisito:** lab 04.01 completado

---

## Objetivo

Crear Suppression Rules para archivar automáticamente findings conocidos y recurrentes. Entender la diferencia entre Suppression Rules (archivado automático futuro) y Archive manual (acción puntual).

---

## Paso 1 — Obtener el Detector ID

```bash
export AWS_REGION="eu-west-1"

DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$AWS_REGION" \
  --query 'DetectorIds[0]' --output text)

echo "Detector ID: $DETECTOR_ID"
```

---

## Paso 2 — Generar findings de prueba (si no los hay)

```bash
# Generar sample findings para tener datos con los que trabajar
aws guardduty create-sample-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-types \
    "PenTest:IAMUser/KaliLinux" \
    "Recon:EC2/Portscan" \
    "UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.B" \
  --region "$AWS_REGION"

sleep 10
echo "Sample findings generados"
```

---

## Paso 3 — Ver findings antes de crear la Suppression Rule

```bash
# Ver todos los findings activos
aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-criteria '{"Criterion": {"service.archived": {"Eq": ["false"]}}}' \
  --region "$AWS_REGION" \
  --query 'length(FindingIds)' \
  --output text

echo "findings activos (no archivados)"
```

---

## Paso 4 — Crear una Suppression Rule

Caso de uso: el equipo de pentest usa Kali Linux y genera `PenTest:IAMUser/KaliLinux` findings constantemente. Queremos archivarlos automáticamente.

```bash
# Crear Suppression Rule (llamada "Filter" en la API de GuardDuty)
# Los filtros con action=ARCHIVE son Suppression Rules
aws guardduty create-filter \
  --detector-id "$DETECTOR_ID" \
  --name "suppress-pentest-kali" \
  --description "Archiva automáticamente findings de Kali Linux del equipo de pentest" \
  --action ARCHIVE \
  --finding-criteria '{
    "Criterion": {
      "type": {
        "Equals": ["PenTest:IAMUser/KaliLinux"]
      }
    }
  }' \
  --region "$AWS_REGION"

echo "Suppression Rule creada: suppress-pentest-kali"
```

### Suppression Rule más específica (por usuario + tipo)

En producción querrías ser más específico para no suprimir findings legítimos:

```bash
aws guardduty create-filter \
  --detector-id "$DETECTOR_ID" \
  --name "suppress-pentest-specific-user" \
  --description "Archiva PenTest findings solo del usuario pentest-authorized" \
  --action ARCHIVE \
  --finding-criteria '{
    "Criterion": {
      "type": {
        "Equals": ["PenTest:IAMUser/KaliLinux"]
      },
      "resource.accessKeyDetails.userName": {
        "Equals": ["pentest-authorized"]
      }
    }
  }' \
  --region "$AWS_REGION"

echo "Suppression Rule específica creada"
```

---

## Paso 5 — Verificar que los nuevos findings se archivan automáticamente

```bash
# Generar más findings del mismo tipo
aws guardduty create-sample-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-types "PenTest:IAMUser/KaliLinux" \
  --region "$AWS_REGION"

sleep 15

# Verificar: los nuevos PenTest:IAMUser/KaliLinux deben aparecer como Archived
aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-criteria '{
    "Criterion": {
      "type": {"Equals": ["PenTest:IAMUser/KaliLinux"]},
      "service.archived": {"Eq": ["true"]}
    }
  }' \
  --region "$AWS_REGION" \
  --query 'length(FindingIds)' \
  --output text

echo "findings de PenTest:IAMUser/KaliLinux archivados por la Suppression Rule"
```

---

## Paso 6 — Listar todas las Suppression Rules

```bash
aws guardduty list-filters \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --output table
```

### Ver el detalle de una Suppression Rule

```bash
aws guardduty get-filter \
  --detector-id "$DETECTOR_ID" \
  --filter-name "suppress-pentest-kali" \
  --region "$AWS_REGION" \
  --query '{Nombre:Name,Descripcion:Description,Accion:Action}' \
  --output table
```

---

## Archive manual vs Suppression Rules

```bash
# Archive MANUAL: archivar un finding específico puntualmente
FINDING_ID=$(aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --query 'FindingIds[0]' --output text)

aws guardduty archive-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-ids "$FINDING_ID" \
  --region "$AWS_REGION"

echo "Finding $FINDING_ID archivado manualmente"
```

**Diferencia de comportamiento:**

```
Archive manual:
├── Finding específico → archivado
├── No afecta a findings futuros del mismo tipo
└── Hay que hacer clic/comando por cada finding

Suppression Rule:
├── Finding actual → archivado
├── Todos los findings futuros que cumplan el criterio → archivados automáticamente
└── GuardDuty los procesa pero Security Hub no los recibe
```

---

## Caso de uso: equipo de pentest autorizado

```
Escenario: Empresa tiene equipo de pentest interno que opera semanalmente.
Los findings tipo PenTest:* aparecen cada semana y no son amenazas reales.

Solución correcta según el examen SAA-C03:

Si las IPs del pentest son fijas:
→ Trusted IP List (findings no se crean en absoluto)

Si las IPs varían pero el usuario IAM es siempre "pentest-user":
→ Suppression Rule con criterio: type=PenTest* AND user=pentest-user
  (findings se crean pero se archivan automáticamente)

Si fue un evento puntual (un solo pentest):
→ Archive manual de los findings específicos
```

---

## Paso 7 — Limpiar

```bash
# Eliminar Suppression Rules
aws guardduty delete-filter \
  --detector-id "$DETECTOR_ID" \
  --filter-name "suppress-pentest-kali" \
  --region "$AWS_REGION"

aws guardduty delete-filter \
  --detector-id "$DETECTOR_ID" \
  --filter-name "suppress-pentest-specific-user" \
  --region "$AWS_REGION" 2>/dev/null || echo "Filtro específico no existe, OK"

echo "Suppression Rules eliminadas"
```
