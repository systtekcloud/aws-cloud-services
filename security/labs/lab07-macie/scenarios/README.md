# Lab 07 — Scenarios SAA-C03

Escenarios de examen sobre Amazon Macie, clasificación de datos S3 y gestión de findings.

---

## Escenario 1 — Leer el prefijo del finding para elegir la remediación

**Contexto:** El equipo de seguridad recibe estos dos findings de Macie en la misma semana:

**Finding A:** `SensitiveData:S3Object/Personal` en el bucket `hr-employee-records`
**Finding B:** `Policy:IAMUser/S3BucketEncryptionDisabled` en el bucket `finance-reports`

**Pregunta:** ¿Cuál es la acción correcta para cada finding?

**Respuesta:**

**Finding A — `SensitiveData:S3Object/Personal`:**
- El problema está en el **CONTENIDO** del objeto (datos PII de empleados)
- El hecho de que el bucket tenga BPA habilitado o no es irrelevante para este finding
- Acciones correctas:
  1. Identificar qué objetos tienen PII (ver `classificationDetails.result.sensitiveData`)
  2. Evaluar si el PII debe estar ahí (¿es legítimo?)
  3. Si no es legítimo: eliminar el objeto
  4. Si es legítimo: asegurarse de que el acceso está restringido (IAM + bucket policy)
  5. Considerar cifrado con KMS + key policy restrictiva

**Finding B — `Policy:IAMUser/S3BucketEncryptionDisabled`:**
- El problema está en la **CONFIGURACIÓN** del bucket (sin cifrado por defecto)
- No importa si el contenido tiene datos sensibles o no — la configuración es insegura
- Acciones correctas:
  1. Habilitar SSE-S3 (AES256) o SSE-KMS como cifrado por defecto
  2. Verificar que los objetos existentes también se cifren

```bash
# Remediar Finding B: habilitar cifrado SSE-S3
aws s3api put-bucket-encryption \
  --bucket finance-reports \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'
```

**Pista SAA-C03:**
- `SensitiveData:` → remediar el CONTENIDO
- `Policy:` → remediar la CONFIGURACIÓN

---

## Escenario 2 — Macie vs Access Analyzer para detectar buckets públicos

**Contexto:** Una empresa quiere implementar controles para detectar buckets S3 públicos. El equipo de seguridad debate entre usar Macie o IAM Access Analyzer.

**Pregunta:** ¿Cuándo usar Macie vs Access Analyzer para este problema?

**Opciones:**
- A) Solo Macie — detecta buckets públicos con findings `Policy:`
- B) Solo Access Analyzer — detecta accesos externos en bucket policies
- C) Ambos — son complementarios y detectan aspectos diferentes
- D) AWS Config con regla `s3-bucket-public-read-prohibited`

**Respuesta correcta: C (y D también es válido, pero por razones distintas)**

**Explicación:**

```
Macie (Policy:IAMUser/S3BucketPubliclyAccessible):
  Detecta: BPA deshabilitado + policy pública = bucket efectivamente público
  Fuerza: visión completa del estado del bucket
  Limitación: solo S3, no otros recursos

Access Analyzer (finding de acceso externo en S3):
  Detecta: bucket policy que permite acceso a Principal:* o a otra cuenta
  Fuerza: análisis de permisos IAM efectivos (considera SCPs, etc.)
  Limitación: no analiza el contenido, solo políticas

Config (s3-bucket-public-read-prohibited):
  Detecta: configuración de Block Public Access deshabilitada
  Fuerza: puede remediar automáticamente (SSM Automation)
  Limitación: no analiza contenido ni permisos efectivos complejos
```

**La respuesta más completa para SAA-C03:**
- Si la pregunta es "detectar PII expuesto" → **Macie**
- Si la pregunta es "detectar policies cross-account" → **Access Analyzer**
- Si la pregunta es "compliance y remediación automática" → **Config**
- Si la pregunta incluye "centralizado multi-cuenta" → **Security Hub** (agrega todos)

---

## Escenario 3 — Custom Identifier en Macie

**Contexto:** Una empresa de seguros almacena números de póliza en S3 con el formato `POL-XXXXXXXX` (ej: `POL-12345678`). Quieren que Macie detecte automáticamente estos números en objetos S3, ya que son datos sensibles según su política interna.

**Pregunta:** ¿Qué funcionalidad de Macie deben usar?

**Opciones:**
- A) Esperar a que Automated Discovery los detecte como PII genérico
- B) Crear un Custom Data Identifier con el patrón regex `POL-\d{8}`
- C) Crear una Config Rule personalizada que detecte el patrón
- D) Usar GuardDuty con una lista de amenazas personalizada

**Respuesta correcta: B**

**Explicación:**
- **Custom Data Identifiers** en Macie permiten definir patrones regex propios para detectar datos sensibles específicos de tu organización
- Macie usa estos patrones en los Discovery Jobs y Automated Discovery
- Los findings generados son de tipo `SensitiveData:S3Object/CustomIdentifier`

```bash
# Crear Custom Data Identifier
aws macie2 create-custom-data-identifier \
  --name "numero-poliza-seguros" \
  --description "Detecta números de póliza con formato POL-XXXXXXXX" \
  --regex "POL-\d{8}" \
  --keywords "poliza" "póliza" "policy" \
  --maximum-match-distance 50 \
  --region eu-west-1
```

**Pista SAA-C03:** "datos sensibles con formato propietario de la empresa" → **Custom Data Identifier** en Macie.

---

## Tabla resumen SAA-C03 — Macie

| Dimensión | Macie |
|-----------|-------|
| **¿Qué analiza?** | Contenido y configuración de S3 |
| **Findings categoría POLICY** | Configuración insegura del bucket |
| **Findings categoría SENSITIVE_INFORMATION** | Contenido con datos sensibles (PII, financiero, credenciales) |
| **Automated Discovery** | Continuo con sampling |
| **Discovery Jobs** | Manual, exhaustivo, scope definido |
| **Custom Identifiers** | Regex para datos sensibles propios |
| **¿Analiza otros servicios?** | **No** — solo S3 |
| **Multi-cuenta** | Sí — delegated administrator via Organizations |

**Para recordar la diferencia de findings:**
- `SensitiveData:` = el objeto **TIENE** datos problemáticos → proteger el contenido
- `Policy:` = el bucket **ESTÁ** mal configurado → corregir la configuración
