# Lab 08.02 — Investigación Forense con Detective

> **Coste:** GRATIS (free trial) | **Prerrequisito:** lab 08.01 + 24-48h de maduración del grafo

---

## Objetivo

Usar Amazon Detective para investigar un finding de GuardDuty: explorar el grafo de la entidad afectada, identificar el timeline de API calls y conexiones de red, y documentar el alcance del incidente.

---

## Paso 1 — Seleccionar un finding de GuardDuty para investigar

```bash
export AWS_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$AWS_REGION" \
  --query 'DetectorIds[0]' --output text)

GRAPH_ARN=$(aws detective list-graphs \
  --region "$AWS_REGION" \
  --query 'GraphList[0].Arn' --output text)

# Listar findings disponibles, priorizando HIGH y CRITICAL
aws guardduty get-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-ids $(aws guardduty list-findings \
    --detector-id "$DETECTOR_ID" \
    --region "$AWS_REGION" \
    --query 'FindingIds[:10]' \
    --output text) \
  --region "$AWS_REGION" \
  --query 'Findings[].{ID:Id,Tipo:Type,Severidad:Severity,Recurso:Resource.ResourceType}' \
  --output table 2>/dev/null | head -20
```

```bash
# Seleccionar un finding de IAM o EC2 para investigar
# Preferir tipos: UnauthorizedAccess, Recon, PrivilegeEscalation
FINDING_ID=$(aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-criteria '{
    "Criterion": {
      "type": {
        "Neq": []
      },
      "severity": {
        "Gte": 4
      }
    }
  }' \
  --region "$AWS_REGION" \
  --query 'FindingIds[0]' --output text)

echo "Finding seleccionado: $FINDING_ID"

# Ver el detalle del finding
aws guardduty get-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-ids "$FINDING_ID" \
  --region "$AWS_REGION" \
  --query 'Findings[0].{Tipo:Type,Severidad:Severity,Recurso:Resource.ResourceType,Principal:Resource.AccessKeyDetails.UserName}' \
  --output json
```

---

## Paso 2 — Investigar la entidad en Detective

```bash
# Detective API: buscar la entidad afectada en el grafo
# Para un finding de IAM User:
ENTITY_ARN=$(aws guardduty get-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-ids "$FINDING_ID" \
  --region "$AWS_REGION" \
  --query 'Findings[0].Resource.AccessKeyDetails.PrincipalId' \
  --output text 2>/dev/null || echo "")

echo "Entidad a investigar: $ENTITY_ARN"
```

```bash
# Buscar la entidad en Detective
# Detective expone datos via la consola web; la API CLI es limitada
# Comandos útiles via CLI:

# Ver investigaciones guardadas (si hay alguna)
aws detective list-investigations \
  --graph-arn "$GRAPH_ARN" \
  --region "$AWS_REGION" \
  --query 'InvestigationDetails[].{ID:InvestigationId,Estado:Status,Entidad:EntityArn}' \
  --output table 2>/dev/null || echo "Sin investigaciones guardadas aún"
```

```bash
# Crear una investigación formal para el finding
# (Detective permite guardar investigaciones para trazabilidad)
INVESTIGATION_ID=$(aws detective create-investigation \
  --graph-arn "$GRAPH_ARN" \
  --entity-arn "arn:aws:iam::${ACCOUNT_ID}:user/alice" \
  --scope-start-time "$(date -u -d '2 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-2d '+%Y-%m-%dT%H:%M:%SZ')" \
  --scope-end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --region "$AWS_REGION" \
  --query 'InvestigationId' --output text 2>/dev/null || echo "API no disponible en esta versión")

echo "Investigation ID: $INVESTIGATION_ID"
```

---

## Paso 3 — Explorar el grafo en la consola (investigación visual)

La mayor parte del valor de Detective está en la **consola web**, que proporciona visualizaciones que no están disponibles via CLI.

```
Pasos en la consola (https://eu-west-1.console.aws.amazon.com/detective):

1. Ir a "Findings" en el menú lateral
   → Ver los findings de GuardDuty importados

2. Seleccionar un finding HIGH o CRITICAL

3. Click "Investigate" en el finding
   → Detective abre el perfil de la entidad afectada

4. En el perfil de la entidad (ej: IAM User):
   ┌─────────────────────────────────────────────────────────────┐
   │  Secciones clave:                                            │
   │                                                              │
   │  a) Overview                                                 │
   │     → Actividad reciente vs baseline histórico              │
   │     → Anomalías estadísticas destacadas                     │
   │                                                              │
   │  b) API call volume                                          │
   │     → Gráfico temporal de API calls                         │
   │     → ¿Spike anómalo a las 14:23?                           │
   │                                                              │
   │  c) IP addresses                                             │
   │     → IPs desde las que se autenticó                        │
   │     → ¿IP nueva vs IPs habituales?                          │
   │                                                              │
   │  d) AWS resources accessed                                   │
   │     → S3, EC2, IAM... qué tocó                              │
   │     → Click en S3 → ver qué buckets y cuántos objetos       │
   │                                                              │
   │  e) Roles assumed                                            │
   │     → ¿Asumió otros roles? (movimiento lateral)             │
   └─────────────────────────────────────────────────────────────┘

5. En cada relación, click para profundizar:
   Usuario → Bucket S3 → ver GetObject timeline
   Usuario → EC2 → ver Flow Logs de la instancia
```

---

## Paso 4 — Comparar con buscar lo mismo en CloudTrail

Este ejercicio demuestra el valor de Detective vs CloudTrail manual:

```bash
# Buscar en CloudTrail manualmente el mismo evento
# (esto es lo que harías SIN Detective)

START_TIME=$(date -u -d '2 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
             date -u -v-2d '+%Y-%m-%dT%H:%M:%SZ')

# Ver eventos de IAM en CloudTrail
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=iam.amazonaws.com \
  --start-time "$START_TIME" \
  --region "$AWS_REGION" \
  --query 'Events[].{Hora:EventTime,Evento:EventName,Usuario:Username,IP:Resources[0].ResourceName}' \
  --output table \
  --max-results 20 2>/dev/null | head -25
```

```
Comparación del tiempo de investigación:

CloudTrail manual:
  1. Lookup por servicio (iam.amazonaws.com) → 20 eventos
  2. Lookup por servicio (s3.amazonaws.com) → 47 eventos
  3. Lookup por VPC Flow Logs en S3 → correlación manual
  4. Cruzar timestamps manualmente
  5. Determinar si el patrón es anómalo sin baseline
  Tiempo total: 2-4 horas

Amazon Detective:
  1. Click "Investigate" en el GuardDuty finding
  2. Ver el grafo con CloudTrail + Flow Logs + contexto histórico
  Tiempo total: 5-15 minutos
```

---

## Paso 5 — Documentar el flujo de investigación

Template de documentación para SAA-C03:

```
FLUJO DE RESPUESTA A INCIDENTE CON DETECTIVE:

1. Detección
   GuardDuty finding: "PrivilegeEscalation:IAMUser/AdministrativePermissions"
   Severity: HIGH | Resource: IAM User

2. Triage inicial (Security Hub)
   Finding aparece en Security Hub dashboard
   Analista asigna investigador

3. Investigación (Detective)
   - Investigar en Detective la entidad afectada
   - Verificar: ¿es el primer login desde esa IP?
   - Verificar: ¿están los API calls en el patrón normal?
   - Verificar: ¿qué recursos accedió? ¿hay datos exfiltrados?
   - Verificar: ¿asumió otros roles? (movimiento lateral)

4. Conclusión
   "Credenciales comprometidas desde [fecha/hora].
    Alcance: acceso a [recursos específicos].
    Datos afectados: [volumen]."

5. Contención
   - Invalidar credenciales del usuario
   - Revocar sesiones activas
   - Aislar recursos afectados

6. Evidencia
   - Exportar timeline de Detective
   - Guardar snapshot de CloudTrail
   - Documentar IPs involucradas
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Detective investiga con cuántos días de datos? | Hasta 1 año de datos históricos |
| ¿Cómo empezar a investigar un finding de GuardDuty? | Click "Investigate in Detective" desde el finding |
| ¿Detective puede bloquear al atacante? | **No** — solo investiga. La contención la hace Lambda via EventBridge |
| ¿Detective vs CloudTrail para investigar? | Detective = correlación automática (minutos). CloudTrail = logs en bruto (horas) |
| ¿Necesita Detective configurar fuentes de datos? | **No** — ingiere CloudTrail + VPC Flow Logs + GuardDuty automáticamente |
