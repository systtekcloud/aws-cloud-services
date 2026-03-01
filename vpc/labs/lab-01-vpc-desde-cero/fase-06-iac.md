# Fase 6 — IaC: Terraform + GitHub Actions + Atmos

> **Tiempo:** ~60 min | **Coste:** 0€ extra (la infra es la misma que las fases anteriores) | **Prerequisito:** Terraform ≥ 1.7, GitHub repo, Fases 1-5 completadas

---

## Objetivo

Reproducir toda la VPC de este lab con código. Aprenderás:
- Estructurar un módulo Terraform reutilizable para VPC
- Gestionar estado remoto con S3 + DynamoDB Lock
- Automatizar plan/apply con GitHub Actions (OIDC — sin secrets de larga duración)
- Entender qué añade Atmos para entornos múltiples (dev/staging/prod)

---

## Estructura de directorios

```
vpc/
└── labs/
    └── lab-01-vpc-desde-cero/
        └── terraform/
            ├── modules/
            │   └── vpc/
            │       ├── main.tf          ← Recursos VPC
            │       ├── variables.tf     ← Inputs del módulo
            │       └── outputs.tf       ← Outputs exportables
            ├── envs/
            │   ├── dev/
            │   │   ├── main.tf          ← Llama al módulo con valores dev
            │   │   ├── terraform.tfvars ← Variables específicas de dev
            │   │   └── backend.tf       ← Estado remoto en S3
            │   └── prod/
            │       ├── main.tf
            │       ├── terraform.tfvars
            │       └── backend.tf
            └── .github/
                └── workflows/
                    └── vpc-cicd.yml     ← Pipeline CI/CD
```

---

## Parte A — Módulo Terraform para VPC

### `modules/vpc/variables.tf`

```hcl
variable "vpc_name" {
  description = "Nombre de la VPC (se usa en tags)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block de la VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "azs" {
  description = "Lista de Availability Zones a usar"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]
}

variable "public_subnets" {
  description = "CIDRs de subnets públicas (una por AZ)"
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "private_subnets" {
  description = "CIDRs de subnets privadas"
  type        = list(string)
  default     = ["10.10.11.0/24", "10.10.12.0/24"]
}

variable "isolated_subnets" {
  description = "CIDRs de subnets aisladas (sin ruta a internet)"
  type        = list(string)
  default     = ["10.10.21.0/24", "10.10.22.0/24"]
}

variable "enable_nat_gateway" {
  description = "Crear NAT Gateway (genera coste). Desactivar para entornos de bajo coste."
  type        = bool
  default     = false
}

variable "enable_s3_endpoint" {
  description = "Crear Gateway Endpoint para S3 (gratis)"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Activar VPC Flow Logs a CloudWatch"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags comunes para todos los recursos"
  type        = map(string)
  default     = {}
}
```

### `modules/vpc/main.tf`

```hcl
locals {
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    VpcName   = var.vpc_name
  })
}

# ── VPC ─────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = var.vpc_name })
}

# ── Subnets públicas ─────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count             = length(var.public_subnets)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnets[count.index]
  availability_zone = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-public-${count.index + 1}"
    Tier = "public"
  })
}

# ── Subnets privadas ─────────────────────────────────────────────────────────
resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-private-${count.index + 1}"
    Tier = "private"
  })
}

# ── Subnets aisladas ─────────────────────────────────────────────────────────
resource "aws_subnet" "isolated" {
  count             = length(var.isolated_subnets)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.isolated_subnets[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-isolated-${count.index + 1}"
    Tier = "isolated"
  })
}

# ── Internet Gateway ─────────────────────────────────────────────────────────
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "igw-${var.vpc_name}" })
}

# ── NAT Gateway (condicional) ────────────────────────────────────────────────
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "eip-nat-${var.vpc_name}" })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(local.common_tags, { Name = "nat-${var.vpc_name}" })
  depends_on    = [aws_internet_gateway.this]
}

# ── Route Tables ─────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, { Name = "rt-public-${var.vpc_name}" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "rt-private-${var.vpc_name}" })
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id
  # Sin ruta 0.0.0.0/0 — intencional
  tags   = merge(local.common_tags, { Name = "rt-isolated-${var.vpc_name}" })
}

resource "aws_route_table_association" "isolated" {
  count          = length(aws_subnet.isolated)
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

# ── Gateway Endpoint S3 (condicional, gratis) ────────────────────────────────
resource "aws_vpc_endpoint" "s3" {
  count           = var.enable_s3_endpoint ? 1 : 0
  vpc_id          = aws_vpc.this.id
  service_name    = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.isolated.id,
  ]
  tags = merge(local.common_tags, { Name = "ep-s3-${var.vpc_name}" })
}

data "aws_region" "current" {}

# ── Flow Logs (condicional) ──────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/vpc/flow-logs/${var.vpc_name}"
  retention_in_days = 7
  tags              = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "flow-logs-role-${var.vpc_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count  = var.enable_flow_logs ? 1 : 0
  name   = "flow-logs-cw-policy"
  role   = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup", "logs:CreateLogStream",
        "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "this" {
  count                = var.enable_flow_logs ? 1 : 0
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  iam_role_arn         = aws_iam_role.flow_logs[0].arn
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  max_aggregation_interval = 60
  tags                 = merge(local.common_tags, { Name = "flow-logs-${var.vpc_name}" })
}
```

### `modules/vpc/outputs.tf`

```hcl
output "vpc_id"               { value = aws_vpc.this.id }
output "vpc_cidr"             { value = aws_vpc.this.cidr_block }
output "public_subnet_ids"    { value = aws_subnet.public[*].id }
output "private_subnet_ids"   { value = aws_subnet.private[*].id }
output "isolated_subnet_ids"  { value = aws_subnet.isolated[*].id }
output "public_route_table_id"   { value = aws_route_table.public.id }
output "private_route_table_id"  { value = aws_route_table.private.id }
output "isolated_route_table_id" { value = aws_route_table.isolated.id }
output "nat_gateway_id"       { value = var.enable_nat_gateway ? aws_nat_gateway.this[0].id : null }
output "s3_endpoint_id"       { value = var.enable_s3_endpoint ? aws_vpc_endpoint.s3[0].id : null }
```

---

## Parte B — Entorno Dev

### `envs/dev/backend.tf`

```hcl
terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "tf-state-vpc-lab-ACCOUNT_ID"  # reemplaza ACCOUNT_ID
    key            = "vpc/dev/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "tf-lock-vpc-lab"
    encrypt        = true
  }
}
```

### `envs/dev/main.tf`

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "vpc-lab"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

module "vpc" {
  source = "../../modules/vpc"

  vpc_name         = "vpc-lab-${var.environment}"
  vpc_cidr         = var.vpc_cidr
  azs              = var.azs
  public_subnets   = var.public_subnets
  private_subnets  = var.private_subnets
  isolated_subnets = var.isolated_subnets

  enable_nat_gateway = false   # false en dev para ahorrar coste
  enable_s3_endpoint = true
  enable_flow_logs   = var.enable_flow_logs
}

output "vpc_id"            { value = module.vpc.vpc_id }
output "public_subnets"    { value = module.vpc.public_subnet_ids }
output "private_subnets"   { value = module.vpc.private_subnet_ids }
output "isolated_subnets"  { value = module.vpc.isolated_subnet_ids }
```

### `envs/dev/terraform.tfvars`

```hcl
region      = "eu-west-1"
environment = "dev"

vpc_cidr = "10.10.0.0/16"
azs      = ["eu-west-1a", "eu-west-1b"]

public_subnets   = ["10.10.1.0/24", "10.10.2.0/24"]
private_subnets  = ["10.10.11.0/24", "10.10.12.0/24"]
isolated_subnets = ["10.10.21.0/24", "10.10.22.0/24"]

enable_flow_logs = false  # activar solo cuando se necesite debugging
```

---

## Parte C — Estado Remoto (prerequisito del pipeline)

Antes de ejecutar el pipeline, crea el bucket S3 y la tabla DynamoDB para el estado:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="tf-state-vpc-lab-$ACCOUNT_ID"

# Bucket S3 con versionado y cifrado
aws s3api create-bucket \
  --bucket $BUCKET \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

aws s3api put-bucket-versioning \
  --bucket $BUCKET \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket $BUCKET \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Tabla DynamoDB para lock
aws dynamodb create-table \
  --table-name tf-lock-vpc-lab \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-1

# Actualizar el bucket name en backend.tf
sed -i "s/tf-state-vpc-lab-ACCOUNT_ID/$BUCKET/" envs/dev/backend.tf
```

---

## Parte D — GitHub Actions CI/CD

### Configurar OIDC (sin secrets de larga duración)

OIDC permite a GitHub Actions asumir un IAM Role directamente — sin `AWS_ACCESS_KEY_ID` ni `AWS_SECRET_ACCESS_KEY` en los secrets del repo.

```bash
# 1. Crear OIDC provider para GitHub en tu cuenta AWS
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# 2. Crear IAM Role para GitHub Actions
cat > /tmp/gh-oidc-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:TU_GITHUB_USER/TU_REPO:*"
      },
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name github-actions-vpc-lab \
  --assume-role-policy-document file:///tmp/gh-oidc-trust.json

# Política mínima: permisos VPC + IAM para el módulo
aws iam attach-role-policy \
  --role-name github-actions-vpc-lab \
  --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess

# Guardar el ARN del role
GH_ROLE_ARN=$(aws iam get-role \
  --role-name github-actions-vpc-lab \
  --query 'Role.Arn' --output text)
echo "GH_ROLE_ARN=$GH_ROLE_ARN"
# Añade este ARN como secreto en GitHub: Settings > Secrets > AWS_ROLE_ARN
```

### `.github/workflows/vpc-cicd.yml`

```yaml
name: VPC Infrastructure CI/CD

on:
  pull_request:
    branches: [main]
    paths:
      - 'vpc/labs/lab-01-vpc-desde-cero/terraform/**'
  push:
    branches: [main]
    paths:
      - 'vpc/labs/lab-01-vpc-desde-cero/terraform/**'

env:
  TF_WORKING_DIR: vpc/labs/lab-01-vpc-desde-cero/terraform/envs/dev
  AWS_REGION: eu-west-1

permissions:
  id-token: write   # necesario para OIDC
  contents: read
  pull-requests: write  # para comentar el plan en el PR

jobs:
  # ── Plan (en Pull Requests) ──────────────────────────────────────────────
  plan:
    name: Terraform Plan
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: Terraform Format Check
        id: fmt
        run: terraform fmt -check -recursive
        working-directory: ${{ env.TF_WORKING_DIR }}
        continue-on-error: true

      - name: Terraform Init
        id: init
        run: terraform init
        working-directory: ${{ env.TF_WORKING_DIR }}

      - name: Terraform Validate
        id: validate
        run: terraform validate
        working-directory: ${{ env.TF_WORKING_DIR }}

      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color -out=tfplan 2>&1 | tee plan_output.txt
        working-directory: ${{ env.TF_WORKING_DIR }}
        continue-on-error: true

      - name: Comentar Plan en PR
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const planOutput = fs.readFileSync(
              '${{ env.TF_WORKING_DIR }}/plan_output.txt', 'utf8'
            ).slice(0, 60000);  // GitHub PR comment limit

            const output = `## Terraform Plan 🚀
            #### Format: \`${{ steps.fmt.outcome }}\`
            #### Init: \`${{ steps.init.outcome }}\`
            #### Validate: \`${{ steps.validate.outcome }}\`
            #### Plan: \`${{ steps.plan.outcome }}\`

            <details><summary>Ver Plan completo</summary>

            \`\`\`terraform
            ${planOutput}
            \`\`\`
            </details>

            *Ejecutado por: @${{ github.actor }}*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });

  # ── Apply (en merge a main) ──────────────────────────────────────────────
  apply:
    name: Terraform Apply
    runs-on: ubuntu-latest
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    environment: production   # requiere aprobación manual en GitHub

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: Terraform Init
        run: terraform init
        working-directory: ${{ env.TF_WORKING_DIR }}

      - name: Terraform Apply
        run: terraform apply -auto-approve
        working-directory: ${{ env.TF_WORKING_DIR }}
```

---

## Parte E — Atmos (gestión multi-entorno)

Atmos es un framework sobre Terraform que estandariza la gestión de múltiples entornos y cuentas. Útil cuando tienes dev/staging/prod con la misma infra pero parámetros distintos.

### Concepto de stacks en Atmos

```yaml
# atmos/stacks/eu-west-1/dev/vpc.yaml
components:
  terraform:
    vpc:
      metadata:
        component: vpc           # apunta al módulo terraform/modules/vpc
      vars:
        vpc_name:          "vpc-lab-dev"
        vpc_cidr:          "10.10.0.0/16"
        enable_nat_gateway: false
        enable_flow_logs:   false
        tags:
          Environment: dev
          CostCenter:  engineering

# atmos/stacks/eu-west-1/prod/vpc.yaml
components:
  terraform:
    vpc:
      metadata:
        component: vpc
      vars:
        vpc_name:          "vpc-lab-prod"
        vpc_cidr:          "10.20.0.0/16"   # CIDR distinto — no solapar
        enable_nat_gateway: true             # prod sí tiene NAT
        enable_flow_logs:   true             # prod sí tiene observabilidad
        tags:
          Environment: prod
          CostCenter:  platform
```

### Comandos Atmos

```bash
# Instalar Atmos
brew install cloudposse/tap/atmos

# Plan en dev
atmos terraform plan vpc --stack eu-west-1/dev

# Apply en dev
atmos terraform apply vpc --stack eu-west-1/dev

# Plan en prod (ves la diferencia de configuración)
atmos terraform plan vpc --stack eu-west-1/prod

# Ver diferencias entre stacks
atmos describe stacks --stack eu-west-1/dev --format json | jq '.components.terraform.vpc.vars'
```

### ¿Cuándo usar Atmos vs Terraform vanilla?

| Situación | Recomendación |
|-----------|--------------|
| 1 entorno, 1 cuenta | Terraform vanilla (este lab) |
| 2-3 entornos, 1 cuenta | Workspaces de Terraform o directorios por env |
| Multi-cuenta AWS (Landing Zone) | **Atmos** — gestiona el grafo de dependencias entre stacks |
| Organización grande con plataform team | **Atmos** — estandariza módulos y pipelines |

---

## Validación de la Fase 6

```bash
# 1. Inicializar y planear localmente
cd terraform/envs/dev
terraform init
terraform plan -var-file=terraform.tfvars

# 2. Verificar que el plan muestra los recursos esperados
# Esperado: ~15-20 resources to add (VPC, subnets, IGW, RTs, EP S3)

# 3. Aplicar (crea los recursos)
terraform apply -var-file=terraform.tfvars -auto-approve

# 4. Verificar outputs
terraform output

# 5. Comparar con lo creado en fases anteriores (misma arquitectura)
aws ec2 describe-vpcs \
  --filters "Name=tag:ManagedBy,Values=terraform" \
  --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`VpcName`].Value|[0]]' \
  --output table

# 6. Destruir (no dejar recursos innecesarios)
terraform destroy -var-file=terraform.tfvars -auto-approve
```

✅ **Señales de éxito:**
- `terraform plan` muestra exactamente los mismos recursos que creaste manualmente en Fases 1-5
- El pipeline de GitHub Actions comenta el plan en el PR automáticamente
- `terraform destroy` borra todo sin errores de dependencias

---

**Siguiente paso:** [cleanup.md](./cleanup.md) para borrar cualquier recurso manual que quede.
