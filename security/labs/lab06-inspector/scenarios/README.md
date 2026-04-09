# Lab 06 — Scenarios SAA-C03

Escenarios de examen sobre Amazon Inspector, vulnerabilidades de software y patrones DevSecOps.

---

## Escenario 1 — Enhanced Scanning vs Basic Scanning en ECR

**Contexto:** Una empresa despliega microservicios en ECS usando imágenes ECR. Tienen habilitado el escaneo básico en sus repositorios (Basic Scanning). Tras un incidente de seguridad, el CISO pide:
1. Escanear también las dependencias npm/pip de las aplicaciones (no solo el SO)
2. Re-escanear imágenes existentes automáticamente cuando se publiquen nuevos CVEs

**Pregunta:** ¿Qué cambio deben realizar?

**Opciones:**
- A) Habilitar `scanOnPush=true` en todos los repositorios ECR
- B) Migrar de Basic Scanning a Enhanced Scanning via Amazon Inspector
- C) Agregar Trivy al pipeline CI/CD para escanear en el build
- D) Habilitar AWS Config Rules para verificar el estado del escaneo

**Respuesta correcta: B**

**Explicación:**
- **Enhanced Scanning (Inspector)** es la única opción que cumple ambos requisitos:
  1. Escanea dependencias de aplicación (npm, pip, gem, JAR) además del SO
  2. Realiza `CONTINUOUS_SCAN` — re-escanea imágenes existentes cuando se publican nuevos CVEs
- La opción A solo activa el escaneo en cada push, pero no re-escanea imágenes ya subidas
- La opción C (Trivy en CI/CD) escanea en el build, no las imágenes ya en ECR
- La opción D es para verificar compliance de configuración, no para escanear vulnerabilidades

**Pista SAA-C03:**
- "dependencias de aplicación" → Enhanced Scanning
- "re-escaneo continuo / nuevos CVEs" → Enhanced Scanning (`CONTINUOUS_SCAN`)
- "solo en el push / básico" → Basic Scanning

---

## Escenario 2 — Respuesta automática a CVE crítico en pipeline

**Contexto:** Un equipo de DevOps tiene un pipeline de CI/CD en GitHub Actions. Cuando un developer hace push de una imagen Docker a ECR, quieren que si Inspector detecta un CVE CRITICAL, el pipeline se bloquee automáticamente y el equipo de seguridad reciba una notificación con el detalle del CVE.

**Pregunta:** ¿Cuál es la arquitectura correcta?

**Opciones:**
- A) Inspector → SNS (notificación directa) + Lambda (bloqueo pipeline)
- B) Inspector → EventBridge Rule (severity=CRITICAL, type=ECR) → Lambda (bloqueo) + SNS (notificación)
- C) CloudWatch Alarm sobre métricas de Inspector → Lambda → SNS
- D) Inspector → Systems Manager Automation → GitHub Actions API

**Respuesta correcta: B**

**Explicación:**
- **Inspector no puede invocar SNS ni Lambda directamente.** Inspector publica eventos en EventBridge, que actúa como bus de eventos.
- **EventBridge Rule** con filtro `source: aws.inspector2` + `severity: CRITICAL` + `type: AWS_ECR_CONTAINER_IMAGE` enruta el evento a múltiples targets simultáneamente.
- La opción A es incorrecta porque Inspector no tiene integración directa con SNS.
- La opción C es incorrecta porque Inspector no publica métricas a CloudWatch que se puedan alarmar directamente.
- La opción D es posible pero no es el patrón estándar para esta integración.

**Patrón EventBridge:**
```
source: "aws.inspector2"
detail-type: "Inspector2 Finding"
detail.severity: ["CRITICAL"]
detail.resources.type: ["AWS_ECR_CONTAINER_IMAGE"]
```

---

## Escenario 3 — Inspector vs GuardDuty vs Config

**Contexto:** Un equipo de seguridad recibe tres alertas:

**Alerta A:** Una instancia EC2 está comunicándose con una IP de Command & Control conocida.
**Alerta B:** Una imagen Docker en ECR tiene la biblioteca OpenSSL 1.1.1 con CVE-2022-0778 (severidad CRITICAL).
**Alerta C:** Un Security Group tiene el puerto 22 abierto a 0.0.0.0/0.

**Pregunta:** ¿Qué servicio generaría cada alerta?

**Respuesta:**

| Alerta | Servicio | Razón |
|--------|---------|-------|
| **A** — C2 communication | **GuardDuty** | Detecta comportamiento anómalo analizando VPC Flow Logs + Threat IP Lists |
| **B** — CVE en OpenSSL | **Inspector** | Detecta vulnerabilidades de software en paquetes instalados/imágenes ECR |
| **C** — SG puerto 22 abierto | **Config** (`restricted-ssh`) | Detecta incumplimientos de configuración de recursos AWS |

**Regla mnemotécnica SAA-C03:**
```
¿Alguien está haciendo algo malo AHORA?         → GuardDuty (amenazas activas)
¿Hay un paquete con CVE vulnerable?             → Inspector (vulnerabilidades)
¿Está mal configurado el recurso?               → Config (compliance configuración)
```

**Profundizando:**
- GuardDuty NO detecta CVEs (no mira el software instalado)
- Inspector NO detecta ataques en curso (no analiza comportamiento)
- Config NO detecta C2 communication (no analiza tráfico de red)

---

## Tabla resumen SAA-C03

| Dimensión | Inspector | GuardDuty | Config | Security Hub |
|-----------|----------|----------|--------|-------------|
| **¿Qué detecta?** | CVEs en software | Amenazas activas | Config incorrecta | (agrega todo) |
| **¿Analiza?** | Paquetes instalados | Comportamiento/tráfico | Atributos de recursos | Findings de los 3 |
| **¿Cuándo?** | Continuo (Enhanced) | Continuo | En cambios o periódico | En tiempo real |
| **Targets** | EC2, ECR, Lambda | Toda la cuenta | Todos los recursos | Todos los servicios |
| **Respuesta a finding** | Parchear paquete | Aislar/investigar | Remediar config | Gestionar postura |
| **EventBridge source** | `aws.inspector2` | `aws.guardduty` | `aws.config` | `aws.securityhub` |

**Para recordar la diferencia Inspector / GuardDuty:**
- Inspector = **lo que TIENE** el sistema (software vulnerable)
- GuardDuty = **lo que HACE** el sistema (comportamiento sospechoso)
