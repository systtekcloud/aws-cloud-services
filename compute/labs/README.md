# Lab 01 — EC2: De 2-tier básico a arquitectura enterprise

Lab progresivo de EC2 para AWS Solutions Architect Associate. Cada versión (`v{n}`) añade complejidad sobre la anterior. El mismo workload evoluciona de una app básica con ALB+ASG hasta una arquitectura enterprise con IaC multi-entorno y GitOps.

## Arquitectura final (v1-v4)

```
Internet
   │
   ├── Global Accelerator (anycast IPs)
   │         │ backbone AWS
   └── Route53 (app.systtekcloud.dev) ──→ ALB (eu-west-1)
                                               │
                               ┌───────────────┴───────────────┐
                          TG-Blue (90%)                   TG-Green (10%)
                               │                                │
                          ASG-Blue                         ASG-Green
                    (EC2 subnets privadas)           (EC2 subnets privadas)
                    IMDSv2 | gp3 | AL2023           Warm Pool pre-calentado
                               │
                    ┌──────────┴──────────┐
               Aurora MySQL            ElastiCache
               Multi-AZ               Redis (TLS)
                               │
                         Secrets Manager
```

**Región:** eu-west-1 | **Dominio:** systtekcloud.dev | **Coste máx:** ~25€/mes (Aurora+GA)

---

## Versiones disponibles

| Versión | Qué añade | Coste/día | Herramientas |
|---|---|---|---|
| **v1** — 2-tier básico | VPC + ALB + ASG + Launch Template IMDSv2 | ~0.5€ | AWS CLI + Terraform |
| **v2** — 3-tier Aurora | Aurora MySQL Multi-AZ + ElastiCache Redis + Secrets Manager | ~8-12€ | AWS CLI + Terraform |
| **v3** — Resiliencia | Step Scaling + Warm Pool + FIS + Blue/Green Weighted TGs | +0€ (sobre v1) | AWS CLI + Terraform |
| **v4** — DNS global | ACM wildcard + HTTPS + Route53 Alias + Global Accelerator | ~1.5€/día | AWS CLI + Terraform |
| **v5** — Enterprise IaC | Terragrunt multi-env + Atmos stacks + GitHub Actions OIDC | 0€ (IaC) | Terragrunt + Atmos |

---

## Estructura

```
lab-01-ec2-2tier-to-3tier/
├── app/
│   └── app.py                  ← Flask app compartida (IMDSv2, /health, /db-check)
│
├── v1-2tier-basico/
│   ├── README.md               ← Instrucciones Fase A (CLI) + Fase B (Terraform)
│   ├── cli/
│   │   ├── 01-prereqs.sh       ← Budget + Key Pair + IAM + S3
│   │   ├── 02-networking.sh    ← VPC + Subnets + IGW + NAT + Route Tables
│   │   ├── 03-compute.sh       ← SGs + Launch Template + TG + ALB + ASG
│   │   ├── 04-validacion.sh    ← Health check + round-robin test
│   │   └── 99-cleanup.sh       ← Borrado ordenado completo
│   └── terraform/
│       ├── main.tf             ← VPC + ALB + ASG completo
│       ├── variables.tf
│       └── outputs.tf
│
├── v2-3tier-aurora/
│   ├── README.md
│   ├── cli/
│   │   ├── 01-db-subnets.sh    ← Subnets capa DB + subnet groups
│   │   ├── 02-aurora.sh        ← Aurora MySQL Multi-AZ
│   │   ├── 03-elasticache.sh   ← Redis TLS + auth token
│   │   ├── 04-secrets-app.sh   ← Secrets Manager + Instance Refresh
│   │   ├── 05-validacion.sh    ← Test /health con db+cache
│   │   └── 99-cleanup.sh
│   └── terraform/
│       ├── main.tf             ← Aurora + ElastiCache + Secrets Manager
│       ├── variables.tf
│       └── outputs.tf
│
├── v3-resiliencia/
│   ├── README.md
│   ├── cli/
│   │   ├── 01-scaling-policies.sh  ← Step Scaling + Scheduled
│   │   ├── 02-warm-pool.sh         ← Warm Pool (instancias pre-calentadas)
│   │   ├── 03-fault-injection.sh   ← FIS experiment: terminar EC2
│   │   ├── 04-blue-green.sh        ← Weighted TGs + ASG Green
│   │   └── 99-cleanup.sh
│   └── terraform/
│       ├── main.tf             ← Step Scaling + Warm Pool + Blue/Green TG
│       ├── variables.tf
│       └── outputs.tf
│
├── v4-dns-global/
│   ├── README.md
│   ├── cli/
│   │   ├── 01-acm-cert.sh      ← Wildcard cert + DNS validation
│   │   ├── 02-alb-https.sh     ← HTTPS listener + HTTP redirect
│   │   ├── 03-route53.sh       ← A Alias record + EvaluateTargetHealth
│   │   ├── 04-global-accel.sh  ← GA + listener + endpoint group
│   │   ├── 05-validacion.sh    ← DNS + HTTPS + GA test
│   │   └── 99-cleanup.sh
│   └── terraform/
│       ├── main.tf             ← ACM + ALB HTTPS + Route53 + Global Accelerator
│       ├── variables.tf
│       └── outputs.tf
│
├── v5-enterprise-iac/
│   ├── README.md
│   ├── terragrunt/
│   │   ├── terragrunt.hcl      ← Root: remote state S3 + DynamoDB + provider
│   │   ├── _modules/vpc/       ← Módulo VPC reutilizable
│   │   ├── dev/eu-west-1/      ← env.hcl + vpc/ + compute/ + database/
│   │   └── prod/eu-west-1/     ← env.hcl (multi-AZ NAT, instancias más grandes)
│   ├── atmos/
│   │   ├── atmos.yaml          ← Configuración Atmos
│   │   ├── components/terraform/
│   │   └── stacks/             ← globals.yaml + dev.yaml + prod.yaml
│   └── .github/workflows/
│       ├── plan.yml            ← Plan en PR (OIDC, sin access keys)
│       └── apply.yml           ← Apply en merge (dev auto, prod con aprobación)
│
└── troubleshooting/
    ├── 01-health-check-unhealthy.md   ← Target Group unhealthy (app, path, port, SG)
    ├── 02-sg-blocks-traffic.md        ← SG mal configurado + NACLs stateless
    ├── 03-asg-no-scale.md             ← ASG no escala (max, cooldown, suspensión)
    ├── 04-alb-listener-rules.md       ← Prioridad de reglas + path patterns
    ├── 05-target-type-mismatch.md     ← instance vs ip vs lambda
    ├── 06-route53-ttl-propagation.md  ← TTL, propagación, EvaluateTargetHealth
    ├── 07-global-accelerator.md       ← GA no responde (SG, health, propagación)
    └── 08-nat-routes.md               ← NAT en subnet privada, route table faltante
```

---

## Variables de entorno necesarias

Los scripts CLI usan estas variables (guardadas en `~/.ec2-lab-env`):

```bash
# Se exportan automáticamente por los scripts de cada versión
export PROJECT="ec2lab-lab"
export REGION="eu-west-1"
export VPC_ID="vpc-xxx"
export SUBNET_APP_A="subnet-xxx"
export SG_ALB_ID="sg-xxx"
export SG_EC2_ID="sg-xxx"
export ALB_DNS="ec2lab-lab-alb-xxx.eu-west-1.elb.amazonaws.com"
export TG_ARN="arn:aws:elasticloadbalancing:..."
export ASG_NAME="ec2lab-lab-asg"
export S3_BUCKET="ec2lab-lab-artefactos-123456789"
export DOMAIN="systtekcloud.dev"
```

---

## Cómo ejecutar

```bash
# 1. Subir app al bucket S3 (lo crea el script 01-prereqs.sh)
# Primero ejecutar v1 completo:
bash v1-2tier-basico/cli/01-prereqs.sh
bash v1-2tier-basico/cli/02-networking.sh
bash v1-2tier-basico/cli/03-compute.sh

# 2. Subir la app
source ~/.ec2-lab-env
aws s3 cp app/app.py s3://$S3_BUCKET/app/app.py

# 3. Validar v1
bash v1-2tier-basico/cli/04-validacion.sh

# 4. Avanzar a versiones siguientes según necesidad
bash v2-3tier-aurora/cli/01-db-subnets.sh
# ...

# 5. Cleanup al terminar (de mayor a menor versión)
bash v4-dns-global/cli/99-cleanup.sh
bash v3-resiliencia/cli/99-cleanup.sh
bash v2-3tier-aurora/cli/99-cleanup.sh
bash v1-2tier-basico/cli/99-cleanup.sh
```

---

## Recursos costosos — recordatorio

| Recurso | Coste aprox. | Acción al terminar |
|---|---|---|
| Aurora cluster (2 × db.t3.medium) | ~10€/día | `aws rds stop-db-cluster --db-cluster-identifier $AURORA_CLUSTER` (máx 7 días) |
| NAT Gateway × 3 | ~3.6€/día | Eliminar con cleanup |
| Global Accelerator | ~1.5€/día | Deshabilitar y eliminar |
| ElastiCache Redis | ~1.2€/día | Eliminar con cleanup |
| ALB | ~0.6€/día | Eliminar con cleanup |
