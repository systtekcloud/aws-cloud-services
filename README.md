# AWS Cloud Services — Laboratorios Prácticos

Repositorio de laboratorios progresivos para aprender los servicios core de AWS de forma práctica. El objetivo es construir un portfolio técnico real mientras se prepara el examen **AWS Solutions Architect Associate (SAA-C03)**.

Cada módulo sigue la misma filosofía: entender **por qué** cada decisión existe, no solo cómo ejecutarla. Las arquitecturas evolucionan de lo más básico hasta patrones enterprise, implementadas siempre con dos variantes: **AWS CLI** (para entender los recursos) y **Terraform** (para producción).

---

## Estructura del repositorio

```
aws-cloud-services/
├── vpc/          ← Fundamentos de red: VPC, subnets, routing, endpoints
├── compute/      ← EC2: ALB, ASG, Aurora, escalado, DNS global, IaC enterprise
├── ecs/          ← Contenedores: Fargate, CI/CD, GitOps, optimización de costes
├── eks/          ← (próximamente) Kubernetes gestionado en AWS
├── databases/    ← (próximamente) RDS, Aurora, DynamoDB, ElastiCache
└── route53/      ← (próximamente) DNS, routing policies, health checks
```

Cada módulo contiene:
- `concept-map/` — mapa conceptual del servicio orientado al examen SA Associate
- `labs/` — laboratorios hands-on con CLI y Terraform
- `scenarios/` — escenarios de troubleshooting y casos de uso del examen

---

## Servicios desarrollados

### VPC — Fundamentos de red

**Por qué:** La VPC es la base de cualquier arquitectura en AWS. Sin entender subnets, route tables, NAT, NACLs y VPC Endpoints es imposible diseñar correctamente ningún otro servicio.

El lab construye una VPC de producción completa en 6 fases progresivas, pasando por consola, CLI y Terraform con CI/CD:

| Fase | Qué se construye |
|------|-----------------|
| 0 — Planificación | Diseño de CIDRs y arquitectura de red |
| 1 — Red básica | VPC + subnets públicas/privadas + IGW + route tables |
| 2 — Egress controlado | NAT Gateway para instancias privadas |
| 3 — 3-tier + aislamiento | Subnets isolated + NACLs para capa de base de datos |
| 4 — VPC Endpoints | Gateway EP (S3) + Interface EP (SSM) sin salida a internet |
| 5 — Flow Logs | Observabilidad de tráfico + troubleshooting de conectividad |
| 6 — IaC | Terraform completo + GitHub Actions CI/CD |

**Coste:** < 1€ por sesión completa. El único recurso costoso es el NAT Gateway, que se elimina al terminar cada fase.

---

### Compute (EC2) — De 2-tier básico a arquitectura enterprise

**Por qué:** EC2 con ALB y ASG es el patrón de compute más extendido en AWS. El lab cubre todos los componentes que aparecen en el examen SA Associate: Launch Templates con IMDSv2, Target Groups, políticas de escalado, Aurora Multi-AZ, Secrets Manager, Blue/Green deployments, Route53 y Global Accelerator.

El workload (una Flask app) evoluciona en 5 versiones acumulativas:

| Versión | Qué añade | Coste/día |
|---------|-----------|-----------|
| v1 — 2-tier básico | VPC + ALB + ASG + Launch Template (IMDSv2) | ~0.5€ |
| v2 — 3-tier Aurora | Aurora MySQL Multi-AZ + ElastiCache Redis + Secrets Manager | ~8-12€ |
| v3 — Resiliencia | Step Scaling + Warm Pool + FIS (fault injection) + Blue/Green | +0€ sobre v1 |
| v4 — DNS global | ACM wildcard + HTTPS + Route53 Alias + Global Accelerator | ~1.5€ |
| v5 — Enterprise IaC | Terragrunt multi-env + Atmos stacks + GitHub Actions OIDC | 0€ (IaC) |

Incluye 8 guías de troubleshooting de escenarios reales: health checks, Security Groups, ASG que no escala, listener rules, Route53 TTL, Global Accelerator y NAT routing.

---

### ECS — Contenedores Fargate de zero a enterprise

**Por qué:** ECS Fargate es la opción serverless de contenedores en AWS y uno de los servicios más presentes en el examen SA Associate. El lab lleva una API real (ShopAPI, FastAPI + Python) desde un container manual hasta una arquitectura multi-AZ con CI/CD y GitOps.

7 versiones progresivas:

| Versión | Qué añade | Nivel |
|---------|-----------|-------|
| v1 — Primer container | ECR + Task Definition + RunTask manual | Básico |
| v2 — Servicio con ALB | ECS Service + ALB + VPC privada + rolling update | Intermedio |
| v3 — Secrets y observabilidad | Secrets Manager + CloudWatch + X-Ray + IAM roles | Intermedio |
| v4 — AutoScaling Multi-AZ | Application Auto Scaling + Fargate Spot + SQS workers | Avanzado |
| v5 — CI/CD | GitHub Actions → ECR → ECS deploy automático | Avanzado |
| v6 — Cost optimization | VPC Endpoints + Capacity Providers + Graviton (ARM) | Avanzado |
| v7 — Enterprise GitOps | Terragrunt + Atmos + multi-entorno dev/staging/prod | Expert |

Incluye además `codex-labs/`: 5 escenarios de arquitectura enterprise para SA Pro (troubleshooting avanzado, optimización de costes, integraciones AWS).

---

## Herramientas utilizadas

- **AWS CLI v2** — aprovisionamiento manual y scripts de validación
- **Terraform ≥ 1.7** — IaC de todos los labs
- **Terragrunt** — gestión multi-entorno (v5+ en compute, v5+ en ECS)
- **Atmos** — stacks declarativos para arquitecturas enterprise
- **GitHub Actions** — CI/CD con OIDC (sin access keys en secretos)
- **Docker** — build y push de imágenes a ECR (labs ECS)

## Región por defecto

Todos los labs usan **eu-west-1** (Irlanda). El dominio de ejemplo es `systtekcloud.dev`.

## Prerrequisitos

```bash
aws --version          # 2.x
terraform --version    # 1.7+
terragrunt --version   # 0.54+ (labs enterprise)
docker --version       # 24.x (labs ECS)

# Verificar credenciales
aws sts get-caller-identity
```
