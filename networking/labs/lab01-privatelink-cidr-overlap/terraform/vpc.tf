# =============================================================================
# vpc.tf — VPC-A (consumer) y VPC-B (provider)
#
# PUNTO CLAVE: Ambas VPCs tienen el mismo CIDR (10.0.0.0/16).
# Esto hace IMPOSIBLE el VPC Peering — AWS rechaza el peering con:
#   "VPC CIDR overlaps with peer VPC CIDR"
#
# VPC Peering funciona añadiendo rutas estáticas en las tablas de rutas:
#   10.0.0.0/16 → pcx-xxxxx
# Con dos VPCs con el mismo CIDR, esta ruta es ambigua y AWS la rechaza.
#
# PrivateLink no necesita rutas IP entre VPCs — el consumidor solo necesita
# alcanzar la ENI del Interface Endpoint en su propia VPC.
# =============================================================================

# ---------------------------------------------------------------------------
# VPC-A — Consumer
# EC2 consumer se conecta al servicio de VPC-B via Interface Endpoint
# ---------------------------------------------------------------------------
resource "aws_vpc" "a" {
  cidr_block = var.vpc_cidr

  # Necesario para que las Interface Endpoints tengan hostnames DNS resolvibles
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.prefix}-vpc-a-consumer" }
}

# Subnet pública en VPC-A — el consumer EC2 vive aquí
# "Pública" porque tiene ruta al IGW → permite que el SSM agent
# contacte con los endpoints de SSM via internet (sin VPC endpoints)
resource "aws_subnet" "a" {
  vpc_id                  = aws_vpc.a.id
  cidr_block              = var.vpc_a_subnet_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = true # IP pública para que SSM funcione sin VPC endpoints

  tags = { Name = "${var.prefix}-subnet-a-public" }
}

# Internet Gateway para VPC-A
# Necesario para: (1) SSM agent contacte AWS APIs, (2) acceso a AL2023 repos
resource "aws_internet_gateway" "a" {
  vpc_id = aws_vpc.a.id
  tags   = { Name = "${var.prefix}-igw-a" }
}

# Route table para la subnet pública de VPC-A
resource "aws_route_table" "a_public" {
  vpc_id = aws_vpc.a.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.a.id
  }

  tags = { Name = "${var.prefix}-rt-a-public" }
}

resource "aws_route_table_association" "a_public" {
  subnet_id      = aws_subnet.a.id
  route_table_id = aws_route_table.a_public.id
}

# ---------------------------------------------------------------------------
# VPC-B — Provider
# Contiene el NLB y el EC2 que sirve el HTTP service
# ---------------------------------------------------------------------------
resource "aws_vpc" "b" {
  # MISMO CIDR que VPC-A — esto es lo que hace imposible el VPC Peering
  cidr_block = var.vpc_cidr

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.prefix}-vpc-b-provider" }
}

# Subnet privada en VPC-B — NLB y provider EC2 viven aquí
# "Privada" porque no necesita acceso directo a internet:
#   - El NLB recibe tráfico via PrivateLink (no desde internet)
#   - El provider EC2 no requiere acceso saliente para el lab
resource "aws_subnet" "b" {
  vpc_id            = aws_vpc.b.id
  cidr_block        = var.vpc_b_subnet_cidr
  availability_zone = var.az

  tags = { Name = "${var.prefix}-subnet-b-private" }
}

# ---------------------------------------------------------------------------
# DEMOSTRACIÓN: Por qué VPC Peering fallaría aquí
#
# Si descomentas este bloque, Terraform fallará con:
#   "InvalidVpcPeeringConnectionID.Overlapping: CidrBlock overlaps with peer"
#
# resource "aws_vpc_peering_connection" "demo_fail" {
#   vpc_id      = aws_vpc.a.id
#   peer_vpc_id = aws_vpc.b.id
#   auto_accept = true
#
#   # ERROR: Both VPCs have CIDR 10.0.0.0/16 — AWS rejects this peering.
#   # La tabla de rutas no puede tener dos entradas para 10.0.0.0/16
#   # apuntando a destinos distintos.
# }
# ---------------------------------------------------------------------------
