# _modules/networking/vpcs.tf
#
# 3 VPCs con CIDRs distintos (requisito para VPC Peering).
# Cada VPC tiene una subnet privada donde vive la EC2.
# VPC-B tiene además una subnet pública con IGW para el NAT GW
# que da acceso a internet a SSM Agent en los tres nodos.

locals {
  vpcs = {
    a = { cidr = "10.1.0.0/16", private_cidr = "10.1.1.0/24" }
    b = { cidr = "10.2.0.0/16", private_cidr = "10.2.1.0/24", public_cidr = "10.2.0.0/24" }
    c = { cidr = "10.3.0.0/16", private_cidr = "10.3.1.0/24" }
  }
}

# VPC-A
resource "aws_vpc" "a" {
  cidr_block           = local.vpcs.a.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "lab04-vpc-a-${var.environment}" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.a.id
  cidr_block        = local.vpcs.a.private_cidr
  availability_zone = "${var.region}a"
  tags = { Name = "lab04-subnet-private-a-${var.environment}" }
}

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.a.id
  tags   = { Name = "lab04-rt-private-a-${var.environment}" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

# VPC-B (hub de peering y salida a internet para SSM)
resource "aws_vpc" "b" {
  cidr_block           = local.vpcs.b.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "lab04-vpc-b-${var.environment}" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.b.id
  cidr_block        = local.vpcs.b.private_cidr
  availability_zone = "${var.region}a"
  tags = { Name = "lab04-subnet-private-b-${var.environment}" }
}

resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.b.id
  cidr_block        = local.vpcs.b.public_cidr
  availability_zone = "${var.region}a"
  tags = { Name = "lab04-subnet-public-b-${var.environment}" }
}

resource "aws_internet_gateway" "b" {
  vpc_id = aws_vpc.b.id
  tags   = { Name = "lab04-igw-b-${var.environment}" }
}

resource "aws_route_table" "public_b" {
  vpc_id = aws_vpc.b.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.b.id
  }
  tags = { Name = "lab04-rt-public-b-${var.environment}" }
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_b.id
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.b.id
  tags   = { Name = "lab04-rt-private-b-${var.environment}" }
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}

# VPC-C
resource "aws_vpc" "c" {
  cidr_block           = local.vpcs.c.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "lab04-vpc-c-${var.environment}" }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.c.id
  cidr_block        = local.vpcs.c.private_cidr
  availability_zone = "${var.region}a"
  tags = { Name = "lab04-subnet-private-c-${var.environment}" }
}

resource "aws_route_table" "private_c" {
  vpc_id = aws_vpc.c.id
  tags   = { Name = "lab04-rt-private-c-${var.environment}" }
}

resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private_c.id
}
