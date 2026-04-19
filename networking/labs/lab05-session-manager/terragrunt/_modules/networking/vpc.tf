# _modules/networking/vpc.tf
#
# VPC con una subnet privada (donde vive la EC2) siempre presente.
# Subnet pública e IGW solo en modo "internet" — en modo "endpoints"
# no hace falta salida a internet en absoluto.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true  # necesario para que los Interface Endpoints resuelvan por DNS
  enable_dns_support   = true  # idem — ambos flags obligatorios para endpoints privados

  tags = { Name = "lab05-vpc-${var.environment}" }
}

# Subnet privada — aquí vive la EC2 en ambos modos
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)  # 10.0.1.0/24
  availability_zone = "${var.region}a"

  tags = { Name = "lab05-subnet-private-${var.environment}" }
}

# Subnet pública — solo en modo "internet" (necesaria para el NAT GW)
resource "aws_subnet" "public" {
  count             = var.ssm_mode == "internet" ? 1 : 0
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)  # 10.0.0.0/24
  availability_zone = "${var.region}a"

  tags = { Name = "lab05-subnet-public-${var.environment}" }
}

# IGW — solo en modo "internet"
resource "aws_internet_gateway" "this" {
  count  = var.ssm_mode == "internet" ? 1 : 0
  vpc_id = aws_vpc.this.id

  tags = { Name = "lab05-igw-${var.environment}" }
}

# Route table pública — solo en modo "internet"
resource "aws_route_table" "public" {
  count  = var.ssm_mode == "internet" ? 1 : 0
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = { Name = "lab05-rt-public-${var.environment}" }
}

resource "aws_route_table_association" "public" {
  count          = var.ssm_mode == "internet" ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

# Route table privada — siempre presente
# En modo "internet" tendrá la ruta 0.0.0.0/0 → NAT GW (gestionada en internet_access.tf)
# En modo "endpoints" NO tiene ruta por defecto → zero internet
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "lab05-rt-private-${var.environment}" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
