# Lab 04 — Amazon GuardDuty

> **Coste:** GRATIS durante 30 días de free trial | **Región:** eu-west-1
> ⚠️ **Prerequisito para:** lab05-security-hub y lab08-detective

---

## Objetivo

Dominar Amazon GuardDuty como servicio de detección de amenazas: activación, análisis de findings, Trusted IP Lists, Threat IP Lists, Suppression Rules y respuesta automática via EventBridge + Lambda. Contenido relevante para SAA-C03.

---

## Arquitectura

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Amazon GuardDuty                                                            │
│                                                                              │
│  Fuentes de datos analizadas:                                                │
│  ┌──────────────┐ ┌─────────────┐ ┌──────────┐ ┌──────────────────────┐   │
│  │ VPC Flow Logs│ │ CloudTrail  │ │ DNS Logs │ │ S3 / EKS / Lambda    │   │
│  └──────┬───────┘ └──────┬──────┘ └────┬─────┘ └──────────┬───────────┘   │
│         └────────────────┴─────────────┴──────────────────┘                │
│                                    │                                         │
│                          Machine Learning + Threat Intel                    │
│                                    │                                         │
│                                    ▼                                         │
│                             Finding generado                                 │
│                         (tipo, severidad, recurso)                           │
│                                    │                                         │
│          ┌─────────────────────────┼────────────────────────────┐           │
│          │                         │                            │           │
│   Trusted IP List           Suppression Rules              EventBridge      │
│   (no generar findings      (archivar auto)             (respuesta auto)    │
│    para IPs conocidas)                                         │           │
│                                                                 ▼           │
│                                                     Lambda (aislar EC2)     │
│                                                     + SNS (notificar)       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — Setup](labs/01-setup/README.md) | Habilitar GuardDuty + generar sample findings | Free trial |
| [02 — Trusted IPs](labs/02-trusted-ips/README.md) | Trusted IP List + Threat IP List | Free trial |
| [03 — Suppression](labs/03-suppression/README.md) | Suppression Rules automáticas | Free trial |
| [04 — Remediation](labs/04-remediation/README.md) | EventBridge → Lambda (aislar EC2) + SNS | ~$0.10 |

**Orden recomendado:** 01 → 02 → 03 → 04

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- Fuentes de datos que analiza GuardDuty
- Tipos de findings y nomenclatura
- Trusted IP List vs Threat IP List vs Suppression Rules
- Patrón de respuesta: GuardDuty → EventBridge → Lambda + SNS
- Tabla comparativa: GuardDuty vs Config vs Inspector vs Macie

---

## Terraform

El directorio [terraform/](terraform/) contiene la infraestructura completa:

```bash
cd terraform/

# Setup básico (GuardDuty + IP Lists + Suppression Rule)
terraform init
terraform apply

# Con remediación automática
terraform apply -var="enable_remediation=true" -var="alert_email=tu@email.com"

# Limpiar todo
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para 4 escenarios de examen:

1. Respuesta a credenciales IAM comprometidas
2. Equipo de pentest genera ruido (Trusted IP List vs Suppression Rules)
3. Respuesta automática a instancia comprometida (EventBridge + Lambda)
4. GuardDuty vs Macie vs Inspector vs Config — tabla comparativa

---

## Limpieza

Ver [cleanup.md](cleanup.md) para instrucciones completas.

**Lo más importante:** deshabilitar el detector para evitar costes después del free trial:

```bash
DETECTOR_ID=$(aws guardduty list-detectors --region eu-west-1 --query 'DetectorIds[0]' --output text)
aws guardduty delete-detector --detector-id "$DETECTOR_ID" --region eu-west-1
```

> ⚠️ Si vas a hacer lab05 o lab08, **NO deshabilites GuardDuty** — es prerequisito.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿GuardDuty bloquea el tráfico malicioso? | **No** — solo detecta |
| ¿GuardDuty necesita que Flow Logs estén habilitados? | **No** — los analiza directamente |
| ¿Cómo responder automáticamente a un finding? | GuardDuty → **EventBridge** → Lambda / SNS |
| ¿Qué es una Trusted IP List? | IPs para las que GuardDuty NO genera findings |
| ¿Qué es una Suppression Rule? | Findings se crean pero se archivan automáticamente |
| ¿Cuándo usar Trusted IP List vs Suppression Rule? | IP fija y conocida → Trusted IP List. Criterio complejo o IPs variables → Suppression Rule |
| ¿Prerequisito para Security Hub y Detective? | GuardDuty activo |
