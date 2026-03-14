# Fase 6 — IaC: Terraform + GitHub Actions + Atmos

> **Tiempo:** ~60 min | **Coste:** 0€ extra (la infra es la misma que las fases anteriores) | **Prerequisito:** Terraform ≥ 1.12, GitHub repo, Fases 1-5 completadas

---

## Objetivo

Reproducir toda la VPC de este lab con código. Aprenderás:
- Estructurar un módulo Terraform reutilizable para VPC
- Gestionar estado remoto con S3 (locking nativo desde Terraform 1.10)
- Automatizar plan/apply con GitHub Actions (OIDC — sin secrets de larga duración)
- Entender qué añade Atmos para entornos múltiples (dev/staging/prod)

---

## Estructura de directorios

```
vpc/
└── labs/
    └── lab01-vpc/
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
  service_name    = "com.amazonaws.${data.aws_region.current.region}.s3"
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

# ── NACL para subnets aisladas ────────────────────────────────────────────────
# Stateless: necesita reglas explícitas inbound + outbound, incluidos puertos efímeros
resource "aws_network_acl" "isolated" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.isolated[*].id

  # Inbound: respuestas TCP desde S3 vía Gateway Endpoint (puertos efímeros)
  # NACLs no soportan prefix lists — 0.0.0.0/0 es seguro: rt-isolated no tiene ruta default
  ingress {
    rule_no    = 90
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Inbound: PostgreSQL desde subnets privadas
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.private_subnets[0]
    from_port  = 5432
    to_port    = 5432
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.private_subnets[1]
    from_port  = 5432
    to_port    = 5432
  }

  # Inbound: ICMP desde subnets privadas (ping hacia la DB)
  ingress {
    rule_no    = 120
    protocol   = "icmp"
    action     = "allow"
    cidr_block = var.private_subnets[0]
    from_port  = 0
    to_port    = 0
    icmp_type  = -1
    icmp_code  = -1
  }

  ingress {
    rule_no    = 130
    protocol   = "icmp"
    action     = "allow"
    cidr_block = var.private_subnets[1]
    from_port  = 0
    to_port    = 0
    icmp_type  = -1
    icmp_code  = -1
  }

  # Outbound: HTTPS hacia S3 vía Gateway Endpoint
  egress {
    rule_no    = 90
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # Outbound: puertos efímeros hacia privadas (respuestas TCP de 5432)
  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.private_subnets[0]
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.private_subnets[1]
    from_port  = 1024
    to_port    = 65535
  }

  # Outbound: ICMP hacia subnets privadas (echo-reply del ping)
  egress {
    rule_no    = 120
    protocol   = "icmp"
    action     = "allow"
    cidr_block = var.private_subnets[0]
    from_port  = 0
    to_port    = 0
    icmp_type  = -1
    icmp_code  = -1
  }

  egress {
    rule_no    = 130
    protocol   = "icmp"
    action     = "allow"
    cidr_block = var.private_subnets[1]
    from_port  = 0
    to_port    = 0
    icmp_type  = -1
    icmp_code  = -1
  }

  tags = merge(local.common_tags, { Name = "nacl-isolated-${var.vpc_name}" })
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

### `envs/dev/variables.tf`

```hcl
variable "region"      { type = string }
variable "environment" { type = string }
variable "vpc_cidr"    { type = string }
variable "azs"         { type = list(string) }
variable "public_subnets"   { type = list(string) }
variable "private_subnets"  { type = list(string) }
variable "isolated_subnets" { type = list(string) }
variable "enable_flow_logs" { type = bool; default = false }
```

### `envs/dev/backend.tf`

```hcl
terraform {
  required_version = ">= 1.10"

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
    use_lockfile   = true  # locking nativo S3, no requiere DynamoDB
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

Antes de ejecutar el pipeline, crea el bucket S3 para el estado (el locking es nativo desde Terraform 1.10, no se necesita DynamoDB):

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

# 2. Crear trust policy — solo permite el repo concreto en el branch main (apply)
#    y en pull_requests. Condición con StringEquals, no StringLike, para evitar
#    que repos de terceros puedan asumir el role por coincidencia de prefijo.
cat > ./policy/gh-oidc-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowMainBranchApply",
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:TU_GITHUB_USER/TU_REPO:ref:refs/heads/main"
        }
      }
    },
    {
      "Sid": "AllowPullRequestPlan",
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:TU_GITHUB_USER/TU_REPO:pull_request"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name github-actions-vpc-lab \
  --assume-role-policy-document file://policy/gh-oidc-trust.json \
  --max-session-duration 3600

# 3. Política de mínimo privilegio — solo lo que Terraform necesita para este módulo
cat > ./policy/gh-actions-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VPCManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute", "ec2:DescribeVpcs",
        "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute", "ec2:DescribeSubnets",
        "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway", "ec2:DetachInternetGateway", "ec2:DescribeInternetGateways",
        "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
        "ec2:CreateRoute", "ec2:DeleteRoute",
        "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
        "ec2:ReplaceRouteTableAssociation", "ec2:DescribeRouteTables",
        "ec2:CreateNatGateway", "ec2:DeleteNatGateway", "ec2:DescribeNatGateways",
        "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:DescribeAddresses",
        "ec2:CreateNetworkAcl", "ec2:DeleteNetworkAcl",
        "ec2:CreateNetworkAclEntry", "ec2:DeleteNetworkAclEntry",
        "ec2:ReplaceNetworkAclAssociation", "ec2:DescribeNetworkAcls",
        "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints",
        "ec2:ModifyVpcEndpoint", "ec2:DescribeVpcEndpoints",
        "ec2:DescribePrefixLists", "ec2:DescribeAvailabilityZones",
        "ec2:CreateTags", "ec2:DeleteTags", "ec2:DescribeTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "FlowLogs",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateFlowLogs", "ec2:DeleteFlowLogs", "ec2:DescribeFlowLogs",
        "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy", "logs:ListTagsLogGroup", "logs:TagLogGroup"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMFlowLogsRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy",
        "iam:GetRole", "iam:GetRolePolicy",
        "iam:PassRole",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
        "iam:TagRole", "iam:UntagRole"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/flow-logs-role-*"
    },
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:GetBucketVersioning", "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::tf-state-vpc-lab-${ACCOUNT_ID}",
        "arn:aws:s3:::tf-state-vpc-lab-${ACCOUNT_ID}/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name github-actions-vpc-lab \
  --policy-name terraform-vpc-lab \
  --policy-document file://policy/gh-actions-policy.json

# 4. Guardar el ARN del role
GH_ROLE_ARN=$(aws iam get-role \
  --role-name github-actions-vpc-lab \
  --query 'Role.Arn' --output text)
echo "GH_ROLE_ARN=$GH_ROLE_ARN"
# Añade este ARN como secreto en GitHub: Settings > Secrets > AWS_ROLE_ARN
```

> 🔒 **Por qué `StringEquals` en la trust policy:** Usar `StringLike` con `repo:USER/REPO:*` permite que cualquier contexto del repo (environments, tags, cualquier rama) asuma el role. Separamos los statements: `main` con `StringEquals` exacto para apply, y `pull_request` para plan. Así los PRs de forks no pueden ejecutar apply.
>
> 🔒 **Por qué política inline y no managed:** La política inline está acotada exactamente a los recursos que Terraform gestiona. `AmazonVPCFullAccess` incluye permisos que no usamos (VPN, peering, Transit Gateway) y no restringe el bucket de estado.

### `.github/workflows/vpc-cicd.yml`

```yaml
name: VPC Infrastructure CI/CD

on:
  pull_request:
    branches: [main]
    paths:
      - 'vpc/labs/lab01-vpc/terraform/**'
  push:
    branches: [main]
    paths:
      - 'vpc/labs/lab01-vpc/terraform/**'

env:
  TF_WORKING_DIR: vpc/labs/lab01-vpc/terraform/envs/dev
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
          terraform_version: "1.12.0"

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
          terraform_version: "1.12.0"

      - name: Terraform Init
        run: terraform init
        working-directory: ${{ env.TF_WORKING_DIR }}

      - name: Terraform Apply
        run: terraform apply -auto-approve
        working-directory: ${{ env.TF_WORKING_DIR }}
```

---

## Parte E — Atmos (gestión multi-entorno)

### Introducción para neófitos

#### ¿Qué problema resuelve?

Imagina que tienes esta VPC funcionando en dev y ahora quieres desplegarla también en staging y prod. Con Terraform vanilla tienes dos opciones, y ambas duelen:

**Opción A — Copiar directorios:**
```
envs/
├── dev/    # main.tf, backend.tf, terraform.tfvars
├── stg/    # ídem — copypaste de dev
└── prod/   # ídem — copypaste de stg
```
Problema: cuando cambias una variable (p.ej. `enable_s3_endpoint = true`) tienes que editarlo en los 3 sitios. Con 10 entornos y 20 módulos son 200 archivos a tocar.

**Opción B — Terraform Workspaces:**
Un solo directorio, múltiples estados. Parece elegante pero los workspaces no soportan backends diferentes por entorno, ni cuentas AWS distintas, ni valores radicalmente distintos entre entornos sin lógica condicional que ensucia el código.

**Atmos resuelve esto con herencia YAML.** Defines los valores comunes una vez en un catálogo, y cada entorno solo sobreescribe lo que cambia.

---

#### Los tres conceptos clave

```
┌─────────────────────────────────────────────────────────┐
│  ATMOS                                                  │
│                                                         │
│  Component  =  un módulo Terraform  (p.ej. modules/vpc) │
│  Stack      =  un entorno/cuenta    (p.ej. dev, prod)   │
│  Catalog    =  valores por defecto compartidos          │
│                                                         │
│  Stack hereda de Catalog → solo sobreescribe diferencias│
└─────────────────────────────────────────────────────────┘
```

**Analogía con programación orientada a objetos:**
- `catalog/vpc.yaml` es la **clase base** con los valores por defecto
- `eu-west-1/dev/vpc.yaml` es una **subclase** que hereda y sobreescribe solo lo necesario
- `atmos terraform plan vpc --stack dev` es **instanciar la clase** en ese entorno

#### ¿Qué hace Atmos exactamente?

Atmos es un **orquestador CLI** — no reemplaza Terraform, lo envuelve. Cuando ejecutas:

```bash
atmos terraform plan vpc --stack vpc-lab-dev
```

Atmos hace por ti lo que harías a mano con Terraform vanilla:
1. Lee todos los YAML del stack (con herencia del catálogo)
2. Mezcla las variables en el orden correcto (catálogo → región → entorno)
3. Genera el `backend.tf` automáticamente
4. Ejecuta `terraform init && terraform plan` con las vars correctas

Sin Atmos necesitarías hacer esto manualmente para cada entorno.

#### Flujo de herencia de variables

```
catalog/vpc.yaml          ← valores base (azs, subnets, enable_s3_endpoint...)
        │
        │  import
        ▼
eu-west-1/_defaults.yaml  ← variables de región (region, tenant)
        │
        │  import
        ▼
eu-west-1/dev/vpc.yaml    ← override del entorno (vpc_name, vpc_cidr, tags...)
        │
        │  Atmos mezcla todo
        ▼
vars finales efectivas    ← lo que recibe Terraform
```

Puedes ver las vars finales de cualquier stack en cualquier momento:
```bash
atmos describe component vpc --stack vpc-lab-dev --format json | jq '.vars'
```

#### ¿Cuándo **no** necesitas Atmos?

Si tienes un solo entorno o dos entornos simples, Atmos añade complejidad sin beneficio. Las Partes A-D de esta fase (Terraform vanilla con directorios por entorno) son suficientes. Atmos empieza a pagar su coste cuando:
- Tienes 3+ entornos
- Usas múltiples cuentas AWS (una por entorno)
- Tienes un equipo de plataforma que gestiona muchos módulos a la vez

---

Atmos es un framework CLI sobre Terraform que resuelve el problema de gestionar la misma infraestructura en múltiples entornos y cuentas AWS sin duplicar código. Introduce tres conceptos clave: **components** (módulos Terraform), **stacks** (entornos/cuentas) y **catálogo** (valores compartidos con herencia).

### Estructura de directorios Atmos

```
vpc/labs/lab01-vpc/
├── atmos.yaml                        ← Configuración global de Atmos
├── terraform/
│   └── modules/
│       └── vpc/                      ← El módulo que ya creamos (Parte A)
└── stacks/
    ├── catalog/
    │   └── vpc.yaml                  ← Valores por defecto compartidos (mixin)
    └── eu-west-1/
        ├── _defaults.yaml            ← Variables globales de la región
        ├── dev/
        │   └── vpc.yaml              ← Override dev
        └── prod/
            └── vpc.yaml              ← Override prod
```

### `atmos.yaml` — Configuración global

```yaml
# atmos.yaml (en la raíz del proyecto)
base_path: "."

components:
  terraform:
    base_path: "terraform/modules"   # donde están los módulos
    apply_auto_approve: false
    deploy_run_init: true
    init_run_reconfigure: true
    auto_generate_backend_file: false  # backend.tf.json gestionado manualmente en el módulo
    # Con auto_generate_backend_file: false, Atmos NO genera el backend.
    # El backend completo está definido en terraform/modules/vpc/backend.tf.json
    # incluyendo bucket, key, region, workspace_key_prefix, encrypt y use_lockfile.

stacks:
  base_path: "stacks"
  included_paths:
    - "eu-west-1/**/*"
  excluded_paths:
    - "**/_defaults.yaml"
    - "**/catalog/**"
  name_pattern: "{tenant}-{environment}"

templates:
  settings:
    enabled: true   # habilita Go templates en los YAML de stacks
    # Permite usar {{ env "VAR" }} para leer variables de entorno

logs:
  file: "/dev/stderr"
  level: Info
```

> **Nota:** `${VAR}` en un YAML lo lee Atmos como cadena literal — no es expansión de shell.
> Para leer variables de entorno usa `{{ env "VAR" }}` (Go template). Requiere `templates.settings.enabled: true`.
> Antes de ejecutar Atmos exporta: `export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`

### `stacks/catalog/vpc.yaml` — Valores por defecto (mixin)

El catálogo define los valores que comparten TODOS los entornos. Los stacks heredan de aquí y solo sobreescriben lo que cambia.

```yaml
# stacks/catalog/vpc.yaml
components:
  terraform:
    vpc:
      metadata:
        component: vpc              # apunta a terraform/modules/vpc/
      backend_type: s3              # tipo de backend — requerido por Atmos para auto_generate_backend_file
      vars:
        # Valores comunes a todos los entornos
        azs:
          - eu-west-1a
          - eu-west-1b
        public_subnets:
          - "10.10.1.0/24"
          - "10.10.2.0/24"
        private_subnets:
          - "10.10.11.0/24"
          - "10.10.12.0/24"
        isolated_subnets:
          - "10.10.21.0/24"
          - "10.10.22.0/24"
        enable_s3_endpoint:  true   # gratis, siempre activo
        enable_nat_gateway:  false  # por defecto off — cada env decide
        enable_flow_logs:    false  # por defecto off — solo en prod
      settings:
        spacelift:
          workspace_enabled: false
```

### `stacks/eu-west-1/_defaults.yaml` — Variables de región

```yaml
# stacks/eu-west-1/_defaults.yaml
vars:
  region:  eu-west-1
  tenant:  vpc-lab
```

> **Importante:** `_defaults.yaml` **no se hereda automáticamente** — hay que importarlo
> explícitamente en cada stack. Atmos lo excluye del descubrimiento de stacks
> (`excluded_paths` en `atmos.yaml`) pero no lo inyecta solo. Sin importarlo,
> `atmos describe stacks` falla con `tenant not defined`.
>
> La solución es añadir la entrada en la sección `import` de cada stack:
> ```yaml
> import:
>   - eu-west-1/_defaults   # ← esto es lo que propaga tenant y region al stack
>   - catalog/vpc
> ```
> Los stacks dev y prod de abajo ya lo incluyen.

### `stacks/eu-west-1/dev/vpc.yaml` — Stack dev

```yaml
# stacks/eu-west-1/dev/vpc.yaml
import:
  - eu-west-1/_defaults             # hereda tenant + region de la región
  - catalog/vpc                     # hereda defaults del componente

vars:
  environment: dev

components:
  terraform:
    vpc:
      vars:
        vpc_name:          "vpc-lab-dev"
        vpc_cidr:          "10.10.0.0/16"
        enable_nat_gateway: false   # dev no necesita NAT — ahorra ~30€/mes
        enable_flow_logs:   false
        tags:
          Environment: dev
          CostCenter:  engineering
      backend:
        bucket: 'tf-state-vpc-lab-{{ env "AWS_ACCOUNT_ID" }}'
        key:    "eu-west-1/dev/vpc/terraform.tfstate"
        region: eu-west-1
```

### `stacks/eu-west-1/prod/vpc.yaml` — Stack prod

```yaml
# stacks/eu-west-1/prod/vpc.yaml
import:
  - eu-west-1/_defaults             # hereda tenant + region de la región
  - catalog/vpc

vars:
  environment: prod

components:
  terraform:
    vpc:
      vars:
        vpc_name:          "vpc-lab-prod"
        vpc_cidr:          "10.20.0.0/16"   # CIDR distinto — nunca solapar con dev
        enable_nat_gateway: true             # prod sí necesita NAT para updates
        enable_flow_logs:   true             # observabilidad obligatoria en prod
        tags:
          Environment: prod
          CostCenter:  platform
      backend:
        bucket: 'tf-state-vpc-lab-{{ env "AWS_ACCOUNT_ID" }}'
        key:    "eu-west-1/prod/vpc/terraform.tfstate"
        region: eu-west-1
```

### Instalación y comandos

```bash
# Instalar Atmos
brew install cloudposse/tap/atmos   # macOS
# o
curl -fsSL https://raw.githubusercontent.com/cloudposse/atmos/main/scripts/install.sh | bash

# Prerequisito: exportar account ID antes de cualquier comando Atmos
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Verificar configuración — muestra los stacks detectados
atmos describe stacks

# Ver las vars efectivas de un stack (después de herencia del catálogo)
atmos describe component vpc --stack vpc-lab-dev

# Plan en dev
atmos terraform plan vpc --stack vpc-lab-dev

# Apply en dev
atmos terraform apply vpc --stack vpc-lab-dev

# Plan en prod — mismos comandos, distinto stack
atmos terraform plan vpc --stack vpc-lab-prod

# Destroy en dev (cuidado)
atmos terraform destroy vpc --stack vpc-lab-dev

# Comparar vars entre entornos
atmos describe component vpc --stack vpc-lab-dev --format json | jq '.vars'
atmos describe component vpc --stack vpc-lab-prod --format json | jq '.vars'
```

### Integración con GitHub Actions

Reemplaza los pasos de `terraform init/plan/apply` en el workflow por comandos Atmos:

```yaml
# .github/workflows/vpc-cicd.yml (fragmento — reemplaza los steps de Terraform)

      # AWS_ACCOUNT_ID no está disponible por defecto en GitHub Actions.
      # Hay que derivarla tras asumir el rol OIDC y exportarla al entorno del job.
      - name: Export AWS Account ID
        run: |
          echo "AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)" >> $GITHUB_ENV

      - name: Setup Atmos
        uses: cloudposse/github-action-setup-atmos@v2
        with:
          atmos-version: latest

      - name: Atmos Plan
        run: |
          atmos terraform plan vpc --stack vpc-lab-${{ env.ENVIRONMENT }} \
            -- -no-color -out=tfplan 2>&1 | tee plan_output.txt
        env:
          ENVIRONMENT: dev   # o prod según el branch/env de GitHub

      - name: Atmos Apply
        if: github.ref == 'refs/heads/main'
        run: |
          atmos terraform apply vpc --stack vpc-lab-${{ env.ENVIRONMENT }} \
            -- -auto-approve
```

> **Por qué `>> $GITHUB_ENV`:** en GitHub Actions, las variables exportadas con `export` solo viven en ese paso. Usando `>> $GITHUB_ENV` la variable queda disponible para todos los pasos siguientes del job, incluido el que ejecuta Atmos con `{{ env "AWS_ACCOUNT_ID" }}`.

### ¿Cuándo usar Atmos vs Terraform vanilla?

| Situación | Recomendación |
|-----------|--------------|
| 1 entorno, 1 cuenta | **Terraform vanilla** — Partes A-D de esta fase |
| 2-3 entornos, 1 cuenta | **Directorios por env** (`envs/dev`, `envs/prod`) o workspaces |
| 3+ entornos o multi-cuenta | **Atmos** — la herencia del catálogo elimina la duplicación |
| Landing Zone multi-cuenta | **Atmos** — gestiona dependencias entre stacks (VPC → RDS → App) |
| Platform team con módulos internos | **Atmos** — catálogo centralizado + vendoring de módulos |

> 💡 **La ventaja real de Atmos:** cuando tienes 10 entornos, cambiar una variable en `catalog/vpc.yaml` la propaga a todos. Con directorios por env tendrías que editar 10 archivos. El catálogo es el equivalente a una clase base en OOP.

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
