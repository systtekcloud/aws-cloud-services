# Lab 06 — Amazon Inspector: Mapa Conceptual

---

## Qué es Amazon Inspector

Amazon Inspector es un servicio de **escaneo continuo de vulnerabilidades** para cargas de trabajo AWS. Detecta CVEs (Common Vulnerabilities and Exposures) en software instalado, configuraciones de red, y vulnerabilidades en imágenes de contenedor.

**Principio clave:** Inspector detecta **vulnerabilidades de software** — no amenazas activas (eso es GuardDuty), ni incumplimientos de configuración (eso es Config).

```
Inspector escanea:
┌────────────────────────────────────────────────────────────────────┐
│  Amazon EC2                                                         │
│  → Paquetes instalados con CVEs conocidos                          │
│  → Vulnerabilidades en el sistema operativo                        │
│  → Puertos de red accesibles (Network Reachability)                │
│                                                                     │
│  Amazon ECR (Container Registry)                                   │
│  → Imágenes de contenedor almacenadas                              │
│  → CVEs en capas del sistema y dependencias de aplicación          │
│                                                                     │
│  AWS Lambda                                                         │
│  → Dependencias del package (npm, pip, etc.)                       │
│  → CVEs en bibliotecas del runtime                                 │
└────────────────────────────────────────────────────────────────────┘
```

---

## Enhanced Scanning vs Basic Scanning en ECR

Esta distinción es **crítica para el SAA-C03**:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Basic Scanning (ECR nativo)           Enhanced Scanning (Inspector)      │
│  ──────────────────────────────        ──────────────────────────────     │
│  Motor: Clair (open source)            Motor: Amazon Inspector            │
│                                                                           │
│  Cuándo escanea:                       Cuándo escanea:                    │
│  - Solo en el PUSH                     - Continuo (re-escanea imágenes   │
│  - No re-escanea automáticamente         existentes cuando se publican   │
│                                          nuevos CVEs)                    │
│                                                                           │
│  Profundidad:                          Profundidad:                       │
│  - Solo paquetes del SO                - Paquetes SO + dependencias de   │
│                                          aplicación (npm, pip, gem)      │
│                                                                           │
│  CVE database:                         CVE database:                      │
│  - CVE database básica                 - Multiple feeds (NVD, vendor,   │
│                                          distro-specific)                │
│                                                                           │
│  Findings en:                          Findings en:                       │
│  - Solo ECR Console                    - Inspector Console               │
│                                        - Security Hub                    │
│                                        - EventBridge (automatizable)     │
│                                                                           │
│  Coste: Gratis                         Coste: Free trial 30 días         │
└──────────────────────────────────────────────────────────────────────────┘

Regla SAA-C03:
  "escaneo continuo de imágenes" o "dependencias de aplicación" → Enhanced Scanning
  "escaneo solo en el push" o "básico" → Basic Scanning
```

---

## Estructura de un finding de Inspector

```json
{
  "findingArn": "arn:aws:inspector2:eu-west-1:123456789012:finding/abc123",
  "type": "PACKAGE_VULNERABILITY",
  "severity": "CRITICAL",
  "status": "ACTIVE",
  "packageVulnerabilityDetails": {
    "vulnerabilityId": "CVE-2021-44228",          ← ID del CVE
    "vulnerablePackages": [{
      "name": "log4j-core",                        ← Paquete afectado
      "version": "2.14.1",                         ← Versión vulnerable
      "fixedInVersion": "2.17.1",                  ← Versión que corrige
      "packageManager": "JAR"
    }],
    "cvss": [{"baseScore": 10.0}],                ← Puntuación CVSS
    "referenceUrls": ["https://nvd.nist.gov/..."]
  },
  "resources": [{
    "type": "AWS_ECR_CONTAINER_IMAGE",
    "id": "arn:aws:ecr:eu-west-1:123:repository/mi-app/image/sha256:abc"
  }]
}
```

**Para el examen — campos clave:**
- `vulnerabilityId` → CVE ID (ej: CVE-2021-44228 = Log4Shell)
- `vulnerablePackages[].fixedInVersion` → qué versión corrige el problema
- `severity` → CRITICAL / HIGH / MEDIUM / LOW / INFORMATIONAL
- `status` → ACTIVE / SUPPRESSED / CLOSED

---

## Patrón DevSecOps con Inspector

Este patrón aparece frecuentemente en el SAA-C03:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Patrón: Inspector → EventBridge → parar pipeline                        │
│                                                                           │
│  1. Developer hace push de imagen a ECR                                  │
│     docker push 123.dkr.ecr.eu-west-1.amazonaws.com/mi-app:v1.2.3      │
│                           │                                              │
│                           ▼                                              │
│  2. Inspector escanea automáticamente (Enhanced Scanning)                │
│     → Detecta CVE-2023-XXXX en dependencia npm                          │
│     → Genera finding severity=CRITICAL                                   │
│                           │                                              │
│                           ▼                                              │
│  3. EventBridge Rule:                                                     │
│     source: aws.inspector2                                               │
│     detail-type: Inspector2 Finding                                      │
│     detail.severity: CRITICAL                                            │
│     detail.resources[].type: AWS_ECR_CONTAINER_IMAGE                    │
│                           │                                              │
│                    ┌──────┴──────┐                                       │
│                    │             │                                        │
│                    ▼             ▼                                        │
│  4a. Lambda function        4b. SNS topic                                │
│     → Llamar API de CI/CD        → Notificar al equipo                  │
│       (GitHub/GitLab)              con CVE ID y paquete                  │
│     → Marcar build como FAILED                                           │
│     → Bloquear deploy a prod                                             │
│                                                                           │
│  IMPORTANTE: Inspector NO puede invocar SNS directamente.                │
│  Necesita EventBridge como intermediario.                                │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Tabla comparativa: Inspector vs GuardDuty vs Config

```
┌────────────────┬──────────────────────────┬─────────────────────────┬────────────────────────┐
│ Dimensión      │ Amazon Inspector         │ Amazon GuardDuty        │ AWS Config             │
├────────────────┼──────────────────────────┼─────────────────────────┼────────────────────────┤
│ ¿Qué detecta?  │ Vulnerabilidades (CVEs)  │ Amenazas activas        │ Incumplimientos de     │
│                │ en software              │ y comportamientos       │ configuración de       │
│                │                          │ anómalos                │ recursos AWS           │
├────────────────┼──────────────────────────┼─────────────────────────┼────────────────────────┤
│ ¿Cuándo?       │ Continuo (sin agente     │ Continuo (Flow Logs,    │ Basado en cambios      │
│                │ en EC2 con SSM)          │ CloudTrail, DNS)        │ de configuración o     │
│                │                          │                         │ periódico              │
├────────────────┼──────────────────────────┼─────────────────────────┼────────────────────────┤
│ ¿Qué analiza?  │ EC2, ECR, Lambda         │ Cuenta entera           │ Recursos AWS           │
│                │ (software installed)     │ (comportamiento)        │ (atributos)            │
├────────────────┼──────────────────────────┼─────────────────────────┼────────────────────────┤
│ Pregunta       │ "¿Tiene mi servidor      │ "¿Alguien está          │ "¿Está mi SG abierto   │
│ SAA-C03        │  Log4Shell?"             │  exfiltrando datos?"    │  al puerto 22?"        │
├────────────────┼──────────────────────────┼─────────────────────────┼────────────────────────┤
│ Respuesta a    │ Parchear el software     │ Aislar el recurso,      │ Remediar la            │
│ un finding     │                          │ investigar el incidente  │ configuración          │
└────────────────┴──────────────────────────┴─────────────────────────┴────────────────────────┘
```

---

## Analogía DevOps

```
Inspector ≈ Vulnerability scanning en CI/CD pipeline

Pipeline CI/CD tradicional:          Inspector en AWS:
────────────────────────────         ────────────────────────────
snyk / trivy / grype                 Amazon Inspector

Escanea:                             Escanea:
  - Dependencias npm/pip/gem           - Paquetes en EC2
  - Imagen Docker                      - Imágenes ECR
  - Código (SAST)                      - Lambda dependencies

Integración:                         Integración:
  - Bloquea el pipeline                - EventBridge → Lambda
    si hay CVE crítico                   → CI/CD API
  - Notifica al desarrollador          - SNS → Slack/PagerDuty

Clave: Inspector hace para AWS lo que Snyk/Trivy hacen en tu pipeline local,
pero de forma continua y sin necesidad de configurarlo en el Jenkinsfile.
```
