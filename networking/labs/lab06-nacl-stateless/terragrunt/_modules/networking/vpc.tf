# _modules/networking/vpc.tf

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "lab06-vpc-${var.environment}" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "lab06-igw-${var.environment}" }
}

# Subnet publica — ALB
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)  # 10.0.0.0/24
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "lab06-subnet-public-${var.environment}" }
}

# Segunda subnet publica en otra AZ — necesaria para el ALB (minimo 2 AZs)
resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 2)  # 10.0.2.0/24
  availability_zone = data.aws_availability_zones.available.names[1]
  tags              = { Name = "lab06-subnet-public-b-${var.environment}" }
}

# Subnet privada — EC2 con nginx
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)  # 10.0.1.0/24
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "lab06-subnet-private-${var.environment}" }
}

# Route table publica
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "lab06-rt-public-${var.environment}" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# Route table privada — sin ruta por defecto (se anade en ec2.tf via NAT GW)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "lab06-rt-private-${var.environment}" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
