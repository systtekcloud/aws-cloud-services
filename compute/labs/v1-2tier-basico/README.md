# v1 — 2-Tier Básico: ALB + Auto Scaling Group

## Objetivo

Construir la arquitectura 2-tier mínima de producción:

```
Internet
    │
  [IGW]
    │
[ALB externo — HTTPS:80]
sg-alb: 0.0.0.0/0:80
    │
    ├── AZ-a          ├── AZ-b          ├── AZ-c
  EC2 t3.micro      EC2 t3.micro      EC2 t3.micro
  subnet-app-a      subnet-app-b      subnet-app-c
  (ASG desired=2, min=2, max=6)
  sg-ec2: src=sg-alb:8080
    │
  [NAT GW AZ-a]   [NAT GW AZ-b]
  subnet-pub-a     subnet-pub-b
```

## Prerrequisitos

- AWS CLI v2 configurado y con permisos suficientes
- Variables de entorno base exportadas:
  ```bash
  export REGION=eu-west-1
  export DOMAIN=systtekcloud.dev
  export PROJECT=ec2-lab
  export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  ```
- Terraform >= 1.5 (solo para Fase B)

---

## Fase A — CLI

### Consola AWS (pasos de alto nivel)

1. **Budget**: Billing > Budgets > Create budget → 25 USD, alerta 80%
2. **VPC**: VPC > Create VPC → CIDR 10.0.0.0/16, DNS hostnames ON
3. **Subnets**: 3 públicas (10.0.1-3.0/24) + 3 privadas app (10.0.11-13.0/24) + 3 privadas db (10.0.21-23.0/24)
4. **IGW**: VPC > IGW > Create + Attach a la VPC
5. **NAT GW**: 2 NAT GWs (AZ-a y AZ-b) en subnets públicas con EIPs
6. **Route Tables**: RT pública → IGW; RT privada AZ-a → NAT-a; RT privada AZ-b → NAT-b
7. **IAM Role**: IAM > Roles > Create → EC2 trust policy + SSM + CloudWatch
8. **SGs**: `sg-alb-ext` (0.0.0.0/0:80) y `sg-ec2-app` (src=sg-alb-ext:8080)
9. **Launch Template**: EC2 > Launch Templates > Create (IMDSv2, gp3, user-data)
10. **Target Group**: tipo `instance`, puerto 8080, health check `/health:200`
11. **ALB**: internet-facing, subnets públicas, listener HTTP:80 → TG
12. **ASG**: min=2, max=6, desired=2, health-check-type=ELB, grace=120s

### CLI paso a paso

```bash
./cli/01-prereqs.sh       # Budget alarm, Key pair, IAM role
./cli/02-networking.sh    # VPC, subnets, IGW, NAT GW, route tables, S3 endpoint
./cli/03-compute.sh       # SGs, Launch Template, TG, ALB, ASG
./cli/04-validacion.sh    # Health checks, curl tests, métricas
```

---

## Fase B — Terraform

```bash
cd terraform/

# Inicializar providers
terraform init

# Revisar plan
terraform plan \
  -var="account_id=$ACCOUNT_ID" \
  -var="region=$REGION" \
  -var="project=$PROJECT"

# Aplicar
terraform apply \
  -var="account_id=$ACCOUNT_ID" \
  -var="region=$REGION" \
  -var="project=$PROJECT"

# Obtener ALB DNS
terraform output alb_dns_name

# Verificar
curl http://$(terraform output -raw alb_dns_name)/health
```

### Estado remoto (opcional — recomendado)

```bash
# Crear bucket S3 para state + tabla DynamoDB para lock
aws s3api create-bucket --bucket tf-state-ec2-lab-$ACCOUNT_ID \
  --region $REGION --create-bucket-configuration LocationConstraint=$REGION
aws dynamodb create-table --table-name tf-locks-ec2-lab \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region $REGION

# Descomentar el bloque backend "s3" en terraform/main.tf
```

---

## Expected Outcomes

| Verificación | Comando | Resultado esperado |
|---|---|---|
| 2 targets healthy | `aws elbv2 describe-target-health --target-group-arn $TG_ARN` | 2 × `healthy` |
| App responde | `curl http://$ALB_DNS/` | JSON con host, AZ, version |
| Round-robin | 10 curls → 2 hosts distintos | Instancias distintas AZ-a/b |
| ASG distribuido | `aws autoscaling describe-auto-scaling-instances` | Instancias en ≥2 AZs |

---

## Conceptos clave (examen SAA-C03)

| Concepto | Exam trap |
|----------|-----------|
| Health check type | `health-check-type=ELB` detecta app caída; `EC2` solo detecta VM parada |
| SG source | SG EC2 usa `src=sg-alb-id`, no CIDRs — cuando el ALB escala, las IPs cambian |
| Target type | `instance` para ASG tradicional; `ip` para ECS/Lambda/VPC-peer |
| IMDSv2 | `HttpTokens=required` en el LT — obligatorio para CIS/PCI compliance |
| LT vs LC | Launch Configuration está deprecada — usar siempre Launch Template |

---

## Limpieza

```bash
./cli/99-cleanup.sh
# O con Terraform:
terraform destroy -var="account_id=$ACCOUNT_ID" -var="region=$REGION" -var="project=$PROJECT"
```

> **Recursos más costosos**: NAT GW (~0.048 USD/h × 2). Bórralos aunque no haya tráfico.
