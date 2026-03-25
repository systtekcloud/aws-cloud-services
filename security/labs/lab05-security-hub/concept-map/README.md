# Lab 05 — AWS Security Hub: Mapa Conceptual

---

## Qué es Security Hub

Security Hub es un **agregador de findings de seguridad**. No detecta amenazas por sí solo — consolida, normaliza y prioriza los findings de múltiples servicios de seguridad AWS y terceros en un único panel.

**Principio clave:** Security Hub **agrega y prioriza** — no detecta.

```
Sin Security Hub:                Con Security Hub:
                                  ┌─────────────────────────────────────┐
GuardDuty findings               │  AWS Security Hub                    │
Config findings       →  caos   │                                      │
Inspector findings               │  GuardDuty ──┐                       │
Macie findings                   │  Config ─────┼──> Findings           │
Access Analyzer                  │  Inspector ──┤    normalizados        │
                                  │  Macie ──────┤    + Security Score   │
                                  │  Access A. ──┤    + Estándares CIS   │
                                  │  Terceros ───┘    + FSBP             │
                                  └─────────────────────────────────────┘
```

---

## Fuentes de datos (integraciones nativas)

| Fuente | Tipo de findings |
|--------|----------------|
| **Amazon GuardDuty** | Amenazas activas y comportamiento anómalo |
| **Amazon Macie** | Datos sensibles en S3 |
| **Amazon Inspector** | Vulnerabilidades en EC2/ECR/Lambda |
| **AWS Config** | Incumplimientos de Config Rules |
| **IAM Access Analyzer** | Accesos externos no intencionados |
| **AWS Firewall Manager** | Incumplimientos de políticas de red |
| **AWS Health** | Eventos que afectan a tu cuenta |
| **Terceros** | CrowdStrike, Palo Alto, Splunk, etc. (via ASFF) |

> **ASFF (Amazon Security Finding Format):** Security Hub normaliza todos los findings a un formato estándar. Esto permite comparar y filtrar findings de distintos servicios con los mismos campos.

---

## Security Score

Security Hub calcula un **Security Score** (0-100%) que representa el porcentaje de controles que están pasando.

```
Security Score = (Controles PASSED / Total controles evaluados) × 100

Ejemplo:
- 80 controles en total
- 64 controles PASSED
- 16 controles FAILED
→ Security Score = 80%
```

El score mejora automáticamente cuando:
1. Remedias un control fallido (recurso pasa a COMPLIANT)
2. Deshabilitas un control (ya no cuenta en el denominador)

---

## Estándares disponibles

| Estándar | Descripción | Controles |
|---------|-------------|----------|
| **AWS FSBP** (Foundational Security Best Practices) | Best practices de AWS para cada servicio | ~300 |
| **CIS AWS Foundations Benchmark** | Estándar CIS para hardening de AWS | ~160 |
| **PCI-DSS** | Requisitos de seguridad para pagos con tarjeta | ~150 |
| **NIST SP 800-53** | Marco de seguridad del gobierno de EE.UU. | ~200 |

> **Para SAA-C03:** conocer FSBP y CIS es suficiente.

---

## Estados de findings en Security Hub

| Estado | Significado | Cuándo usar |
|--------|-------------|-------------|
| **ACTIVE** | Finding requiere atención | Por defecto al recibir el finding |
| **SUPPRESSED** | Known issue, no requiere acción | Caso recurrente conocido y aceptado |
| **RESOLVED** | El problema fue remediado | Después de corregir el recurso |
| **NOTIFIED** | Se notificó al equipo responsable | Triage completado |

**Distinción crítica para el examen:**
- `SUPPRESSED` → problema conocido, conscientemente ignorado (ej: control deshabilitado por razón de negocio)
- `RESOLVED` → problema remediado (el recurso pasó a ser compliant)

---

## Suppression Rules en Security Hub

Similar a GuardDuty, Security Hub tiene Suppression Rules automáticas:

```bash
# Ejemplo: suprimir automáticamente todos los findings LOW de GuardDuty
# en recursos de dev (Resource.Tags.Environment = "dev")

Criterio de la Suppression Rule:
  Product: GuardDuty
  Severity: LOW
  Resource.Tags.Environment: dev
→ Todos los findings que cumplan estos criterios se marcan SUPPRESSED automáticamente
```

**Diferencia vs deshabilitar un control:**
- **Suppression Rule** → finding se crea pero se archiva automáticamente (para casos basados en atributos del finding)
- **Deshabilitar control** → el control no se evalúa en absoluto (para controles que no aplican a tu entorno)

---

## Diferencia: Security Hub vs Detective

Esta comparación aparece frecuentemente en el examen SAA-C03:

```
Security Hub                          Amazon Detective
────────────────────────────          ────────────────────────────────
"¿Cuál es mi postura global?"         "¿Qué pasó exactamente?"

- Agrega findings de muchos           - Correlaciona eventos para
  servicios                             investigar un incidente específico
- Dashboard de compliance             - Grafo de relaciones entre
- Security Score                        entidades (IPs, roles, instancias)
- Estándares (CIS, FSBP, PCI)        - Línea temporal de eventos
- Vista multi-cuenta                  - Profundidad temporal (90 días)

Cuándo usar:                          Cuándo usar:
→ Visión general de seguridad        → "¿Qué hizo el atacante exactamente?"
→ Compliance vs estándares           → "¿Qué recursos tocó?"
→ Priorizar qué remediar             → Investigación forense post-incidente
```

---

## Analogía DevOps

```
Security Hub ≈ Dashboard de observabilidad (tipo Grafana o Datadog)

Grafana:                              Security Hub:
─────────────────────────            ─────────────────────────
- Agrega métricas de múltiples       - Agrega findings de múltiples
  sources (Prometheus, CloudWatch)     servicios (GuardDuty, Config...)
- Dashboards unificados              - Panel unificado de seguridad
- Alertas basadas en umbrales        - Security Score + controles fallidos
- No genera las métricas             - No genera los findings
  (solo las muestra)                   (solo los consolida)

Del mismo modo que en observabilidad separas:
  colección (exporters) → agregación (Prometheus) → visualización (Grafana)

En seguridad:
  detección (GuardDuty/Inspector) → agregación (Security Hub) → investigación (Detective)
```
