# _modules/networking/vpc.tf
#
# VPC con 2 subnets públicas (para los NAT GWs) y 2 subnets privadas
# (donde viven las EC2). Una subnet por AZ para poder demostrar el fallo zonal.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Usamos las dos primeras AZs disponibles en la región
  az_a = data.aws_availability_zones.available.names[0]  # eu-west-1a
  az_b = data.aws_availability_zones.available.names[1]  # eu-west-1b
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_vpc
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "lab03-vpc-${var.environment}"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "lab03-igw-${var.environment}"
  }
}

# Subnets públicas — aquí viven los NAT Gateways (requieren subnet pública con IGW)
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_vpc, 8, count.index + 1)  # 10.0.1.0/24, 10.0.2.0/24
  availability_zone = count.index == 0 ? local.az_a : local.az_b

  tags = {
    Name = "lab03-subnet-public-${count.index == 0 ? "a" : "b"}-${var.environment}"
  }
}

# Subnets privadas — aquí viven las EC2, sin acceso directo a internet
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_vpc, 8, count.index + 11)  # 10.0.11.0/24, 10.0.12.0/24
  availability_zone = count.index == 0 ? local.az_a : local.az_b

  tags = {
    Name = "lab03-subnet-private-${count.index == 0 ? "a" : "b"}-${var.environment}"
  }
}

# Route table pública — ambas subnets públicas usan la misma (solo necesitan IGW)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "lab03-rt-public-${var.environment}"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
