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
