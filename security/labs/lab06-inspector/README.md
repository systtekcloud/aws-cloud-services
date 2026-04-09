# Lab 06 — Amazon Inspector

> **Coste:** GRATIS durante 30 días de free trial | **Región:** eu-west-1
> **Prerrequisito:** ECR disponible, Docker instalado localmente

---

## Objetivo

Dominar Amazon Inspector como escáner continuo de vulnerabilidades: EC2 scanning via SSM, Enhanced Scanning en ECR (dependencias de aplicación), y el patrón DevSecOps Inspector → EventBridge → bloquear pipeline. Contenido clave para SAA-C03.

---

## Arquitectura

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Amazon Inspector                                                          │
│                                                                            │
│  Recursos escaneados:              Patrón DevSecOps:                      │
│  ┌───────────────────────┐         docker push                            │
│  │ EC2 (via SSM Agent)   │──┐          │                                  │
│  │ CVEs en paquetes SO   │  │          ▼                                  │
│  └───────────────────────┘  │      Inspector                              │
│  ┌───────────────────────┐  ├─→   (Enhanced Scanning)                    │
│  │ ECR (Enhanced)        │  │          │                                  │
│  │ CVEs en SO + app deps │  │          ▼ finding CRITICAL                 │
│  └───────────────────────┘  │      EventBridge Rule                      │
│  ┌───────────────────────┐  │          ├──► Lambda (bloquea pipeline)    │
│  │ Lambda (dependencias) │──┘          └──► SNS (notifica equipo)        │
│  └───────────────────────┘                                                │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — EC2 Scanning](labs/01-ec2-scanning/README.md) | Habilitar Inspector + EC2 con SSM + findings | Free trial |
| [02 — ECR Scanning](labs/02-ecr-scanning/README.md) | Enhanced vs Basic Scanning + imagen vulnerable | Free trial |
| [03 — Pipeline Integration](labs/03-pipeline-integration/README.md) | EventBridge → Lambda + SNS al detectar CVE CRITICAL | Free trial |

**Orden recomendado:** 01 → 02 → 03

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- Inspector vs GuardDuty vs Config — tabla comparativa
- Enhanced Scanning vs Basic Scanning — diferencia crítica para el examen
- Estructura de un finding (CVE ID, paquete, versión, fix)
- Patrón DevSecOps: Inspector → EventBridge → pipeline
- Por qué Inspector necesita EventBridge (no puede invocar SNS directamente)

---

## Terraform

El directorio [terraform/](terraform/) contiene:

```bash
cd terraform/

# Setup básico (Inspector + ECR + Lambda + EventBridge)
terraform init
terraform apply

# Con notificación email
terraform apply -var="notification_email=tu-email@ejemplo.com"

# Solo EC2 scanning
terraform apply -var="enable_ecr_scanning=false"

# Limpiar
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para 3 escenarios de examen:

1. Enhanced Scanning vs Basic Scanning — cuándo usar cada uno
2. Respuesta automática a CVE crítico — arquitectura con EventBridge
3. Inspector vs GuardDuty vs Config — tabla comparativa completa

---

## Limpieza

Ver [cleanup.md](cleanup.md) para instrucciones completas.

```bash
aws inspector2 disable \
  --account-ids "$(aws sts get-caller-identity --query Account --output text)" \
  --resource-types EC2 ECR \
  --region eu-west-1
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Inspector detecta amenazas activas? | **No** — detecta vulnerabilidades de software (CVEs) |
| ¿Qué necesita para escanear EC2? | SSM Agent en la instancia + IAM Role con `AmazonSSMManagedInstanceCore` |
| ¿Enhanced vs Basic Scanning en ECR? | Enhanced = Inspector (SO + deps app, continuo). Basic = ECR nativo (SO solo, en push) |
| ¿Cómo automatizar respuesta a CVE crítico? | Inspector → EventBridge → Lambda (bloquear pipeline) + SNS |
| ¿Inspector puede invocar SNS directamente? | **No** — necesita EventBridge como intermediario |
| ¿Inspector vs GuardDuty? | Inspector = software vulnerable. GuardDuty = comportamiento sospechoso |
