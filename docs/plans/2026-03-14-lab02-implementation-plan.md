# Lab 02 — Gateway Endpoint vs Interface Endpoint S3 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Demostrar con VPC Flow Logs que el tráfico S3 desde una subnet con Gateway Endpoint no pasa por NAT Gateway, mientras que sin él sí lo hace.

**Architecture:** Una VPC con dos subnets privadas. `subnet-gw` tiene route table con S3 Gateway Endpoint; `subnet-nat` solo tiene ruta al NAT GW. Dos EC2 generan tráfico S3 simultáneamente. VPC Flow Logs captura todo y `validate.sh` muestra la diferencia en bytes via NAT.

**Tech Stack:** Terraform >= 1.10, Terragrunt, AWS provider ~> 5.0, eu-west-1, S3 native locking.

---

## Convenciones (copiar de Lab 01)

- Prefijo de recursos: `${var.prefix}-resource-name` → `lab02-vpc`, `lab02-ec2-gw`, etc.
- Tags via `default_tags` en provider + `Name` individual en cada recurso
- Comentarios extensos explicando el POR QUÉ de cada decisión
- Backend key: `lab02-gateway-vs-interface-endpoint-s3/terraform.tfstate`
- Mismo bucket de estado que Lab 01: `networking-labs-tfstate-ACCOUNT-eu-west-1`

---

## Task 1: Scaffolding — estructura de carpetas

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/.gitkeep`
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terragrunt/.gitkeep`

**Step 1: Crear la estructura de directorios**

```bash
mkdir -p networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform
mkdir -p networking/labs/lab02-gateway-vs-interface-endpoint-s3/terragrunt
```

**Step 2: Verificar que existe**

```bash
ls networking/labs/lab02-gateway-vs-interface-endpoint-s3/
```
Expected output:
```
terraform/   terragrunt/
```

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/
git commit -m "chore: scaffold lab02 directory structure"
```

---

## Task 2: variables.tf

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/variables.tf`

**Step 1: Crear variables.tf**

```hcl
# =============================================================================
# variables.tf — Inputs del lab
# =============================================================================

variable "prefix" {
  description = "Prefijo para nombres de recursos"
  type        = string
  default     = "lab02"
}

variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "eu-west-1"
}

variable "vpc_cidr" {
  description = "CIDR de la VPC principal"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR de la subnet pública — donde vive el NAT Gateway"
  type        = string
  default     = "10.0.0.0/24"
}

variable "subnet_gw_cidr" {
  description = <<-EOT
    CIDR de la subnet privada con Gateway Endpoint.
    La route table de esta subnet tiene una entrada para S3 → Gateway Endpoint.
    El tráfico S3 desde aquí NO pasa por NAT Gateway.
  EOT
  type    = string
  default = "10.0.1.0/24"
}

variable "subnet_nat_cidr" {
  description = <<-EOT
    CIDR de la subnet privada sin Gateway Endpoint.
    La route table de esta subnet solo tiene 0.0.0.0/0 → NAT Gateway.
    Todo el tráfico (incluido S3) pasa por NAT Gateway.
  EOT
  type    = string
  default = "10.0.2.0/24"
}

variable "az" {
  description = "Availability Zone para todos los recursos (lab single-AZ)"
  type        = string
  default     = "eu-west-1a"
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "flow_log_retention_days" {
  description = "Días de retención de Flow Logs en CloudWatch (mínimo para ahorrar coste)"
  type        = number
  default     = 1
}
```

**Step 2: Validar sintaxis**

```bash
cd networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform
terraform validate
```
Expected: `Success! The configuration is valid.`
(Si falla con "no configuration files", es normal — aún no hay main.tf. Continúa.)

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/variables.tf
git commit -m "feat(lab02): add variables.tf"
```

---

## Task 3: vpc.tf — VPC, subnets, IGW, NAT GW, route tables

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/vpc.tf`

**Step 1: Crear vpc.tf**

```hcl
# =============================================================================
# vpc.tf — VPC, subnets, NAT Gateway y route tables diferenciadas
#
# PUNTO CLAVE: Dos subnets privadas con route tables distintas.
#
# subnet-gw-private → route table con entrada S3 → Gateway Endpoint
#   Efecto: tráfico a S3 sale por el Gateway Endpoint (interno a AWS, gratis)
#           el NAT Gateway NO ve este tráfico
#
# subnet-nat-private → route table con solo 0.0.0.0/0 → NAT Gateway
#   Efecto: tráfico a S3 sale por NAT Gateway como cualquier otro tráfico
#           genera coste de procesamiento de datos en NAT (~$0.045 per GB)
#
# VPC Flow Logs captura el tráfico en todos los ENIs, incluyendo el ENI
# del NAT Gateway. Filtrando por la IP del NAT GW como destino vemos
# exactamente cuántos bytes de S3 pasaron por él.
# =============================================================================

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.prefix}-vpc" }
}

# ---------------------------------------------------------------------------
# Subnet pública — NAT Gateway vive aquí
# Necesita IGW para que el NAT Gateway pueda enrutar tráfico saliente
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = false # NAT GW tiene EIP, no necesitamos IPs públicas aquí

  tags = { Name = "${var.prefix}-subnet-public" }
}

# ---------------------------------------------------------------------------
# Subnet privada CON Gateway Endpoint (subnet-gw)
# Las EC2 aquí acceden a S3 directamente via Gateway Endpoint
# ---------------------------------------------------------------------------
resource "aws_subnet" "gw_private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_gw_cidr
  availability_zone = var.az

  tags = { Name = "${var.prefix}-subnet-gw-private" }
}

# ---------------------------------------------------------------------------
# Subnet privada SIN Gateway Endpoint (subnet-nat)
# Las EC2 aquí acceden a S3 a través del NAT Gateway como cualquier destino
# ---------------------------------------------------------------------------
resource "aws_subnet" "nat_private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_nat_cidr
  availability_zone = var.az

  tags = { Name = "${var.prefix}-subnet-nat-private" }
}

# ---------------------------------------------------------------------------
# Internet Gateway — necesario para que el NAT Gateway salga a internet
# (S3 es un servicio AWS pero sin Gateway Endpoint, el tráfico sale a la
#  IP pública del endpoint S3 regional, pasando por internet/NAT)
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.prefix}-igw" }
}

# ---------------------------------------------------------------------------
# EIP para el NAT Gateway
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.prefix}-eip-nat" }
}

# ---------------------------------------------------------------------------
# NAT Gateway — en subnet pública
# Solo subnet-nat-private usará este NAT GW para tráfico S3
# subnet-gw-private también usa este NAT GW para tráfico NO-S3 (e.g. apt-get)
# pero su tráfico S3 va directo via Gateway Endpoint
# ---------------------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = { Name = "${var.prefix}-nat-gw" }

  depends_on = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------------------
# Route table — subnet pública
# Solo necesita ruta al IGW
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.prefix}-rt-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Route table — subnet-gw-private (CON Gateway Endpoint)
#
# NOTA: La ruta S3 → Gateway Endpoint NO se define aquí directamente.
# Se crea automáticamente cuando asociamos el Gateway Endpoint a esta
# route table en endpoints.tf usando route_table_ids.
# AWS añade una entrada con el prefix list de S3 (pl-xxxxx) como destino.
# ---------------------------------------------------------------------------
resource "aws_route_table" "gw_private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  # La ruta S3 → Gateway Endpoint se añade automáticamente via endpoints.tf
  # Después del apply verás algo como:
  #   pl-6da54004 (com.amazonaws.eu-west-1.s3) → vpce-xxxxxxxxx

  tags = { Name = "${var.prefix}-rt-gw-private" }
}

resource "aws_route_table_association" "gw_private" {
  subnet_id      = aws_subnet.gw_private.id
  route_table_id = aws_route_table.gw_private.id
}

# ---------------------------------------------------------------------------
# Route table — subnet-nat-private (SIN Gateway Endpoint)
#
# Solo tiene la ruta default a NAT GW.
# Todo el tráfico (incluido S3) pasa por NAT Gateway.
# ---------------------------------------------------------------------------
resource "aws_route_table" "nat_private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.prefix}-rt-nat-private" }
}

resource "aws_route_table_association" "nat_private" {
  subnet_id      = aws_subnet.nat_private.id
  route_table_id = aws_route_table.nat_private.id
}
```

**Step 2: Validar sintaxis**

```bash
cd networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform
terraform validate
```
Expected: `Success! The configuration is valid.`

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/vpc.tf
git commit -m "feat(lab02): add vpc.tf with dual private subnets"
```

---

## Task 4: endpoints.tf — S3 Gateway Endpoint

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/endpoints.tf`

**Step 1: Crear endpoints.tf**

```hcl
# =============================================================================
# endpoints.tf — S3 Gateway Endpoint
#
# GATEWAY ENDPOINT vs INTERFACE ENDPOINT para S3:
#
# Gateway Endpoint:
#   - Gratuito (sin coste por hora ni por GB procesado)
#   - Solo funciona dentro de la VPC (no accesible desde on-prem ni peering)
#   - Se implementa como entrada en la route table (prefix list → vpce)
#   - No tiene IP privada ni ENI — es una abstracción de enrutamiento
#   - Soporta S3 y DynamoDB únicamente
#
# Interface Endpoint (PrivateLink):
#   - $0.01/h + $0.01/GB procesado
#   - Accesible desde on-prem (via Direct Connect/VPN) y VPC Peering
#   - Tiene ENI con IP privada en la subnet
#   - Soporta la mayoría de servicios AWS
#
# Para este lab usamos Gateway Endpoint porque:
#   1. Es gratuito — demuestra el ahorro de coste real
#   2. Es el recomendado por AWS para S3 dentro de una VPC
#   3. El contraste con NAT Gateway es más impactante en coste
# =============================================================================

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.s3"

  # Gateway es el tipo correcto para S3 — no Interface
  # Interface Endpoint para S3 existe pero tiene coste adicional
  vpc_endpoint_type = "Gateway"

  # CLAVE: Solo asociamos este endpoint a la route table de subnet-gw-private.
  # subnet-nat-private NO está en esta lista → su tráfico S3 sigue por NAT GW.
  # AWS añade automáticamente una ruta en rt-gw-private:
  #   pl-6da54004 (prefix list S3 eu-west-1) → vpce-xxxxxxxxx
  route_table_ids = [aws_route_table.gw_private.id]

  # Política permisiva — permite todas las operaciones S3
  # En producción restricirías a buckets específicos o acciones concretas
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:*"
        Resource  = "*"
      }
    ]
  })

  tags = { Name = "${var.prefix}-s3-gateway-endpoint" }
}
```

**Step 2: Validar sintaxis**

```bash
cd networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform
terraform validate
```
Expected: `Success! The configuration is valid.`

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/endpoints.tf
git commit -m "feat(lab02): add S3 Gateway Endpoint (only for subnet-gw)"
```

---

## Task 5: s3.tf — Bucket de test

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/s3.tf`

**Step 1: Crear s3.tf**

```hcl
# =============================================================================
# s3.tf — Bucket S3 de test para generar tráfico
#
# Este bucket sirve como destino para medir si el tráfico pasa por NAT o no.
# Las EC2 subirán y descargarán objetos de este bucket.
# VPC Flow Logs capturará si esas operaciones pasaron por el NAT Gateway.
# =============================================================================

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "test" {
  # Nombre único usando account ID para evitar colisiones globales
  bucket = "${var.prefix}-lab-test-${data.aws_caller_identity.current.account_id}"

  # force_destroy permite borrar el bucket con objetos al hacer terraform destroy
  # En producción esto sería peligroso — aquí es necesario para cleanup limpio
  force_destroy = true

  tags = { Name = "${var.prefix}-test-bucket" }
}

# Bloquear acceso público — no necesitamos acceso desde internet
resource "aws_s3_bucket_public_access_block" "test" {
  bucket = aws_s3_bucket.test.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning deshabilitado — no necesitamos versiones en un bucket de test
resource "aws_s3_bucket_versioning" "test" {
  bucket = aws_s3_bucket.test.id
  versioning_configuration {
    status = "Disabled"
  }
}
```

**Step 2: Validar**

```bash
terraform validate
```
Expected: `Success! The configuration is valid.`

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/s3.tf
git commit -m "feat(lab02): add S3 test bucket"
```

---

## Task 6: security_groups.tf

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/security_groups.tf`

**Step 1: Crear security_groups.tf**

```hcl
# =============================================================================
# security_groups.tf — Sin puerto 22, acceso solo via SSM
#
# No abrimos SSH porque usamos AWS Systems Manager Session Manager.
# SSM funciona porque las EC2 tienen IAM Instance Profile con AmazonSSMManagedInstanceCore
# y alcanzan los endpoints SSM via NAT Gateway (ambas subnets tienen ruta 0.0.0.0/0 → NAT).
# =============================================================================

resource "aws_security_group" "ec2" {
  name        = "${var.prefix}-sg-ec2"
  description = "SG para EC2 de lab — sin SSH, acceso via SSM"
  vpc_id      = aws_vpc.main.id

  # Sin reglas de ingress — las EC2 no necesitan recibir tráfico entrante
  # SSM Session Manager inicia la conexión desde AWS (outbound desde EC2)

  egress {
    description = "Todo tráfico saliente permitido — necesario para SSM y S3"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-sg-ec2" }
}
```

**Step 2: Validar**

```bash
terraform validate
```
Expected: `Success! The configuration is valid.`

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/security_groups.tf
git commit -m "feat(lab02): add security groups (no SSH, SSM only)"
```

---

## Task 7: ec2.tf — Dos instancias con IAM para SSM + S3

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/ec2.tf`

**Step 1: Crear ec2.tf**

```hcl
# =============================================================================
# ec2.tf — Dos instancias EC2 para comparar rutas de tráfico S3
#
# EC2-A (subnet-gw-private): su tráfico S3 usa Gateway Endpoint
# EC2-B (subnet-nat-private): su tráfico S3 pasa por NAT Gateway
#
# Ambas usan SSM Session Manager para acceso shell sin SSH.
# Ambas tienen IAM role con permisos S3 para leer/escribir el bucket de test.
# =============================================================================

# ---------------------------------------------------------------------------
# IAM Role para EC2 — permisos SSM + S3
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name = "${var.prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.prefix}-ec2-role" }
}

# AmazonSSMManagedInstanceCore — permite SSM Session Manager
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Política inline S3 — permisos solo para el bucket de test
resource "aws_iam_role_policy" "s3_test" {
  name = "${var.prefix}-s3-test-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.test.arn,
          "${aws_s3_bucket.test.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------------------
# AMI más reciente de Amazon Linux 2023
# ---------------------------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ---------------------------------------------------------------------------
# EC2-A — subnet-gw-private (CON Gateway Endpoint)
# Su tráfico S3 NO pasará por NAT Gateway
# ---------------------------------------------------------------------------
resource "aws_instance" "ec2_gw" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.gw_private.id
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  # SSM Agent viene preinstalado en AL2023
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Etiquetar la instancia para identificarla en los logs
    export AWS_DEFAULT_REGION=${var.aws_region}
    echo "EC2-A: subnet con Gateway Endpoint S3" > /etc/lab-identity
  EOF
  )

  tags = { Name = "${var.prefix}-ec2-gw" }
}

# ---------------------------------------------------------------------------
# EC2-B — subnet-nat-private (SIN Gateway Endpoint)
# Su tráfico S3 PASARÁ por NAT Gateway
# ---------------------------------------------------------------------------
resource "aws_instance" "ec2_nat" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.nat_private.id
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    export AWS_DEFAULT_REGION=${var.aws_region}
    echo "EC2-B: subnet sin Gateway Endpoint (solo NAT GW)" > /etc/lab-identity
  EOF
  )

  tags = { Name = "${var.prefix}-ec2-nat" }
}
```

**Step 2: Validar**

```bash
terraform validate
```
Expected: `Success! The configuration is valid.`

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/ec2.tf
git commit -m "feat(lab02): add EC2 instances with SSM + S3 IAM role"
```

---

## Task 8: flow_logs.tf — VPC Flow Logs a CloudWatch

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/flow_logs.tf`

**Step 1: Crear flow_logs.tf**

```hcl
# =============================================================================
# flow_logs.tf — VPC Flow Logs para visualizar qué tráfico pasa por NAT GW
#
# Flow Logs captura metadatos de cada flujo de red: src IP, dst IP, bytes,
# acción (ACCEPT/REJECT), etc. NO captura el contenido del paquete.
#
# Qué buscaremos en los logs:
#   - Flujos donde srcaddr = IP de EC2-B Y dstaddr = IP pública del NAT GW
#     → esto indica tráfico S3 pasando por NAT
#   - Flujos donde srcaddr = IP de EC2-A Y dstaddr = prefix list S3
#     → esto va directo al Gateway Endpoint (distinto dstaddr)
#
# Formato de log: ${srcaddr} ${dstaddr} ${bytes} ${action}
# =============================================================================

# CloudWatch Log Group para los Flow Logs
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/flow-logs/${var.prefix}"
  retention_in_days = var.flow_log_retention_days # 1 día — solo para el lab

  tags = { Name = "${var.prefix}-flow-logs" }
}

# IAM Role para que VPC pueda escribir en CloudWatch
resource "aws_iam_role" "flow_logs" {
  name = "${var.prefix}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.prefix}-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

# Flow Log sobre la VPC completa (captura todos los ENIs, incluido NAT GW)
resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL" # ACCEPT + REJECT
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  # Formato custom para facilitar el parsing en validate.sh
  log_format = "$${srcaddr} $${dstaddr} $${bytes} $${action} $${protocol} $${srcport} $${dstport}"

  tags = { Name = "${var.prefix}-flow-log" }
}
```

**Step 2: Validar**

```bash
terraform validate
```
Expected: `Success! The configuration is valid.`

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/flow_logs.tf
git commit -m "feat(lab02): add VPC Flow Logs to CloudWatch"
```

---

## Task 9: outputs.tf

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/outputs.tf`

**Step 1: Crear outputs.tf**

```hcl
# =============================================================================
# outputs.tf — Valores para validación del lab
# =============================================================================

output "ec2_gw_instance_id" {
  description = "EC2-A (subnet con Gateway Endpoint) — usar con SSM"
  value       = aws_instance.ec2_gw.id
}

output "ec2_nat_instance_id" {
  description = "EC2-B (subnet sin Gateway Endpoint, solo NAT) — usar con SSM"
  value       = aws_instance.ec2_nat.id
}

output "ec2_gw_private_ip" {
  description = "IP privada de EC2-A"
  value       = aws_instance.ec2_gw.private_ip
}

output "ec2_nat_private_ip" {
  description = "IP privada de EC2-B"
  value       = aws_instance.ec2_nat.private_ip
}

output "nat_gateway_public_ip" {
  description = "IP pública del NAT Gateway — buscar esta IP en Flow Logs para ver qué tráfico pasa por NAT"
  value       = aws_eip.nat.public_ip
}

output "s3_bucket_name" {
  description = "Nombre del bucket S3 de test"
  value       = aws_s3_bucket.test.bucket
}

output "s3_endpoint_id" {
  description = "ID del Gateway Endpoint S3"
  value       = aws_vpc_endpoint.s3.id
}

output "cloudwatch_log_group" {
  description = "Nombre del Log Group de Flow Logs — para consultas manuales en CloudWatch"
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "summary" {
  description = "Resumen del lab y comandos de validación"
  value = <<-EOT

    ============================================================
    Lab02 — Gateway Endpoint vs NAT Gateway para S3
    ============================================================

    EC2-A (Gateway Endpoint): ${aws_instance.ec2_gw.id}  IP: ${aws_instance.ec2_gw.private_ip}
    EC2-B (NAT Gateway only): ${aws_instance.ec2_nat.id}  IP: ${aws_instance.ec2_nat.private_ip}
    NAT Gateway public IP   : ${aws_eip.nat.public_ip}
    S3 bucket               : ${aws_s3_bucket.test.bucket}
    Flow Logs               : ${aws_cloudwatch_log_group.flow_logs.name}

    ── Validación ──────────────────────────────────────────────
    ./validate.sh

    ── Cleanup ─────────────────────────────────────────────────
    cd terragrunt && terragrunt destroy
    ============================================================
  EOT
}
```

**Step 2: Validar**

```bash
terraform validate
```
Expected: `Success! The configuration is valid.`

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/terraform/outputs.tf
git commit -m "feat(lab02): add outputs.tf"
```

---

## Task 10: terragrunt.hcl

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/terragrunt/terragrunt.hcl`

**Step 1: Crear terragrunt.hcl**

```hcl
# =============================================================================
# Lab02 — Gateway Endpoint vs Interface Endpoint S3
# Terragrunt Configuration
#
# Backend: S3 con locking nativo (Terraform >= 1.10, sin DynamoDB)
# Mismo bucket de estado que lab01 — key diferente por lab
# =============================================================================

locals {
  aws_region = "eu-west-1"
  account_id = get_aws_account_id()
}

# ---------------------------------------------------------------------------
# Remote state — S3 native locking
# Usa el mismo bucket que lab01 (ya debe existir)
# Si no existe: aws s3 mb s3://networking-labs-tfstate-ACCOUNT-eu-west-1
# ---------------------------------------------------------------------------
remote_state {
  backend = "s3"

  config = {
    bucket       = "networking-labs-tfstate-${local.account_id}-${local.aws_region}"
    key          = "lab02-gateway-vs-interface-endpoint-s3/terraform.tfstate"
    region       = local.aws_region
    encrypt      = true
    use_lockfile = true # S3 native locking — requiere Terraform >= 1.10
  }

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------
generate "provider" {
  path      = "provider_override.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<EOF
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "${local.aws_region}"

  default_tags {
    tags = {
      Project   = "networking-labs"
      Lab       = "lab02-gateway-endpoint-s3"
      Concept   = "GatewayEndpoint-vs-NATGateway-S3"
      ManagedBy = "terragrunt"
    }
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Módulo Terraform
# ---------------------------------------------------------------------------
terraform {
  source = "../terraform"
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
inputs = {
  aws_region = local.aws_region
  prefix     = "lab02"

  vpc_cidr           = "10.0.0.0/16"
  public_subnet_cidr = "10.0.0.0/24"
  subnet_gw_cidr     = "10.0.1.0/24" # CON Gateway Endpoint
  subnet_nat_cidr    = "10.0.2.0/24" # SIN Gateway Endpoint

  az            = "eu-west-1a"
  instance_type = "t3.micro"

  flow_log_retention_days = 1
}
```

**Step 2: Verificar que Terragrunt puede leer la config**

```bash
cd networking/labs/lab02-gateway-vs-interface-endpoint-s3/terragrunt
terragrunt validate-inputs 2>&1 || echo "OK si dice 'no inputs defined' — normal antes del apply"
```

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/terragrunt/terragrunt.hcl
git commit -m "feat(lab02): add terragrunt.hcl with S3 native locking"
```

---

## Task 11: validate.sh

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/validate.sh`

**Step 1: Crear validate.sh**

```bash
#!/usr/bin/env bash
# =============================================================================
# validate.sh — Lab 02: Gateway Endpoint vs NAT Gateway para S3
#
# Qué hace este script:
#   1. Lee outputs de Terraform para obtener IDs/IPs necesarios
#   2. Desde EC2-A (subnet-gw): sube un objeto de 5MB a S3
#   3. Desde EC2-B (subnet-nat): sube un objeto de 5MB a S3
#   4. Espera 90s para que los Flow Logs lleguen a CloudWatch
#   5. Consulta CloudWatch Insights para ver qué tráfico pasó por NAT GW
#   6. Muestra resultado: EC2-A → 0 bytes via NAT, EC2-B → ~5MB via NAT
#
# Pre-requisitos:
#   - terragrunt apply completado
#   - aws CLI configurada con perfil de lab
#   - jq instalado (apt-get install jq / brew install jq)
# =============================================================================

set -euo pipefail

REGION="eu-west-1"
TERRAGRUNT_DIR="$(dirname "$0")/terragrunt"

echo "============================================================"
echo "Lab 02 — Validación: Gateway Endpoint vs NAT Gateway S3"
echo "============================================================"

# Leer outputs de Terraform
echo ""
echo "[1/6] Leyendo outputs de Terraform..."
cd "$TERRAGRUNT_DIR"

EC2_GW_ID=$(terragrunt output -raw ec2_gw_instance_id 2>/dev/null)
EC2_NAT_ID=$(terragrunt output -raw ec2_nat_instance_id 2>/dev/null)
EC2_GW_IP=$(terragrunt output -raw ec2_gw_private_ip 2>/dev/null)
EC2_NAT_IP=$(terragrunt output -raw ec2_nat_private_ip 2>/dev/null)
NAT_GW_IP=$(terragrunt output -raw nat_gateway_public_ip 2>/dev/null)
BUCKET=$(terragrunt output -raw s3_bucket_name 2>/dev/null)
LOG_GROUP=$(terragrunt output -raw cloudwatch_log_group 2>/dev/null)

echo "  EC2-A (Gateway Endpoint): $EC2_GW_ID  IP: $EC2_GW_IP"
echo "  EC2-B (NAT only):         $EC2_NAT_ID  IP: $EC2_NAT_IP"
echo "  NAT Gateway IP:           $NAT_GW_IP"
echo "  S3 Bucket:                $BUCKET"
echo "  Flow Logs:                $LOG_GROUP"

# Esperar a que SSM esté disponible en ambas instancias
echo ""
echo "[2/6] Esperando disponibilidad SSM (hasta 120s)..."
for INSTANCE_ID in "$EC2_GW_ID" "$EC2_NAT_ID"; do
  for i in $(seq 1 24); do
    STATUS=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
      --region "$REGION" \
      --query "InstanceInformationList[0].PingStatus" \
      --output text 2>/dev/null || echo "None")
    if [ "$STATUS" = "Online" ]; then
      echo "  ✓ $INSTANCE_ID: Online"
      break
    fi
    echo "  ... $INSTANCE_ID: $STATUS (intento $i/24)"
    sleep 5
  done
done

# Generar tráfico S3 desde EC2-A (Gateway Endpoint)
echo ""
echo "[3/6] EC2-A → S3 via Gateway Endpoint (generando 5MB de tráfico)..."
aws ssm send-command \
  --instance-ids "$EC2_GW_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'dd if=/dev/urandom bs=1M count=5 2>/dev/null | aws s3 cp - s3://$BUCKET/test-from-ec2-gw.bin --region $REGION',
    'echo EXIT_CODE:\$?'
  ]" \
  --region "$REGION" \
  --output text \
  --query "Command.CommandId" > /tmp/cmd_gw_id.txt

CMD_GW_ID=$(cat /tmp/cmd_gw_id.txt)
echo "  Command ID: $CMD_GW_ID"

# Generar tráfico S3 desde EC2-B (solo NAT)
echo ""
echo "[4/6] EC2-B → S3 via NAT Gateway (generando 5MB de tráfico)..."
aws ssm send-command \
  --instance-ids "$EC2_NAT_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'dd if=/dev/urandom bs=1M count=5 2>/dev/null | aws s3 cp - s3://$BUCKET/test-from-ec2-nat.bin --region $REGION',
    'echo EXIT_CODE:\$?'
  ]" \
  --region "$REGION" \
  --output text \
  --query "Command.CommandId" > /tmp/cmd_nat_id.txt

CMD_NAT_ID=$(cat /tmp/cmd_nat_id.txt)
echo "  Command ID: $CMD_NAT_ID"

# Esperar resultados de los comandos
echo ""
echo "[5/6] Esperando resultado de los comandos SSM..."
sleep 30
for CMD_ID in "$CMD_GW_ID" "$CMD_NAT_ID"; do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id $([ "$CMD_ID" = "$CMD_GW_ID" ] && echo "$EC2_GW_ID" || echo "$EC2_NAT_ID") \
    --region "$REGION" \
    --query "Status" --output text 2>/dev/null || echo "Unknown")
  echo "  Comando $CMD_ID: $STATUS"
done

# Esperar a que los Flow Logs lleguen a CloudWatch
echo ""
echo "[6/6] Esperando Flow Logs en CloudWatch (90s)..."
sleep 90

# Consultar CloudWatch Logs Insights
# Buscamos flujos donde el destino es la IP pública del NAT Gateway
# (tráfico que pasó DESDE la VPC HACIA el NAT GW hacia internet)
echo ""
echo "============================================================"
echo "RESULTADOS — Tráfico S3 via NAT Gateway"
echo "============================================================"
echo ""
echo "Consultando CloudWatch Logs Insights..."
echo "(Buscando flujos con destino $NAT_GW_IP — IP del NAT Gateway)"
echo ""

QUERY_ID=$(aws logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time $(date -d '10 minutes ago' +%s 2>/dev/null || date -v-10M +%s) \
  --end-time $(date +%s) \
  --query-string "
    fields @timestamp, srcaddr, dstaddr, bytes, action
    | filter dstaddr = \"$NAT_GW_IP\"
    | filter srcaddr = \"$EC2_GW_IP\" or srcaddr = \"$EC2_NAT_IP\"
    | stats sum(bytes) as total_bytes by srcaddr
  " \
  --region "$REGION" \
  --query "queryId" \
  --output text)

echo "Query ID: $QUERY_ID"
sleep 10

RESULTS=$(aws logs get-query-results \
  --query-id "$QUERY_ID" \
  --region "$REGION" \
  --output json)

echo ""
echo "Bytes de tráfico que pasaron por NAT Gateway:"
echo "$RESULTS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('results', [])
if not results:
    print('  (Sin datos aún — espera más tiempo o verifica que los comandos SSM completaron)')
for row in results:
    row_dict = {f['field']: f['value'] for f in row}
    src = row_dict.get('srcaddr', '?')
    bytes_val = int(row_dict.get('total_bytes', 0))
    label = 'EC2-A (Gateway Endpoint)' if src == '$EC2_GW_IP' else 'EC2-B (NAT only)'
    print(f'  {label} ({src}): {bytes_val:,} bytes via NAT')
"

echo ""
echo "CONCLUSIÓN:"
echo "  EC2-A (Gateway Endpoint) → tráfico S3 NO debería aparecer via NAT"
echo "  EC2-B (NAT only)         → tráfico S3 SÍ aparece via NAT (~5MB)"
echo ""
echo "Verifica también en la consola AWS:"
echo "  CloudWatch → Log Insights → $LOG_GROUP"
echo ""
echo "Cleanup:"
echo "  cd terragrunt && terragrunt destroy"
echo "============================================================"
```

**Step 2: Dar permisos de ejecución**

```bash
chmod +x networking/labs/lab02-gateway-vs-interface-endpoint-s3/validate.sh
```

**Step 3: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/validate.sh
git commit -m "feat(lab02): add validate.sh"
```

---

## Task 12: README.md

**Files:**
- Create: `networking/labs/lab02-gateway-vs-interface-endpoint-s3/README.md`

**Step 1: Crear README.md**

````markdown
# Lab 02 — Gateway Endpoint vs NAT Gateway para S3

**Concepto:** Demostrar con VPC Flow Logs que el tráfico S3 desde una subnet con Gateway Endpoint no pasa por NAT Gateway, mientras que sin él sí lo hace.

**Coste estimado:** < $0.10 si se destruye en < 1h
**Stack:** Terraform >= 1.10 · Terragrunt · eu-west-1

---

## Diagrama

```
                         ┌─────────────────────────────────────────────────┐
                         │  VPC 10.0.0.0/16                                │
                         │                                                  │
                         │  ┌─────────────────────┐                        │
                         │  │  subnet-public       │                        │
                         │  │  10.0.0.0/24         │                        │
                         │  │  [NAT Gateway] ──────┼──── IGW ──── Internet  │
                         │  └─────────────────────┘                        │
                         │                                                  │
  S3 Gateway Endpoint    │  ┌─────────────────────┐                        │
  (interno AWS, gratis)  │  │  subnet-gw-private   │                        │
  ◄──────────────────────┼──│  10.0.1.0/24         │                        │
                         │  │  [EC2-A]             │                        │
                         │  │  Route: S3 → GW EP   │                        │
                         │  │         0/0 → NAT    │                        │
                         │  └─────────────────────┘                        │
                         │                                                  │
                         │  ┌─────────────────────┐                        │
                         │  │  subnet-nat-private  │                        │
                         │  │  10.0.2.0/24         │                        │
                         │  │  [EC2-B]             │                        │
                         │  │  Route: 0/0 → NAT ───┼── NAT GW ── IGW ─► S3 │
                         │  └─────────────────────┘                        │
                         │                                                  │
                         │  VPC Flow Logs → CloudWatch                      │
                         └─────────────────────────────────────────────────┘
```

**EC2-A → S3:** tráfico va por el Gateway Endpoint (sin pasar por NAT)
**EC2-B → S3:** tráfico va 0.0.0.0/0 → NAT GW → IGW → IP pública S3

---

## Por qué importa esto

| | Gateway Endpoint | Sin Gateway Endpoint (NAT) |
|--|--|--|
| Coste transferencia | **$0.00** | ~$0.045/GB via NAT |
| Latencia | Menor (ruta interna AWS) | Mayor (sale a internet y vuelve) |
| Disponibilidad desde on-prem | No | Sí (via Direct Connect + Interface EP) |
| Servicios soportados | Solo S3 y DynamoDB | Todos |

---

## Despliegue

### Pre-requisitos

```bash
# Terraform >= 1.10 y Terragrunt instalados
terraform version   # >= 1.10.0
terragrunt version

# Bucket de estado (usar mismo que lab01, ya debería existir)
aws s3 ls s3://networking-labs-tfstate-$(aws sts get-caller-identity --query Account --output text)-eu-west-1

# Si no existe:
aws s3 mb s3://networking-labs-tfstate-$(aws sts get-caller-identity --query Account --output text)-eu-west-1 \
  --region eu-west-1
```

### Desplegar

```bash
cd terragrunt
terragrunt init
terragrunt plan    # Revisar: 1 VPC, 3 subnets, 1 NAT GW, 1 S3 EP, 2 EC2, Flow Logs
terragrunt apply
```

### Validar

```bash
cd ..
./validate.sh
```

El script:
1. Lee outputs (IDs, IPs, nombre bucket)
2. Sube 5MB a S3 desde cada EC2 via SSM Run Command
3. Espera 90s para que los Flow Logs lleguen a CloudWatch
4. Consulta CloudWatch Logs Insights
5. Muestra bytes que pasaron por NAT GW por cada EC2

**Resultado esperado:**
```
EC2-A (Gateway Endpoint) (10.0.1.x): 0 bytes via NAT
EC2-B (NAT only)         (10.0.2.x): ~5,242,880 bytes via NAT
```

### Verificación manual en consola

1. **CloudWatch → Log Insights** → seleccionar `/aws/vpc/flow-logs/lab02`
2. Ejecutar query:
```
fields srcaddr, dstaddr, bytes, action
| filter dstaddr = "<NAT_GW_IP>"
| stats sum(bytes) as total by srcaddr
```

### Destruir

```bash
cd terragrunt
terragrunt destroy
```

**Recursos con coste por hora:**
- NAT Gateway: $0.045/h — destruir cuando termines

---

## Archivos

```
lab02-gateway-vs-interface-endpoint-s3/
├── README.md              ← Este fichero
├── validate.sh            ← Script de validación automática
├── terraform/
│   ├── vpc.tf             ← VPC, subnets, IGW, NAT GW, route tables
│   ├── endpoints.tf       ← S3 Gateway Endpoint (solo subnet-gw)
│   ├── ec2.tf             ← EC2-A y EC2-B con IAM SSM+S3
│   ├── flow_logs.tf       ← VPC Flow Logs → CloudWatch
│   ├── s3.tf              ← Bucket de test
│   ├── security_groups.tf ← Sin SSH, solo SSM
│   ├── variables.tf
│   └── outputs.tf
└── terragrunt/
    └── terragrunt.hcl     ← Backend S3 native locking
```
````

**Step 2: Commit**

```bash
git add networking/labs/lab02-gateway-vs-interface-endpoint-s3/README.md
git commit -m "docs(lab02): add README with architecture diagram and deploy steps"
```

---

## Task 13: Deploy y validación final

**Step 1: Init y plan**

```bash
cd networking/labs/lab02-gateway-vs-interface-endpoint-s3/terragrunt
terragrunt init
terragrunt plan
```

Expected: plan sin errores mostrando ~20-25 recursos a crear.

**Step 2: Apply**

```bash
terragrunt apply
```

Expected: `Apply complete! Resources: ~22 added, 0 changed, 0 destroyed.`

**Step 3: Validar**

```bash
cd ..
./validate.sh
```

Expected:
```
EC2-A (Gateway Endpoint) (10.0.1.x): 0 bytes via NAT
EC2-B (NAT only)         (10.0.2.x): ~5,242,880 bytes via NAT
```

**Step 4: Destruir**

```bash
cd terragrunt
terragrunt destroy
```

Expected: `Destroy complete! Resources: 22 destroyed.`

**Step 5: Commit final**

```bash
git add -A
git commit -m "feat(lab02): complete Gateway Endpoint vs NAT Gateway S3 lab"
```

---

*DATP-2028 · Lab 02 Implementation Plan · 2026-03-14*
