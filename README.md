# AWS Cloud Services — Laboratorios Prácticos

Repositorio de laboratorios progresivos para aprender los servicios core de AWS de forma práctica. El objetivo es construir un portfolio técnico real mientras se prepara el examen **AWS Solutions Architect Associate (SAA-C03)**.

Cada módulo sigue la misma filosofía: entender **por qué** cada decisión existe, no solo cómo ejecutarla. Las arquitecturas evolucionan de lo más básico hasta patrones enterprise, implementadas siempre con dos variantes: **AWS CLI** (para entender los recursos) y **Terraform** (para producción).

---

## Estructura del repositorio

```
aws-cloud-services/
├── vpc/          ← Fundamentos de red: VPC, subnets, routing, endpoints, Flow Logs, IaC
├── networking/   ← Patrones avanzados: PrivateLink, NAT HA, VPC Peering, TGW, NACL, SSM
├── compute/      ← EC2: ALB, ASG, Aurora, escalado, DNS global, IaC enterprise
├── ecs/          ← Contenedores: Fargate, CI/CD, GitOps, optimización de costes
├── databases/    ← RDS, Aurora, DynamoDB, ElastiCache
├── security/     ← Organizations, Identity Center, Config, GuardDuty, Inspector, Macie, Detective
├── data/         ← Kinesis, MSK, Glue, EMR, Redshift, OpenSearch, data lake con Terragrunt
├── eks/          ← Kubernetes gestionado en AWS (próximamente)
├── route53/      ← DNS, routing policies, health checks (próximamente)
└── storage/      ← S3, EFS, EBS, Glacier (próximamente)
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

### Networking — Patrones avanzados de conectividad

**Por qué:** Más allá de la VPC básica, el examen SA Associate evalúa la capacidad de diseñar conectividad segura entre VPCs y optimizar el coste del tráfico hacia servicios AWS. Estos labs demuestran conceptos que se malinterpretan con frecuencia.

| Lab | Concepto demostrado | Coste |
|-----|---------------------|-------|
| Lab 01 — PrivateLink con CIDRs solapados | Dos VPCs con el mismo CIDR (`10.0.0.0/16`) se comunican via NLB + Interface Endpoint. Demuestra por qué PrivateLink no depende de enrutamiento IP entre VPCs, a diferencia de VPC Peering | < $0.50 |
| Lab 02 — Gateway Endpoint vs NAT Gateway para S3 | VPC Flow Logs prueba empíricamente que el tráfico S3 desde una subnet con Gateway Endpoint no pasa por NAT. Dos EC2 en subnets distintas permiten comparar ambas rutas | < $0.10 |

**Stack:** Terraform + Terragrunt · SSM Session Manager (sin SSH) · eu-west-1

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

### Databases — RDS, Aurora, DynamoDB, ElastiCache

**Por qué:** Las bases de datos son una de las áreas con más peso en el SA Associate. Saber cuándo elegir RDS vs Aurora vs DynamoDB vs ElastiCache, y cómo configurar HA, réplicas y caching, es fundamental para el examen y para diseñar correctamente.

5 labs progresivos que van desde la base hasta una arquitectura 3-tier completa:

| Lab | Qué se construye | Coste estimado |
|-----|-----------------|----------------|
| Lab 01 — RDS básico | RDS MySQL Multi-AZ + Read Replica + Secrets Manager + SG | ~2€/h |
| Lab 02 — Aurora | Aurora MySQL Cluster + failover automático + Auto Scaling de réplicas | ~3€/h |
| Lab 03 — DynamoDB | Tabla + GSI + capacity modes + TTL + DynamoDB Streams + Lambda | < $1 |
| Lab 04 — ElastiCache | Redis Cluster Mode + cache-aside pattern + pipeline de invalidación | ~0.5€/h |
| Lab 05 — 3-tier full stack | Aurora + RDS Proxy + DynamoDB + Lambda + ElastiCache integrados en una VPC 3-tier | ~5€/h |

Incluye guías de troubleshooting: conexión fallida a RDS, aurora no hace failover, throttling DynamoDB, cache inconsistente, y más.

---

### Security — Organizations, Identity Center y Governance

**Por qué:** La seguridad multi-cuenta es el modelo estándar de AWS para enterprise. Entender Organizations, SCPs, Identity Center (SSO) y logging centralizado es imprescindible tanto para el examen SA Associate como para el Security Specialty.

| Lab | Qué se construye | Coste |
|-----|-----------------|-------|
| Lab 01 — Security & Governance multi-cuenta | Organizations + OUs + SCPs + Identity Center + CloudTrail + Config + Secrets Manager | ~15-20€/sesión |
| Lab 02 — IAM Access Analyzer | Zone of trust, findings (Active/Archived/Resolved), S3 y cross-account | GRATIS |
| Lab 03 — AWS Config + Remediation | Config Rules (managed/custom Lambda) + Automatic Remediation SSM + Aggregator | ~$2-3 |
| Lab 04 — Amazon GuardDuty | Threat detection, Trusted IP Lists, Suppression Rules, EventBridge → Lambda | GRATIS 30 días |
| Lab 05 — AWS Security Hub | Findings aggregation, Security Score, CIS/FSBP standards, Automation Rules | GRATIS 30 días |
| Lab 06 — Amazon Inspector | CVE scanning en EC2/ECR (Enhanced vs Basic), DevSecOps pipeline integration | GRATIS 30 días |
| Lab 07 — Amazon Macie | `SensitiveData:` vs `Policy:` findings, PII detection, Custom Identifiers | GRATIS 30 días |
| Lab 08 — Amazon Detective | Behavior graph, forensic investigation, Detective vs CloudTrail | GRATIS 30 días |

---

### Data & Streaming — Kinesis, MSK, Glue, EMR, Redshift, OpenSearch

**Por qué:** Los servicios de datos son una de las áreas de mayor peso en el SA Associate. Saber cuándo elegir Kinesis vs MSK, Glue vs EMR, Redshift vs Athena es fundamental para el examen y para diseñar arquitecturas de datos modernas.

8 labs que cubren el ciclo completo de datos (ingesta → procesamiento → almacenamiento → consulta → gobernanza):

| Lab | Qué se construye | Coste |
|-----|-----------------|-------|
| Lab 01 — Kinesis | Data Streams (shards, consumers) + Firehose (S3/Redshift) + patrones de arquitectura | ~$0.50/h |
| Lab 02 — Kinesis Analytics | SQL/Flink sobre streams, windowing, anomaly detection con RANDOM_CUT_FOREST | ~$0.50/h |
| Lab 03 — MSK | Kafka gestionado, topics/partitions, MSK Connect (S3 Sink Connector) | partition-hours |
| Lab 04 — Glue + Lake Formation | ETL serverless, Data Catalog, column-level security con Lake Formation | mínimo |
| Lab 05 — EMR Serverless | Spark sin gestionar clusters, integración con Glue Data Catalog | solo job duration |
| Lab 06 — Redshift | Data warehouse columnar, COPY desde S3, Redshift Spectrum sobre S3 | Serverless RPU |
| Lab 07 — OpenSearch | Búsqueda full-text, pipeline Firehose → OpenSearch, dashboards | instancia/h |
| Lab 08 — Data Lake con Terragrunt | Arquitectura lambda completa (batch + streaming) con Terragrunt multi-capa | variable |

---

## Herramientas utilizadas

- **AWS CLI v2** — aprovisionamiento manual y scripts de validación
- **Terraform ≥ 1.7** — IaC de todos los labs
- **Terragrunt** — gestión multi-entorno (v5+ en compute, v5+ en ECS, labs networking)
- **Atmos** — stacks declarativos para arquitecturas enterprise
- **GitHub Actions** — CI/CD con OIDC (sin access keys en secretos)
- **Docker** — build y push de imágenes a ECR (labs ECS)
- **SSM Session Manager** — acceso a EC2 sin SSH ni bastión (labs networking y databases)

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
