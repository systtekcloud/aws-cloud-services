# Lab 05 — AWS Security Hub

> **Coste:** GRATIS durante 30 días de free trial | **Región:** eu-west-1
> **Prerrequisito:** lab04-guardduty activo

---

## Objetivo

Dominar AWS Security Hub como agregador de findings de seguridad: habilitación, estándares CIS/FSBP, gestión de findings (Suppressed/Resolved), Automation Rules y Security Score. Contenido relevante para SAA-C03.

---

## Arquitectura

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  AWS Security Hub (agregador)                                                │
│                                                                              │
│  Fuentes:                          Outputs:                                  │
│  ┌────────────┐                   ┌──────────────────────────────────────┐  │
│  │ GuardDuty  │──┐                │ Security Score (0-100%)              │  │
│  │ Config     │  │                │ Controles CIS / FSBP / PCI           │  │
│  │ Inspector  │  ├──> Findings   │ Findings normalizados (ASFF)          │  │
│  │ Macie      │  │    unificados  │ Insights personalizados               │  │
│  │ Access A.  │──┘                │                                      │  │
│  │ Terceros   │                   └──────────────────────────────────────┘  │
│  └────────────┘                                                              │
│                                                                              │
│  Gestión de findings:                                                        │
│  NEW → [revisar] → SUPPRESSED (conocido) o RESOLVED (remediado)             │
│  Automation Rules → archivado automático por criterios                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — Setup](labs/01-setup/README.md) | Habilitar Security Hub + estándares CIS y FSBP | Free trial |
| [02 — Findings](labs/02-findings/README.md) | Filtrar, suprimir, resolver findings + Automation Rules | Free trial |
| [03 — Standards](labs/03-standards/README.md) | Remediar controles fallidos + deshabilitar controles | Free trial |

**Orden recomendado:** 01 → 02 → 03

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- Security Hub como agregador (no detector)
- Fuentes de datos y estándares disponibles
- Security Score y cómo mejorarlo
- SUPPRESSED vs RESOLVED
- Suppression Rules vs deshabilitar controles
- Security Hub vs Detective — distinción crítica

---

## Terraform

El directorio [terraform/](terraform/) contiene:

```bash
cd terraform/

# Setup básico (Security Hub + FSBP + CIS)
terraform init
terraform apply

# Con PCI-DSS también
terraform apply -var="enable_pci_dss=true"

# Limpiar
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para 4 escenarios de examen:

1. Partner de seguridad autorizado genera findings conocidos
2. Security Hub vs Detective — cuándo usar cada uno
3. Deshabilitar control vs Suppression Rule
4. Arquitectura multi-cuenta con delegated administrator

---

## Limpieza

Ver [cleanup.md](cleanup.md) para instrucciones completas.

```bash
aws securityhub disable-security-hub --region eu-west-1
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Security Hub detecta amenazas? | **No** — agrega findings de GuardDuty, Config, etc. |
| ¿Diferencia SUPPRESSED vs RESOLVED? | SUPPRESSED = aceptado. RESOLVED = remediado |
| ¿Qué es el Security Score? | % de controles pasando (0-100%) |
| ¿Cómo mejorar el Security Score? | Remediar controles o deshabilitar controles no aplicables |
| ¿Diferencia con Detective? | Security Hub = postura global. Detective = investigación forense |
| ¿Multi-cuenta? | Delegated administrator via AWS Organizations |
